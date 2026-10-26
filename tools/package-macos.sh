#!/bin/bash
set -euo pipefail

[[ "$(/usr/bin/uname -s)" == Darwin ]] || { echo 'ERROR: PKG creation requires macOS.' >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
IDENTITY=''
NOTARY_PROFILE=''
UNSIGNED=false
while (( $# > 0 )); do
  case "$1" in
    --unsigned) UNSIGNED=true; shift ;;
    --sign|--notary-profile)
      [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: $1 requires a value." >&2; exit 2; }
      if [[ "$1" == --sign ]]; then IDENTITY="$2"; else NOTARY_PROFILE="$2"; fi
      shift 2
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 2 ;;
  esac
done
if [[ "$UNSIGNED" == true ]]; then
  [[ -z "$IDENTITY" && -z "$NOTARY_PROFILE" ]] || { echo 'ERROR: --unsigned cannot be combined with signing options.' >&2; exit 2; }
else
  [[ -n "$IDENTITY" && -n "$NOTARY_PROFILE" ]] || {
    echo 'ERROR: Release packaging requires --sign <Developer ID Installer identity> and --notary-profile <keychain profile>. Use --unsigned only for local validation.' >&2
    exit 2
  }
fi

PACKAGE_ROOT="$ROOT/output/devbox/macos/package-root"
[[ -d "$PACKAGE_ROOT" ]] || { echo 'ERROR: Run npm run build before packaging.' >&2; exit 1; }
VERSION="$(/usr/bin/plutil -extract versions.macos raw -expect string -o - "$ROOT/output/devbox/service.json")"
OUTPUT="$ROOT/output/devbox/macos/bos-devbox-$VERSION.pkg"
if [[ "$UNSIGNED" == true ]]; then OUTPUT="${OUTPUT%.pkg}-unsigned.pkg"; fi
STAGING="$(/usr/bin/mktemp -d "$ROOT/output/devbox/macos/.bos-devbox-pkg.XXXXXX")"
cleanup(){ /bin/rm -rf "$STAGING"; }
trap cleanup EXIT

/usr/bin/ditto "$PACKAGE_ROOT" "$STAGING/root"
/bin/chmod -R u=rwX,go=rX "$STAGING/root"
ARGS=(--root "$STAGING/root" --identifier com.blackoutsecure.endpoint-toolkit.devbox --version "$VERSION" --install-location / --ownership recommended)
if [[ "$UNSIGNED" == false ]]; then ARGS+=(--sign "$IDENTITY"); fi
/usr/bin/pkgbuild "${ARGS[@]}" "$STAGING/devbox.pkg"
if [[ "$UNSIGNED" == false ]]; then
  /usr/bin/xcrun notarytool submit "$STAGING/devbox.pkg" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 10m
  /usr/bin/xcrun stapler staple "$STAGING/devbox.pkg"
  /usr/sbin/pkgutil --check-signature "$STAGING/devbox.pkg"
  /usr/sbin/spctl --assess --type install "$STAGING/devbox.pkg"
fi
/bin/mv "$STAGING/devbox.pkg" "$OUTPUT"
if [[ "$UNSIGNED" == true ]]; then
  echo "UNSIGNED validation package only (not a release): $OUTPUT"
else
  echo "Signed, notarized, stapled package: $OUTPUT"
fi
