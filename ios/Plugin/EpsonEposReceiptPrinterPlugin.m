#import "EpsonEposReceiptPrinterPlugin.h"
#import <Capacitor/CAPBridgedJSTypes.h>  // ObjC accessors + resolve/reject (not in the Capacitor.h umbrella)
#import "ePOS2.h"

/*
    ePOS2 raw-mode transport (analysis plan D-P2). Receipts are rendered to
    ESC/POS app-side by ReceiptPrinterEncoder; this plugin only ships those
    bytes through the SDK's addCommand -> sendData raw pass-through. It never
    uses the ePOS2 document builder (addText/addImage/…) — the encoder is the
    single source of receipt truth on every platform.

    Threading: Capacitor dispatches plugin method bodies on the bridge's serial
    background queue (CapacitorBridge.dispatchQueue), so the blocking SDK calls
    (connect / sendData / getStatus) already run off the main thread — same
    reliance on Capacitor's threading as the Star twin. Discovery pass
    scheduling is marshalled onto the main queue; the discovery result dict is
    guarded with @synchronized because onDiscovery arrives on an SDK thread.

    No auto-reconnect (Star parity): a dropped connection surfaces as a
    `disconnected` event; the app drives reconnect().
*/
@interface EpsonEposReceiptPrinterPlugin () <Epos2DiscoveryDelegate, Epos2PtrReceiveDelegate, Epos2ConnectionDelegate>

// The single held connection (D2) and what it is bound to.
@property (nonatomic, strong) Epos2Printer *printer;
@property (nonatomic, copy) NSString *boundTarget;      // the ePOS2 target string, keys idempotency
@property (nonatomic, copy) NSString *boundModel;        // discovered/persisted model name
@property (nonatomic, copy) NSString *boundInterface;    // js-facing interface string

// One-shot discovery state.
@property (nonatomic, strong) CAPPluginCall *discoveryCall;
@property (nonatomic, strong) NSMutableDictionary<NSString *, Epos2DeviceInfo *> *discoveredDevices;
@property (nonatomic, strong) NSArray<NSNumber *> *discoveryPasses;   // ordered Epos2PortType values
@property (nonatomic, assign) NSUInteger discoveryIndex;
@property (nonatomic, assign) long discoveryPassMs;

// Last onPtrReceive result — internal telemetry only; resolve() never blocks on it.
@property (nonatomic, assign) int lastReceiveCode;

@end

@implementation EpsonEposReceiptPrinterPlugin

#pragma mark - isAvailable / ensurePermissions

/* The ePOS2 SDK is compiled into every iOS build, so the native plugin is
   always present. Whether any Epson device is reachable is discover()'s job. */
- (void)isAvailable:(CAPPluginCall *)call {
    [call resolve:@{ @"available": @YES }];
}

/* iOS needs no runtime permission call — classic-BT (MFi) and BLE are gated by
   the Info.plist usage strings / UISupportedExternalAccessoryProtocols, not a
   Capacitor prompt. The JS class only routes here on non-iOS via
   checkPermissions/requestPermissions; on iOS it short-circuits. Resolve
   granted for a direct caller. */
- (void)ensurePermissions:(CAPPluginCall *)call {
    [call resolve:@{ @"granted": @YES }];
}

#pragma mark - discover

/*
    One-shot discovery across the requested interfaces (D3). Resolves
    { devices: [{ interface, identifier, model }] } where identifier is the
    ePOS2 target string ("BT:…", "TCP:…", …) and interface is derived from its
    prefix.

    Epos2FilterOption.portType is a SINGLE enum value (not a bitmask), so a set
    of interfaces cannot be expressed in one pass. Strategy:
      - the JS default (all four supported port types) collapses to ONE
        EPOS2_PORTTYPE_ALL pass over the full timeout;
      - any strict subset (e.g. Salonhub's MVP ['bluetooth','bluetoothLE','usb']
        with 'lan' omitted) runs SEQUENTIAL passes, one port type each, splitting
        the timeout budget, deduped by target.
*/
- (void)discover:(CAPPluginCall *)call {
    id rawInterfaces = call.options[@"interfaces"];
    NSArray *names = [rawInterfaces isKindOfClass:[NSArray class]]
        ? (NSArray *)rawInterfaces
        : @[ @"lan", @"bluetooth", @"bluetoothLE", @"usb" ];

    long timeout = [[call getNumber:@"timeout" defaultValue:@5000] longValue];
    if (timeout <= 0) {
        timeout = 5000;
    }

    NSMutableArray<NSNumber *> *portTypes = [NSMutableArray array];
    NSMutableSet<NSNumber *> *requested = [NSMutableSet set];
    for (id name in names) {
        if (![name isKindOfClass:[NSString class]]) {
            continue;
        }
        int portType = [EpsonEposReceiptPrinterPlugin portTypeFromInterface:(NSString *)name];
        if (portType < 0) {
            continue;
        }
        NSNumber *boxed = @(portType);
        if (![requested containsObject:boxed]) {
            [requested addObject:boxed];
            [portTypes addObject:boxed];
        }
    }

    if (portTypes.count == 0) {
        [call reject:@"no_valid_interfaces" :nil :nil :nil];
        return;
    }

    // Collapse to a single ALL pass only when every supported port type is asked
    // for; a strict subset must be honoured per-type (ALL would leak omitted
    // interfaces such as 'lan').
    NSSet *allSupported = [NSSet setWithArray:@[
        @(EPOS2_PORTTYPE_TCP), @(EPOS2_PORTTYPE_BLUETOOTH),
        @(EPOS2_PORTTYPE_USB), @(EPOS2_PORTTYPE_BLUETOOTH_LE)
    ]];
    NSArray<NSNumber *> *passes = [requested isEqualToSet:allSupported]
        ? @[ @(EPOS2_PORTTYPE_ALL) ]
        : [portTypes copy];

    long perPass = timeout / (long)passes.count;
    if (perPass < 500) {
        perPass = 500;   // floor so slow BLE inquiry still has a chance per pass
    }

    @synchronized (self) {
        self.discoveryCall = call;
        self.discoveredDevices = [NSMutableDictionary dictionary];
        self.discoveryPasses = passes;
        self.discoveryIndex = 0;
        self.discoveryPassMs = perPass;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self runNextDiscoveryPass];
    });
}

- (void)runNextDiscoveryPass {
    NSArray<NSNumber *> *passes;
    NSUInteger index;
    long perPass;
    @synchronized (self) {
        passes = self.discoveryPasses;
        index = self.discoveryIndex;
        perPass = self.discoveryPassMs;
    }
    if (passes == nil) {
        return;   // discovery was torn down
    }
    if (index >= passes.count) {
        [self finishDiscovery];
        return;
    }

    int portType = passes[index].intValue;

    Epos2FilterOption *filter = [[Epos2FilterOption alloc] init];
    [filter setPortType:portType];
    [filter setDeviceModel:EPOS2_MODEL_ALL];
    [filter setDeviceType:EPOS2_TYPE_PRINTER];   // this is a receipt-printer plugin (D-P6)

    [Epos2Discovery stop];   // ensure no prior run is still active
    (void)[Epos2Discovery start:filter delegate:self];   // errors (e.g. already-running) fall through; the pass still elapses

    @synchronized (self) {
        self.discoveryIndex = index + 1;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(perPass * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [Epos2Discovery stop];
        [self runNextDiscoveryPass];
    });
}

- (void)finishDiscovery {
    [Epos2Discovery stop];

    CAPPluginCall *call;
    NSMutableArray *devices = [NSMutableArray array];
    @synchronized (self) {
        call = self.discoveryCall;
        for (Epos2DeviceInfo *info in self.discoveredDevices.allValues) {
            NSString *target = info.target ?: @"";
            [devices addObject:@{
                @"interface": [EpsonEposReceiptPrinterPlugin interfaceFromTarget:target],
                @"identifier": target,
                @"model": info.deviceName ?: @""
            }];
        }
        self.discoveryCall = nil;
        self.discoveredDevices = nil;
        self.discoveryPasses = nil;
        self.discoveryIndex = 0;
    }

    if (call != nil) {
        [call resolve:@{ @"devices": devices }];
    }
}

#pragma mark - Epos2DiscoveryDelegate

- (void)onDiscovery:(Epos2DeviceInfo *)deviceInfo {
    if (deviceInfo == nil) {
        return;
    }
    NSString *target = deviceInfo.target;
    if (target.length == 0) {
        return;
    }
    @synchronized (self) {
        if (self.discoveredDevices == nil) {
            return;
        }
        self.discoveredDevices[target] = deviceInfo;   // dedupe by target across passes
    }
}

#pragma mark - connect

/*
    Open the single native connection to { interface, identifier, model? }
    (D2). Single-connection lifecycle:
      - already connected to the SAME target  -> no-op (R6 twin)
      - connected to a DIFFERENT target        -> disconnect it first, then open
    Emits `connected` on success.
*/
- (void)connect:(CAPPluginCall *)call {
    NSString *identifier = [call getString:@"identifier" defaultValue:nil];
    NSString *interfaceName = [call getString:@"interface" defaultValue:nil];
    NSString *model = [call getString:@"model" defaultValue:nil];

    if (identifier.length == 0) {
        // ePOS2 has no FIRST_FOUND-device concept — a concrete target is required.
        [call reject:@"no_target" :nil :nil :nil];
        return;
    }

    // Same-target no-op.
    if (self.printer != nil && [self.boundTarget isEqualToString:identifier]) {
        [call resolve];
        return;
    }

    // Different target: drop the current connection first.
    if (self.printer != nil) {
        [self teardownPrinter];
    }

    // Map the model name to a printer series. Raw addCommand pass-through does
    // NOT depend on the series builder logic, so an unrecognized model falling
    // back to the generic T88 series is harmless (D-P2).
    int series = [EpsonEposReceiptPrinterPlugin printerSeriesFromModel:model];

    Epos2Printer *printer = [[Epos2Printer alloc] initWithPrinterSeries:series lang:EPOS2_MODEL_ANK];
    if (printer == nil) {
        [call reject:@"init_failed" :nil :nil :nil];
        return;
    }
    [printer setReceiveEventDelegate:self];      // print-result status (telemetry only)
    [printer setConnectionEventDelegate:self];   // connection-drop detection

    int result = [printer connect:identifier timeout:EPOS2_PARAM_DEFAULT];
    if (result == EPOS2_SUCCESS) {
        self.printer = printer;
        self.boundTarget = identifier;
        self.boundModel = model;
        self.boundInterface = interfaceName.length > 0
            ? interfaceName
            : [EpsonEposReceiptPrinterPlugin interfaceFromTarget:identifier];
        [self notifyListeners:@"connected" data:@{}];
        [call resolve];
    } else {
        [printer setReceiveEventDelegate:nil];
        [printer setConnectionEventDelegate:nil];
        [call reject:[EpsonEposReceiptPrinterPlugin errorName:result] :nil :nil :nil];
    }
}

#pragma mark - disconnect

- (void)disconnect:(CAPPluginCall *)call {
    if (self.printer == nil) {
        [call resolve];
        return;
    }
    [self teardownPrinter];
    [call resolve];
}

/* Clear delegates, disconnect, clear the command buffer, release the printer. */
- (void)teardownPrinter {
    Epos2Printer *printer = self.printer;
    if (printer == nil) {
        return;
    }
    [printer setReceiveEventDelegate:nil];
    [printer setConnectionEventDelegate:nil];
    [printer disconnect];
    [printer clearCommandBuffer];

    self.printer = nil;
    self.boundTarget = nil;
    self.boundModel = nil;
    self.boundInterface = nil;
}

#pragma mark - print / kick

/* Raw, already-encoded ESC/POS bytes (base64 from JS). */
- (void)print:(CAPPluginCall *)call {
    [self rawPrint:call];
}

/* The cash-drawer kick is rendered pulse bytes over the very same raw path
   (D-P5) — the JS class routes kick() through print({data}), so this method is
   normally unused; it stays a real raw-print alias for a direct plugin caller. */
- (void)kick:(CAPPluginCall *)call {
    [self rawPrint:call];
}

- (void)rawPrint:(CAPPluginCall *)call {
    Epos2Printer *printer = self.printer;   // local strong ref survives a concurrent drop
    if (printer == nil) {
        [call reject:@"not_connected" :nil :nil :nil];
        return;
    }

    NSString *base64 = [call getString:@"data" defaultValue:nil];
    NSData *data = base64 != nil
        ? [[NSData alloc] initWithBase64EncodedString:base64 options:0]
        : nil;
    if (data == nil) {
        [call reject:@"no_data" :nil :nil :nil];
        return;
    }

    int addResult = [printer addCommand:data];
    int sendResult = EPOS2_ERR_FAILURE;
    if (addResult == EPOS2_SUCCESS) {
        // Asynchronous send; the print result arrives via onPtrReceive. We
        // resolve on the send return code and do NOT block on the callback —
        // mirrors the Star transport's promptness.
        sendResult = [printer sendData:EPOS2_PARAM_DEFAULT];
    }
    [printer clearCommandBuffer];   // always, after — each job is self-contained

    if (addResult == EPOS2_SUCCESS && sendResult == EPOS2_SUCCESS) {
        [call resolve];
    } else {
        int failCode = (addResult != EPOS2_SUCCESS) ? addResult : sendResult;
        [call reject:[EpsonEposReceiptPrinterPlugin errorName:failCode] :nil :nil :nil];
    }
}

#pragma mark - getStatus

/*
    Stable status shape for parity with Star (currently unused app-side — status
    UI is out of scope). Mapped from Epos2PrinterStatusInfo:
    { connected, model, coverOpen, paperEmpty, paperNearEmpty }.
    No printer held -> { connected: false }.
*/
- (void)getStatus:(CAPPluginCall *)call {
    Epos2Printer *printer = self.printer;
    if (printer == nil) {
        [call resolve:@{ @"connected": @NO }];
        return;
    }

    Epos2PrinterStatusInfo *status = [printer getStatus];
    BOOL connected = ([status getConnection] == EPOS2_TRUE);
    BOOL coverOpen = ([status getCoverOpen] == EPOS2_TRUE);
    int paper = [status getPaper];

    [call resolve:@{
        @"connected": @(connected),
        @"model": self.boundModel ?: @"",
        @"coverOpen": @(coverOpen),
        @"paperEmpty": @(paper == EPOS2_PAPER_EMPTY),
        @"paperNearEmpty": @(paper == EPOS2_PAPER_NEAR_END)
    }];
}

#pragma mark - Epos2PtrReceiveDelegate (print-result telemetry only)

- (void)onPtrReceive:(Epos2Printer *)printerObj code:(int)code status:(Epos2PrinterStatusInfo *)status printJobId:(NSString *)printJobId {
    // Print jobs resolve on the sendData return code; this only records the last
    // asynchronous result. Deliberately does not resolve/reject any call.
    self.lastReceiveCode = code;
}

#pragma mark - Epos2ConnectionDelegate (connection-drop detection, R8)

- (void)onConnection:(id)deviceObj eventType:(int)eventType {
    // Only the final DISCONNECT matters. RECONNECTING / RECONNECT are the SDK's
    // own transient events — ignored, since the app owns reconnect (no
    // auto-reconnect, Star parity).
    if (eventType != EPOS2_EVENT_DISCONNECT) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self handleLostConnection];
    });
}

- (void)handleLostConnection {
    Epos2Printer *printer = self.printer;
    if (printer == nil) {
        return;
    }
    // The link is already gone — just detach and forget it (no blocking
    // disconnect from the callback path). The app drives reconnect().
    [printer setReceiveEventDelegate:nil];
    [printer setConnectionEventDelegate:nil];
    self.printer = nil;
    self.boundTarget = nil;
    self.boundModel = nil;
    self.boundInterface = nil;
    [self notifyListeners:@"disconnected" data:@{}];
}

#pragma mark - Interface <-> ePOS2 mapping helpers

/* JS interface name -> Epos2PortType, or -1 when unrecognized. */
+ (int)portTypeFromInterface:(NSString *)name {
    NSString *n = name.lowercaseString;
    if ([n isEqualToString:@"lan"]) {
        return EPOS2_PORTTYPE_TCP;
    }
    if ([n isEqualToString:@"bluetooth"]) {
        return EPOS2_PORTTYPE_BLUETOOTH;
    }
    if ([n isEqualToString:@"bluetoothle"]) {
        return EPOS2_PORTTYPE_BLUETOOTH_LE;
    }
    if ([n isEqualToString:@"usb"]) {
        return EPOS2_PORTTYPE_USB;
    }
    return -1;
}

/* ePOS2 target prefix ("TCP:…", "BT:…", "BLE:…", "USB:…") -> JS interface. */
+ (NSString *)interfaceFromTarget:(NSString *)target {
    if (target.length == 0) {
        return @"unknown";
    }
    NSRange colon = [target rangeOfString:@":"];
    NSString *prefix = colon.location == NSNotFound
        ? target
        : [target substringToIndex:colon.location];
    prefix = prefix.uppercaseString;

    if ([prefix isEqualToString:@"TCP"] || [prefix isEqualToString:@"TCPS"]) {
        return @"lan";
    }
    if ([prefix isEqualToString:@"BT"]) {
        return @"bluetooth";
    }
    if ([prefix isEqualToString:@"BLE"]) {
        return @"bluetoothLE";
    }
    if ([prefix isEqualToString:@"USB"]) {
        return @"usb";
    }
    return @"unknown";
}

/*
    Map a discovered/persisted model name (e.g. "TM-m30III") to an
    Epos2PrinterSeries constant. Normalized by upper-casing and stripping
    separators, then longest-prefix matched (most-specific first, so "M30III"
    wins over "M30II" over "M30"). Unrecognized models default to the generic
    EPOS2_TM_T88 — harmless for raw addCommand pass-through (D-P2).
*/
+ (int)printerSeriesFromModel:(NSString *)model {
    if (model.length == 0) {
        return EPOS2_TM_T88;
    }

    NSMutableString *normalized = [[model uppercaseString] mutableCopy];
    [normalized replaceOccurrencesOfString:@"-" withString:@"" options:0 range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@"_" withString:@"" options:0 range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@" " withString:@"" options:0 range:NSMakeRange(0, normalized.length)];

    // Ordered most-specific-first — each entry is { normalized token, series }.
    NSArray<NSArray *> *table = @[
        @[ @"TMM30III", @(EPOS2_TM_M30III) ],
        @[ @"TMM30II",  @(EPOS2_TM_M30II) ],
        @[ @"TMM30",    @(EPOS2_TM_M30) ],
        @[ @"TMM50II",  @(EPOS2_TM_M50II) ],
        @[ @"TMM50",    @(EPOS2_TM_M50) ],
        @[ @"TMM55",    @(EPOS2_TM_M55) ],
        @[ @"TMM10",    @(EPOS2_TM_M10) ],
        @[ @"TMP20II",  @(EPOS2_TM_P20II) ],
        @[ @"TMP20",    @(EPOS2_TM_P20) ],
        @[ @"TMP60II",  @(EPOS2_TM_P60II) ],
        @[ @"TMP60",    @(EPOS2_TM_P60) ],
        @[ @"TMP80II",  @(EPOS2_TM_P80II) ],
        @[ @"TMP80",    @(EPOS2_TM_P80) ],
        @[ @"TMT88VII", @(EPOS2_TM_T88VII) ],
        @[ @"TMT88",    @(EPOS2_TM_T88) ],
        @[ @"TMT20",    @(EPOS2_TM_T20) ],
        @[ @"TMT60",    @(EPOS2_TM_T60) ],
        @[ @"TMT70",    @(EPOS2_TM_T70) ],
        @[ @"TMT81",    @(EPOS2_TM_T81) ],
        @[ @"TMT82",    @(EPOS2_TM_T82) ],
        @[ @"TMT83III", @(EPOS2_TM_T83III) ],
        @[ @"TMT83",    @(EPOS2_TM_T83) ],
        @[ @"TMT90KP",  @(EPOS2_TM_T90KP) ],
        @[ @"TMT90",    @(EPOS2_TM_T90) ],
        @[ @"TMT100",   @(EPOS2_TM_T100) ],
        @[ @"TMU220II", @(EPOS2_TM_U220II) ],
        @[ @"TMU220",   @(EPOS2_TM_U220) ],
        @[ @"TMU330",   @(EPOS2_TM_U330) ],
        @[ @"TML90LFC", @(EPOS2_TM_L90LFC) ],
        @[ @"TML100",   @(EPOS2_TM_L100) ],
        @[ @"TML90",    @(EPOS2_TM_L90) ],
        @[ @"TMH6000",  @(EPOS2_TM_H6000) ],
        @[ @"TST100",   @(EPOS2_TS_100) ],
        @[ @"TS100",    @(EPOS2_TS_100) ],
        @[ @"SBH50",    @(EPOS2_SB_H50) ],
        @[ @"SBM30",    @(EPOS2_SB_M30) ],
    ];

    for (NSArray *entry in table) {
        if ([normalized hasPrefix:entry[0]]) {
            return [entry[1] intValue];
        }
    }
    return EPOS2_TM_T88;
}

/* Epos2ErrorStatus code -> stable name for reject() messages. */
+ (NSString *)errorName:(int)code {
    switch (code) {
        case EPOS2_SUCCESS:              return @"SUCCESS";
        case EPOS2_ERR_PARAM:            return @"ERR_PARAM";
        case EPOS2_ERR_CONNECT:          return @"ERR_CONNECT";
        case EPOS2_ERR_TIMEOUT:          return @"ERR_TIMEOUT";
        case EPOS2_ERR_MEMORY:           return @"ERR_MEMORY";
        case EPOS2_ERR_ILLEGAL:          return @"ERR_ILLEGAL";
        case EPOS2_ERR_PROCESSING:       return @"ERR_PROCESSING";
        case EPOS2_ERR_NOT_FOUND:        return @"ERR_NOT_FOUND";
        case EPOS2_ERR_IN_USE:           return @"ERR_IN_USE";
        case EPOS2_ERR_TYPE_INVALID:     return @"ERR_TYPE_INVALID";
        case EPOS2_ERR_DISCONNECT:       return @"ERR_DISCONNECT";
        case EPOS2_ERR_ALREADY_OPENED:   return @"ERR_ALREADY_OPENED";
        case EPOS2_ERR_ALREADY_USED:     return @"ERR_ALREADY_USED";
        case EPOS2_ERR_BOX_COUNT_OVER:   return @"ERR_BOX_COUNT_OVER";
        case EPOS2_ERR_BOX_CLIENT_OVER:  return @"ERR_BOX_CLIENT_OVER";
        case EPOS2_ERR_UNSUPPORTED:      return @"ERR_UNSUPPORTED";
        case EPOS2_ERR_DEVICE_BUSY:      return @"ERR_DEVICE_BUSY";
        case EPOS2_ERR_RECOVERY_FAILURE: return @"ERR_RECOVERY_FAILURE";
        case EPOS2_ERR_FAILURE:          return @"ERR_FAILURE";
        default:                         return [NSString stringWithFormat:@"ERR_%d", code];
    }
}

@end
