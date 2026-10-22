<#
.SYNOPSIS
    Compila el kernel SWEET (xnu-8796 arm64) en GitHub Actions y baja el artefacto.

.DESCRIPTION
    XNU para arm64 necesita macOS + Xcode: no se puede compilar de forma nativa
    en Windows (ni con clang/lld de Windows). El propio proyecto usa un runner
    macOS (workflow .github/workflows/xnu.yml). Este script automatiza:

      fork (opcional) -> push -> gh workflow run xnu.yml -> esperar -> descargar

    El artefacto queda en xnu/out/kernel.development.sweet, que es lo que
    pc/run-pc.ps1 espera.

.EXAMPLE
    pwsh -File pc/build-kernel.ps1 -Fork
    pwsh -File pc/build-kernel.ps1 -Repo mi-usuario/ios-sweet
#>
[CmdletBinding()]
param(
    [string]$Repo = '',
    [string]$Ref = 'main',
    [switch]$Fork
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'Falta gh (GitHub CLI): winget install GitHub.cli'
}
& gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host '[!] gh no tiene sesion. Ejecuta: gh auth login' -ForegroundColor Yellow
    exit 1
}

Push-Location $root
try {
    if (-not $Repo) {
        $Repo = (& gh repo view --json nameWithOwner -q .nameWithOwner)
        $owner = $Repo.Split('/')[0]
        if ($owner -eq 'dipa-studio' -and -not $Fork) {
            Write-Host "[!] $Repo es el repo original: no puedes lanzar workflows ahi." -ForegroundColor Yellow
            Write-Host '    Usa -Fork (crea tu fork, sube el codigo y compila alli) o -Repo TU/FORK.' -ForegroundColor Yellow
            exit 1
        }
    }

    if ($Fork) {
        $origin = (& gh repo view --json nameWithOwner -q .nameWithOwner)
        Write-Host "[*] fork de $origin" -ForegroundColor Cyan
        & gh repo fork $origin --clone=false --remote=false
        if ($LASTEXITCODE -ne 0) { throw 'gh repo fork fallo' }
        $Repo = (& gh api user -q .login) + '/' + $origin.Split('/')[1]
        if (-not (git remote | Select-String -Quiet '^fork$')) {
            git remote add fork "https://github.com/$Repo.git"
        }
        Write-Host "[*] push a $Repo ($Ref)" -ForegroundColor Cyan
        git push fork "HEAD:$Ref"
        if ($LASTEXITCODE -ne 0) { throw 'git push fallo' }
    }

    Write-Host "[*] lanzando xnu.yml en $Repo ($Ref)" -ForegroundColor Cyan
    & gh workflow run xnu.yml -R $Repo --ref $Ref
    if ($LASTEXITCODE -ne 0) { throw 'gh workflow run fallo' }
    Start-Sleep -Seconds 5

    $runId = (& gh run list -R $Repo --workflow xnu.yml -L 1 --json databaseId -q '.[0].databaseId')
    if (-not $runId) { throw 'no encuentro el run recien lanzado' }
    Write-Host "[*] run $runId; esperando (5-15 min de runner macOS)..." -ForegroundColor Cyan
    & gh run watch $runId -R $Repo --exit-status
    $status = $LASTEXITCODE

    Write-Host '[*] descargando artefacto xnu-kernel' -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'xnu/out') | Out-Null
    & gh run download $runId -R $Repo -n xnu-kernel -D (Join-Path $root 'xnu/out')

    $kernel = Join-Path $root 'xnu/out/kernel.development.sweet'
    if (Test-Path $kernel) {
        Write-Host "[ok] kernel: $kernel" -ForegroundColor Green
        Get-Content (Join-Path $root 'xnu/out/SHA256SUMS') -ErrorAction SilentlyContinue
    } elseif ($status -ne 0) {
        Write-Host "[!] el build fallo; mira: gh run view $runId -R $Repo --log-failed" -ForegroundColor Red
        exit 1
    } else {
        Write-Host '[!] el artefacto no trae kernel.development.sweet' -ForegroundColor Yellow
        Get-ChildItem (Join-Path $root 'xnu/out') | Format-Table Name, Length
        exit 1
    }
    exit 0
}
finally {
    Pop-Location
}
