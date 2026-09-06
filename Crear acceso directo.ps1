#Requires -Version 5.1
<#
    Crea el acceso directo del Limpiador de USB en el Escritorio.

    Queda marcado para abrirse SIEMPRE como administrador: eso no se puede
    poner desde WScript.Shell, hay que encender un bit del propio archivo
    .lnk (el 0x20 del byte 0x15).
#>
[CmdletBinding()]
param(
    # Carpeta donde dejar el acceso directo. Por defecto, el Escritorio.
    [string]$Destino,
    # Nombre del acceso directo, sin extension.
    [string]$Nombre = 'Limpiador de USB'
)

$ErrorActionPreference = 'Stop'

$base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ps1 = Join-Path $base 'Limpiador-USB.ps1'
if (-not (Test-Path -LiteralPath $ps1)) {
    Write-Host "  No encuentro Limpiador-USB.ps1 junto a este script." -ForegroundColor Red
    Write-Host "  Buscado en: $base" -ForegroundColor DarkGray
    exit 1
}

if (-not $Destino) { $Destino = [Environment]::GetFolderPath('Desktop') }
if (-not (Test-Path -LiteralPath $Destino)) {
    New-Item -ItemType Directory -Path $Destino -Force | Out-Null
}
$lnk = Join-Path $Destino ($Nombre + '.lnk')

$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut($lnk)
$s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$s.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $ps1
$s.WorkingDirectory = $base
$s.Description = 'Limpiador de USB - limpiar, formatear, reparar, grabar imagenes y diagnosticar discos'

$ico = Join-Path $base 'limpiador.ico'
$s.IconLocation = if (Test-Path -LiteralPath $ico) {
    "$ico,0"
} else {
    (Join-Path $env:SystemRoot 'System32\imageres.dll') + ',109'
}
$s.Save()

# Marcar "ejecutar como administrador" encendiendo el bit 0x20.
$bytes = [System.IO.File]::ReadAllBytes($lnk)
$bytes[0x15] = $bytes[0x15] -bor 0x20
[System.IO.File]::WriteAllBytes($lnk, $bytes)

Write-Host ''
Write-Host '  Acceso directo creado.' -ForegroundColor Green
Write-Host "    $lnk" -ForegroundColor DarkGray
Write-Host '    Se abre siempre como administrador (lo pide al hacer doble clic).' -ForegroundColor DarkGray
Write-Host ''
