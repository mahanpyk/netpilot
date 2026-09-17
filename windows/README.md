# NetPilot for Windows

Target: Windows 10 22H2 and Windows 11, x64, Win32 EXEs. The Flutter Runner is
unelevated. `NetPilotService.exe` (LocalSystem) owns route mutation, WFP policy,
and the TCP/UDP relay. `NetPilotWfp.sys` is the only kernel component.
The service registers its PID through a System/Administrators-only driver IOCTL;
the callout then attaches that PID, an owned redirect context, and WFP redirect
records to local TCP/UDP proxy flows. This prevents proxy loops and lets other
WFP redirectors preserve the flow chain.

## Developer build

Install Visual Studio 2022 with Desktop C++, Windows 10/11 SDK, WDK, CMake,
Flutter 3.47.4+, and WiX v4. In an elevated PowerShell:

```powershell
.\windows\scripts\prepare_dev_machine.ps1
# reboot when requested, then set the printed thumbprint
$env:NETPILOT_TEST_CERT_THUMBPRINT='...'
.\windows\scripts\build_windows.ps1
.\windows\installer\build.ps1 -Configuration Debug
```

The test-signed package is only for Test Mode development. Public distribution
requires a production certificate and Microsoft Hardware Dashboard signing.
Run the mandatory [WFP integration gate](IntegrationTests/WFP_GATE.md) before
enabling Windows app routing for acceptance.
