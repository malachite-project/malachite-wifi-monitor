#!/system/bin/sh
# malachite Wi-Fi monitor+injection: actively swap the stock gen4m stack for ours.
# Runs each boot (from service.sh).
#
# Safety invariant: we NEVER unload the stock driver unless we have a known-good
# on-disk copy of every stock module to put back, and if ours does not come up
# functionally we restore stock automatically. Worst realistic case is "Wi-Fi is
# plain stock after a reboot", never "Wi-Fi is dead".

MODDIR=${0%/*}
KO="$MODDIR/modules"
SD=/data/adb/malachite_wifi_monitor
mkdir -p "$SD"; chmod 700 "$SD"

# ---- single-instance lock, held for this boot so the Action button won't poke
#      Wi-Fi mid-swap. service.sh launches us exactly once per boot, so any lock
#      present now is stale from a crashed previous boot -> clear it, then take it.
LOCK="$SD/.swap.lock"
rm -rf "$LOCK" 2>/dev/null
mkdir "$LOCK" 2>/dev/null
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ---- log, keeping the previous boot's log so a boot-loop still leaves evidence
LOG="$SD/swap.log"
[ -f "$LOG" ] && mv -f "$LOG" "$SD/swap.log.1" 2>/dev/null
: > "$LOG"; exec >>"$LOG" 2>&1
log(){ echo "[$(date +%H:%M:%S)] $*"; }
mods(){ grep -E '^(wlan_drv_gen4m_6878|mac80211|cfg80211) ' /proc/modules 2>/dev/null | awk '{print $1"("$3")"}' | tr '\n' ' '; }
loaded(){ grep -q "^$1 " /proc/modules 2>/dev/null; }
# Capture SELinux/module denials so we know exactly what (if anything) to add to
# sepolicy.rule. A module_load/sys_module AVC here is the usual insmod blocker.
avc_dump(){ D=$(dmesg 2>/dev/null | grep -iE 'avc: .*denied' | grep -iE 'module|\.ko|cfg80211|mac80211|wlan|sys_module' | tail -8); [ -n "$D" ] && { log "---- relevant AVC denials ----"; echo "$D"; log "------------------------------"; }; }
# Wi-Fi is "functional" once the driver has created the wlan0 netdev.
wifi_ok(){ ip link show wlan0 >/dev/null 2>&1 || iw dev 2>/dev/null | grep -q 'Interface wlan0'; }

log "==== malachite wifi driver swap (v1.2) ===="

# 1) wait for boot to finish, then for the stock wlan module to be loaded
i=0; while [ "$(getprop sys.boot_completed)" != 1 ] && [ $i -lt 120 ]; do sleep 2; i=$((i+2)); done
log "boot_completed=$(getprop sys.boot_completed) (+${i}s)"
i=0; while ! loaded wlan_drv_gen4m_6878 && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done
log "stock stack present: [$(mods)] (+${i}s)"

# 2) find a known-good on-disk stock copy (we do NOT overlay these, so they are
#    genuine stock). If we cannot, we must not touch the running driver.
STOCKDIR=""
for d in /vendor_dlkm/lib/modules /vendor/lib/modules /system/vendor_dlkm/lib/modules /odm/lib/modules; do
  if [ -f "$d/wlan_drv_gen4m_6878.ko" ] && [ -f "$d/cfg80211.ko" ] && [ -f "$d/mac80211.ko" ]; then
    STOCKDIR="$d"; break
  fi
done
log "stock module dir: ${STOCKDIR:-NOT FOUND}"
if [ -z "$STOCKDIR" ]; then
  log "ABORT (safe): no restorable stock modules found -> leaving stock driver untouched."
  exit 0
fi

# Our payload must be complete too.
for m in cfg80211 mac80211 wlan_drv_gen4m_6878; do
  [ -f "$KO/$m.ko" ] || { log "ABORT (safe): payload $m.ko missing -> leaving stock untouched."; exit 0; }
done

restore_stock(){
  log "!! loading OURS failed -> restoring stock from $STOCKDIR"
  avc_dump
  rmmod wlan_drv_gen4m_6878 2>/dev/null
  rmmod mac80211 2>/dev/null
  rmmod cfg80211 2>/dev/null
  insmod "$STOCKDIR/cfg80211.ko" 2>/dev/null
  insmod "$STOCKDIR/mac80211.ko" 2>/dev/null
  insmod "$STOCKDIR/wlan_drv_gen4m_6878.ko" 2>/dev/null
  svc wifi enable 2>/dev/null
  i=0; while ! wifi_ok && [ $i -lt 15 ]; do sleep 1; i=$((i+1)); done
  log "restore done: [$(mods)] wifi_ok=$(wifi_ok && echo 1 || echo 0)"
}

# 3) give our .ko files the same SELinux context as the stock ones, so the
#    kernel's module loader will accept them (best-effort; ignore if unsupported).
STOCKCTX=$(ls -Zd "$STOCKDIR/wlan_drv_gen4m_6878.ko" 2>/dev/null | awk '{print $1}')
case "$STOCKCTX" in
  u:object_r:*) chcon "$STOCKCTX" "$KO"/*.ko 2>/dev/null && log "ctx set to $STOCKCTX" ;;
  *)            log "ctx: could not read stock context (continuing)" ;;
esac

# 4) quiesce Wi-Fi so wlan0/p2p are torn down and the modules are idle
svc wifi disable 2>/dev/null; cmd wifi set-wifi-enabled disabled 2>/dev/null; sleep 3
for IF in wlan0 p2p0 p2p1 ap0; do ip link set "$IF" down 2>/dev/null; done; sleep 1
log "before: [$(mods)]"

# 5) unload stock stack (wlan is a leaf, refcount 0; then mac80211, then cfg80211)
n=0; until ! loaded wlan_drv_gen4m_6878 || [ $n -ge 5 ]; do rmmod wlan_drv_gen4m_6878 2>/dev/null; n=$((n+1)); sleep 1; done
rmmod mac80211 2>/dev/null
rmmod cfg80211 2>/dev/null
log "after unload: [$(mods)]"

if loaded wlan_drv_gen4m_6878; then
  log "ABORT: stock wlan would not unload (busy). Re-enabling stock wifi as-is."
  svc wifi enable 2>/dev/null; exit 0
fi
if loaded cfg80211; then
  log "NOTE: cfg80211 still held (p2p?) -> cannot swap it; restoring stock."
  restore_stock; exit 0
fi

# 6) load OURS (order: cfg80211 -> mac80211 -> wlan). Any failure -> full restore.
insmod "$KO/cfg80211.ko"; r=$?; log "insmod cfg80211 rc=$r"; [ $r -ne 0 ] && { restore_stock; exit 0; }
insmod "$KO/mac80211.ko"; r=$?; log "insmod mac80211 rc=$r"; [ $r -ne 0 ] && { restore_stock; exit 0; }
insmod "$KO/wlan_drv_gen4m_6878.ko"; r=$?; log "insmod wlan rc=$r"; [ $r -ne 0 ] && { restore_stock; exit 0; }
log "after load: [$(mods)]"

# 7) bring Wi-Fi back and confirm the driver is FUNCTIONAL (wlan0 exists).
#    If it never comes up, ours is broken -> restore stock so the user is fine.
svc wifi enable 2>/dev/null
i=0; while ! wifi_ok && [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done
if ! wifi_ok; then
  log "!! ours loaded but wlan0 never came up (+${i}s) -> restoring stock."
  restore_stock; exit 0
fi

# 8) functional: report the monitor capability (diagnostic only; stock has none).
MON=$(iw phy 2>/dev/null | grep -ci '\* monitor')
SNIFF=$(dmesg 2>/dev/null | grep -ci 'enable sniffer mode')
log "OUR DRIVER LOADED + wlan0 up (+${i}s). monitor-capable=$MON (expect >=1)  dmesg-sniffer=$SNIFF"
log "Arm monitor via the module Action button or iw."
log "==== swap complete ===="
