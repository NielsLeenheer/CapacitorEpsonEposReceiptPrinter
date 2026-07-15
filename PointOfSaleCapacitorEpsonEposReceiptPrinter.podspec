require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name = 'PointOfSaleCapacitorEpsonEposReceiptPrinter'
  s.version = package['version']
  s.summary = package['description']
  s.license = package['license']
  s.homepage = 'https://github.com/NielsLeenheer/CapacitorEpsonEposReceiptPrinter'
  s.author = package['author']
  s.source = { :git => 'https://github.com/NielsLeenheer/CapacitorEpsonEposReceiptPrinter.git', :tag => s.version.to_s }
  s.source_files = 'ios/Plugin/**/*.{swift,h,m}'

  # ePOS2 needs iOS 15+ (SDK-supported 15–18.5 + iPadOS 26). The Application's
  # iOS 15 floor was already set by the Star work (its R2 sign-off), so there is
  # no deployment-target work here — this matches that floor.
  s.ios.deployment_target = '15.0'

  s.dependency 'Capacitor'

  # Epson ePOS2 SDK linkage — STATIC (decided at E0, plan D-P8).
  #
  # The SDK ships BOTH libepos2.xcframework (dynamic) and
  # libepos2-static.xcframework (static). We vendor the STATIC one — it is the
  # simplest `vendored_frameworks` drop-in — RENAMED to libepos2.xcframework
  # (the `-static` suffix dropped) at the vendored path. Both slices
  # (ios-arm64 device + ios-arm64_x86_64-simulator) are present, so it links for
  # device AND simulator. The binaries are COMMITTED here (D-P8 — the 2023 EULA
  # permits redistribution as an integrated plug-in component), so there is NO
  # fetch-at-install step and NO prepare_command: a fresh clone + `pod install`
  # just works. Refresh from a new SDK ZIP with scripts/update-epson-sdk.sh.
  s.vendored_frameworks = 'ios/Frameworks/libepos2.xcframework'

  # PrivacyInfo.xcprivacy (App Store privacy-manifest requirement). The STATIC
  # xcframework cannot carry its own resources (a static .a is not a bundle), so
  # the SDK ships the manifest standalone — we deliver it into the app bundle via
  # a resource bundle. (If a consuming toolchain does not pick this up, the app
  # can instead add ios/Frameworks/PrivacyInfo.xcprivacy to its own target — see
  # the README.)
  s.resource_bundles = {
    'PointOfSaleCapacitorEpsonEposReceiptPrinter_Privacy' => ['ios/Frameworks/PrivacyInfo.xcprivacy']
  }

  # ePOS2 transports: classic Bluetooth is an MFi accessory (ExternalAccessory,
  # com.epson.escpos), BLE uses CoreBluetooth.
  s.frameworks = 'ExternalAccessory', 'CoreBluetooth'

  s.swift_version = '5.1'
end
