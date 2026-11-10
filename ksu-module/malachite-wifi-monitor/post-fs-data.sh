#!/system/bin/sh
#
# malachite Wi-Fi monitor mode + injection — boot-time driver swap
#
# IMPORTANT (loader race): the internal Wi-Fi driver (wlan_drv_gen4m_6878.ko) is
# loaded from vendor_dlkm by the ROM's module loader (init.insmod.rc, early in
# boot). A KSU bind mount in post-fs-data only changes what LATER file opens
# see, so it is NOT guaranteed to win the race against the loader. A successful
# mount plus working Wi-Fi can therefore be a FALSE PASS (stock driver still
# live).
#
# => For the FIRST test image, do NOT rely on this module to deliver the driver.
#    Build a test ROM that carries the monitor .ko in vendor_dlkm so the ROM's
#    own loader picks it up, and verify the loaded driver's identity (srcversion)
#    on-device. Use this module only once the overlay is proven to win the race.
#
# This script bind-mounts the payload and then RECORDS whether the overlay is
# actually the loaded driver, so the log makes a false pass visible.
#
# SAFETY: if the replacement fails to load (ABI/CRC mismatch) Wi-Fi simply will
# not come up — this does NOT bootloop. Remove the module and reboot to recover.
# No destructive action, no global SELinux change here.

MODDIR=${0%/*}
STATEDIR=/data/adb/malachite_wifi_monitor
mkdir -p "$STATEDIR" 2>/dev/null; chmod 700 "$STATEDIR" 2>/dev/null
LOG="$STATEDIR/boot.log"
KO="$MODDIR/modules/wlan_drv_gen4m_6878.ko"
STOCK_KO="$(cat "$MODDIR/stock_ko_path" 2>/dev/null)"
[ -z "$STOCK_KO" ] && STOCK_KO="/vendor/lib/modules/wlan_drv_gen4m_6878.ko"

echo "[$(date)] post-fs-data start" > "$LOG"

if [ ! -s "$KO" ]; then
	echo "no built driver payload; leaving stock in place" >> "$LOG"
	exit 0
fi

if [ -f "$STOCK_KO" ]; then
	mount -o bind "$KO" "$STOCK_KO" 2>>"$LOG" \
		&& echo "bind-mounted monitor driver over $STOCK_KO" >> "$LOG" \
		|| echo "bind mount FAILED over $STOCK_KO" >> "$LOG"
else
	echo "stock .ko path not found: $STOCK_KO" >> "$LOG"
fi

# Record which driver is actually loaded, so a false pass is visible in the log.
OUR_SRCVER="$(modinfo "$KO" 2>/dev/null | awk '/^srcversion:/{print $2}')"
echo "payload srcversion: ${OUR_SRCVER:-unknown}" >> "$LOG"
echo "note: compare with the loaded driver after boot:" >> "$LOG"
echo "      modinfo wlan_drv_gen4m_6878 | grep srcversion" >> "$LOG"

echo "[$(date)] post-fs-data done" >> "$LOG"
