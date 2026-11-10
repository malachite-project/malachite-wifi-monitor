#!/system/bin/sh
#
# malachite Wi-Fi monitor mode + injection — action button
#
# KSU runs this when the user taps Action. Rotating menu via a root-owned state
# file. Each step reports its real result (no false "success").

MODDIR=${0%/*}
. "$MODDIR/common.sh"
STATE="$STATEDIR/menu.state"
S="$(cat "$STATE" 2>/dev/null || echo 0)"

case "$S" in
  0) echo "== Arm monitor, 2.4GHz channel 6 =="
     if arm_monitor 6;  then echo "OK: armed on ch6";  echo 1 > "$STATE"
     else echo "FAILED: see $LOG"; fi ;;
  1) echo "== Arm monitor, 5GHz channel 36 =="
     if arm_monitor 36; then echo "OK: armed on ch36"; echo 2 > "$STATE"
     else echo "FAILED: see $LOG"; fi ;;
  2) echo "== Injection self-test (aireplay-ng -9) =="
     T="$MODDIR/tools/aireplay-ng"
     if [ -x "$T" ]; then
	echo "Running injection test on $IFACE (needs an AP in range)..."
	"$T" -9 "$IFACE" 2>&1 | tail -20
     else
	echo "aireplay-ng not bundled; add it under tools/."
     fi
     echo 3 > "$STATE" ;;
  3) echo "== Disarm, restore normal Wi-Fi =="; disarm_monitor; echo "done"; echo 4 > "$STATE" ;;
  *) echo "== Status =="; status; echo 0 > "$STATE" ;;
esac

echo
echo "Tap Action again for the next step. Log: $LOG"
