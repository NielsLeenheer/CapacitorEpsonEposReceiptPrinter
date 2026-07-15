#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

/*
    Capacitor plugin bridge. Registration key "EpsonEposReceiptPrinter" (D-P7,
    Star convention: project name minus the Capacitor prefix) — the JS class
    reaches this one plugin.

    This lives in its own translation unit ON PURPOSE: the CAP_PLUGIN macro
    expands to `@interface EpsonEposReceiptPrinterPlugin : NSObject` (plus the
    CAPBridgedPlugin category), which conflicts with the real
    `: CAPPlugin` interface if compiled together. Keeping the macro here — and
    NOT importing EpsonEposReceiptPrinterPlugin.h — is exactly how the stock
    Capacitor ObjC plugins (spryrocks, bcyesil) register. The category attaches
    to the real CAPPlugin subclass at runtime by class name.
*/
CAP_PLUGIN(EpsonEposReceiptPrinterPlugin, "EpsonEposReceiptPrinter",
           CAP_PLUGIN_METHOD(isAvailable, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(ensurePermissions, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(discover, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(connect, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(disconnect, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(print, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(kick, CAPPluginReturnPromise);
           CAP_PLUGIN_METHOD(getStatus, CAPPluginReturnPromise);
)
