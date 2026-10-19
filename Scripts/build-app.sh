#!/bin/zsh
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "$0")" && pwd)"
package_root="$(cd -- "$script_directory/.." && pwd)"
app_path="$package_root/.build/Indoor Sensor Simulator.app"
scratch_path="/tmp/IMDFPositioningSimulatorReleaseBuild"

swift build \
  --disable-sandbox \
  --package-path "$package_root" \
  --scratch-path "$scratch_path" \
  -c release \
  --product IMDFSimulator
binary_directory="$(swift build \
  --disable-sandbox \
  --package-path "$package_root" \
  --scratch-path "$scratch_path" \
  -c release \
  --show-bin-path)"

if [[ -d "$app_path" ]]; then
  /bin/rm -rf "$app_path"
fi

/bin/mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
/bin/cp "$binary_directory/IMDFSimulator" "$app_path/Contents/MacOS/IMDFSimulator"
/bin/cp "$package_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
/usr/bin/xattr -cr "$app_path"
/usr/bin/codesign --force --sign - "$app_path"
/usr/bin/xattr -cr "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"

/bin/echo "$app_path"
