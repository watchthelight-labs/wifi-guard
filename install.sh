#!/bin/bash
# <wtl> project: wifi-guard | file: install.sh | author: watchthelight </wtl>
# Install the Wi-Fi boot guard: sudo ./install.sh (from this folder, as the user who stages the attempts).
# Writes /usr/local/etc/wifi-guard.conf with GUARD_USER set to that user if no config is there yet; set GUARD_EFI_DEV
# and GUARD_EFI_MOUNT in it before the first stage.
# Undo:
#   sudo launchctl bootout system/org.watchthelight.wifi-guard
#   sudo rm /Library/LaunchDaemons/org.watchthelight.wifi-guard.plist /usr/local/bin/wifi-guard /usr/local/etc/wifi-guard.conf
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
CONF=/usr/local/etc/wifi-guard.conf
mkdir -p /usr/local/bin /usr/local/etc /Users/Shared/wifi-guard
if [ ! -f "$CONF" ]; then
  [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] || { echo "run with sudo from the user account that stages the attempts, or write $CONF first (see wifi-guard.conf.example)"; exit 1; }
  sed "s/^GUARD_USER=.*/GUARD_USER=$SUDO_USER/" wifi-guard.conf.example > "$CONF"
  chown root:wheel "$CONF"; chmod 644 "$CONF"
  echo "wrote $CONF (GUARD_USER=$SUDO_USER); set GUARD_EFI_DEV and GUARD_EFI_MOUNT in it"
fi
install -m 755 -o root -g wheel guard.sh /usr/local/bin/wifi-guard
install -m 644 -o root -g wheel org.watchthelight.wifi-guard.plist /Library/LaunchDaemons/org.watchthelight.wifi-guard.plist
launchctl bootout system/org.watchthelight.wifi-guard 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/org.watchthelight.wifi-guard.plist
echo "installed /usr/local/bin/wifi-guard and the LaunchDaemon (log: /Users/Shared/wifi-guard/wifi-guard.log)"
