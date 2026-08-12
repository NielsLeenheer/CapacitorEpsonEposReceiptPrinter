package nl.salonhub.epson

import android.content.Context
import android.hardware.usb.UsbManager
import android.util.Base64
import android.util.Log
import com.epson.epos2.ConnectionListener
import com.epson.epos2.Epos2Exception
import com.epson.epos2.discovery.DeviceInfo
import com.epson.epos2.discovery.Discovery
import com.epson.epos2.discovery.DiscoveryListener
import com.epson.epos2.discovery.FilterOption
import com.epson.epos2.printer.Printer
import com.epson.epos2.printer.PrinterStatusInfo
import com.epson.epos2.printer.ReceiveListener
import com.getcapacitor.JSArray
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/*
    ePOS2 raw-mode transport (analysis plan D-P2) — Android. The Kotlin twin of
    ios/Plugin/EpsonEposReceiptPrinterPlugin.m; it mirrors that file's method
    surface, result keys, event names and semantics one-to-one.

    Receipts are rendered to ESC/POS app-side by ReceiptPrinterEncoder; this
    plugin only ships those bytes through the SDK's addCommand -> sendData raw
    pass-through. It never uses the ePOS2 document builder (addText/addImage/…) —
    the encoder is the single source of receipt truth on every platform (D-P2).

    One native plugin, one held connection (D2). Registration key
    "EpsonEposReceiptPrinter" (Star convention — project name minus the Capacitor
    prefix, D-P7). No scanner half — Epson TM printers have no mPOP-style input
    device (D-P6).

    Threading: Capacitor dispatches @PluginMethod bodies on the app's main thread;
    the ePOS2 SDK's connect / sendData / getStatus calls BLOCK, so every
    SDK-touching operation runs on the single background executor below (never the
    main thread). The one exception is Discovery, which is non-blocking (results
    arrive via the DiscoveryListener callback) — its sequential passes are timed
    on the same single-thread scheduled executor. The discovered-device map is
    guarded (discoveryLock) because onDiscovery arrives on an SDK thread.

    isAvailable: unconditionally true — ePOS2 supports Android 5+, our minSdk 22
    is fine, so (unlike the Star twin's API-26 floor) there is no availability
    guard. Whether an Epson device is actually reachable is discover()'s job.

    Permissions: the `bluetooth` @CapacitorPlugin alias (BLUETOOTH_SCAN +
    BLUETOOTH_CONNECT) backs Capacitor's synthesised checkPermissions() /
    requestPermissions(), which the JS class's ensurePermissions() drives on
    Android 12+ (API 31). No native ensurePermissions method is needed — same as
    the Star twin; the iOS .m has one only because iOS lacks that synthesis.

    No auto-reconnect (Star / iOS parity): a dropped connection surfaces as a
    `disconnected` event and clears the held printer; the app drives reconnect().
*/
@CapacitorPlugin(
    name = "EpsonEposReceiptPrinter",
    permissions = [
        Permission(
            strings = [
                "android.permission.BLUETOOTH_SCAN",
                "android.permission.BLUETOOTH_CONNECT",
            ],
            alias = "bluetooth"
        ),
    ]
)
class EpsonEposReceiptPrinterPlugin : Plugin() {

    // Hardware bring-up logging. Filter logcat for this tag; the iOS twin logs
    // the same events under `[SH-POS][Epson/ios]`. Remove once discovery/connect
    // is proven on device.
    private val logTag = "SH-POS/Epson"

    // The single held connection (D2) and what it is bound to.
    private var printer: Printer? = null
    private var boundTarget: String? = null       // ePOS2 target string, keys idempotency
    private var boundModel: String? = null         // discovered/persisted model name
    private var boundInterface: String? = null     // js-facing interface string

    // One-shot discovery state, guarded by discoveryLock (onDiscovery arrives on
    // an SDK thread; the pass timer runs on the executor thread).
    private val discoveryLock = Any()
    private var discoveryCall: PluginCall? = null
    private var discoveredDevices: LinkedHashMap<String, DeviceInfo>? = null
    private var discoveryPasses: List<Int>? = null
    private var discoveryIndex: Int = 0
    private var discoveryPassMs: Long = 0

    // Last onPtrReceive result — internal telemetry only; resolve() never blocks on it.
    private var lastReceiveCode: Int = 0

    // Single background thread for the blocking SDK calls AND the discovery-pass
    // timer (schedule). Keeps every ePOS2 touch off the main thread.
    private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()

    private val receiveEvents = ReceiveEvents()
    private val connectionEvents = ConnectionEvents()
    private val discoveryEvents = DiscoveryEvents()

    // MARK: - isAvailable / ensurePermissions

    /* The ePOS2 SDK is compiled into every Android build, so the native plugin is
       always present, and it runs on our whole minSdk-22 range. Whether any Epson
       device is reachable is discover()'s job. */
    @PluginMethod
    fun isAvailable(call: PluginCall) {
        call.resolve(JSObject().put("available", true))
    }

    // MARK: - discover

    /*
        One-shot discovery across the requested interfaces (D3). Resolves
        { devices: [{ interface, identifier, model }] } where identifier is the
        ePOS2 target string ("BT:…", "TCP:…", "USB:…") and interface is derived
        from its prefix.

        FilterOption.portType is a SINGLE enum value (not a bitmask), so a set of
        interfaces cannot be expressed in one pass. Strategy (mirrors iOS):
          - when EVERY Android-supported port type (TCP + Bluetooth + USB) is
            asked for, collapse to ONE PORTTYPE_ALL pass over the full timeout;
          - any strict subset (e.g. Salonhub's MVP ['bluetooth','usb']) runs
            SEQUENTIAL passes, one port type each, splitting the timeout budget,
            deduped by target.

        'bluetoothLE' is NOT supported by the Android ePOS2 SDK, so it is silently
        dropped from the pass list (portTypeFromInterface returns -1). Requested
        alongside other interfaces it simply contributes nothing; the JS default
        ['lan','bluetooth','bluetoothLE','usb'] therefore collapses to the same
        PORTTYPE_ALL pass as 'lan'+'bluetooth'+'usb'.
    */
    @PluginMethod
    fun discover(call: PluginCall) {
        val requested: List<String> = try {
            call.getArray("interfaces")?.toList<String>()
        } catch (e: Exception) {
            null
        } ?: listOf("lan", "bluetooth", "bluetoothLE", "usb")

        var timeout = call.getInt("timeout") ?: 5000
        if (timeout <= 0) {
            timeout = 5000
        }

        Log.d(logTag, "discover() requested=$requested timeout=${timeout}ms")

        // Map to port types, dropping BLE/unknown, dedupe preserving request order.
        val portTypes = LinkedHashSet<Int>()
        for (name in requested) {
            val portType = portTypeFromInterface(name)
            if (portType >= 0) {
                portTypes.add(portType)
            }
        }

        if (portTypes.isEmpty()) {
            Log.d(logTag, "discover() REJECT no_valid_interfaces (BLE is unsupported on Android ePOS2 and is dropped)")
            call.reject("no_valid_interfaces")
            return
        }

        // Collapse to a single ALL pass only when every Android-supported port
        // type is asked for; a strict subset must be honoured per-type (ALL would
        // leak omitted interfaces such as 'lan').
        val allSupported = setOf(
            Discovery.PORTTYPE_TCP,
            Discovery.PORTTYPE_BLUETOOTH,
            Discovery.PORTTYPE_USB
        )
        val passes: List<Int> = if (portTypes == allSupported) {
            listOf(Discovery.PORTTYPE_ALL)
        } else {
            portTypes.toList()
        }

        var perPass = timeout.toLong() / passes.size
        if (perPass < 500) {
            perPass = 500   // floor so a slow inquiry still has a chance per pass
        }

        Log.d(logTag, "discover() plan: ${passes.size} pass(es)=$passes, ${perPass}ms each")

        synchronized(discoveryLock) {
            discoveryCall = call
            discoveredDevices = LinkedHashMap()
            discoveryPasses = passes
            discoveryIndex = 0
            discoveryPassMs = perPass
        }

        executor.execute { runNextDiscoveryPass() }
    }

    private fun runNextDiscoveryPass() {
        val passes: List<Int>?
        val index: Int
        val perPass: Long
        synchronized(discoveryLock) {
            passes = discoveryPasses
            index = discoveryIndex
            perPass = discoveryPassMs
        }

        if (passes == null) {
            return   // discovery was torn down
        }
        if (index >= passes.size) {
            finishDiscovery()
            return
        }

        val portType = passes[index]

        val filter = FilterOption()
        filter.portType = portType
        filter.deviceModel = Discovery.MODEL_ALL
        filter.deviceType = Discovery.TYPE_PRINTER   // this is a receipt-printer plugin (D-P6)

        try {
            Discovery.stop()   // ensure no prior run is still active
        } catch (e: Exception) {
            // Nothing running.
        }
        try {
            Discovery.start(context, filter, discoveryEvents)
            Log.d(logTag, "discover() pass ${index + 1}/${passes.size} started: portType=$portType")
        } catch (e: Exception) {
            // Errors (e.g. already-running) fall through; the pass still elapses.
            Log.d(logTag, "discover() pass ${index + 1}/${passes.size} start threw: ${e.message}")
        }

        synchronized(discoveryLock) {
            discoveryIndex = index + 1
        }

        executor.schedule({
            try {
                Discovery.stop()
            } catch (e: Exception) {
                // Nothing to stop.
            }
            runNextDiscoveryPass()
        }, perPass, TimeUnit.MILLISECONDS)
    }

    private fun finishDiscovery() {
        try {
            Discovery.stop()
        } catch (e: Exception) {
            // Nothing to stop.
        }

        val call: PluginCall?
        val devices = JSArray()
        synchronized(discoveryLock) {
            call = discoveryCall
            discoveredDevices?.values?.forEach { info ->
                val target = info.target ?: ""
                devices.put(
                    JSObject()
                        .put("interface", interfaceFromTarget(target))
                        .put("identifier", target)
                        .put("model", usbProductName(target) ?: info.deviceName ?: "")
                )
            }
            discoveryCall = null
            discoveredDevices = null
            discoveryPasses = null
            discoveryIndex = 0
        }

        Log.d(logTag, "discover() finished — resolving ${devices.length()} device(s) to JS: $devices")
        call?.resolve(JSObject().put("devices", devices))
    }

    /*
        ePOS2 USB discovery reports the generic deviceName "TM Printer"; the USB
        descriptor's product string carries the REAL model (e.g. "TM-P20II"),
        which drives both the app's 'Automatisch' encoder-preset mapping and the
        printer-series choice at connect. The ePOS2 target "USB:/dev/bus/usb/…"
        suffix is exactly UsbDevice.deviceName, so the lookup is a direct match.
        productName needs no USB permission (unlike the serial number).
    */
    private fun usbProductName(target: String): String? {
        if (!target.startsWith("USB:")) {
            return null
        }
        return try {
            val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
            val product = usbManager.deviceList.values
                .firstOrNull { it.deviceName == target.removePrefix("USB:") }
                ?.productName
            if (product != null) {
                Log.d(logTag, "usbProductName: $target → $product")
            }
            product
        } catch (e: Exception) {
            Log.d(logTag, "usbProductName lookup failed for $target: ${e.message}")
            null
        }
    }

    // MARK: - connect

    /*
        Open the single native connection to { interface, identifier, model? }
        (D2). Single-connection lifecycle:
          - already connected to the SAME target  -> no-op (R6 twin)
          - connected to a DIFFERENT target        -> disconnect it first, then open
        Emits `connected` on success.
    */
    @PluginMethod
    fun connect(call: PluginCall) {
        val identifier = call.getString("identifier")
        val interfaceName = call.getString("interface")
        val model = call.getString("model")

        Log.d(logTag, "connect() interface=$interfaceName identifier=$identifier model=$model")

        if (identifier.isNullOrEmpty()) {
            // ePOS2 has no FIRST_FOUND-device concept — a concrete target is required.
            Log.d(logTag, "connect() REJECT no_target (empty identifier)")
            call.reject("no_target")
            return
        }

        // Same-target no-op.
        if (printer != null && boundTarget == identifier) {
            Log.d(logTag, "connect() no-op — already bound to this target")
            call.resolve()
            return
        }

        executor.execute {
            // A still-running discovery starves the open on the shared radio —
            // finish it first (stops the SDK discovery and resolves a pending
            // discover call with whatever it found so far). No-op when idle.
            val discoveryActive = synchronized(discoveryLock) { discoveryCall != null }
            if (discoveryActive) {
                Log.d(logTag, "connect() finishing in-flight discovery before open")
                finishDiscovery()
            }

            // Different target: drop the current connection first.
            if (printer != null) {
                teardownPrinter()
            }

            // Map the model name to a printer series. Raw addCommand pass-through
            // does NOT depend on the series builder logic, so an unrecognized
            // model falling back to the generic T88 series is harmless (D-P2).
            val series = printerSeriesFromModel(model)

            val newPrinter = try {
                Printer(series, Printer.MODEL_ANK, context)
            } catch (e: Epos2Exception) {
                call.reject(errorName(e.errorStatus))
                return@execute
            }

            newPrinter.setReceiveEventListener(receiveEvents)      // print-result status (telemetry only)
            newPrinter.setConnectionEventListener(connectionEvents) // connection-drop detection

            try {
                newPrinter.connect(identifier, Printer.PARAM_DEFAULT)
            } catch (e: Epos2Exception) {
                try {
                    newPrinter.setReceiveEventListener(null)
                    newPrinter.setConnectionEventListener(null)
                } catch (ignored: Exception) {
                }
                Log.d(logTag, "connect() FAILED — ePOS2 connect returned ${errorName(e.errorStatus)}")
                call.reject(errorName(e.errorStatus))
                return@execute
            }

            printer = newPrinter
            boundTarget = identifier
            boundModel = model
            boundInterface = if (!interfaceName.isNullOrEmpty()) {
                interfaceName
            } else {
                interfaceFromTarget(identifier)
            }
            Log.d(logTag, "connect() ok — bound to $identifier (series=$series)")
            notifyListeners("connected", JSObject())
            call.resolve()
        }
    }

    // MARK: - disconnect

    @PluginMethod
    fun disconnect(call: PluginCall) {
        if (printer == null) {
            call.resolve()
            return
        }
        executor.execute {
            teardownPrinter()
            call.resolve()
        }
    }

    /* Clear listeners, disconnect, clear the command buffer, release the printer. */
    private fun teardownPrinter() {
        val current = printer ?: return
        try {
            current.setReceiveEventListener(null)
            current.setConnectionEventListener(null)
        } catch (ignored: Exception) {
        }
        try {
            current.disconnect()
        } catch (ignored: Exception) {
            // Best-effort — the connection is going away regardless.
        }
        try {
            current.clearCommandBuffer()
        } catch (ignored: Exception) {
        }
        printer = null
        boundTarget = null
        boundModel = null
        boundInterface = null
    }

    // MARK: - print / kick

    /* Raw, already-encoded ESC/POS bytes (base64 from JS). */
    @PluginMethod
    fun print(call: PluginCall) {
        rawPrint(call)
    }

    /* The cash-drawer kick is rendered pulse bytes over the very same raw path
       (D-P5) — the JS class routes kick() through print({data}), so this method
       is normally unused; it stays a real raw-print alias for a direct caller. */
    @PluginMethod
    fun kick(call: PluginCall) {
        rawPrint(call)
    }

    private fun rawPrint(call: PluginCall) {
        val current = printer   // local ref survives a concurrent drop
        if (current == null) {
            call.reject("not_connected")
            return
        }

        val base64 = call.getString("data")
        val bytes = if (base64 != null) {
            try {
                Base64.decode(base64, Base64.DEFAULT)
            } catch (e: IllegalArgumentException) {
                null
            }
        } else {
            null
        }

        if (bytes == null) {
            call.reject("no_data")
            return
        }

        Log.d(logTag, "print() ${bytes.size} bytes → addCommand/sendData")

        executor.execute {
            // add -> send -> clear -> resolve/reject (iOS parity: the command
            // buffer is ALWAYS cleared after, each job self-contained).
            var failure: String? = null
            try {
                current.addCommand(bytes)
                current.sendData(Printer.PARAM_DEFAULT)
            } catch (e: Epos2Exception) {
                failure = errorName(e.errorStatus)
            }
            try {
                current.clearCommandBuffer()
            } catch (ignored: Exception) {
            }

            if (failure == null) {
                Log.d(logTag, "print() sendData ok (${bytes.size} bytes)")
                call.resolve()
            } else {
                Log.d(logTag, "print() FAILED: $failure")
                call.reject(failure)
            }
        }
    }

    // MARK: - getStatus

    /*
        Stable status shape for parity with Star / iOS (currently unused app-side
        — status UI is out of scope). Mapped from PrinterStatusInfo:
        { connected, model, coverOpen, paperEmpty, paperNearEmpty }.
        No printer held -> { connected: false }.
    */
    @PluginMethod
    fun getStatus(call: PluginCall) {
        val current = printer
        if (current == null) {
            call.resolve(JSObject().put("connected", false))
            return
        }

        executor.execute {
            val status: PrinterStatusInfo = current.status
            val connected = status.connection == Printer.TRUE
            val coverOpen = status.coverOpen == Printer.TRUE
            val paper = status.paper

            call.resolve(
                JSObject()
                    .put("connected", connected)
                    .put("model", boundModel ?: "")
                    .put("coverOpen", coverOpen)
                    .put("paperEmpty", paper == Printer.PAPER_EMPTY)
                    .put("paperNearEmpty", paper == Printer.PAPER_NEAR_END)
            )
        }
    }

    // MARK: - connection-drop handling (R8 twin)

    private fun handleLostConnection() {
        val current = printer ?: return
        // The link is already gone — just detach and forget it (no blocking
        // disconnect from the callback path). The app drives reconnect().
        try {
            current.setReceiveEventListener(null)
            current.setConnectionEventListener(null)
        } catch (ignored: Exception) {
        }
        printer = null
        boundTarget = null
        boundModel = null
        boundInterface = null
        notifyListeners("disconnected", JSObject())
    }

    // MARK: - ReceiveListener (print-result telemetry only)

    private inner class ReceiveEvents : ReceiveListener {
        override fun onPtrReceive(
            printerObj: Printer?,
            code: Int,
            status: PrinterStatusInfo?,
            printJobId: String?
        ) {
            // Print jobs resolve on the sendData return; this only records the
            // last asynchronous result. Deliberately resolves/rejects nothing.
            // The code is the printer's own verdict on the job (CODE_SUCCESS=0)
            // and the only place a printer-side stall becomes visible — log it.
            lastReceiveCode = code
            Log.d(
                logTag,
                "onPtrReceive: code=$code jobId=$printJobId" +
                    " online=${status?.online} paper=${status?.paper} error=${status?.errorStatus}"
            )
        }
    }

    // MARK: - ConnectionListener (connection-drop detection, R8)

    private inner class ConnectionEvents : ConnectionListener {
        override fun onConnection(deviceObj: Any?, eventType: Int) {
            // Only the final DISCONNECT matters. RECONNECTING / RECONNECT are the
            // SDK's own transient events — ignored, since the app owns reconnect
            // (no auto-reconnect, Star / iOS parity). Serialised onto the executor
            // so all printer-field mutations happen on one thread.
            if (eventType != ConnectionListener.EVENT_DISCONNECT) {
                return
            }
            executor.execute { handleLostConnection() }
        }
    }

    // MARK: - DiscoveryListener

    private inner class DiscoveryEvents : DiscoveryListener {
        override fun onDiscovery(deviceInfo: DeviceInfo?) {
            val info = deviceInfo ?: return
            val target = info.target
            if (target.isNullOrEmpty()) {
                return
            }
            Log.d(logTag, "onDiscovery: target=$target deviceName=${info.deviceName}")

            var fresh = false
            synchronized(discoveryLock) {
                // dedupe by target across passes
                fresh = discoveredDevices?.put(target, info) == null && discoveredDevices != null
            }

            // Discovery runs its passes to the end, so a caller that waits for
            // the resolve shows nothing for seconds; this lets the pairing list
            // fill as printers answer. Only the first sighting of a target is
            // announced — the passes see the same printer more than once.
            if (fresh) {
                notifyListeners(
                    "printerFound",
                    JSObject()
                        .put("interface", interfaceFromTarget(target))
                        .put("identifier", target)
                        .put("model", usbProductName(target) ?: info.deviceName ?: "")
                )
            }
        }
    }

    // MARK: - interface <-> ePOS2 mapping helpers

    /* JS interface name -> Discovery.PORTTYPE_*, or -1 when unrecognized. BLE is
       recognized but UNSUPPORTED on Android ePOS2, so it returns -1 (dropped). */
    private fun portTypeFromInterface(name: String): Int = when (name.lowercase()) {
        "lan" -> Discovery.PORTTYPE_TCP
        "bluetooth" -> Discovery.PORTTYPE_BLUETOOTH
        "bluetoothle" -> -1   // no BLE on Android ePOS2 — silently skipped
        "usb" -> Discovery.PORTTYPE_USB
        else -> -1
    }

    /* ePOS2 target prefix ("TCP:…", "BT:…", "BLE:…", "USB:…") -> JS interface. */
    private fun interfaceFromTarget(target: String): String {
        if (target.isEmpty()) {
            return "unknown"
        }
        val colon = target.indexOf(':')
        val prefix = (if (colon < 0) target else target.substring(0, colon)).uppercase()
        return when (prefix) {
            "TCP", "TCPS" -> "lan"
            "BT" -> "bluetooth"
            "BLE" -> "bluetoothLE"
            "USB" -> "usb"
            else -> "unknown"
        }
    }

    /*
        Map a discovered/persisted model name (e.g. "TM-m30III") to a Printer
        series constant. Normalized by upper-casing and stripping separators, then
        longest-prefix matched (most-specific first, so "M30III" wins over "M30II"
        over "M30"). Unrecognized models default to the generic TM_T88 — harmless
        for raw addCommand pass-through (D-P2). Table mirrors the iOS twin exactly.
    */
    private fun printerSeriesFromModel(model: String?): Int {
        if (model.isNullOrEmpty()) {
            return Printer.TM_T88
        }

        val normalized = model.uppercase()
            .replace("-", "")
            .replace("_", "")
            .replace(" ", "")

        // Ordered most-specific-first.
        val table = listOf(
            "TMM30III" to Printer.TM_M30III,
            "TMM30II" to Printer.TM_M30II,
            "TMM30" to Printer.TM_M30,
            "TMM50II" to Printer.TM_M50II,
            "TMM50" to Printer.TM_M50,
            "TMM55" to Printer.TM_M55,
            "TMM10" to Printer.TM_M10,
            "TMP20II" to Printer.TM_P20II,
            "TMP20" to Printer.TM_P20,
            "TMP60II" to Printer.TM_P60II,
            "TMP60" to Printer.TM_P60,
            "TMP80II" to Printer.TM_P80II,
            "TMP80" to Printer.TM_P80,
            "TMT88VII" to Printer.TM_T88VII,
            "TMT88" to Printer.TM_T88,
            "TMT20" to Printer.TM_T20,
            "TMT60" to Printer.TM_T60,
            "TMT70" to Printer.TM_T70,
            "TMT81" to Printer.TM_T81,
            "TMT82" to Printer.TM_T82,
            "TMT83III" to Printer.TM_T83III,
            "TMT83" to Printer.TM_T83,
            "TMT90KP" to Printer.TM_T90KP,
            "TMT90" to Printer.TM_T90,
            "TMT100" to Printer.TM_T100,
            "TMU220II" to Printer.TM_U220II,
            "TMU220" to Printer.TM_U220,
            "TMU330" to Printer.TM_U330,
            "TML90LFC" to Printer.TM_L90LFC,
            "TML100" to Printer.TM_L100,
            "TML90" to Printer.TM_L90,
            "TMH6000" to Printer.TM_H6000,
            "TST100" to Printer.TS_100,
            "TS100" to Printer.TS_100,
            "SBH50" to Printer.SB_H50,
            "SBM30" to Printer.SB_M30,
        )

        for ((token, series) in table) {
            if (normalized.startsWith(token)) {
                return series
            }
        }
        return Printer.TM_T88
    }

    /* Epos2Exception error status -> stable name for reject() messages. */
    private fun errorName(code: Int): String = when (code) {
        Epos2Exception.ERR_PARAM -> "ERR_PARAM"
        Epos2Exception.ERR_CONNECT -> "ERR_CONNECT"
        Epos2Exception.ERR_TIMEOUT -> "ERR_TIMEOUT"
        Epos2Exception.ERR_MEMORY -> "ERR_MEMORY"
        Epos2Exception.ERR_ILLEGAL -> "ERR_ILLEGAL"
        Epos2Exception.ERR_PROCESSING -> "ERR_PROCESSING"
        Epos2Exception.ERR_NOT_FOUND -> "ERR_NOT_FOUND"
        Epos2Exception.ERR_IN_USE -> "ERR_IN_USE"
        Epos2Exception.ERR_TYPE_INVALID -> "ERR_TYPE_INVALID"
        Epos2Exception.ERR_DISCONNECT -> "ERR_DISCONNECT"
        Epos2Exception.ERR_ALREADY_OPENED -> "ERR_ALREADY_OPENED"
        Epos2Exception.ERR_ALREADY_USED -> "ERR_ALREADY_USED"
        Epos2Exception.ERR_BOX_COUNT_OVER -> "ERR_BOX_COUNT_OVER"
        Epos2Exception.ERR_BOX_CLIENT_OVER -> "ERR_BOX_CLIENT_OVER"
        Epos2Exception.ERR_UNSUPPORTED -> "ERR_UNSUPPORTED"
        Epos2Exception.ERR_RECOVERY_FAILURE -> "ERR_RECOVERY_FAILURE"
        Epos2Exception.ERR_FAILURE -> "ERR_FAILURE"
        else -> "ERR_$code"
    }

    // MARK: - lifecycle

    override fun handleOnDestroy() {
        super.handleOnDestroy()
        try {
            Discovery.stop()
        } catch (e: Exception) {
            // Nothing to stop.
        }
        executor.shutdown()
    }
}
