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
    sys.exit("assetutil --info: expected a JSON array")

found_1024 = False
appicon = []
for entry in data:
    if not isinstance(entry, dict) or entry.get("Name") != "AppIcon":
        continue
    appicon.append(
        {
            "AssetType": entry.get("AssetType"),
            "RenditionName": entry.get("RenditionName"),
            "PixelWidth": entry.get("PixelWidth"),
            "PixelHeight": entry.get("PixelHeight"),
            "Scale": entry.get("Scale"),
            "SizeClassHorizontal": entry.get("SizeClassHorizontal"),
            "Idiom": entry.get("Idiom"),
        }
    )
    asset_type = entry.get("AssetType")
    width = entry.get("PixelWidth")
    scale = entry.get("Scale")
    rendition = entry.get("RenditionName") or ""
    if asset_type in ("Icon Image", "MultiSized Image", "Image"):
        if width == 1024 or rendition.endswith("512x512@2x.png") or (
            scale in (2, 2.0, "2", "2x") and width == 1024
        ):
            found_1024 = True
    # Some actool builds report Scale as 2 with Size 512 points.
    if asset_type == "Icon Image" and scale in (2, 2.0, "2") and entry.get("PixelHeight") == 1024:
        found_1024 = True

if not appicon:
    print("error: Assets.car has no AppIcon entries", file=sys.stderr)
    sys.exit(1)

if not found_1024:
    print("error: Assets.car missing AppIcon 512pt @2x (1024px) — ITMS-90236", file=sys.stderr)
    print("AppIcon entries in Assets.car:", file=sys.stderr)
    for row in appicon:
        print(f"  {row}", file=sys.stderr)
    sys.exit(1)

print(f"Verified AppIcon 512pt @2x in Assets.car ({len(appicon)} AppIcon entries)")
PY
