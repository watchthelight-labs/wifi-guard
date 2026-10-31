# WTLWifiGuard

Renamed from `wifi-guard` on 2026-10-31; the installed tool is still `wifi-guard`. Old links redirect here.

A boot-time safety net for testing Wi-Fi kext builds on an OpenCore Hackintosh. You stage a build on the EFI partition and restart. After the boot, the guard waits for the Wi-Fi to actually work: the kexts loaded, a DHCP lease, a gateway that answers, and at the later stages an associated network. If that happens, the new build becomes the known-good set. If it doesn't happen within 240 s, the guard copies the last known-good kexts and `config.plist` back onto the EFI partition and restarts.

I wrote it while bringing up a driver for the MediaTek MT7925 on a laptop with no Ethernet cable nearby. A bad Wi-Fi build there doesn't only break Wi-Fi. It takes the machine off the network, so nothing remote can fix it, and whatever was driving the test (a script, an ssh session, a coding agent) can't reach the network either. The guard needs no network and no person. It decides from inside the machine and puts the working set back.

The defaults fit the MT7925 drivers [MtkWlan](https://github.com/watchthelight-labs/WTLMtkWireless) and [MtkWlanNative](https://github.com/watchthelight-labs/WTLWifiMenu). Other kexts work by changing a few settings.

## The flow

1. Build the kexts.
2. Stage the attempt:

   ```
   ./stage.sh test-07 E "mtkfe=native mtknativeif=1" ~/build/out
   ```

   `test-07` is any label you like; it names the capture folders and the `config.plist` backup. `E` is the stage (below). The third argument is the boot-arg tokens for this attempt. The last argument is the folder with the built kexts, or `--no-kexts` to test boot-args only.
3. Restart.
4. The guard waits up to 240 s for the stage's criteria.
5. Pass: `result: pass`, a capture, and the live kexts and `config.plist` become the new known-good set (at stages B and C it does something else, see below).
6. Fail: `result: rolled-back` with the reason, a capture, the known-good set back on the EFI partition, restart. On the rollback boot the same criteria are checked again and the result is `pass-after-rollback` or `stuck`.

The guard restarts the Mac at most once per attempt. A boot that panicked or hung before it decided (you power-cycled it) is rolled back as soon as the next boot starts.

## Stages

The stage says how much of the network has to work for a pass.

| Stage | Pass needs | After a pass |
|---|---|---|
| A | core kext loaded, IPv4 lease, gateway answers ping | known-good set updated |
| B, C | also the front-end kext loaded | waits 60 s, captures, puts the known-good set back and restarts. The result stays `pass` |
| D | also an SSID reported for the interface; the guard asks macOS to join `GUARD_SSID` every 20 s | known-good set updated |
| E | as D, plus a default route that isn't interface-scoped only (so apps get internet); removes a stale Ethernet network service for the interface once | known-good set updated |

B and C are for a front end that can get a lease but isn't yet seen as associated, which leaves apps without internet. Going back to the known-good set right away gives the next boot a working network. For a finished driver, use E.

## Installation

Needs admin rights (the guard is a root LaunchDaemon that writes to the EFI partition) and `/usr/bin/python3`, which comes with the Xcode Command Line Tools (`xcode-select --install`).

```
git clone https://github.com/watchthelight-labs/WTLWifiGuard
cd wifi-guard
sudo ./install.sh
```

Run it from the account that stages the attempts. It installs:

| Path | What |
|---|---|
| `/usr/local/bin/wifi-guard` | the guard (`guard.sh`) |
| `/Library/LaunchDaemons/org.watchthelight.wifi-guard.plist` | runs the guard at every boot, as root |
| `/usr/local/etc/wifi-guard.conf` | settings, written from `wifi-guard.conf.example` with `GUARD_USER` set to you (only if it doesn't exist) |

Then edit `/usr/local/etc/wifi-guard.conf` with `sudo` and set at least `GUARD_EFI_DEV` and `GUARD_EFI_MOUNT` (`diskutil list` shows the partition; mount it once to see its mount point). `stage.sh` stays in the clone; run it from there.

### sudo and passwords

`stage.sh` runs as your user and calls `sudo` for the EFI writes. On a terminal it asks for your password once (`sudo -v`). Without a terminal, for example from a script, it reads the password from the first line of stdin and hands it to `sudo -S`:

```
printf '%s\n' "$PASSWORD" | ./stage.sh test-07 E "mtkfe=native mtknativeif=1" ~/build/out
```

The password stays in a shell variable for the life of the script. It is never written to a file, a log or `pending.json`, and never printed. Where `$PASSWORD` comes from is up to you; don't put it in a file in the repo.

## Configuration

`/usr/local/etc/wifi-guard.conf` is a shell file read by both scripts.

| Setting | Default | Meaning |
|---|---|---|
| `GUARD_USER` | (set by install.sh) | owns the state folder and the captures |
| `GUARD_EFI_DEV` | none, required | the OpenCore EFI partition, e.g. `disk0s1` |
| `GUARD_EFI_MOUNT` | none, required | where it mounts, e.g. `/Volumes/EFI` |
| `GUARD_STATE_DIR` | `~/.cache/wifi-guard` | `pending.json` and the captures |
| `GUARD_LOG_DIR` | `/Users/Shared/wifi-guard` | `wifi-guard.log` and the packet capture |
| `GUARD_IFACE` | `en1` | the Wi-Fi interface |
| `GUARD_SSID` | none | the network stages D and E join (a saved or open network) |
| `GUARD_REPO` | none | a git checkout that must be clean when you stage; its HEAD is recorded |
| `GUARD_KEXTS` | `MtkWlan.kext MtkWlanNative.kext` | the kexts swapped and rolled back as a set |
| `GUARD_CORE_ID` | `org.watchthelight.MtkWlan` | bundle id that must be loaded at every stage |
| `GUARD_NATIVE_ID` | `org.watchthelight.MtkWlanNative` | bundle id that must be loaded from stage B on |
| `GUARD_KEXT_SRC` | `./{name}.kext` | where `stage.sh` finds builds when no folder is given; `{name}` is the kext name |
| `GUARD_BOOTARG_STRIP` | `mtkfe= mtknativeif= mtknative= mtknativedelay=` | boot-arg tokens removed before the attempt's own are added |
| `GUARD_KEXT_GREP`, `GUARD_DMESG_GREP` | `watchthelight\|nullmoth`, `mtk` | capture filters |

For a single-kext driver, set `GUARD_KEXTS` to that one kext, set `GUARD_CORE_ID` to its bundle id and stage at A (or set `GUARD_NATIVE_ID` to the same id and use D or E).

Environment variables for testing: `WIFI_GUARD_CONF`, `WIFI_GUARD_STATE`, `WIFI_GUARD_PENDING`, `WIFI_GUARD_LASTGOOD` (another known-good folder), `WIFI_GUARD_TIMEOUT` (default 240), `WIFI_GUARD_LINGER` (the 60 s at B and C), `WIFI_GUARD_SSID` (at stage time), `WIFI_GUARD_DRY=1`.

## What gets captured

On every pass and every rollback, `<label>-pass/` or `<label>-rollback/` in the state folder:

| File | Contents |
|---|---|
| `ioreg-<kext>.txt` | each kext's registry entries (drivers often keep counters and traces there) |
| `ifconfig.txt`, `netstat-rn.txt`, `arp.txt` | interface, routes, neighbours |
| `kextstat.txt` | loaded kexts matching `GUARD_KEXT_GREP` |
| `dmesg.txt` | the last 200 matching kernel log lines |
| `configd-<iface>.txt` | IPConfiguration and configd lines for the interface, last 6 minutes |
| `airport-profile.txt`, `wdutil-info.txt` | what macOS thinks of the Wi-Fi |
| `wifi-daemons.txt` | airportd, wifid, WiFiAgent and 802.11 kernel lines, last 6 minutes |
| `wifi-<label>.pcap` | DHCP, ARP and ICMP on the interface since boot (tcpdump, 256-byte snap) |

`pending.json` keeps `result`, `reason`, `started_boot` and `auto_reboots`. The log is `/Users/Shared/wifi-guard/wifi-guard.log`. The known-good set lives on the EFI partition in `EFI/OC/wifi-lastgood/`, and each stage leaves `EFI/OC/config.<label>.plist.bak`.

## Dry run

```
WIFI_GUARD_DRY=1 WIFI_GUARD_PENDING=/tmp/p.json WIFI_GUARD_LASTGOOD=/path/to/a/copy WIFI_GUARD_TIMEOUT=5 sudo -E /usr/local/bin/wifi-guard
```

It restores into a temporary folder instead of the EFI partition, starts no packet capture and never restarts. Use a copy of a real `pending.json`: the dry run writes `started_boot` and a result into the file you give it.

## Uninstall

```
sudo launchctl bootout system/org.watchthelight.wifi-guard
sudo rm /Library/LaunchDaemons/org.watchthelight.wifi-guard.plist /usr/local/bin/wifi-guard /usr/local/etc/wifi-guard.conf
rm -rf ~/.cache/wifi-guard; sudo rm -rf /Users/Shared/wifi-guard
```

`EFI/OC/wifi-lastgood/` and the `config.*.plist.bak` files stay on the EFI partition; delete them by hand if you want.

## Safety notes

- **It writes your boot partition as root.** A wrong `GUARD_EFI_DEV` means the guard mounts and writes the wrong partition. Check it with `diskutil info` before the first stage, and keep a bootable USB with a working EFI.
- A rollback restores the **whole** `config.plist` from the known-good set, not only the boot-args. Any other config change made since the known-good set was taken is undone too.
- A pass at A, D or E promotes the live set to known-good automatically. Pick the stage that matches what "working" means for you.
- The config file is sourced by the root daemon. Keep it `root:wheel 644`.
- It restarts once per attempt at most, so it can't loop. A failed rollback boot is `stuck` and waits for you.
- Nothing leaves the machine. The packet capture holds your local network's DHCP and ARP traffic (addresses, MACs); keep that in mind before attaching it to an issue.

## Status

Used daily for Wi-Fi test boots on a Lenovo Legion 5 15IAX10 Hackintosh (MediaTek MT7925, macOS 26.7.1 25G241, OpenCore 1.0.8) while bringing up MtkWlan and MtkWlanNative. It has rolled back failed builds on its own, and once recorded `stuck` when the rollback boot failed the same criteria. Tested on that one machine only.

## How it works

The state machine and the criteria in detail: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md). The GPU counterpart, which asks a person instead of checking the network, is [WTLGpuGuard](https://github.com/watchthelight-labs/WTLGpuGuard).

## Licence

ISC, see [LICENSE](LICENSE).
