#!/system/bin/sh
#
# malachite Wi-Fi monitor mode + injection - installer (v1.2, active driver swap)
#
# Verifies this is a malachite (MT6878) device and that the module carries a
# complete built payload. Nothing about the radio is touched at install time.
# On each boot, service.sh -> swap.sh actively unloads the stock gen4m stack and
# loads ours (auto-restoring stock if ours fails). Monitor mode is armed only
# when the user runs the Action.

ui_print " "
ui_print "  malachite Wi-Fi monitor + injection (TEST)"
ui_print "  active driver swap - KSU module, no fastboot"
ui_print " "

ABORT() { ui_print "  ! $1"; abort; }

# --- Device guard --------------------------------------------------------------
# getprop is spoofed on this ROM; read build.prop / bootconfig directly.
PLATFORM="$(grep -m1 'ro.board.platform=' /vendor/build.prop 2>/dev/null | cut -d= -f2)"
[ -z "$PLATFORM" ] && PLATFORM="$(grep -m1 -o 'androidboot.board_id=[^ ]*' /proc/bootconfig 2>/dev/null)"
if [ "$PLATFORM" != "mt6878" ]; then
	ABORT "Not an MT6878 device (vendor platform='$PLATFORM'). Aborting."
fi
ui_print "  - MT6878 confirmed"

# --- Payload guard -------------------------------------------------------------
# v1.2 swaps the whole stack, so all three modules must be present AArch64 ELFs.
for m in cfg80211 mac80211 wlan_drv_gen4m_6878; do
	KO="$MODPATH/modules/$m.ko"
	if [ ! -s "$KO" ]; then
		ui_print "  ! No built $m.ko in modules/."
		ui_print "  ! This is the UNBUILT scaffold. Build the modules from the"
		ui_print "  ! kernel source (see ../../patches/BUILD.md), drop"
		ui_print "  ! cfg80211/mac80211/wlan_drv_gen4m_6878 .ko into modules/,"
		ui_print "  ! then repackage."
		ABORT "Refusing to install with an incomplete payload."
	fi
	MAGIC="$(od -An -tx1 -N4 "$KO" 2>/dev/null | tr -d ' \n')"
	EMACH="$(od -An -tx1 -j18 -N2 "$KO" 2>/dev/null | tr -d ' \n')"
	[ "$MAGIC" = "7f454c46" ] || ABORT "modules/$m.ko is not an ELF file."
	[ "$EMACH" = "b700" ] || ABORT "$m.ko is not AArch64 (e_machine=$EMACH, expected b700)."
done
ui_print "  - payload complete: cfg80211 + mac80211 + wlan (AArch64)"

# Record the stock driver path for sanity (swap.sh finds it at runtime too).
STOCK_KO="/vendor_dlkm/lib/modules/wlan_drv_gen4m_6878.ko"
[ -f "$STOCK_KO" ] || STOCK_KO="$(find /vendor_dlkm /vendor /odm -name wlan_drv_gen4m_6878.ko 2>/dev/null | head -1)"
ui_print "  - stock driver: ${STOCK_KO:-not found}"

# --- Permissions ---------------------------------------------------------------
set_perm_recursive "$MODPATH/modules" 0 0 0755 0644
[ -d "$MODPATH/tools" ] && set_perm_recursive "$MODPATH/tools" 0 0 0755 0755
for s in swap.sh service.sh common.sh action.sh uninstall.sh; do
	[ -f "$MODPATH/$s" ] && set_perm "$MODPATH/$s" 0 0 0755
done

ui_print " "
ui_print "  Installed. REBOOT, then read the result:"
ui_print "    su -c 'cat /data/adb/malachite_wifi_monitor/swap.log'"
ui_print "    look for: insmod wlan rc=0   and   wlan0 up   and"
ui_print "              monitor-capable>=1"
ui_print "  Then arm monitor with the module Action button."
ui_print "  Fail-safe: stock is auto-restored if ours doesn't come up."
ui_print " "
