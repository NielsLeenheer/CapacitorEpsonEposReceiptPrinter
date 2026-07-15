# CapacitorEpsonEposReceiptPrinter

This is a Capacitor plugin for **Epson** receipt printers (TM-m30 family, Mobilink P20II/P80II, and the wider TM line), via the Epson **ePOS2** SDK. It is the **Epson twin of [`CapacitorStarIOReceiptPrinter`](https://github.com/NielsLeenheer/CapacitorStarIOReceiptPrinter)** — the same JS surface, the same single-connection native contract, the same raw-bytes transport — minus the scanner (Epson TM printers have no mPOP-style input device). Both iOS and Android are targeted; the native plugins are one-to-one twins sharing one JS class and event contract.

> **Status**: **E0** — repo scaffold + vendored SDK. The JS library, build config, podspec and Android gradle are in place and the SDK binaries are committed; the native **Swift** (E1) and **Kotlin** (B1) plugin sources land in the following steps. Run `npm install && npm run build` to produce the `dist/` bundles.

<br>

## What does this plugin do?

One native plugin, **one** JS class:

-   `CapacitorEpsonEposReceiptPrinter` — a thin raw-bytes transport for an Epson receipt printer. Receipts are built and encoded to ESC/POS app-side (for example with [`ReceiptPrinterEncoder`](https://github.com/NielsLeenheer/ReceiptPrinterEncoder), one of the existing `epson-tm-*` presets); this class only ships those bytes through the SDK's **`addCommand` → `sendData`** raw pass-through via the native `print()` call. The ePOS2 document-builder API (`addText`/`addImage`/…) is **not** used — the encoder stays the single source of receipt truth on every platform.

There is **no scanner class** — Epson TM printers have no barcode-input peripheral in scope, so the plugin exports a single printer class.

**What this plugin is for.** Epson *network* printers already print from Capacitor today over raw ESC/POS on TCP 9100 (the existing network transport), and that path stays exactly as it is. This plugin fills the gap: **Bluetooth** (iOS MFi + Android classic), **BLE**, **USB**, and SDK-grade discovery/status. LAN/WLAN is supported by the plugin too, but Salonhub omits it from its discovery filter for now — network Epson printing stays on the proven TCP-9100 path (the `lan` leg is present and switchable later).

<br>

## Printing receipts

```js
import { CapacitorEpsonEposReceiptPrinter } from '@point-of-sale/capacitor-epson-epos-receipt-printer';

const receiptPrinter = new CapacitorEpsonEposReceiptPrinter();

receiptPrinter.addEventListener('connected', device => {
    console.log(`Connected to ${device.model || 'Epson printer'}`);
});

/* Discover, then connect to the chosen device (the app drives the pairing UI) */

let [ device ] = await receiptPrinter.discover({ interfaces: ['bluetooth', 'usb'] });
await receiptPrinter.connect(device);

let encoder = new ReceiptPrinterEncoder({ printerModel: 'epson-tm-m30iii' });

let data = encoder
    .initialize()
    .text('The quick brown fox jumps over the lazy dog')
    .newline()
    .encode();

await receiptPrinter.print(data);
```

### API surface (D3)

Mirrors the Star surface, minus the scanner:

-   `isAvailable()` — is an ePOS2-capable native plugin present on this device?
-   `ensurePermissions()` — holds the Android 12+ runtime Bluetooth grants (no-op on iOS/web and below Android 12).
-   `discover({ interfaces, timeout })` — one-shot discovery; returns `[{ interface, identifier, model }, …]`. `interfaces` is a **per-call filter** — `'lan' | 'bluetooth' | 'bluetoothLE' | 'usb'` (default: all four). The plugin itself is **never** protocol-limited; filtering is purely the caller's choice.
-   `connect(device)` — opens the single native connection; idempotent when already connected; adds a `disconnected` listener and emits `connected`.
-   `reconnect(previous)`, `disconnect()`.
-   `print(command)` — raw ESC/POS `Uint8Array` → base64 → the native `print({ data })` (`addCommand` → `sendData`).
-   `kick(command)` — cash-drawer pulse bytes over the same raw print path (no dedicated drawer API needed).
-   `getStatus()` — resolves `{ connected, model, coverOpen, paperEmpty, paperNearEmpty }` (`{ connected: false }` when nothing is connected). Currently unused app-side — present for parity with the Star surface.
-   `addEventListener(name, fn)` — `connected` / `disconnected` events.

### Interfaces per platform

The `interface` values map to the ePOS2 SDK per platform:

-   **iOS**: LAN/WLAN, Bluetooth classic (MFi/iAP2), BLE (P20II/P80II generation — documented-slow), USB (MFi, m30/m50-family only).
-   **Android**: LAN/WLAN, Bluetooth classic (SPP), USB (VID `0x04B8`). ePOS2 has **no BLE on Android** — a requested `'bluetoothLE'` simply returns no devices there, it does not error.

### Background / resume

ePOS2 does not transparently reconnect. An ExternalAccessory / Bluetooth-classic session drops when the app backgrounds, the printer power-cycles, or it goes out of range; the plugin surfaces that as a `disconnected` event. **Reopening the connection is the app's responsibility** — the receipt-printer transport's `reconnect()`, driven on resume/boot.

<br>

## Epson ePOS2 SDK — version, source, and linkage

-   **SDK version: `2.37.0a`** (June 2026 build). Epson closed its developer portal in June 2024; the SDK now ships as manual ZIP downloads from Epson's regional product pages (`ePOS_SDK_iOS_v2.37.0a.zip` / `ePOS_SDK_Android_v2.37.0a.zip`). Record the source URL + checksum here when publishing.
-   **The binaries are committed** (plan D-P8). Unlike the Star plugin — which fetches its XCFramework with an install script — the ePOS2 binaries live **in the repo** at their vendored paths and ship inside the npm package. There is **no fetch step and no developer prerequisite**: a fresh clone + `pod install` / gradle build just works. This is permitted by the Epson EULA (see [Licensing](#licensing)). Trade-off: repo/package weight (~80 MB of binaries), accepted with D-P8.
-   **iOS linkage: STATIC** (decided at E0). The SDK ships both `libepos2.xcframework` (dynamic) and `libepos2-static.xcframework` (static). We vendor the **static** one — the simplest `vendored_frameworks` drop-in — **renamed** to `ios/Frameworks/libepos2.xcframework` (the `-static` suffix dropped). Both slices are present (`ios-arm64` device + `ios-arm64_x86_64-simulator`), so it links for device and simulator. Dynamic is Epson's stated future direction (a Static→Dynamic migration guide ships in the SDK); the switch can be made later if wanted.
-   **`PrivacyInfo.xcprivacy`** (App Store privacy-manifest requirement). A static `.a` cannot carry its own resources, so the SDK ships the manifest standalone. This plugin delivers it into the app bundle via the podspec's `resource_bundles`. If a consuming toolchain does not pick that up, the app can instead add `ios/Frameworks/PrivacyInfo.xcprivacy` to its own target directly.
-   **Android**: `android/libs/ePOS2.jar` + per-ABI `android/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libepos2.so`. It is a plain jar + JNI (**not** an `.aar`), so it carries no manifest and imposes no minSdk floor — no `tools:overrideLibrary` dance. `x86` and the unused `ePOSEasySelect` are not vendored.

### Updating the SDK

```bash
# Re-read the shipped EULA first — Epson revises it (see below).
./scripts/update-epson-sdk.sh <ePOS_SDK_iOS_*.zip> <ePOS_SDK_Android_*.zip>
```

The script refreshes the vendored iOS xcframework (static, renamed), `PrivacyInfo.xcprivacy`, the committed `EPSON-EULA.en.txt`, the Android jar and the three per-ABI `.so` files exactly as vendored here, and prints the SDK version folder names it found in each ZIP. The source ZIPs themselves are git-ignored (`*.zip`) — only the extracted binaries are committed.

<br>

<a name="licensing"></a>
## Licensing (dual)

This package is **dual-licensed**:

-   **The wrapper code** (the JS class, native plugin sources, build config, podspec, gradle) is © 2026 Niels Leenheer under the **[MIT license](LICENSE)**.
-   **The vendored Epson binaries** (`ios/Frameworks/libepos2.xcframework`, `android/libs/ePOS2.jar`, `android/src/main/jniLibs/**/libepos2.so`) are Epson's, distributed under the **Epson End User Software License Agreement** — see **[`EPSON-EULA.en.txt`](EPSON-EULA.en.txt)**.

The 2023-revision EULA (§1) expressly grants the right to create "Derivative Software Products" — *explicitly including plug-ins* — and to distribute the Software as an integrated component of them. The obligations honored here: the binaries are used only with Epson hardware (§2.1); no reverse engineering (§2.5); and per **§2.2 the EULA text accompanies the binaries** wherever they are distributed — so `EPSON-EULA.en.txt` is committed next to them and included in the published package (`files`). **Re-read the shipped EULA on every SDK bump** — Epson has revised it before and the terms could tighten.

<br>

## iOS notes (E1)

The Swift plugin lands in E1. The podspec already vendors the static xcframework, links `ExternalAccessory` + `CoreBluetooth`, ships the privacy manifest, and targets **iOS 15.0** (ePOS2's floor — already the app's floor via the Star work, so no deployment-target change). Classic-BT Epson printers are **MFi accessories**: the app's `Info.plist` gains `com.epson.escpos` in `UISupportedExternalAccessoryProtocols`, and an Epson MFi app registration (Application Information Sheet → PPID) is required before App Store submission (development on registered test devices proceeds meanwhile). LAN-only and BLE are exempt from MFi.

## Android notes (B1)

The Kotlin plugin lands in B1, reached under the registration key `EpsonEposReceiptPrinter`. Because the ePOS2 SDK carries no manifest of its own, this plugin's `AndroidManifest.xml` declares the full Bluetooth permission set itself — the legacy `BLUETOOTH`/`BLUETOOTH_ADMIN` (`maxSdkVersion="30"`) and the Android 12+ runtime `BLUETOOTH_SCAN` (`neverForLocation`) / `BLUETOOTH_CONNECT`, plus `INTERNET` for the LAN leg. On Android 12+ the two runtime grants must be requested before `discover()`/`connect()` — the JS class wraps that in `ensurePermissions()`, backed by the plugin's `bluetooth` `@CapacitorPlugin` alias.

<br>

## Installation in the Salonhub Application

Consumed as a `file:` dependency from a sibling checkout under `~/Projects/Dependencies`. It is a **dual install** — the JS half in the Application's own `package.json` (feeds the grunt web build via the device-library emission), the native half in `build/capacitor/package.json` (feeds the Capacitor CLI). Both `file:` paths point at the same checkout so they cannot drift.

```json
"@point-of-sale/capacitor-epson-epos-receipt-printer": "file:../Dependencies/CapacitorEpsonEposReceiptPrinter"
```

The `package.json` `"capacitor"` block declares both `ios` and `android`, so a plain npm install auto-registers the plugin the usual Capacitor way.

<br>

-----

<br>

The wrapper code for this plugin has been created by Niels Leenheer under the [MIT license](LICENSE); the vendored Epson ePOS2 SDK binaries are licensed separately under the [Epson EULA](EPSON-EULA.en.txt). The development of this plugin is sponsored by Salonhub.

<a href="https://salonhub.nl"><img src="https://salonhub.nl/assets/images/salonhub.svg" width=140></a>
