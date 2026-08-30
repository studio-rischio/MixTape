#!/bin/bash
#
# Cut a release zip of MixTape.
#
#   ./release.sh            # build, audit, zip
#   ALLOW_DIRTY=1 ./release.sh   # skip the clean-tree check (testing only)
#
# The app ships as a free download to people who have no way to inspect it, so
# this script's real job is the audit in step 3 — every check there is a hard
# failure, not a warning. A release that leaks the builder's home directory or
# ships a debuggable binary is worse than no release, and both are invisible
# unless something looks for them.
#
# Publishing is deliberately NOT automated. The script stops at a verified zip
# and prints the two commands that make it public, so pushing a release stays a
# decision someone makes on purpose.

set -euo pipefail
cd "$(dirname "$0")"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { printf "${GREEN}==>${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}Warning:${NC} %s\n" "$1"; }
fail() { printf "${RED}Error:${NC} %s\n" "$1" >&2; exit 1; }

APP="build/Build/Products/Release/MixTape.app"
BIN="$APP/Contents/MacOS/MixTape"

# ---------------------------------------------------------------- 1. version

# MARKETING_VERSION in the project is the single source of truth — a zip whose
# name disagrees with CFBundleShortVersionString is a support problem later.
VERSION="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' MixTape.xcodeproj/project.pbxproj | head -1)"
[ -n "$VERSION" ] || fail "Couldn't read MARKETING_VERSION from project.pbxproj."
ARCH="$(uname -m)"
ZIP="MixTape-$VERSION-$ARCH.zip"

# A release is a claim that some commit produces this binary. If the tree is
# dirty that claim is unverifiable, and the tag you push won't rebuild to this.
if [ -z "${ALLOW_DIRTY:-}" ] && [ -n "$(git status --porcelain)" ]; then
    git status --short
    fail "Working tree is dirty. Commit first, or re-run with ALLOW_DIRTY=1 for a test build."
fi

step "Releasing MixTape $VERSION ($ARCH) from $(git rev-parse --short HEAD)"

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    warn "Tag v$VERSION already exists — bump MARKETING_VERSION before publishing."
fi

# ------------------------------------------------------------------ 2. build

step "Building Release (stripped, no injected entitlements)..."
./build.sh build >/dev/null
[ -d "$APP" ] || fail "Build succeeded but no app at $APP"

ACTUAL_ARCH="$(lipo -archs "$BIN")"
case " $ACTUAL_ARCH " in
    *" $ARCH "*) ;;
    *) fail "Expected $ARCH but the binary is [$ACTUAL_ARCH]." ;;
esac

# ------------------------------------------------------------------ 3. audit

step "Auditing the bundle for anything personal..."
failures=0
check() {  # check <description> <actual> <expected>
    if [ "$2" = "$3" ]; then
        printf "    ok    %s\n" "$1"
    else
        printf "${RED}    FAIL${NC}  %s (found: %s, expected: %s)\n" "$1" "$2" "$3"
        failures=$((failures + 1))
    fi
}

# The linker's debug map (N_OSO stabs) names every .o file by absolute path,
# embedding the builder's home directory dozens of times. It lives in the symbol
# table, so `strings` won't show it — this is the check that catches it.
check "no debug-map stabs (N_OSO)" "$(nm -ap "$BIN" 2>/dev/null | grep -c OSO || true)" "0"

# Xcode injects get-task-allow unless told not to. It lets any process attach a
# debugger to the shipped app — fine locally, wrong for a download.
check "no get-task-allow entitlement" \
      "$(codesign -d --entitlements - "$BIN" 2>/dev/null | grep -c get-task-allow || true)" "0"

# Belt and braces for the two above: no file in the bundle may mention a home
# directory, whoever built it.
check "no /Users/ paths in any bundle file" \
      "$(grep -rlaE '/Users/[A-Za-z0-9._-]+' "$APP" 2>/dev/null | wc -l | tr -d ' ')" "0"

# Identity that can leak in via paths, defaults, or an errant literal.
for needle in "$(whoami)" "$(hostname -s)"; do
    check "no \"$needle\" in the binary" \
          "$(strings -a "$BIN" | grep -ic "$needle" || true)" "0"
done

check "no build-machine paths (DerivedData, /private/var/folders)" \
      "$(strings -a "$BIN" | grep -icE 'DerivedData|/private/var/folders' || true)" "0"

# The sandbox is what makes the app safe to hand out; a release that silently
# lost it would still run, and nobody would notice.
ENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null | grep -oE 'com\.apple\.security\.[a-z.-]+' | sort | tr '\n' ' ')"
check "exactly the four expected entitlements" "$ENTS" \
      "com.apple.security.app-sandbox com.apple.security.files.bookmarks.app-scope com.apple.security.files.user-selected.read-write com.apple.security.network.client "

codesign --verify --deep --strict "$APP" 2>/dev/null \
    && printf "    ok    code signature verifies\n" \
    || { printf "${RED}    FAIL${NC}  code signature does not verify\n"; failures=$((failures + 1)); }

[ "$failures" -eq 0 ] || fail "$failures audit check(s) failed — nothing was packaged."

# -------------------------------------------------------------------- 4. zip

# ditto, not zip: zip mangles the code signature. --keepParent puts MixTape.app
# at the root of the archive rather than its contents.
step "Packaging $ZIP ..."
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# The .dSYM sitting beside the .app carries full DW_AT_comp_dir build paths by
# design. It must never reach a release, so confirm none rode along.
if unzip -l "$ZIP" | grep -q "\.dSYM"; then
    rm -f "$ZIP"
    fail "The archive contained a .dSYM — deleted it rather than ship build paths."
fi

SIZE="$(du -h "$ZIP" | cut -f1 | tr -d ' ')"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

step "Built $ZIP ($SIZE)"
printf "    sha256  %s\n" "$SHA"

# ------------------------------------------------------------ 5. next steps

cat <<EOF

$(printf "${GREEN}==>${NC}") Ready to publish. Nothing has been pushed.

    git tag -a v$VERSION -m "MixTape $VERSION"
    git push origin v$VERSION
    gh release create v$VERSION "$ZIP" \\
        --title "MixTape $VERSION" \\
        --notes "..."

The download button on the landing page points at /releases/latest, so it
starts working the moment the release is published — no page edit needed.
EOF
