<#
.SYNOPSIS
    Autotest del arnes QEMU en Windows: no necesita el kernel de XNU ni CI.

.DESCRIPTION
    Compila un "kernel" falso de 12 instrucciones (pc/selftest-kernel.S) que
    pinta de verde la parte alta del framebuffer de 1080x2400 y se queda
    colgado. Pasa por la misma cadena que el kernel real:
      clang -> mkinit.py -> mkadt.py --qemu -> mkpayload.py -> qemu-sweet.py
    y comprueba que QEMU ejecuto el codigo y que la captura del framebuffer
    por QMP funciona. Si esto pasa, el port a PC esta sano.
#>
[CmdletBinding()]
param(
    [int]$Secs = 8
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $PSScriptRoot 'out-selftest'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$py = 'python'

function Find-Tool([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallbacks = @("$env:ProgramFiles\LLVM\bin\$Name.exe", "$env:ProgramFiles\qemu\$Name.exe")
    foreach ($f in $fallbacks) { if (Test-Path $f) { return $f } }
    return $null
}

$clang = Find-Tool clang
if (-not $clang) { throw 'clang no encontrado: winget install LLVM.LLVM' }

Write-Host '[*] 1/5 compilando el kernel de prueba (Mach-O arm64)' -ForegroundColor Cyan
& $clang -target arm64-apple-ios16.0 -c (Join-Path $PSScriptRoot 'selftest-kernel.S') -o (Join-Path $out 'selftest.o')
if ($LASTEXITCODE -ne 0) { throw 'clang fallo' }

Write-Host '[*] 2/5 envolviendo en un ejecutable Mach-O (mkinit.py)' -ForegroundColor Cyan
& $py (Join-Path $root 'tools/mkinit.py') (Join-Path $out 'selftest.o') (Join-Path $out 'selftest.macho')
if ($LASTEXITCODE -ne 0) { throw 'mkinit.py fallo' }

Write-Host '[*] 3/5 generando el Apple Device Tree de QEMU' -ForegroundColor Cyan
& $py (Join-Path $root 'tools/mkadt.py') (Join-Path $out 'qemu.adt') --qemu
if ($LASTEXITCODE -ne 0) { throw 'mkadt.py fallo' }

Write-Host '[*] 4/5 empaquetando el payload SWEETXNU' -ForegroundColor Cyan
& $py (Join-Path $root 'tools/mkpayload.py') (Join-Path $out 'selftest.macho') (Join-Path $out 'qemu.adt') `
    (Join-Path $out 'selftest.bin') --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -noprogress'
if ($LASTEXITCODE -ne 0) { throw 'mkpayload.py fallo' }

Write-Host "[*] 5/5 arrancando QEMU $Secs s" -ForegroundColor Cyan
& $py (Join-Path $root 'tools/qemu-sweet.py') (Join-Path $out 'selftest.bin') (Join-Path $out 'run') `
    --secs $Secs --hmp 'x /4wx 0x9c000000'
$rc = $LASTEXITCODE

$regs = Join-Path $out 'run/regs.txt'
$log = Join-Path $out 'run/qemu.log'
$ok = $false
if (Test-Path $regs) {
    $text = Get-Content $regs -Raw
    $ok = $text -match '0xff00ff00'
    if ($ok) { Write-Host '[ok] el invitado escribio en el framebuffer (0xff00ff00)' -ForegroundColor Green }
    else { Write-Host '[!!] no aparece 0xff00ff00 en regs.txt' -ForegroundColor Red }
}
if (Test-Path $log) {
    $ex = (Get-Content $log | Select-String 'Taking exception').Count
    if ($ex -eq 0) { Write-Host '[ok] sin excepciones de CPU' -ForegroundColor Green }
    else { Write-Host "[!!] $ex excepciones en qemu.log" -ForegroundColor Red; $ok = $false }
}
if (Test-Path (Join-Path $out 'run/fb.png')) { Write-Host "[ok] captura: $(Join-Path $out 'run/fb.png')" -ForegroundColor Green }

if ($ok) { Write-Host '[ok] arnes QEMU en Windows funcionando' -ForegroundColor Green; exit 0 }
Write-Host '[!] autotest fallido (codigo qemu-sweet: ' -NoNewline -ForegroundColor Yellow
Write-Host "$rc)" -ForegroundColor Yellow
exit 1
