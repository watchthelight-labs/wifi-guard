# Changelog

## 0.1.0 (2026-10-19)

- First public release. `stage.sh` puts a Wi-Fi kext build and its boot-args on the OpenCore EFI partition and keeps the known-good set; the `org.watchthelight.wifi-guard` LaunchDaemon checks kexts, lease, gateway and (stages D and E) association, and rolls back and restarts once when they fail.
- Settings in `/usr/local/etc/wifi-guard.conf`; defaults fit the MT7925 drivers MtkWlan and MtkWlanNative.
- `stage.sh` asks for the sudo password on a terminal, or reads it from stdin without one.
- Dry run mode (`WIFI_GUARD_DRY=1`) that restores into a temporary folder.
