#!/bin/bash
# Builds the hand-off kit: a folder someone with an Apple Developer account can
# unzip and double-click, with no questions asked and nothing else to install.
#
#   ./tools/make-kit.sh            → ~/Desktop/Sill — notarize this.zip
#   ./tools/make-kit.sh /some/dir  → /some/dir/Sill — notarize this.zip
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${1:-$HOME/Desktop}"
KIT="build/kit/Sill — notarize this"
ZIP="$OUT_DIR/Sill — notarize this.zip"

echo "→ building a fresh release app"
./build.sh release >/dev/null

echo "→ assembling the kit"
rm -rf "build/kit" "$ZIP"
mkdir -p "$KIT"
# ditto, not cp: preserves the code signature and the bundle's symlinks intact.
ditto build/Sill.app "$KIT/Sill.app"
cp tools/notarize.command "$KIT/notarize.command"
cp tools/kit-readme.txt   "$KIT/READ ME.txt"
chmod +x "$KIT/notarize.command"

# Quarantine and Finder metadata ride along on copied files and make the
# recipient's codesign fail with "resource fork ... not allowed".
xattr -cr "$KIT"

echo "→ zipping"
ditto -c -k --keepParent "$KIT" "$ZIP"

echo
echo "  $ZIP"
echo "  $(du -h "$ZIP" | cut -f1)"
echo
echo "  contents:"
ditto -x -k "$ZIP" "build/kit-verify" >/dev/null
find "build/kit-verify" -maxdepth 2 -mindepth 2 -not -name '.*' | sed 's|.*/|    |'
rm -rf "build/kit-verify"
