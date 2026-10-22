<#
.SYNOPSIS
    Arranca el kernel SWEET de XNU en QEMU sobre Windows/macOS/Linux.

.DESCRIPTION
    Equivalente a los pasos del README del proyecto, pero sin shim ni telefono:
      mkadt.py --qemu  ->  sweet-init (si hay clang)  ->  mkpayload.py  ->  qemu-sweet.py

    Lo que se puede ver aqui es el kernel arrancando de verdad: memoria, GICv3,
    timer, pmap, BSD init y (con el init de prueba en un RAM disk) el primer
    proceso de usuario. NO se puede ver SpringBoard/iOS: la GUI depende del
    panel, UFS, PMIC y I2C del telefono, que QEMU virt no modela.

.EXAMPLE
    pwsh -File pc/run-pc.ps1 -Secs 240 -LiveSerial
    pwsh -File pc/run-pc.ps1 -Kernel D:\xnu\kernel.development.sweet -NoRamdisk
#>
[CmdletBinding()]
param(
    [string]$Kernel = '',
    [int]$Secs = 240,
    [switch]$Highmem,
    [switch]$NoRamdisk,
    [switch]$LiveSerial,
    [string]$Cpu = 'cortex-a76'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $PSScriptRoot 'out-run'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$py = 'python'

if (-not $Kernel) { $Kernel = Join-Path $root 'xnu/out/kernel.development.sweet' }
if (-not (Test-Path $Kernel)) {
    Write-Host "[!] No hay kernel en $Kernel" -ForegroundColor Yellow
    Write-Host '    El kernel no esta en git: hay que compilarlo (pc/build-kernel.ps1)' -ForegroundColor Yellow
    Write-Host '    o pasar -Kernel RUTA.' -ForegroundColor Yellow
    exit 1
}

$adtArgs = @((Join-Path $out 'qemu.adt'), '--qemu')
if ($Highmem) { $adtArgs += '--highmem' }
Write-Host '[*] ADT para QEMU virt' -ForegroundColor Cyan
& $py (Join-Path $root 'tools/mkadt.py') @adtArgs
if ($LASTEXITCODE -ne 0) { throw 'mkadt.py fallo' }

$ramdisk = $null
if (-not $NoRamdisk) {
    $clang = (Get-Command clang -ErrorAction SilentlyContinue).Source
    if (-not $clang -and (Test-Path "$env:ProgramFiles\LLVM\bin\clang.exe")) {
        $clang = "$env:ProgramFiles\LLVM\bin\clang.exe"
    }
    if ($clang) {
        Write-Host '[*] init de prueba para el RAM disk (rd=md0)' -ForegroundColor Cyan
        & $clang -target arm64-apple-ios16.0 -c (Join-Path $root 'tools/sweet-init.S') -o (Join-Path $out 'sweet-init.o')
        if ($LASTEXITCODE -eq 0) {
            & $py (Join-Path $root 'tools/mkinit.py') (Join-Path $out 'sweet-init.o') (Join-Path $out 'sweet-init')
            if ($LASTEXITCODE -eq 0) { $ramdisk = Join-Path $out 'sweet-init' }
        }
        if (-not $ramdisk) { Write-Host '[..] no se pudo construir sweet-init; sigo sin RAM disk' -ForegroundColor Yellow }
    } else {
        Write-Host '[..] clang no disponible; sigo sin RAM disk' -ForegroundColor Yellow
    }
}

$cmdline = 'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress'
if ($ramdisk) { $cmdline += ' rd=md0' }
$payload = Join-Path $out 'payload.bin'
$mk = @((Join-Path $root 'tools/mkpayload.py'), $Kernel, (Join-Path $out 'qemu.adt'), $payload, '--cmdline', $cmdline)
if ($ramdisk) { $mk += @('--ramdisk', $ramdisk) }
Write-Host '[*] payload SWEETXNU' -ForegroundColor Cyan
& $py @mk
if ($LASTEXITCODE -ne 0) { throw 'mkpayload.py fallo' }

$run = @((Join-Path $root 'tools/qemu-sweet.py'), $payload, (Join-Path $out 'run'),
         '--secs', $Secs, '--kernel', $Kernel, '--fail-on-panic', '--cpu', $Cpu)
if ($LiveSerial) { $run += '--live-serial' }
Write-Host "[*] QEMU, $Secs s (TCG: el arranque real tarda minutos)" -ForegroundColor Cyan
& $py @run
exit $LASTEXITCODE
