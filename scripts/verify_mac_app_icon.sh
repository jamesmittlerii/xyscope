#!/bin/bash
# Fail the Mac archive if Assets.car is missing AppIcon 512pt @2x (ITMS-90236),
# and replace actool's thinned AppIcon.icns with the full Oscope.icns.
set -euo pipefail

if [[ "${PLATFORM_NAME:-}" != "macosx" ]]; then
  exit 0
fi

RESOURCES="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
CAR="${RESOURCES}/Assets.car"
APP_ICNS="${RESOURCES}/AppIcon.icns"
FULL_ICNS="${SRCROOT:?}/Resources/Oscope.icns"

if [[ ! -f "${CAR}" ]]; then
  echo "error: Assets.car missing at ${CAR}" >&2
  exit 1
fi

# actool's thinned AppIcon.icns often omits 512 / 512@2x; ASC still cares.
if [[ -f "${FULL_ICNS}" ]]; then
  cp -f "${FULL_ICNS}" "${APP_ICNS}"
  echo "note: replaced AppIcon.icns with full Oscope.icns (512 + 512@2x)"
fi

python3 - "${CAR}" <<'PY'
import json
import subprocess
import sys

car = sys.argv[1]
raw = subprocess.check_output(["/usr/bin/assetutil", "--info", car], text=True)
data = json.loads(raw)
if not isinstance(data, list):
    print("error: assetutil --info: expected a JSON array", file=sys.stderr)
    sys.exit(1)

required = {
    "icon_16x16.png": (16, 1),
    "icon_16x16_2x.png": (32, 2),
    "icon_32x32.png": (32, 1),
    "icon_32x32_2x.png": (64, 2),
    "icon_128x128.png": (128, 1),
    "icon_128x128_2x.png": (256, 2),
    "icon_256x256.png": (256, 1),
    "icon_256x256_2x.png": (512, 2),
    "icon_512x512.png": (512, 1),
    "icon_512x512_2x.png": (1024, 2),
}

seen = {}
appicon = []
for entry in data:
    if not isinstance(entry, dict) or entry.get("Name") != "AppIcon":
        continue
    if entry.get("AssetType") != "Icon Image":
        continue
    rendition = entry.get("RenditionName") or ""
    width = entry.get("PixelWidth")
    scale = entry.get("Scale")
    appicon.append({"RenditionName": rendition, "PixelWidth": width, "Scale": scale})
    if rendition in required:
        seen[rendition] = (width, scale)

if not appicon:
    print("error: Assets.car has no AppIcon Icon Image entries", file=sys.stderr)
    sys.exit(1)

missing = [name for name in required if name not in seen]
# Accept either naming scheme while migrating off '@2x' filenames.
if "icon_512x512_2x.png" not in seen and not any(
    (e.get("PixelWidth") == 1024 and e.get("Scale") in (2, 2.0, "2")) for e in appicon
):
    print("error: Assets.car missing AppIcon 512pt @2x (1024px) — ITMS-90236", file=sys.stderr)
    print("note: AppIcon Icon Image entries in Assets.car:", file=sys.stderr)
    for row in appicon:
        print(f"note:   {row}", file=sys.stderr)
    if missing:
        print("note: missing renditions: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)

print(f"Verified AppIcon 512pt @2x in Assets.car ({len(appicon)} Icon Image entries)")
PY
