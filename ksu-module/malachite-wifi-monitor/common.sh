#!/system/bin/sh
#
# malachite Wi-Fi monitor mode + injection — shared helpers
#
# MediaTek gen4m has no nexutil. Monitor is driven through the driver's own
# cfg80211 paths: change the interface type to monitor (handled by
# mtk_init_monitor_role when CFG_SUPPORT_SNIFFER_RADIOTAP is built in) and set
# the monitor channel (mtk_cfg80211_set_monitor_channel). Injection then uses
# radiotap TX on the monitor interface (aireplay-ng), which the driver routes
# through the firmware 802.11 data path (see the gen4m injection patch).

IFACE=wlan0

# Root-owned, 0700 state dir (NOT /data/local/tmp, which the shell user can
# write — that would expose our privileged writes to tampering / symlink games).
STATEDIR=/data/adb/malachite_wifi_monitor
LOG="$STATEDIR/run.log"
WIFI_STATE_FILE="$STATEDIR/wifi_was"

mkdir -p "$STATEDIR" 2>/dev/null
chmod 700 "$STATEDIR" 2>/dev/null

log() { echo "[$(date)] $*" | tee -a "$LOG"; }

# Resolve a usable `iw`: prefer the bundled one, else system. Returns non-zero
# and sets IW empty if none is found — callers MUST check before touching Wi-Fi.
MODDIR_DEFAULT=/data/adb/modules/malachite_wifi_monitor
resolve_iw() {
	for c in "${MODDIR:-$MODDIR_DEFAULT}/tools/iw" /system/bin/iw /vendor/bin/iw; do
		if [ -x "$c" ]; then IW="$c"; return 0; fi
	done
	command -v iw >/dev/null 2>&1 && { IW="$(command -v iw)"; return 0; }
	IW=""; return 1
}

# Save the original Android Wi-Fi state ONCE (persisted across action taps), so a
# later Disarm in a different shell can still restore it.
save_wifi_state_once() {
	[ -f "$WIFI_STATE_FILE" ] && return 0
	settings get global wifi_on 2>/dev/null > "$WIFI_STATE_FILE"
}
restore_wifi_state() {
	WAS="$(cat "$WIFI_STATE_FILE" 2>/dev/null)"
	[ "$WAS" = "1" ] && svc wifi enable
	rm -f "$WIFI_STATE_FILE"
}

arm_monitor() {  # $1 = channel (e.g. 6 or 36)
	CH="${1:-6}"
	if ! resolve_iw; then
		log "ERROR: no 'iw' binary found (bundle it under tools/). NOT touching Wi-Fi."
		return 1
	fi
	log "arming monitor on $IFACE channel $CH (iw=$IW)"
	save_wifi_state_once
	svc wifi disable
	sleep 1
	# Warm-up: the firmware often yields 0 frames on the first arm right
	# after wifi disable. Cycle twice, then arm for real (mirrors the o1s
	# finding; confirm the exact cycle count on-device). Use explicit HT20 —
	# bare 'set channel' defaults to NOHT, which the driver's width switch
	# rejects.
	for i in 1 2; do
		ip link set "$IFACE" down 2>>"$LOG"
		"$IW" dev "$IFACE" set type monitor 2>>"$LOG"
		ip link set "$IFACE" up 2>>"$LOG"
		"$IW" dev "$IFACE" set channel "$CH" HT20 2>>"$LOG"
		sleep 1
		ip link set "$IFACE" down 2>>"$LOG"
		"$IW" dev "$IFACE" set type managed 2>>"$LOG"
	done
	ip link set "$IFACE" down 2>>"$LOG"
	if ! "$IW" dev "$IFACE" set type monitor 2>>"$LOG"; then
		log "ERROR: could not set monitor type; rolling back"
		disarm_monitor
		return 1
	fi
	ip link set "$IFACE" up 2>>"$LOG"
	if ! "$IW" dev "$IFACE" set channel "$CH" HT20 2>>"$LOG"; then
		log "ERROR: could not set channel $CH; rolling back"
		disarm_monitor
		return 1
	fi
	# The driver discards kalIoctl()'s result and returns success, so the
	# interface type alone does NOT prove the channel took. Confirm real
	# frame reception (airodump) before trusting it.
	log "monitor armed: $("$IW" dev "$IFACE" info 2>/dev/null | grep -i -E 'type|channel' | tr '\n' ' ')"
	log "note: verify capture with airodump before trusting the channel."
	return 0
}

disarm_monitor() {
	resolve_iw || log "warn: no iw for disarm; attempting restore anyway"
	log "disarming monitor on $IFACE"
	ip link set "$IFACE" down 2>>"$LOG"
	[ -n "$IW" ] && "$IW" dev "$IFACE" set type managed 2>>"$LOG"
	ip link set "$IFACE" up 2>>"$LOG"
	restore_wifi_state
	log "restored managed mode"
}

status() {
	resolve_iw
	echo "iface:   $IFACE"
	echo "iw:      ${IW:-NOT FOUND}"
	[ -n "$IW" ] && echo "type:    $("$IW" dev "$IFACE" info 2>/dev/null | grep -i -E 'type|channel' | tr '\n' ' ')"
	echo "driver:  $(modinfo wlan_drv_gen4m_6878 2>/dev/null | grep -E 'vermagic|srcversion' | tr '\n' ' ')"
	echo "sniffer: $(dmesg 2>/dev/null | grep -i 'enable sniffer' | tail -1)"
}
