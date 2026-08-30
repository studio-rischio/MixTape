#!/bin/bash
set -euo pipefail

# Release build into ./build (git-ignored).
#
# The four extra settings are not optional for anything you intend to publish:
#
#   DEPLOYMENT_POSTPROCESSING + STRIP_INSTALLED_PRODUCT + STRIP_STYLE
#     A plain `xcodebuild build` leaves the linker's debug map in the executable
#     — N_OSO stab entries naming every .o file by absolute path. That embeds
#     the builder's home directory (/Users/<you>/...) ~40 times in a binary
#     that otherwise contains no personal information, and `strings` won't show
#     it because the paths live in the symbol table rather than __TEXT. Check
#     with: grep -c "/Users/$(whoami)" "<app>/Contents/MacOS/<binary>"
#
#   CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
#     Otherwise Xcode injects com.apple.security.get-task-allow, which lets any
#     process attach a debugger to the shipped app. Fine for local runs, wrong
#     for a download.
#
# Verify before uploading (both should print 0):
#   grep -rlEa "/Users/$(whoami)" "build/Build/Products/Release/MixTape.app" | wc -l
#   codesign -d --entitlements - "<app>" 2>/dev/null | grep -c get-task-allow
#
# Ship ONLY the .app. The .dSYM built alongside it still contains the full
# DW_AT_comp_dir build paths by design — that is what it is for — so it must
# never be uploaded to a release.

# Usage:
#   ./build.sh           # build, then launch the .app
#   ./build.sh build     # build only — what release.sh calls
case "${1:-run}" in
    run|build) ;;
    *) echo "Unknown command: $1 (expected: build | run)" >&2; exit 1 ;;
esac

xcodebuild -project MixTape.xcodeproj \
  -scheme MixTape \
  -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build \
  DEPLOYMENT_POSTPROCESSING=YES \
  STRIP_INSTALLED_PRODUCT=YES \
  STRIP_STYLE=debugging \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  clean build

# The app ends up at:
[ "${1:-run}" = "build" ] || open "build/Build/Products/Release/MixTape.app"
