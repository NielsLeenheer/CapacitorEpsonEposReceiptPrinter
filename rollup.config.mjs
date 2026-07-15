import resolve from '@rollup/plugin-node-resolve';
import commonjs from '@rollup/plugin-commonjs';
import terser from '@rollup/plugin-terser';

export default [
	// browser-friendly UMD build, one class per file

	{
		input: 'src/main-printer.js',
		output: {
			name: 'CapacitorEpsonEposReceiptPrinter',
			file: 'dist/capacitor-epson-epos-receipt-printer.umd.js',
			sourcemap: true,
			format: 'umd'
		},
		plugins: [
			resolve(),
			commonjs(),
			terser()
		]
	},

	// self-contained ES module build

	{
		input: 'src/main-printer.js',
		output: {
			file: 'dist/capacitor-epson-epos-receipt-printer.esm.js',
			sourcemap: true,
			format: 'es'
		},
		plugins: [
			resolve(),
			commonjs(),
			terser()
		]
	}
];
