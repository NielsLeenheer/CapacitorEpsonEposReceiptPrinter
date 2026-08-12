import EventEmitter from "./event-emitter.js";

/*
	Hardware bring-up logging. Every line is tagged `[SH-POS][Epson/js]` so it can
	be filtered in the device console. Capacitor forwards webview console.* to the
	native log (Xcode / Console.app on iOS, logcat on Android), and Safari Web
	Inspector shows it directly. Remove once ePOS2 discovery/connect is proven on
	device.
*/
function log(...args) {
	try {
		console.log('[SH-POS][Epson/js]', ...args);
	} catch (e) {}
}

/* True only when the native plugin is actually registered under the Capacitor
   runtime; safe to call on web (no throw). */
function pluginPresence() {
	let cap = typeof window !== 'undefined' ? window.Capacitor : undefined;
	let platform = cap && typeof cap.getPlatform === 'function' ? cap.getPlatform() : 'web';
	let registered = !!(cap && cap.Plugins && cap.Plugins.EpsonEposReceiptPrinter);
	return { platform, registered };
}

class ReceiptPrinterDriver {}

/*
	Thin raw-bytes transport for an Epson receipt printer, driving the native
	Epson ePOS2 plugin. The native side owns a single open connection (analysis
	plan D2/D3); this class is a client of it and stays interchangeable with the
	other capacitor receipt-printer transports (capacitor/bluetooth.js,
	capacitor/network.js, capacitor/star.js).

	Epson twin of CapacitorStarIOReceiptPrinter: same surface, minus the scanner
	(Epson TM printers have no mPOP-style input device — D-P6). Receipts are built
	and encoded to ESC/POS app-side (ReceiptPrinterEncoder, the existing epson-tm-*
	presets, D-P2 raw mode); this class only writes those bytes through the SDK's
	addCommand -> sendData raw pass-through via the native print() call. The single
	native plugin is reached under the registration key EpsonEposReceiptPrinter
	(Star convention — project name minus the Capacitor prefix, D-P7).
*/

class CapacitorEpsonEposReceiptPrinter extends ReceiptPrinterDriver {

	#emitter;
	#connected = false;
	#listener = null;

	constructor() {
		super();

		this.#emitter = new EventEmitter();
	}

	get #plugin() {
		return window.Capacitor.Plugins.EpsonEposReceiptPrinter;
	}

	/* Is an ePOS2-capable native plugin present on this device? */

	async isAvailable() {
		let { platform, registered } = pluginPresence();
		log('isAvailable() called; platform =', platform, '; plugin registered =', registered);

		if (!registered) {
			log('isAvailable() → false (native plugin not registered on this runtime)');
			return false;
		}

		let result = await this.#plugin.isAvailable();
		log('isAvailable() → native reports available =', result && result.available);

		return result.available === true;
	}

	/*
		Ensure the Android 12+ (API 31) runtime "Nearby devices" grants
		(BLUETOOTH_SCAN + BLUETOOTH_CONNECT) are held before discover()/connect().
		The app's pairing path calls this first.

		Cleaner surface than folding the request into discover(): permissions are
		a one-time UX concern the app owns, so it stays an explicit call rather
		than a hidden side effect of every discovery.

		No-op everywhere it should be:
		  - web: no native plugin, nothing to request.
		  - iOS: classic-BT (MFi) and BLE are gated by the Info.plist usage
		    strings / MFi accessory protocol, not a Capacitor runtime prompt —
		    Epson needs no runtime permission call here.
		  - Android below API 31: the legacy strings are install-time, so the
		    native checkPermissions() resolves them `granted` and no prompt appears.
		Only Android 12+ actually surfaces the system prompt. Backed by the native
		`bluetooth` permission alias (@CapacitorPlugin), which makes Capacitor's
		built-in checkPermissions()/requestPermissions() available.
	*/

	async ensurePermissions() {
		let platform = window.Capacitor && typeof window.Capacitor.getPlatform === 'function'
			? window.Capacitor.getPlatform()
			: 'web';

		if (platform !== 'android') {
			return { bluetooth: 'granted' };
		}

		let status = await this.#plugin.checkPermissions();

		if (status.bluetooth !== 'granted') {
			status = await this.#plugin.requestPermissions();
		}

		return status;
	}

	/*
		Discover reachable Epson devices per interface. One-shot (D3 — the MVP
		needs no streaming discovery events). Returns an array of
		{ interface, identifier, model } (D-P3 — the model lets the transport map
		to a ReceiptPrinterEncoder printerModel, e.g. 'TM-m30III' -> 'epson-tm-m30iii',
		and the settings UI show what it found). The app's pairing flow (the
		.deviceSelector window, D4) presents these; the driver itself opens no UI.

		`interfaces` is a per-call filter (D3): callers may limit discovery to
		certain protocols, but the plugin itself is NEVER protocol-limited — the
		full D-P3 surface is always compiled in, and filtering is purely the
		caller's choice. Salonhub's concrete MVP filter omits 'lan' (network Epson
		printing stays on the proven TCP-9100 path).

		Interface types (ePOS2 SDK per platform):
		'lan', 'bluetooth', 'bluetoothLE', 'usb'. On iOS the practical interfaces
		are LAN, Bluetooth classic (MFi/iAP2), BLE (P20II/P80II generation) and USB
		(MFi, m30/m50-family only). On Android: LAN, Bluetooth classic (SPP) and USB
		(VID 0x04B8) — ePOS2 has no BLE on Android, so a requested 'bluetoothLE'
		simply returns no devices there, it does not error.
	*/

	async discover(options, onFound) {
		options = Object.assign({
			interfaces: ['lan', 'bluetooth', 'bluetoothLE', 'usb'],
			timeout: 5000
		}, options || {});

		let { platform, registered } = pluginPresence();
		log('discover() called; platform =', platform, '; plugin registered =', registered, '; options =', JSON.stringify(options));

		if (!registered) {
			log('discover() ABORT — window.Capacitor.Plugins.EpsonEposReceiptPrinter is undefined; returning []');
			return [];
		}

		let started = Date.now();

		/* The native side runs discovery for its whole window and only then
		   resolves. When the caller wants them as they arrive — a pairing list
		   that fills instead of sitting empty — it passes onFound and gets each
		   printer the moment the SDK reports it; the resolve still carries the
		   complete set. */

		let listener = onFound
			? await this.#plugin.addListener('printerFound', (device) => {
				log('discover() printerFound:', JSON.stringify(device));
				onFound(device);
			})
			: null;

		try {
			let result = await this.#plugin.discover(options);
			let devices = (result && result.devices) || [];
			log('discover() resolved after', (Date.now() - started) + 'ms;', devices.length, 'device(s):', JSON.stringify(devices));
			return devices;
		} catch (e) {
			log('discover() REJECTED after', (Date.now() - started) + 'ms:', (e && (e.message || e.errorMessage)) || e);
			throw e;
		} finally {
			if (listener) {
				await listener.remove();
			}
		}
	}

	/*
		Open the single native connection to the chosen device. Double-connect
		is a no-op (R6 twin): the native side treats connect-on-already-open as
		idempotent, and this JS guard short-circuits before the round trip.

		`device` is a { interface, identifier } descriptor from discover() — the
		persisted-settings shape the app's transport stores (D4). When omitted the
		native side connects to the first found device. The native single-connection
		lifecycle owns same-device (no-op) vs different-device (disconnect-first)
		behaviour; this JS guard is the short-circuit that skips the round trip
		when already connected.
	*/

	async connect(device) {
		if (this.#connected) {
			log('connect() no-op — already connected (JS guard)');
			return;
		}

		log('connect() called; device =', JSON.stringify(device || null));

		let started = Date.now();

		try {
			await this.#plugin.connect(device ? {
				interface: device.interface,
				identifier: device.identifier
			} : {});
			log('connect() native connect resolved after', (Date.now() - started) + 'ms');
		} catch (e) {
			log('connect() native connect REJECTED after', (Date.now() - started) + 'ms:', (e && (e.message || e.errorMessage)) || e);
			throw e;
		}

		/* Reflect native-initiated drops (printer power-cycle, background/resume
		   — R8: EA sessions drop on background) so the shared connected state
		   stays truthful. */

		this.#listener = await this.#plugin.addListener('disconnected', () => {
			this.#handleDisconnected();
		});

		this.#connected = true;

		this.#emitter.emit('connected', Object.assign({ type: 'epson' }, device || {}));
	}

	async reconnect(previousDevice) {
		await this.connect(previousDevice);
	}

	async disconnect() {
		if (!this.#connected) {
			return;
		}

		if (this.#listener) {
			await this.#listener.remove();
			this.#listener = null;
		}

		await this.#plugin.disconnect();

		this.#connected = false;

		this.#emitter.emit('disconnected');
	}

	#handleDisconnected() {
		log('native "disconnected" event received');

		if (!this.#connected) {
			return;
		}

		if (this.#listener) {
			this.#listener.remove();
			this.#listener = null;
		}

		this.#connected = false;

		this.#emitter.emit('disconnected');
	}

	get connected() {
		return this.#connected;
	}

	/*
		Print raw, already-encoded printer commands. The bytes are ESC/POS,
		produced app-side by ReceiptPrinterEncoder (the existing epson-tm-*
		presets, D-P2 raw mode) — this class is only the transport, shipping those
		bytes to the printer through the SDK's addCommand -> sendData raw path via
		the native print() call.
	*/

	async print(command) {
		let data = this.#encode(command);

		await this.#plugin.print({ data });
	}

	/*
		Kick the cash drawer. The drawer has no dedicated MVP API (D-P5): the kick
		is rendered pulse bytes sent over the very same raw print path, as on every
		other transport. `command` is those rendered bytes.
	*/

	async kick(command) {
		let data = this.#encode(command);

		await this.#plugin.print({ data });
	}

	/*
		Printer state, for print-failure telemetry. Resolves the D3 shape mapped
		from the SDK's status machinery:
		{ connected, model, coverOpen, paperEmpty, paperNearEmpty }.
		When nothing is connected it resolves { connected: false }. Currently
		unused app-side (status UI is out of scope, §8) — present for parity with
		the Star surface.
	*/

	async getStatus() {
		let result = await this.#plugin.getStatus();

		return result;
	}

	#encode(command) {
		let bytes = command instanceof Uint8Array ? command : Uint8Array.from(command);
		let binary = '';

		for (let i = 0; i < bytes.length; i += 0x8000) {
			binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
		}

		return btoa(binary);
	}

	addEventListener(n, f) {
		this.#emitter.on(n, f);
	}
}

export { CapacitorEpsonEposReceiptPrinter };
export default CapacitorEpsonEposReceiptPrinter;
