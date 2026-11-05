"""Portable structural checks. Does not pretend to compile Swift or run XCTest."""
from pathlib import Path
import json
import plistlib
import re
import struct
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
project = (root / "GMSchedule.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
ids = re.findall(r"^([A-F0-9]{24}) = ", project, re.M)
assert len(ids) == len(set(ids)), "duplicate Xcode objects"
assert all(item in set(ids) for item in re.findall(r"\b[A-F0-9]{24}\b", project)), "unresolved Xcode object"
for source in (root / "GMSchedule").glob("*.swift"):
    assert f'path = "{source.name}";' in project, source
assert 'IPHONEOS_DEPLOYMENT_TARGET = "15.0"' in project
assert 'MARKETING_VERSION = "3.0.1"' in project
assert 'CURRENT_PROJECT_VERSION = "21"' in project
assert 'version = 2.13.5' in project
plistlib.loads((root / "GMSchedule/Info.plist").read_bytes())
ET.parse(root / "GMSchedule.xcodeproj/xcshareddata/xcschemes/GMSchedule.xcscheme")
icons = root / "GMSchedule/Assets.xcassets/AppIcon.appiconset"
contents = json.loads((icons / "Contents.json").read_text(encoding="utf-8-sig"))
assert len(contents["images"]) == 18
for entry in contents["images"]:
    data = (icons / entry["filename"]).read_bytes()
    width, height = struct.unpack(">II", data[16:24])
    expected = int(float(entry["size"].split("x")[0]) * int(entry["scale"][0]))
    assert (width, height) == (expected, expected), entry
    assert data[25] == 2, "icon must be RGB without alpha"
assert not list(root.rglob("*.ipa"))
assert not list(root.rglob("*.mobileprovision"))
print(f"Structure OK: {len(ids)} Xcode objects, 18 opaque icons, plist, shared scheme, sources, iOS15/version/dependency settings")
