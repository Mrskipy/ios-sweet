// pc/selftest-kernel.S -- a fake "kernel" that proves the QEMU harness works
// on a PC without Apple CI artifacts: it paints the top of the 1080x2400
// framebuffer green and spins. No MMU, no XNU, no dependencies.
//
//   clang -target arm64-apple-ios16.0 -c pc/selftest-kernel.S -o selftest.o
//   python tools/mkinit.py selftest.o selftest.macho
//   python tools/mkadt.py q.adt --qemu
//   python tools/mkpayload.py selftest.macho q.adt selftest.bin --cmdline "debug=0xc"
//   python tools/qemu-sweet.py selftest.bin out --secs 8 --hmp "x /4wx 0x9c000000"
//
// The kernel entry contract is x0 = boot_args; this stub ignores it.
// Everything is position independent (adr/branch only) so mkinit.py accepts it.

	.text
	.global _start
_start:
	movz	x0, #0x9c00, lsl #16		// framebuffer physical base 0x9c000000
	movz	w1, #0xff00			// ARGB 0xff00ff00 (opaque green)
	movk	w1, #0xff00, lsl #16
	movz	x2, #0xf1a0			// 1080 * 300 pixels = 0x0004f1a0
	movk	x2, #0x4, lsl #16
1:	str	w1, [x0], #4
	subs	x2, x2, #1
	b.ne	1b
2:	wfe					// park the CPU
	b	2b
