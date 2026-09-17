param(
  [ValidateSet('Debug','Release')][string]$Configuration = 'Debug',
  [string]$PublishDir = "$PSScriptRoot\..\..\build\windows\x64\runner\$Configuration"
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
  throw 'WiX Toolset v4 is required. Install it with: dotnet tool install --global wix'
}
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$msi = Join-Path $out 'NetPilot.msi'
wix build "$PSScriptRoot\Package.wxs" -arch x64 -d "PublishDir=$PublishDir" -o $msi
wix build "$PSScriptRoot\Bundle.wxs" -arch x64 -ext WixToolset.Bal.wixext -d "NetPilotMsi=$msi" -o (Join-Path $out 'NetPilotSetup.exe')
