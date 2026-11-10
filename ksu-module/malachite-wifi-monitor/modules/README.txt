Drop the built wlan_drv_gen4m_6878.ko here (AArch64 ELF; the installer rejects
anything else). See ../../../patches/BUILD.md to build it.

First test build should be the PASSIVE monitor driver (patch 0001 only), and is
best delivered via a vendor_dlkm swap in a test ROM, not this bind-mount module
(the ROM's module loader can beat a post-fs-data bind mount). Use this module
once the overlay is proven to win the race.
