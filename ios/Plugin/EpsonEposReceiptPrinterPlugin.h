#import <Capacitor/Capacitor.h>

/*
    Epson ePOS2 receipt printer plugin — Objective-C.

    Deliberate deviation from the Star twin's Swift (documented in the README):
    the ePOS2 SDK is an Objective-C static library shipped as a bare-header
    xcframework (ios/Frameworks/libepos2.xcframework/.../Headers/ePOS2.h). ObjC
    imports ePOS2.h directly and sidesteps the Swift-module-map machinery a
    vendored *static* xcframework would otherwise need.

    One native plugin, one held Epos2Printer connection (analysis plan D2). The
    JS class CapacitorEpsonEposReceiptPrinter (src/main-printer.js) is the sole
    client; this plugin exposes the Star surface minus the scanner (Epson TM
    printers have no mPOP-style input device — D-P6).

    Registration ("EpsonEposReceiptPrinter", D-P7) is in the sibling
    EpsonEposReceiptPrinterPluginRegistration.m — the CAP_PLUGIN macro
    re-declares the class as ": NSObject", which cannot coexist in the same
    translation unit as this ": CAPPlugin" interface, so it lives in its own TU
    (the pattern every Capacitor ObjC plugin uses).
*/
@interface EpsonEposReceiptPrinterPlugin : CAPPlugin

- (void)isAvailable:(CAPPluginCall *)call;
- (void)ensurePermissions:(CAPPluginCall *)call;
- (void)discover:(CAPPluginCall *)call;
- (void)connect:(CAPPluginCall *)call;
- (void)disconnect:(CAPPluginCall *)call;
- (void)print:(CAPPluginCall *)call;
- (void)kick:(CAPPluginCall *)call;
- (void)getStatus:(CAPPluginCall *)call;

@end
