#!/bin/sh
# Installs or updates Luka from the latest GitHub release.
#   curl -fsSL https://raw.githubusercontent.com/StableFluffy/luka/main/install.sh | sh
set -eu

REPO="StableFluffy/luka"
TEAM_ID="GUZM82F84W"

say() { printf '%s\n' "$*"; }
die() { printf 'luka-install: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Luka runs on macOS only."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 15 ] || die "Luka needs macOS 15 or newer (this Mac has $(sw_vers -productVersion))."

tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
tag=${tag##*/}
case "$tag" in
    v[0-9]*) ;;
    *) die "couldn't find the latest release." ;;
esac
version=${tag#v}

if [ -d "/Applications/Luka.app" ]; then
    dest="/Applications"
elif [ -d "$HOME/Applications/Luka.app" ]; then
    dest="$HOME/Applications"
elif [ -w "/Applications" ]; then
    dest="/Applications"
else
    dest="$HOME/Applications"
    mkdir -p "$dest"
fi
app="$dest/Luka.app"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Downloading Luka ${version}..."
curl -fL --progress-bar -o "$tmp/Luka.zip" "https://github.com/$REPO/releases/download/$tag/Luka-${version}.zip"
ditto -x -k "$tmp/Luka.zip" "$tmp/unpacked"
new="$tmp/unpacked/Luka.app"
[ -d "$new" ] || die "the download didn't contain Luka.app."

codesign --verify --deep --strict "$new" 2>/dev/null || die "the app's signature is invalid."
codesign -dv "$new" 2>&1 | grep -q "^TeamIdentifier=$TEAM_ID\$" || die "the app isn't signed by Luka's developer."
spctl --assess --type execute "$new" 2>/dev/null || die "macOS Gatekeeper rejected the app."

if pgrep -xq Luka; then
    say "Quitting Luka..."
    osascript -e 'tell application id "io.github.stablefluffy.luka" to quit' >/dev/null 2>&1 || true
    i=0
    while pgrep -xq Luka && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
    pgrep -xq Luka && die "Luka is still running. Quit it and run this again."
fi

if [ -d "$app" ]; then
    mv "$app" "$tmp/old-Luka.app"
fi
ditto "$new" "$app"

say "Installed Luka ${version} in $dest."
open "$app"
