<#
.SYNOPSIS
    Comprueba (e instala, si se pide) las dependencias del port a PC de ios-sweet.

.DESCRIPTION
    QEMU (qemu-system-aarch64), LLVM (clang + llvm-nm) y Python 3.
    Sin -Install solo informa y devuelve codigo 1 si falta algo.

.EXAMPLE
    pwsh -File pc/setup-pc.ps1
    pwsh -File pc/setup-pc.ps1 -Install
#>
[CmdletBinding()]
param(
    [switch]$Install
)

$ErrorActionPreference = 'Stop'

function Find-Tool([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # winget/MSI installs often land here without refreshing the current PATH
    $fallbacks = @(
        "$env:ProgramFiles\LLVM\bin\$Name.exe",
        "$env:ProgramFiles\qemu\$Name.exe",
        "$env:ProgramFiles\GitHub CLI\$Name.exe"
    )
    foreach ($f in $fallbacks) {
        if ($f -and (Test-Path $f)) { return $f }
    }
    return $null
}

function Install-Package([string]$Id) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget no esta disponible; instala $Id a mano."
    }
    Write-Host "[*] winget install $Id" -ForegroundColor Cyan
    winget install --id $Id -e --accept-source-agreements --accept-package-agreements --disable-interactivity
}

$missing = @()

# --- Python -------------------------------------------------------------
$py = Find-Tool python
if ($py) {
    $ver = (& $py --version) 2>&1
    Write-Host "[ok] $ver -> $py"
} else {
    Write-Host "[!!] Python 3 no encontrado" -ForegroundColor Yellow
    $missing += 'python'
}

# --- QEMU ---------------------------------------------------------------
$qemu = Find-Tool qemu-system-aarch64
if (-not $qemu -and $Install) { Install-Package 'SoftwareFreedomConservancy.QEMU'; $qemu = Find-Tool qemu-system-aarch64 }
if ($qemu) {
    $qver = (& $qemu --version | Select-Object -First 1)
    Write-Host "[ok] $qver -> $qemu"
    $cpus = (& $qemu -M virt -cpu help) 2>&1 | Out-String
    if ($cpus -match 'cortex-a76') {
        Write-Host '[ok] modelo de CPU cortex-a76 disponible'
    } else {
        Write-Host '[!!] cortex-a76 no aparece en -cpu help (prueba -Cpu max)' -ForegroundColor Yellow
        $missing += 'qemu-cpu'
    }
} else {
    Write-Host '[!!] qemu-system-aarch64 no encontrado' -ForegroundColor Yellow
    $missing += 'qemu'
}

# --- LLVM ---------------------------------------------------------------
$clang = Find-Tool clang
$nm = Find-Tool llvm-nm
if ((-not $clang -or -not $nm) -and $Install) {
    Install-Package 'LLVM.LLVM'
    $clang = Find-Tool clang
    $nm = Find-Tool llvm-nm
}
if ($clang) { Write-Host "[ok] clang -> $clang" } else { Write-Host '[!!] clang no encontrado' -ForegroundColor Yellow; $missing += 'clang' }
if ($nm)    { Write-Host "[ok] llvm-nm -> $nm" } else { Write-Host '[!!] llvm-nm no encontrado (solo hace falta con --kernel)' -ForegroundColor Yellow; $missing += 'llvm-nm' }

# --- gh (opcional) ------------------------------------------------------
$gh = Find-Tool gh
if ($gh) { Write-Host "[ok] gh -> $gh" } else { Write-Host '[..] gh no instalado (solo necesario para compilar el kernel en CI)' }

Write-Host ''
if ($missing.Count -eq 0) {
    Write-Host '[ok] entorno listo' -ForegroundColor Green
    exit 0
}
Write-Host ("[!] Falta: " + ($missing -join ', ')) -ForegroundColor Yellow
if (-not $Install) { Write-Host '    vuelve a ejecutar con -Install' }
exit 1
