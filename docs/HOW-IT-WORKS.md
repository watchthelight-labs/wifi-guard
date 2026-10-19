# How wifi-guard works

Two scripts share `pending.json` in the state folder, and the known-good set in `EFI/OC/wifi-lastgood/` on the EFI partition.

## stage.sh

Runs as the user, before the restart:

1. With `GUARD_REPO` set, refuses if that repo has uncommitted changes.
2. Mounts `GUARD_EFI_DEV` and checks for `EFI/OC/config.plist` under `GUARD_EFI_MOUNT`.
3. If there is no `EFI/OC/wifi-lastgood/` yet, copies the current kexts (`GUARD_KEXTS`) and `config.plist` there. That's the known-good set. Later, the guard refreshes it after each pass.
4. Unless `--no-kexts`, copies each built kext in next to the live one as `<name>.kext.new`, deletes the live one and renames the new one into place, then prints its version and short sha256.
5. Backs up `config.plist` as `config.<label>.plist.bak`.
6. Rewrites `NVRAM > Add > 7C436110-AB2A-4BBB-A880-FE41995C9F82 > boot-args`: removes every token starting with one of `GUARD_BOOTARG_STRIP` and appends the attempt's tokens.
7. Writes `pending.json` and unmounts the partition:

```json
{
 "attempt": "test-07",
 "stage": "E",
 "iface": "en1",
 "boot_args": "mtkfe=native mtknativeif=1",
 "ssid": "My Network",
 "auto_reboots": 0,
 "repo_head": "",
 "staged_at": "2026-10-19 10:00:00 CEST"
}
```

## guard.sh

Runs as root at every boot (`RunAtLoad`), and once when `install.sh` loads it. It doesn't wait for a login. With no `pending.json` it exits. Otherwise:

| State | What the guard does |
|---|---|
| `result` is `pass`, `stuck` or `pass-after-rollback` | nothing, the attempt is finished |
| `started_boot` is an earlier boot and no result | that boot never reached a decision (a panic you power-cycled, or a hang): roll back at once, or record `stuck` if it already restarted once |
| `result` is `rolled-back` | the rollback boot: check the criteria for up to 240 s, record `pass-after-rollback` or `stuck`. Never restarts |
| otherwise | the boot under test, below |

The guard writes `started_boot` and starts a `tcpdump` on the interface (DHCP, ARP, ICMP), which waits up to 2 minutes for the interface to appear. Then, every 5 s until the deadline, it checks the criteria.

### Criteria

In order, the first failure is the reason:

1. `GUARD_CORE_ID` in `kextstat`.
2. From stage B: `GUARD_NATIVE_ID` in `kextstat`.
3. `ipconfig getifaddr <iface>` returns an address.
4. A default route on the interface in `netstat -rn`, scoped or not. Until the IO80211 family sees an association, the Wi-Fi service only gets an interface-scoped default (`UGScIg`), which `route get default` doesn't report.
5. The gateway answers one ping, sent out of that interface.
6. Stage E: a default route on the interface without the `I` (interface-scoped) flag. Without it configd ranks the service Never and apps get no internet (no Wi-Fi service, or a captive portal).
7. Stages D and E: `ipconfig getsummary` shows an SSID, or `networksetup -getairportnetwork` reports a current network.

While it waits, at stages D and E it asks macOS to join `GUARD_SSID` with `networksetup -setairportnetwork` every 20 s until an SSID shows up. At stage E, once the interface is listed as a Wi-Fi hardware port, it removes any Ethernet network service still bound to that interface and runs `networksetup -detectnewhardware`, once per boot. A driver that first published the interface as Ethernet leaves such a service behind in `preferences.plist`, and it blocks the Wi-Fi one.

### Pass

`result: pass`, then:

- stages A, D, E: capture to `<label>-pass/`, then copy the live kexts and `config.plist` into `wifi-lastgood/`;
- stages B, C: wait `WIFI_GUARD_LINGER` (60 s) so the Wi-Fi menu issues scans, capture, put the known-good set back, `auto_reboots + 1`, restart. The next boot sees `pass` and does nothing.

### Rollback

1. Mount the EFI partition.
2. No `wifi-lastgood/`: `stuck`, no restart.
3. For each kext in `GUARD_KEXTS` that the known-good set has: copy it in as `<name>.kext.rollback-tmp`, delete the live one, rename. A crash halfway leaves either the old or the new kext, never half of one.
4. Copy the known-good `config.plist` over the live one.
5. Capture to `<label>-rollback/`, unmount, `result: rolled-back` with the reason, `auto_reboots + 1`, restart.

In a dry run (`WIFI_GUARD_DRY=1`) the "EFI partition" is a fresh temporary folder, there is no packet capture, the known-good set isn't refreshed after a pass, and nothing restarts.

## Why it doesn't ask a person

A broken Wi-Fi build is visible from inside the machine: no lease, no gateway, no association. The guard can judge it alone, which matters because the person may be away and the thing that would normally fix it remotely is the network that just broke. Its GPU counterpart, gpu-guard, can't do that: a frozen panel looks fine from inside, so there a person has to say Good.
