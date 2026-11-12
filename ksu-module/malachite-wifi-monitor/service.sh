#!/system/bin/sh
# Run the driver swap in the background so boot is never blocked.
MODDIR=${0%/*}
nohup sh "$MODDIR/swap.sh" >/dev/null 2>&1 &
