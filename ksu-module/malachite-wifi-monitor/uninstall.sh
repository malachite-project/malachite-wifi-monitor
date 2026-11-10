#!/system/bin/sh
#
# malachite Wi-Fi monitor mode + injection — uninstall
#
# The driver swap is a bind mount set up at boot, so removing the module and
# rebooting restores the stock driver by itself. We only clean up our root-owned
# scratch dir here. Nothing in /vendor was modified.

rm -rf /data/adb/malachite_wifi_monitor 2>/dev/null
