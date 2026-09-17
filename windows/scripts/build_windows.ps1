param([ValidateSet('Debug','Release')][string]$Configuration = 'Debug')
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."
$driverProject = Join-Path $root 'windows\native\driver\NetPilotWfp.vcxproj'
$driverOut = Join-Path $root "build\windows\driver\$Configuration"
$thumbprint = $env:NETPILOT_TEST_CERT_THUMBPRINT
if (-not $thumbprint) { throw 'Set NETPILOT_TEST_CERT_THUMBPRINT from prepare_dev_machine.ps1.' }

flutter pub get
flutter analyze
flutter test
flutter build windows --$($Configuration.ToLower())
msbuild $driverProject /m /p:Configuration=$Configuration /p:Platform=x64 /p:OutDir="$driverOut\"
inf2cat /driver:$driverOut /os:10_X64
Get-ChildItem $driverOut -Include *.sys,*.cat -Recurse | ForEach-Object {
  signtool sign /fd sha256 /sha1 $thumbprint /v $_.FullName
  signtool verify /pa /v $_.FullName
}
$runner = Join-Path $root "build\windows\x64\runner\$Configuration"
$driverDestination = Join-Path $runner 'driver'
New-Item -ItemType Directory -Force $driverDestination | Out-Null
Copy-Item "$driverOut\NetPilotWfp.*" $driverDestination -Force
ctest --test-dir (Join-Path $root 'build\windows\x64') -C $Configuration --output-on-failure
Write-Host "Windows artifacts are ready in $runner" -ForegroundColor Green
