#!/bin/bash
#
# Tools/make-dmg.sh — build a drag-to-Applications disk image for Morphiqo.
#
# Requires nothing but macOS + Xcode: ditto, hdiutil, codesign, xcrun, plutil.
# No Homebrew, no Node, no create-dmg. Runs unchanged on a GitHub Actions runner.
#
# Usage:
#   Tools/make-dmg.sh [options] [/path/to/Morphiqo.app]
#
# With no .app argument it uses the newest Release/export build it can find under
# ./build or ~/Library/Developer/Xcode/DerivedData.
#
# Options:
#   -o, --output <file.dmg>  Output path. Default dist/Morphiqo-<version>.dmg
#   -n, --volname <name>     Finder volume name. Default: Morphiqo
#   -i, --identity <id>      Codesign identity for the DMG.
#                            Default: first "Developer ID Application" in the keychain.
#       --dmg-identifier <s> Codesign identifier for the DMG. Must differ from every
#                            bundle ID in the app. Default com.lisenhuang.morphiqo.dmg
#       --no-sign            Do not sign the DMG.
#       --ds-store <file>    Pre-baked .DS_Store for the window layout (headless, CI-safe).
#       --background <png>   Background image (pair with --layout, or with a --ds-store
#                            captured from a run that used the same background).
#       --layout             Arrange the window by scripting Finder. Interactive Macs only.
#       --capture-ds-store <file>
#                            Do --layout, then save the resulting .DS_Store for reuse.
#       --icon-size <n>      Default 128
#       --window-size <w> <h>  Default 660 400
#       --app-x/--app-y/--link-x/--link-y   Icon positions. Default 180 185 / 480 185
#       --zlib-level <0-9>   UDZO compression. Default 9 (hdiutil's own default is 1).
#       --notarize <profile> Submit the finished DMG with `xcrun notarytool
#                            --keychain-profile <profile>`, then staple it.
#   -h, --help
#
# Exit codes: 0 ok, 1 usage/precondition, 2 build failure.

set -euo pipefail

APP=""; OUTPUT=""; VOLNAME="Morphiqo"; IDENTITY=""; DO_SIGN=1
BACKGROUND=""; DS_STORE_IN=""; DS_STORE_CAPTURE=""; DO_LAYOUT=0
ICON_SIZE=128; WIN_W=660; WIN_H=400
APP_X=180; APP_Y=185; LINK_X=480; LINK_Y=185
ZLIB_LEVEL=9; NOTARY_PROFILE=""
DMG_IDENTIFIER="com.lisenhuang.morphiqo.dmg"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_GRN=$'\033[1;32m'
  C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_OFF=""
fi
step() { printf '%s==>%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
info() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
warn() { printf '%swarning:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit "${2:-1}"; }
banner() {
  printf '\n%s%s%s\n' "$C_YEL" "$(printf '=%.0s' {1..72})" "$C_OFF" >&2
  while IFS= read -r l; do printf '%s!! %s%s\n' "$C_YEL" "$l" "$C_OFF" >&2; done
  printf '%s%s%s\n\n' "$C_YEL" "$(printf '=%.0s' {1..72})" "$C_OFF" >&2
}
usage() { sed -n '2,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output)   OUTPUT="${2:?}"; shift 2 ;;
    -n|--volname)  VOLNAME="${2:?}"; shift 2 ;;
    -i|--identity) IDENTITY="${2:?}"; shift 2 ;;
    --dmg-identifier) DMG_IDENTIFIER="${2:?}"; shift 2 ;;
    --no-sign)     DO_SIGN=0; shift ;;
    --background)  BACKGROUND="${2:?}"; shift 2 ;;
    --ds-store)    DS_STORE_IN="${2:?}"; shift 2 ;;
    --layout)      DO_LAYOUT=1; shift ;;
    --capture-ds-store) DS_STORE_CAPTURE="${2:?}"; DO_LAYOUT=1; shift 2 ;;
    --icon-size)   ICON_SIZE="${2:?}"; shift 2 ;;
    --window-size) WIN_W="${2:?}"; WIN_H="${3:?}"; shift 3 ;;
    --app-x)       APP_X="${2:?}"; shift 2 ;;
    --app-y)       APP_Y="${2:?}"; shift 2 ;;
    --link-x)      LINK_X="${2:?}"; shift 2 ;;
    --link-y)      LINK_Y="${2:?}"; shift 2 ;;
    --zlib-level)  ZLIB_LEVEL="${2:?}"; shift 2 ;;
    --notarize)    NOTARY_PROFILE="${2:?}"; shift 2 ;;
    -h|--help)     usage ;;
    -*)            die "unknown option: $1" ;;
    *)             [ -z "$APP" ] || die "more than one .app given"; APP="$1"; shift ;;
  esac
done

# ------------------------------------------------------------ locate the app -
if [ -z "$APP" ]; then
  step "No .app given; looking for the newest Release build"
  DIRS=()
  for d in "$REPO_ROOT/build" "$HOME/Library/Developer/Xcode/DerivedData"; do
    [ -d "$d" ] && DIRS+=("$d")
  done
  if [ ${#DIRS[@]} -gt 0 ]; then
    APP="$(/usr/bin/find "${DIRS[@]}" -maxdepth 6 -type d -name 'Morphiqo.app' \
             \( -path '*/Build/Products/Release/*' -o -path '*/export/*' \) -print 2>/dev/null |
           while IFS= read -r p; do printf '%s\t%s\n' "$(/usr/bin/stat -f%m "$p")" "$p"; done |
           /usr/bin/sort -rn | /usr/bin/head -1 | /usr/bin/cut -f2-)"
  fi
  [ -n "$APP" ] || die "no Release Morphiqo.app found. Build one first:
    xcodebuild archive -project FaceFusionMac.xcodeproj -scheme Morphiqo \\
      -configuration Release -destination 'generic/platform=macOS' \\
      -archivePath build/Morphiqo.xcarchive"
fi
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
[ -d "$APP/Contents" ] || die "not an app bundle: $APP"
APP_NAME="$(basename "$APP")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0)"
BUILDNO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)"
[ -n "$OUTPUT" ] || OUTPUT="$REPO_ROOT/dist/${VOLNAME}-${VERSION}.dmg"
case "$OUTPUT" in /*) ;; *) OUTPUT="$PWD/$OUTPUT" ;; esac
mkdir -p "$(dirname "$OUTPUT")"

step "Packaging $APP_NAME $VERSION ($BUILDNO)"
info "app:    $APP"
info "output: $OUTPUT"

# ------------------------------------------------------------- sanity checks -
EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
ARCHS="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/$EXEC_NAME" 2>/dev/null || echo '?')"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
info "archs:  $ARCHS"
info "min os: macOS $MINOS"
case "$ARCHS" in
  *x86_64*) ;;
  *) warn "arm64-only build: it will not launch on Intel Macs. Archive with"
     warn "  -destination 'generic/platform=macOS'  to get a universal binary." ;;
esac
if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP/Contents/Info.plist" >/dev/null 2>&1 &&
   ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  warn "the app has no icon; it will show a blank generic icon in the DMG and in /Applications."
fi

step "Verifying the app's own signature"
/usr/bin/codesign --verify --deep --strict --verbose=1 "$APP" \
  || die "the app bundle's signature is broken; fix that before packaging" 2

SIG="$(/usr/bin/codesign -dvv "$APP" 2>&1 || true)"
AUTHORITY="$(printf '%s\n' "$SIG" | /usr/bin/awk -F= '/^Authority=/{print $2; exit}')"
ENTS="$(/usr/bin/codesign -d --entitlements - --xml "$APP" 2>/dev/null | /usr/bin/plutil -p - 2>/dev/null || true)"
info "signed by: ${AUTHORITY:-<ad-hoc / unsigned>}"

NOTARIZABLE=1; REASONS=""
case "$AUTHORITY" in "Developer ID Application"*) ;; *)
  NOTARIZABLE=0; REASONS="$REASONS
  * not signed with a Developer ID Application certificate (got: ${AUTHORITY:-ad-hoc})" ;;
esac
printf '%s\n' "$SIG" | /usr/bin/grep -q '^Timestamp=' || {
  NOTARIZABLE=0; REASONS="$REASONS
  * no secure timestamp (codesign shows only \"Signed Time=\")"; }
printf '%s\n' "$SIG" | /usr/bin/grep -q 'flags=.*runtime' || {
  NOTARIZABLE=0; REASONS="$REASONS
  * hardened runtime not enabled"; }
case "$ENTS" in *get-task-allow*)
  NOTARIZABLE=0; REASONS="$REASONS
  * com.apple.security.get-task-allow is present (only archive+exportArchive strips it)" ;;
esac
case "$ENTS" in *application-groups*) ;; *)
  warn "the app carries no com.apple.security.application-groups entitlement."
  warn "the app<->engine shared container will NOT work. Something re-signed it"
  warn "without --entitlements." ;;
esac

if [ "$NOTARIZABLE" -eq 0 ]; then
  banner <<EOF
This app cannot be notarized as it stands, so anyone who DOWNLOADS the DMG will
be blocked by Gatekeeper ("Apple could not verify Morphiqo is free of
malware"). Reasons:
$REASONS

The DMG is still built and still drag-installs. Recipients must run, once:
    xattr -dr com.apple.quarantine /Applications/$APP_NAME
(macOS 15+ removed the right-click > Open bypass; the GUI route is
System Settings > Privacy & Security > "Open Anyway".)
EOF
fi

# ------------------------------------------------------------------- staging -
STAGE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ffm-dmg.XXXXXX")"
MOUNTPOINT=""
cleanup() {
  rc=$?
  if [ -n "$MOUNTPOINT" ] && [ -d "$MOUNTPOINT" ]; then
    /usr/bin/hdiutil detach "$MOUNTPOINT" -quiet -force >/dev/null 2>&1 || true
  fi
  [ -n "$STAGE" ] && /bin/rm -rf "$STAGE"
  exit $rc
}
trap cleanup EXIT INT TERM
SRC="$STAGE/src"; mkdir -p "$SRC"

step "Staging"
# ditto, never cp -R: the embedded onnxruntime.framework has Versions/Current
# symlinks that cp can flatten, which breaks the code-signature seal and gives
# the unrecoverable "app is damaged, move it to the Trash" dialog.
/usr/bin/ditto "$APP" "$SRC/$APP_NAME"
/bin/ln -s /Applications "$SRC/Applications"

if [ -n "$BACKGROUND" ]; then
  [ -f "$BACKGROUND" ] || die "background not found: $BACKGROUND"
  mkdir -p "$SRC/.background"; /usr/bin/ditto "$BACKGROUND" "$SRC/.background/background.png"
fi
if [ -n "$DS_STORE_IN" ]; then
  [ -f "$DS_STORE_IN" ] || die ".DS_Store not found: $DS_STORE_IN"
  /usr/bin/ditto "$DS_STORE_IN" "$SRC/.DS_Store"; DO_LAYOUT=0
  info "layout: pre-baked .DS_Store"
fi
if [ -f "$REPO_ROOT/Tools/dmg/VolumeIcon.icns" ]; then
  /usr/bin/ditto "$REPO_ROOT/Tools/dmg/VolumeIcon.icns" "$SRC/.VolumeIcon.icns"
fi

# --------------------------------------------------------------- build image -
if [ "$DO_LAYOUT" -eq 1 ]; then
  KB=$(( $(/usr/bin/du -sk "$SRC" | /usr/bin/awk '{print $1}') * 3 / 2 + 40000 ))
  step "Creating read/write image (${KB}k) so Finder can lay out the window"
  /usr/bin/hdiutil create -quiet -srcfolder "$SRC" -volname "$VOLNAME" \
    -fs HFS+ -format UDRW -size "${KB}k" -ov "$STAGE/rw.dmg"
  MOUNTPOINT="$STAGE/mnt"; mkdir -p "$MOUNTPOINT"
  /usr/bin/hdiutil attach "$STAGE/rw.dmg" -readwrite -noverify -noautoopen \
    -mountpoint "$MOUNTPOINT" -quiet
  sleep 1
  BG_CLAUSE=""
  [ -n "$BACKGROUND" ] && BG_CLAUSE='set background picture of theViewOptions to file ".background:background.png"'
  if /usr/bin/osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 160, $((200 + WIN_W)), $((160 + WIN_H))}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to $ICON_SIZE
    $BG_CLAUSE
    set position of item "$APP_NAME" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$LINK_X, $LINK_Y}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT
  then info "Finder layout applied"
  else
    warn "AppleScript layout failed (expected on CI and without Automation consent)."
    warn "The DMG is still valid; it just uses Finder's default arrangement."
    warn "Run once locally with --capture-ds-store Tools/dmg/DS_Store, commit that"
    warn "file, and pass --ds-store Tools/dmg/DS_Store in CI."
  fi
  /bin/sync
  if [ -n "$DS_STORE_CAPTURE" ] && [ -f "$MOUNTPOINT/.DS_Store" ]; then
    mkdir -p "$(dirname "$DS_STORE_CAPTURE")"
    /usr/bin/ditto "$MOUNTPOINT/.DS_Store" "$DS_STORE_CAPTURE"
    step "Captured .DS_Store -> $DS_STORE_CAPTURE"
  fi
  if [ -f "$MOUNTPOINT/.VolumeIcon.icns" ] && [ -x /usr/bin/SetFile ]; then
    /usr/bin/SetFile -a C "$MOUNTPOINT" || true
  fi
  /usr/bin/hdiutil detach "$MOUNTPOINT" -quiet; MOUNTPOINT=""
  step "Compressing (UDZO zlib-level=$ZLIB_LEVEL)"
  /bin/rm -f "$OUTPUT"
  /usr/bin/hdiutil convert "$STAGE/rw.dmg" -quiet -format UDZO \
    -imagekey "zlib-level=$ZLIB_LEVEL" -o "$OUTPUT"
else
  step "Creating compressed image (UDZO zlib-level=$ZLIB_LEVEL)"
  /bin/rm -f "$OUTPUT"
  /usr/bin/hdiutil create -quiet -srcfolder "$SRC" -volname "$VOLNAME" \
    -fs HFS+ -format UDZO -imagekey "zlib-level=$ZLIB_LEVEL" -ov "$OUTPUT"
fi
[ -f "$OUTPUT" ] || die "hdiutil produced no output" 2

# --------------------------------------------------------------- sign + ship -
if [ "$DO_SIGN" -eq 1 ]; then
  if [ -z "$IDENTITY" ]; then
    IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null |
      /usr/bin/sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | /usr/bin/head -1)"
  fi
  if [ -n "$IDENTITY" ]; then
    step "Signing the DMG"
    info "identity:   $IDENTITY"
    info "identifier: $DMG_IDENTIFIER"
    # -i/--identifier is not optional: without it codesign derives the identifier
    # from the filename, so it silently changes with every version bump.
    /usr/bin/codesign --force --sign "$IDENTITY" --timestamp \
      --identifier "$DMG_IDENTIFIER" "$OUTPUT"
    /usr/bin/codesign --verify --verbose=1 "$OUTPUT"
  else
    warn "no \"Developer ID Application\" identity in the keychain; DMG left unsigned."
    warn "installed identities:"
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/sed 's/^/      /' >&2
  fi
else
  info "signing skipped (--no-sign)"
fi

if [ -n "$NOTARY_PROFILE" ]; then
  [ "$NOTARIZABLE" -eq 1 ] || die "refusing to notarize: see the reasons above" 1
  step "Submitting to the Apple notary service (profile: $NOTARY_PROFILE)"
  # One submission covers the DMG, the app, the XPC service and the framework:
  # the notary service issues a ticket for every nested bundle.
  /usr/bin/xcrun notarytool submit "$OUTPUT" --keychain-profile "$NOTARY_PROFILE" --wait
  step "Stapling"
  /usr/bin/xcrun stapler staple "$OUTPUT"
  /usr/bin/xcrun stapler validate "$OUTPUT"
  /usr/sbin/spctl -a -t open --context context:primary-signature -vv "$OUTPUT" || true
fi

DMG_BYTES=$(/usr/bin/stat -f%z "$OUTPUT")
APP_BYTES=$(( $(/usr/bin/du -sk "$APP" | /usr/bin/awk '{print $1}') * 1024 ))
step "Done"
printf '    %-12s %s\n' "dmg:"  "$OUTPUT"
printf '    %-12s %s (%s bytes)\n' "size:" "$(/usr/bin/du -h "$OUTPUT" | /usr/bin/awk '{print $1}')" "$DMG_BYTES"
printf '    %-12s %s%%\n' "saved:" "$(( 100 - DMG_BYTES * 100 / APP_BYTES ))"
/usr/bin/shasum -a 256 "$OUTPUT"
