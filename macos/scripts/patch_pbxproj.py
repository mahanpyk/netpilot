#!/usr/bin/env python3
"""Re-apply NetPilot native source entries to project.pbxproj after pod install if needed."""
from pathlib import Path
import re

pbx = Path(__file__).resolve().parents[1] / "Runner.xcodeproj" / "project.pbxproj"
text = pbx.read_text()
ids = {
  "plugin_ref": "A1B2C3D40100000000000001",
  "inv_ref": "A1B2C3D40100000000000002",
  "xpc_ref": "A1B2C3D40100000000000003",
  "prot_ref": "A1B2C3D40100000000000004",
  "spec_ref": "A1B2C3D40100000000000005",
  "mgr_ref": "A1B2C3D40100000000000006",
  "test_ref": "A1B2C3D40100000000000007",
  "plugin_bf": "A1B2C3D40200000000000001",
  "inv_bf": "A1B2C3D40200000000000002",
  "xpc_bf": "A1B2C3D40200000000000003",
  "prot_bf": "A1B2C3D40200000000000004",
  "spec_bf": "A1B2C3D40200000000000005",
  "mgr_bf": "A1B2C3D40200000000000006",
  "test_bf": "A1B2C3D40200000000000007",
  "shared_grp": "A1B2C3D40300000000000001",
}
if ids["plugin_ref"] in text and f'{ids["plugin_bf"]} /* NetPilotPlugin.swift in Sources */' in text:
    # Ensure deployment target
    text2 = text.replace("MACOSX_DEPLOYMENT_TARGET = 10.14;", "MACOSX_DEPLOYMENT_TARGET = 14.0;")
    if text2 != text:
        pbx.write_text(text2)
        print("updated deployment target only")
    else:
        print("pbxproj already contains NetPilot sources")
    raise SystemExit(0)

print("NetPilot sources missing — run full patch manually (see HANDOFF.md)")
raise SystemExit(1)
