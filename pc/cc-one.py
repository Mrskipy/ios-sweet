#!/usr/bin/env python3
"""Compile one XNU source file locally with the flags of the CI build tree.

  cc-one.py BUILDTREE SOURCE [extra clang args...]

BUILDTREE is an extracted `xnu-buildtree` artifact (xnu/, build/xnu.obj/,
fakeroot/). Paths recorded in DEVELOPMENT_ARM64_SWEET/.CFLAGS point at the
GitHub runner; they are remapped to BUILDTREE. Needs clang; by default
`clang` from PATH, or set XNU_CLANG.

This is a syntax/type check, not a bit-identical object: -mkernel, -arch and
the macOS deployment flag are dropped and a Darwin target triple is added.
Use XNU_CC_OBJDIR to emit a real object for llvm-nm checks.
"""
import os, shlex, shutil, subprocess, sys

DROP = {'-arch', '-mkernel', '-mmacosx-version-min', '-c', '-o', '-g'}
CI_DXB = '/Users/runner/work/ios-sweet/ios-sweet/dxb'
CI_SDK = ('/Applications/Xcode_15.0.1.app/Contents/Developer/Platforms/'
          'MacOSX.platform/Developer/SDKs/MacOSX14.0.sdk//System/Library/'
          'Frameworks/Kernel.framework/Versions/A/PrivateHeaders/platform')


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    bt, src = os.path.abspath(argv[1]), argv[2]
    cflags = open(os.path.join(bt, 'build/xnu.obj/DEVELOPMENT_ARM64_SWEET/.CFLAGS'),
                  encoding='utf-8').read().replace('\x00', ' ').split()
    if cflags and cflags[0].endswith('clang'):
        cflags = cflags[1:]
    clang = os.environ.get('XNU_CLANG', 'clang')
    if src.endswith(('.cpp', '.cc')):
        clang = os.path.join(os.path.dirname(shutil.which(clang) or clang), 'clang++')
    args, i = [clang], 0
    while i < len(cflags):
        f = cflags[i]
        if f in DROP:
            i += 2                      # drop the flag and its argument
            continue
        if f == '-c':
            i += 1
            continue
        if CI_DXB in f:
            f = f.replace(CI_DXB, bt)
        if CI_SDK in f:
            f = f.replace(CI_SDK, os.path.join(bt, 'sdk-kernel-platform'))
        args.append(f)
        i += 1
    args += ['-target', 'arm64-apple-macos14', '-ffreestanding']
    # -nostdinc hides the SDK; stdatomic.h comes from clang's resource dir.
    real = shutil.which(clang) or clang
    res = os.path.join(os.path.dirname(os.path.abspath(real)), '..', 'lib', 'clang')
    if os.path.isdir(res):
        for v in os.listdir(res):
            inc = os.path.join(res, v, 'include')
            if os.path.isfile(os.path.join(inc, 'stdatomic.h')):
                args += ['-isystem', inc]
                break
    objdir = os.environ.get('XNU_CC_OBJDIR')
    args.append('-c' if objdir else '-fsyntax-only')
    if objdir:
        args += ['-o', os.path.join(objdir, os.path.basename(src) + '.o')]
    args += argv[3:] + [src]
    print(' '.join(shlex.quote(a) for a in args))
    return subprocess.call(args)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
