# Blocked: packet injection (patch 0002)

`0002-gen4m-packet-injection.patch` is **kept for reference but must not be built**.
Two confirmed blockers at the gen4m source commit the build uses (`ce0e095`):

1. **Compile error.** The patch enables `CFG_SUPPORT_TX_MGMT_USE_DATAQ`, which
   activates code in `nic_tx.c` that references `ENUM_PKT_802_11_MGMT`. That value is
   **not a member of `enum ENUM_PKT_FLAG`** at this commit
   (`os/linux/include/gl_os.h`, lines ~447–468) — it was added in a later gen4m
   release alongside the data-queue mgmt-TX feature. Turning the flag on without that
   enum member does not compile.

2. **No BSS to transmit on in monitor mode.** `mtk_cfg_change_iface()` → monitor calls
   `mtk_uninit_sta_role()` (`os/linux/gl_cfg80211.c` ~line 6789), tearing down the AIS
   STA role. So in pure monitor mode `aisGetDefaultLinkBssIndex()` returns no valid
   BSS, and the firmware 802.11 data path drops a frame with no BSS context before it
   ever reaches the air. The injection path as written cannot work.

## What injection would actually require
- A gen4m base that already has the data-queue mgmt-TX feature (the `ENUM_PKT_802_11_MGMT`
  path) **and**
- a way to keep a valid BSS/STA context alive for transmit while in monitor mode (or a
  dedicated raw-TX firmware command), **and**
- confirmation the firmware will emit a spoofed/arbitrary source address (else firmware RE).

Until then, ship monitor **capture only** (`../0001-gen4m-passive-monitor.patch`), which
drops TX in monitor mode. See `../../FINDINGS-2026-11-12.md`.

---
**Update:** injection is feasible on this same base via the management-TX path
(`cnmMgtPktAlloc` + `MID_MNY_AIS_MGMT_TX`), which needs no newer source and no
`ENUM_PKT_802_11_MGMT`. See `../../INJECTION-DESIGN.md`. This 0002 (data-queue) approach
stays blocked, but it is no longer the only route.
