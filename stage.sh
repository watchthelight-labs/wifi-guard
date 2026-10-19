#!/bin/bash
# <wtl> project: wifi-guard | file: stage.sh | author: watchthelight </wtl>
# Stage a Wi-Fi boot attempt on the OpenCore EFI partition for the guard (guard.sh) and record it. Run as the user
# named in GUARD_USER (not with sudo: it calls sudo itself and asks for the password once on a terminal):
#   ./stage.sh test-07 B "mtkfe=native mtknativeif=1" [<dir with the built kexts> | --no-kexts]
# The first argument is a free-form label for the attempt (it names the capture folders). Without a terminal the
# password is read from the first line of stdin and handed to sudo -S; it is kept in a shell variable only, never
# written to a file or printed.
# What it does, in order: mounts GUARD_EFI_DEV; keeps the current kexts (GUARD_KEXTS) and config.plist as the
# known-good set in EFI/OC/wifi-lastgood/ (only when none is there yet: the guard refreshes it after a pass); copies
# the freshly built kexts (from the given dir, or GUARD_KEXT_SRC) unless --no-kexts; rewrites the GUARD_BOOTARG_STRIP
# tokens of the config.plist boot-args to the given ones (a config.<attempt>.plist.bak is kept beside it); writes
# pending.json. It does not reboot.
set -euo pipefail
CONF=${WIFI_GUARD_CONF:-/usr/local/etc/wifi-guard.conf}
[ -f "$CONF" ] && . "$CONF"
ID=${1:?attempt label}; STAGE=${2:?stage A..E}; ARGS=${3:?the boot-arg tokens for this attempt}; KSRC=${4:-}
REPO=${GUARD_REPO:-}; S=${WIFI_GUARD_STATE:-${GUARD_STATE_DIR:-$HOME/.cache/wifi-guard}}; mkdir -p "$S"
EFI_DEV=${GUARD_EFI_DEV:?set GUARD_EFI_DEV in $CONF}; EFI_MOUNT=${GUARD_EFI_MOUNT:?set GUARD_EFI_MOUNT in $CONF}
KEXTS=${GUARD_KEXTS:-MtkWlan.kext MtkWlanNative.kext}
SRC_TPL=${GUARD_KEXT_SRC:-$PWD/{name\}.kext}
[ -n "$KSRC" ] && [ "$KSRC" != "--no-kexts" ] && SRC_TPL="$(cd "$KSRC" && pwd)/{name}.kext"
STRIP=${GUARD_BOOTARG_STRIP:-mtkfe= mtknativeif= mtknative= mtknativedelay=}
STRIP_RE="^($(echo "$STRIP" | tr -s ' ' '|' | sed -E 's/^\|//; s/\|$//'))"
if [ -t 0 ]; then
  sudo -v
  sudo_() { sudo "$@"; }
else
  read -r PW
  sudo_() { printf '%s\n' "$PW" | sudo -S -p '' "$@"; }
fi
if [ -n "$REPO" ] && [ -n "$(git -C "$REPO" status --porcelain | grep -v '^??')" ]; then echo "REFUSED: uncommitted changes in $REPO"; exit 2; fi
sudo_ diskutil mount "$EFI_DEV" >/dev/null 2>&1 || true
OC=$EFI_MOUNT/EFI/OC
[ -f "$OC/config.plist" ] || { echo "FAIL: $EFI_DEV not mounted at $EFI_MOUNT"; exit 1; }
PB=/usr/libexec/PlistBuddy
LG=$OC/wifi-lastgood
if [ ! -d "$LG" ]; then
  sudo_ mkdir -p "$LG/Kexts"
  for k in $KEXTS; do sudo_ cp -Rp "$OC/Kexts/$k" "$LG/Kexts/$k"; done
  sudo_ cp "$OC/config.plist" "$LG/config.plist"
  echo "lastgood set recorded from the current EFI files"
fi
if [ "$KSRC" != "--no-kexts" ]; then
  for kx in $KEXTS; do
    k=${kx%.kext}
    SRC=${SRC_TPL//\{name\}/$k}
    [ -d "$SRC" ] || { echo "FAIL: no build at $SRC"; exit 1; }
    sudo_ rm -rf "$OC/Kexts/$k.kext.new"
    sudo_ cp -Rp "$SRC" "$OC/Kexts/$k.kext.new"
    sudo_ rm -rf "$OC/Kexts/$k.kext"
    sudo_ mv "$OC/Kexts/$k.kext.new" "$OC/Kexts/$k.kext"
    echo "$k.kext <- $SRC ($($PB -c 'Print :CFBundleVersion' "$SRC/Contents/Info.plist"), sha $(shasum -a 256 "$SRC/Contents/MacOS/$k" | cut -c1-12))"
  done
fi
sudo_ cp "$OC/config.plist" "$OC/config.$(echo "$ID" | tr 'A-Z' 'a-z').plist.bak"
KEY=':NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args'
OLD=$($PB -c "Print $KEY" "$OC/config.plist")
NEW=$(echo "$OLD" | tr ' ' '\n' | grep -vE "$STRIP_RE" | tr '\n' ' ' | sed -E 's/ +$//')
NEW="$NEW $ARGS"
sudo_ $PB -c "Set $KEY $NEW" "$OC/config.plist"
echo "boot-args: $($PB -c "Print $KEY" "$OC/config.plist")"
sync
/usr/bin/python3 - "$ID" "$STAGE" "$ARGS" "$S/pending.json" "$REPO" "${GUARD_IFACE:-en1}" "${WIFI_GUARD_SSID:-${GUARD_SSID:-}}" <<'PY'
import json, sys, time, subprocess
aid, stage, args, path, repo, iface, ssid = sys.argv[1:8]
head = subprocess.run(["git", "-C", repo, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip() if repo else ""
json.dump({"attempt": aid, "stage": stage, "iface": iface, "boot_args": args, "ssid": ssid, "auto_reboots": 0, "repo_head": head,
           "staged_at": time.strftime("%Y-%m-%d %H:%M:%S %Z")}, open(path, "w"), indent=1)
print(f"pending {aid} stage {stage} recorded in {path}" + (f" (repo {head})" if head else ""))
PY
sudo_ diskutil unmount "$EFI_DEV" >/dev/null 2>&1 || true
echo "staged $ID: restart the Mac to run it"
