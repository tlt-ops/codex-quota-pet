#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
bundle="$script_dir/Codex Quota Pet.app"
for helper in quota_client.py install_launch_agent.py watch_codex.py; do
  if [[ ! -f "$script_dir/../scripts/$helper" ]]; then
    echo "Missing required helper: $helper" >&2
    exit 1
  fi
done
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

swiftc -swift-version 5 -O \
  -framework AppKit -framework CoreGraphics -framework CoreImage -framework ImageIO \
  "$script_dir"/*.swift \
  -o "$bundle/Contents/MacOS/CodexQuotaPet"

cp "$script_dir/Info.plist" "$bundle/Contents/Info.plist"
cp "$script_dir/../../../assets/gpt_quota_pet.png" "$bundle/Contents/Resources/gpt_quota_pet.png"
cp "$script_dir/../../../assets/mini_gpt_sheet_original.png" "$bundle/Contents/Resources/mini_gpt_sheet_original.png"
for helper in quota_client.py install_launch_agent.py watch_codex.py; do
  cp "$script_dir/../scripts/$helper" "$bundle/Contents/Resources/$helper"
done
plutil -lint "$bundle/Contents/Info.plist"
echo "$bundle"
