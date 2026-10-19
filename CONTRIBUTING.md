# Contributing

The most useful report is a boot where the guard judged wrong: rolled back a build whose Wi-Fi worked, or kept one that didn't. Open an issue with the machine, the Wi-Fi card (PCI or USB id), the macOS build, the kexts you were testing, your config file (minus anything private), `pending.json` from that attempt and the matching lines of `/Users/Shared/wifi-guard/wifi-guard.log`. Please don't attach the `.pcap` or `ifconfig.txt` publicly without looking at them first: they hold your local addresses and MACs. If you got it working with another Wi-Fi driver, the settings you used are welcome too.

Pull requests: keep them small and say how you tested them. A dry run (`WIFI_GUARD_DRY=1`) is fine for most changes; anything that touches the rollback path needs a real staged boot. I read and test every PR before merging. AI-assisted PRs are fine as long as you can explain the change, which is the same bar I hold my own code to.

Contributions are under the ISC licence, like the rest of the repo.
