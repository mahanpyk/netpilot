#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

Write-Host 'Checking Windows 10/11 x64 development prerequisites...'
if (-not [Environment]::Is64BitOperatingSystem) { throw 'x64 Windows is required.' }
foreach ($command in @('flutter','cmake','msbuild','signtool','inf2cat')) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
    throw "$command is missing. Install Visual Studio 2022 Desktop C++, Windows SDK/WDK, CMake, and Flutter first."
  }
}

$testSigning = bcdedit /enum '{current}' | Select-String 'testsigning\s+Yes'
if (-not $testSigning) {
  bcdedit /set testsigning on | Out-Host
  Write-Host 'Test Mode was enabled. Reboot Windows, take the clean VM snapshot, then run this script again.' -ForegroundColor Yellow
  exit 3010
}

$certificate = Get-ChildItem Cert:\LocalMachine\My |
  Where-Object Subject -eq 'CN=NetPilot Driver Test' |
  Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $certificate) {
  $certificate = New-SelfSignedCertificate -Type CodeSigningCert `
    -Subject 'CN=NetPilot Driver Test' -CertStoreLocation Cert:\LocalMachine\My
}
$publicPath = Join-Path $env:TEMP 'NetPilotDriverTest.cer'
Export-Certificate -Cert $certificate -FilePath $publicPath -Force | Out-Null
Import-Certificate -FilePath $publicPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $publicPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
Write-Host "NETPILOT_TEST_CERT_THUMBPRINT=$($certificate.Thumbprint)"
Write-Host 'Development machine is ready.' -ForegroundColor Green
