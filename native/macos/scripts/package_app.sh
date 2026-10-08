#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
plugin_root="$(cd "$script_dir/.." && pwd)"
output_root="$(cd "$plugin_root/.." && pwd)"
app_name='Codex Quota Pet.app'
archive="$output_root/Codex Quota Pet.app.zip"

bash "$plugin_root/app/build.sh"

# Documents may be backed by a file provider that adds Finder metadata to
# bundles. Sign and verify on a local temporary volume, then archive the app.
sign_stage="$(mktemp -d /private/tmp/codex-quota-pet-package.XXXXXX)"
trap 'rm -rf "$sign_stage"' EXIT
ditto --norsrc "$plugin_root/app/$app_name" "$sign_stage/$app_name"
chmod 644 "$sign_stage/$app_name/Contents/Resources/mini_gpt_sheet_original.png"
xattr -rc "$sign_stage/$app_name"
codesign --force --sign - "$sign_stage/$app_name"
codesign --verify --deep --strict "$sign_stage/$app_name"

ditto -c -k --norsrc --keepParent "$sign_stage/$app_name" "$archive"
mkdir -p "$sign_stage/extracted"
ditto -x -k --norsrc "$archive" "$sign_stage/extracted"
codesign --verify --deep --strict "$sign_stage/extracted/$app_name"

echo "$archive"
