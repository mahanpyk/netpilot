# Windows WFP integration gate

Run this gate on a Windows 11 x64 VM with Test Mode enabled and two active
physical adapters. Do not mark Windows app routing ready until every item passes
on Windows 11 and is repeated on the physical Windows 10 22H2 PC.

1. Run `scripts/prepare_dev_machine.ps1` elevated, reboot, and take a VM snapshot.
2. Run `scripts/build_windows.ps1`, build the WiX package, and install it.
3. Confirm Settings reports Windows Service `running`, WFP Driver `installed`,
   Test Mode `enabled`, and no pending reboot.
4. Add the signed gate client EXE. Confirm Event Log contains its exact canonical
   path-derived `ALE_APP_ID`; repeat with an unsigned copy in a different path.
5. Select Ethernet and use independent TCP and UDP public echo endpoints. Confirm
   both observed public addresses equal the Ethernet ISP address. Run an HTTP/3
   client against a QUIC endpoint and confirm the same result.
6. Confirm an unselected browser still reports the ordinary Windows/VPN public
   address.
7. Disconnect Ethernet. `block` must fail new TCP/UDP/QUIC flows without leaking;
   `fallback` must use the ordinary route. Reconnect and confirm filters rebuild.
8. Keep long-lived TCP and UDP flows open, change a rule, then press **Apply &
   Restart Proxy**. Existing selected flows must close and reconnect on the new
   adapter.
9. Exercise two apps on different adapters, destination/sub-rules, sleep/resume,
   network flap, and a 60-minute mixed TCP/UDP/QUIC stress run.
10. Enable Driver Verifier for `NetPilotWfp.sys`, rerun the traffic suite, then
    disable it before restoring the snapshot.

Capture `Get-NetRoute`, `Get-NetAdapter`, public IP responses, Event Viewer logs,
and the in-app diagnostics for the acceptance record. Payload bytes must never
appear in logs. A failure in App ID attribution, redirect context recovery, or
UDP/QUIC isolation blocks the phase; do not substitute injection or PID matching.
