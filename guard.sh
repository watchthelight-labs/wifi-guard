#!/bin/bash
# <wtl> project: wifi-guard | file: guard.sh | author: watchthelight </wtl>
# Boot-time Wi-Fi guard (LaunchDaemon org.watchthelight.wifi-guard, root). stage.sh records an attempt in pending.json
# before the reboot; this script waits for the attempt's Wi-Fi criteria and, when they are not met, puts the last
# known-good Wi-Fi kexts and config.plist back on the OpenCore EFI partition and restarts. One automatic restart at
# most: a failure after the rollback boot is recorded as "stuck" and left for a person.
#   WIFI_GUARD_DRY=1 guard.sh      restores into a temp folder, never reboots (the dry run before the first real attempt)
#   WIFI_GUARD_PENDING=<file>      use another pending file (dry runs)
# Settings: /usr/local/etc/wifi-guard.conf (WIFI_GUARD_CONF=<file> for another one), see wifi-guard.conf.example.
set -u
CONF=${WIFI_GUARD_CONF:-/usr/local/etc/wifi-guard.conf}
[ -f "$CONF" ] && . "$CONF"
USER_NAME=${GUARD_USER:-}
[ -n "$USER_NAME" ] || { echo "wifi-guard: GUARD_USER is not set in $CONF" >&2; exit 1; }
HOME_DIR=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | awk '{print $2}'); [ -n "$HOME_DIR" ] || HOME_DIR=/Users/$USER_NAME
S=${WIFI_GUARD_STATE:-${GUARD_STATE_DIR:-$HOME_DIR/.cache/wifi-guard}}
P=${WIFI_GUARD_PENDING:-$S/pending.json}
LOGDIR=${GUARD_LOG_DIR:-/Users/Shared/wifi-guard}
LOG=$LOGDIR/wifi-guard.log
DRY=${WIFI_GUARD_DRY:-0}
TIMEOUT=${WIFI_GUARD_TIMEOUT:-240}
EFI_DEV=${GUARD_EFI_DEV:-}
EFI_MOUNT=${GUARD_EFI_MOUNT:-}
# the kexts under test: KEXTS are swapped as a set; CORE_ID must be loaded at every stage, NATIVE_ID from stage B on
KEXTS=${GUARD_KEXTS:-MtkWlan.kext MtkWlanNative.kext}
CORE_ID=${GUARD_CORE_ID:-org.watchthelight.MtkWlan}
NATIVE_ID=${GUARD_NATIVE_ID:-org.watchthelight.MtkWlanNative}
DMESG_GREP=${GUARD_DMESG_GREP:-mtk}
mkdir -p "$S" "$LOGDIR"
[ "$(id -u)" = 0 ] && chown "$USER_NAME":staff "$S" 2>/dev/null   # stage.sh (the user) writes pending.json here too
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
[ -f "$P" ] || { log "no pending attempt"; exit 0; }
[ -n "$EFI_DEV" ] && [ -n "$EFI_MOUNT" ] || { log "GUARD_EFI_DEV and GUARD_EFI_MOUNT must be set in $CONF"; exit 1; }
BOOT=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')
PY=/usr/bin/python3
field() { $PY -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2], ""); print(v if not isinstance(v,bool) else int(v))' "$P" "$1"; }
setfield() { $PY - "$P" "$1" "$2" <<'EOF'
import json, sys
p, k, v = sys.argv[1:4]
d = json.load(open(p))
try: v = json.loads(v)
except Exception: pass
d[k] = v
json.dump(d, open(p, "w"), indent=1)
EOF
}
ATTEMPT=$(field attempt); STAGE=$(field stage); IFACE=$(field iface); [ -n "$IFACE" ] || IFACE=${GUARD_IFACE:-en1}
SSID=$(field ssid); [ -n "$SSID" ] || SSID=${GUARD_SSID:-}   # the network stages D/E ask macOS to join
REBOOTS=$(field auto_reboots); [ -n "$REBOOTS" ] || REBOOTS=0
STARTED=$(field started_boot); RESULT=$(field result)

# What the boot looked like, kept for the next session whatever happens next (the kexts' registry properties hold the
# driver's trace and counters; kernel IOLog lines may not reach log show). The packet capture started below shows
# whether DHCP left the interface and whether anything came back.
capture() {
  local tag=$1 k
  local d=$S/$ATTEMPT-$tag
  mkdir -p "$d"
  for k in $KEXTS; do k=${k%.kext}; ioreg -r -c "$k" -l > "$d/ioreg-$(echo "$k" | tr 'A-Z' 'a-z').txt" 2>/dev/null; done
  ifconfig -a > "$d/ifconfig.txt" 2>/dev/null
  netstat -rn > "$d/netstat-rn.txt" 2>/dev/null
  arp -an > "$d/arp.txt" 2>/dev/null
  kextstat 2>/dev/null | grep -E "${GUARD_KEXT_GREP:-watchthelight|nullmoth}" > "$d/kextstat.txt"
  dmesg 2>/dev/null | grep -iE "$DMESG_GREP" | tail -200 > "$d/dmesg.txt"
  /usr/bin/log show --last 6m --predicate "(subsystem == \"com.apple.IPConfiguration\" AND eventMessage CONTAINS \"$IFACE\") OR (process == \"configd\" AND eventMessage CONTAINS \"$IFACE\")" --style compact > "$d/configd-$IFACE.txt" 2>/dev/null
  # what the Family made of the scan results and the join: the previous boot's unified log may not survive the reboot
  system_profiler SPAirPortDataType > "$d/airport-profile.txt" 2>/dev/null
  wdutil info > "$d/wdutil-info.txt" 2>/dev/null
  /usr/bin/log show --last 6m --info --predicate 'process == "airportd" OR process == "wifid" OR process == "WiFiAgent" OR subsystem BEGINSWITH "com.apple.wifi" OR (process == "kernel" AND eventMessage CONTAINS "80211")' --style compact > "$d/wifi-daemons.txt" 2>/dev/null
  [ -n "${TCPDUMP_PID:-}" ] && { kill "$TCPDUMP_PID" 2>/dev/null; sleep 1; cp "$PCAP" "$d/" 2>/dev/null; }
  chown -R "$USER_NAME":staff "$d" 2>/dev/null
  log "captured $tag -> $d"
}
start_capture() {
  PCAP=$LOGDIR/wifi-$ATTEMPT.pcap
  ( for i in $(seq 1 60); do ifconfig "$IFACE" >/dev/null 2>&1 && break; sleep 2; done
    exec tcpdump -i "$IFACE" -s 256 -w "$PCAP" 'udp port 67 or udp port 68 or arp or icmp or icmp6' ) >/dev/null 2>&1 &
  TCPDUMP_PID=$!
}
mount_efi() {
  if [ "$DRY" = 1 ]; then R=$(mktemp -d /tmp/wifi-guard-dry.XXXX); mkdir -p "$R/EFI/OC/Kexts"; echo "$R"; return; fi
  if [ ! -d "$EFI_MOUNT/EFI/OC" ]; then diskutil mount "$EFI_DEV" >/dev/null 2>&1; sleep 1; fi
  echo "$EFI_MOUNT"
}
rollback() {
  local why=$1 root lg
  root=$(mount_efi)
  lg=${WIFI_GUARD_LASTGOOD:-$EFI_MOUNT/EFI/OC/wifi-lastgood}
  if [ ! -d "$lg" ]; then log "ROLLBACK IMPOSSIBLE: no $lg"; setfield result '"stuck"'; setfield reason "\"no lastgood: $why\""; return 1; fi
  log "rollback ($why): $lg -> $root/EFI/OC"
  for k in $KEXTS; do
    [ -d "$lg/Kexts/$k" ] || continue
    rm -rf "$root/EFI/OC/Kexts/$k.rollback-tmp"
    cp -Rp "$lg/Kexts/$k" "$root/EFI/OC/Kexts/$k.rollback-tmp" && rm -rf "$root/EFI/OC/Kexts/$k" && mv "$root/EFI/OC/Kexts/$k.rollback-tmp" "$root/EFI/OC/Kexts/$k"
  done
  [ -f "$lg/config.plist" ] && cp "$lg/config.plist" "$root/EFI/OC/config.plist"
  sync
  capture "rollback"
  if [ "$DRY" = 1 ]; then log "DRY: restored into $root, no reboot"; setfield result '"rolled-back"'; setfield reason "\"$why\""; return 0; fi
  diskutil unmount "$EFI_DEV" >/dev/null 2>&1
  setfield result '"rolled-back"'; setfield reason "\"$why\""; setfield auto_reboots "$((REBOOTS + 1))"
  log "restarting after rollback ($ATTEMPT)"
  shutdown -r now "wifi-guard rollback $ATTEMPT: $why"
}
refresh_lastgood() {
  local root lg
  root=$(mount_efi); lg=$root/EFI/OC/wifi-lastgood
  [ "$DRY" = 1 ] && { log "DRY: would refresh lastgood"; return; }
  mkdir -p "$lg/Kexts"
  for k in $KEXTS; do rm -rf "$lg/Kexts/$k"; cp -Rp "$root/EFI/OC/Kexts/$k" "$lg/Kexts/$k"; done
  cp "$root/EFI/OC/config.plist" "$lg/config.plist"
  sync; diskutil unmount "$EFI_DEV" >/dev/null 2>&1
  log "lastgood refreshed from the passing set"
}
criteria_ok() {
  # kexts loaded, an IPv4 lease on the Wi-Fi interface, the gateway answers; stages D/E also need the SSID
  kextstat 2>/dev/null | grep -q "$CORE_ID" || { WHY="$CORE_ID not loaded"; return 1; }
  [ "$STAGE" = A ] || kextstat 2>/dev/null | grep -q "$NATIVE_ID" || { WHY="$NATIVE_ID not loaded"; return 1; }
  local ip gw
  ip=$(ipconfig getifaddr "$IFACE" 2>/dev/null)
  [ -n "$ip" ] || { WHY="no IPv4 lease on $IFACE"; return 1; }
  # the default route on the interface, scoped or not: until the Family sees an association (stage D) the Wi-Fi service
  # gets no unscoped default (only "default 192.0.2.1 UGScIg en1"), which route get default does not report
  gw=$(netstat -rn -f inet 2>/dev/null | awk -v i="$IFACE" '$1 == "default" && $NF == i {print $2; exit}')
  [ -n "$gw" ] || { WHY="no default route on $IFACE (lease $ip)"; return 1; }
  ping -c 1 -W 2000 -b "$IFACE" "$gw" >/dev/null 2>&1 || { WHY="gateway $gw does not answer (lease $ip)"; return 1; }
  case "$STAGE" in E)
    netstat -rn -f inet 2>/dev/null | awk -v i="$IFACE" '$1=="default" && $NF==i && $3 !~ /I/' | grep -q . \
      || { WHY="default route on $IFACE is interface-scoped only (configd ranks it Never: captive portal or no Wi-Fi service; lease $ip)"; return 1; } ;;
  esac
  case "$STAGE" in D|E)
    ipconfig getsummary "$IFACE" 2>/dev/null | grep -q ' SSID : ' || networksetup -getairportnetwork "$IFACE" 2>/dev/null | grep -q 'Current Wi-Fi Network' \
      || { WHY="no SSID reported on $IFACE (lease $ip, gateway ok)"; return 1; } ;;
  esac
  WHY="lease $ip, gateway $gw answers"; return 0
}

log "guard start: attempt=$ATTEMPT stage=$STAGE iface=$IFACE boot=$BOOT started_boot=${STARTED:-none} result=${RESULT:-none} auto_reboots=$REBOOTS dry=$DRY"
case "$RESULT" in
  pass|stuck|pass-after-rollback) log "attempt already finished ($RESULT); nothing to do"; exit 0 ;;
esac
# A started marker from an earlier boot with no result = that boot never reached the criteria (a panic the user
# power-cycled, or a hang): roll back now without waiting.
if [ -n "$STARTED" ] && [ "$STARTED" != "$BOOT" ] && [ -z "$RESULT" ]; then
  if [ "$REBOOTS" -ge 1 ]; then setfield result '"stuck"'; setfield reason '"second failure (earlier boot never passed)"'; log "STUCK: no further reboot"; exit 1; fi
  rollback "earlier boot $STARTED never passed"; exit $?
fi
setfield started_boot "$BOOT"
[ "$DRY" = 1 ] || start_capture
if [ "$RESULT" = "rolled-back" ]; then
  log "this is the rollback boot; checking that the known-good set works"
  deadline=$(( $(date +%s) + TIMEOUT )); WHY=""
  while [ "$(date +%s)" -lt "$deadline" ]; do criteria_ok && break; sleep 5; done
  if criteria_ok; then setfield result '"pass-after-rollback"'; log "rollback boot ok: $WHY"; exit 0; fi
  setfield result '"stuck"'; setfield reason "\"rollback boot failed too: $WHY\""; log "STUCK: $WHY (no further reboot)"; exit 1
fi
deadline=$(( $(date +%s) + TIMEOUT )); WHY=""; n=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  criteria_ok && break
  # stages D/E: macOS drives the join, so ask it the way the Wi-Fi menu would, once the interface exists, every 20 s
  # until an SSID is reported. The network goes into its known-networks list too.
  # stage E: if the interface was an Ethernet port before (an earlier driver published it that way), its network service
  # in preferences.plist still says so ("Network Service Inactive" in the Wi-Fi profile). Once macOS lists the port as
  # Wi-Fi, drop that service and let configd create the Wi-Fi one (networksetup -detectnewhardware). Once per boot.
  if [ "$STAGE" = E ] && [ -z "${SERVICE_FIXED:-}" ] && networksetup -listallhardwareports 2>/dev/null | grep -A1 'Hardware Port: Wi-Fi' | grep -q "Device: $IFACE"; then
    SERVICE_FIXED=1
    svc=$(networksetup -listnetworkserviceorder 2>/dev/null | awk -v i="$IFACE" '/^\([0-9*]+\) /{name=$0; sub(/^\([0-9*]+\) /,"",name)} /Hardware Port: Ethernet, Device: /{if ($NF==i")") print name}')
    if [ -n "$svc" ]; then
      out=$(networksetup -removenetworkservice "$svc" 2>&1); log "removed stale Ethernet service '$svc' for $IFACE: ${out:-ok}"
      out=$(networksetup -detectnewhardware 2>&1); log "detectnewhardware: ${out:-ok}"
      log "services now: $(networksetup -listnetworkserviceorder 2>/dev/null | grep -A1 "Device: $IFACE" | tr '\n' ' ')"
    else log "no stale Ethernet service for $IFACE (ok)"; fi
  fi
  case "$STAGE" in D|E)
    if [ $((n % 4)) = 0 ] && ifconfig "$IFACE" >/dev/null 2>&1 && ! ipconfig getsummary "$IFACE" 2>/dev/null | grep -q ' SSID : '; then
      out=$(networksetup -setairportnetwork "$IFACE" "$SSID" 2>&1); log "join request '$SSID' on $IFACE: ${out:-ok}"
    fi ;;
  esac
  n=$((n + 1)); sleep 5
done
if criteria_ok; then
  setfield result '"pass"'; setfield reason "\"$WHY\""; log "PASS $ATTEMPT stage $STAGE: $WHY"
  case "$STAGE" in
    B|C)
      # A pass at these stages still has no internet for apps (the interface is ranked Never until the Family sees an
      # association, stage D), so whatever continues the test could not reach the network. Give the menu a minute to
      # issue scans, capture everything, then go back to the known-good set so the next boot has network; the result
      # stays pass.
      sleep "${WIFI_GUARD_LINGER:-60}"
      capture "pass"
      [ "$DRY" = 1 ] && exit 0
      root=$(mount_efi); lg=${WIFI_GUARD_LASTGOOD:-$EFI_MOUNT/EFI/OC/wifi-lastgood}
      for k in $KEXTS; do
        [ -d "$lg/Kexts/$k" ] || continue
        rm -rf "$root/EFI/OC/Kexts/$k.rollback-tmp"
        cp -Rp "$lg/Kexts/$k" "$root/EFI/OC/Kexts/$k.rollback-tmp" && rm -rf "$root/EFI/OC/Kexts/$k" && mv "$root/EFI/OC/Kexts/$k.rollback-tmp" "$root/EFI/OC/Kexts/$k"
      done
      [ -f "$lg/config.plist" ] && cp "$lg/config.plist" "$root/EFI/OC/config.plist"
      sync; diskutil unmount "$EFI_DEV" >/dev/null 2>&1
      setfield auto_reboots "$((REBOOTS + 1))"
      log "pass at stage $STAGE: known-good set put back for the next boot (no internet at this stage), restarting"
      shutdown -r now "wifi-guard pass $ATTEMPT stage $STAGE: back to the known-good set" ;;
    *)
      capture "pass"
      refresh_lastgood ;;
  esac
  exit 0
fi
log "FAIL $ATTEMPT stage $STAGE after ${TIMEOUT}s: $WHY"
if [ "$REBOOTS" -ge 1 ]; then setfield result '"stuck"'; setfield reason "\"$WHY\""; log "STUCK: already restarted once"; exit 1; fi
rollback "$WHY"
