#!/system/bin/sh
#
# malachite Wi-Fi monitor mode + injection — installer
#
# Verifies this is a malachite (MT6878) device, checks that the module carries a
# built driver, and lays out the native tools. Nothing about the radio is
# touched at install time. The replacement driver is mounted at boot by
# post-fs-data.sh; monitor mode is armed only when the user runs the action.

ui_print " "
ui_print "  malachite Wi-Fi monitor mode + injection (TEST)"
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
KO="$MODPATH/modules/wlan_drv_gen4m_6878.ko"
if [ ! -s "$KO" ]; then
	ui_print "  ! No built driver in modules/."
	ui_print "  ! This is the UNBUILT scaffold. Build the module from the"
	ui_print "  ! kernel source (see ../../patches/BUILD.md), drop"
	ui_print "  ! wlan_drv_gen4m_6878.ko into modules/, then repackage."
	ABORT "Refusing to install a module with no driver."
fi
# Must be an AArch64 ELF, not a placeholder or wrong-arch build.
MAGIC="$(od -An -tx1 -N4 "$KO" 2>/dev/null | tr -d ' \n')"
EMACH="$(od -An -tx1 -j18 -N2 "$KO" 2>/dev/null | tr -d ' \n')"
if [ "$MAGIC" != "7f454c46" ]; then
	ABORT "modules/wlan_drv_gen4m_6878.ko is not an ELF file."
fi
if [ "$EMACH" != "b700" ]; then
	ABORT "Driver is not AArch64 (e_machine=$EMACH, expected b700)."
fi
ui_print "  - payload is an AArch64 ELF"

# Record the stock driver's identity for the restore path / sanity.
STOCK_KO="/vendor/lib/modules/wlan_drv_gen4m_6878.ko"
[ -f "$STOCK_KO" ] || STOCK_KO="$(find /vendor -name wlan_drv_gen4m_6878.ko 2>/dev/null | head -1)"
ui_print "  - stock driver: ${STOCK_KO:-not found}"
echo "$STOCK_KO" > "$MODPATH/stock_ko_path"

# --- Tools ---------------------------------------------------------------------
if [ -d "$MODPATH/tools" ]; then
	set_perm_recursive "$MODPATH/tools" 0 0 0755 0755
	ui_print "  - native tools installed under \$MODDIR/tools"
else
	ui_print "  - (no native tools bundled; airodump/aireplay must be added)"
fi

ui_print " "
ui_print "  Installed. Reboot, then use the module Action button to arm"
ui_print "  monitor mode. Wi-Fi stays normal until you arm it."
ui_print " "
