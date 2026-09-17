# Signed per-app routing integration gate

Run this checklist only from an Xcode build where Runner and
`NetPilotTransparentProxy` use the same valid Team and provisioning profiles
containing the Network Extension entitlement. An unsigned or ad-hoc build does
not satisfy this gate.

1. Build and run Runner from Xcode. In **Apps**, install and approve the System
   Extension. Confirm its status becomes `installed`.
2. Add a signed browser and select one active physical Wi-Fi/Ethernet interface.
   Apply. Confirm the terminal logs an exact signing identifier, Team ID match,
   protocol, and the selected BSD interface. If the provider logs `identity
   metadata unavailable`, stop the test; PID matching is not an allowed fallback.
3. In the selected browser, use controlled IPv4 endpoints that report public IP
   over HTTPS/TCP, UDP, and QUIC. Compare each result with a control request
   explicitly bound to the selected BSD interface. All must use that interface.
4. Repeat from an unselected browser. Its route must remain unchanged.
5. Disconnect the selected interface. With `block`, new flows must fail. With
   `fallback`, they must use the normal macOS route. Reconnect before continuing.
6. Keep an existing flow open, change its rule, and click **Apply & Restart
   Proxy**. Confirm the old flow reconnects and is evaluated against the new
   configuration.
7. Apply two apps to different physical interfaces and verify them concurrently.
8. Keep an existing destination rule active and confirm an unselected app still
   follows it. Confirm a selected app remains pinned by `requiredInterface`.

Capture `[NetPilot App Routing]` logs and the Apps-card flow/byte counters. Do
not capture traffic payloads. DNS is best effort; ICMP, raw IP, IPv6, `utun`, and
VPN stacking are outside this gate.
