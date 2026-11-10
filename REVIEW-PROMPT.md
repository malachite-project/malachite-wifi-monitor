# Prompt for a fresh ChatGPT session — pre-build audit

(Copy everything below the line into a new ChatGPT session that has access to this
machine's filesystem.)

---

You are a senior Linux kernel / Android Wi-Fi driver engineer reviewing a change
before it is built. The goal is **native monitor mode (radiotap RX) AND packet
injection (raw 802.11 TX) on the phone's INTERNAL Wi-Fi chip** — no external USB
adapter. Your job is to catch **every** problem now, because a build is expensive
(a full kernel-from-source CI build) and there is **no phone here** — all on-device
testing is done later by a third-party tester, so a wrong assumption costs days.

Do not take my word for anything. **Verify every claim against the actual source
files** and cite `path:line` evidence for each finding. Where something cannot be
settled without the device, say so explicitly and say exactly what the tester must
check. Make no edits unless I ask — report findings, each with a concrete fix
(exact code/diff or command), ranked P0/P1/P2.

## Device / environment (verify, don't assume)
- Phone: Xiaomi **malachite**, SoC **MediaTek MT6878** (`ro.board.platform=mt6878`),
  HyperOS OS2.0.208 base; ROM is LineageOS 23.2 / crDroid 17.0.
- Internal Wi-Fi: MediaTek **CONNAC2 "gen4m"**, FullMAC, module
  `wlan_drv_gen4m_6878.ko` (`WLAN_CHIP_ID=6878`, `MTK_COMBO_CHIP=CONNAC2X2_SOC7_0`,
  `CONNAC_VER=2_0`, HIF axi). The 802.11 MAC + TX frame-building run in closed
  firmware (`/vendor/firmware/soc7_0_ram_mcu_*.bin`).
- Kernel: our own **ACK 6.1.166** `Image.lz4` + stock-206 vendor modules. The kernel
  and modules are **built from `kernel_manifest-6.1` in GitHub Actions CI**, not
  locally. `device/xiaomi/malachite-kernel` is a prebuilt repo (see its
  `SOURCE_MIGRATION.md`, `AGENTS.md`).
- Root: KernelSU-Next LKM; no SUSFS. getprop is spoofed on this ROM — read
  `build.prop`/bootconfig, not getprop.
- No phone for us. Testers only. Capture is never proof of injection.

## Files to read first
- `<repo>/README.md` — index + status.
- `<repo>/notes/2026-11-10-wifi-injection-handoff.md`
  — full rationale, routes, blockers, §10 staged work, §11 prior review fixes.
- `<repo>/patches/0001-gen4m-enable-monitor-rx.patch`
- `<repo>/patches/0002-gen4m-packet-injection.patch`
- `<repo>/patches/BUILD.md`
- `<repo>/ksu-module/malachite-wifi-monitor/*`
- Driver source the patches target:
  `<gen4m-source>/ (the mt6878-devs android_vendor_mediatek_kernel_modules gen4m tree)`
  (git branch `lineage-23.2`, commit `ce0e095`). The real build may use a different
  `kernel_modules` revision — see "version skew" below.

## What is already done (and the open risks you must confirm)
- `0001` turns on `CFG_SUPPORT_SNIFFER_RADIOTAP` + `CFG_SUPPORT_PDMA_SCATTER` in
  `Kbuild.6878` (monitor RX only; the passive first-test build).
- `0002` adds `CFG_SUPPORT_TX_MGMT_USE_DATAQ=1` and, in `gl_init.c`
  `wlanHardStartXmit`, strips the radiotap header and submits the raw 802.11 frame
  via the firmware's 802.11 data path (flag `ENUM_PKT_802_11_MGMT`, bss index via
  `aisGetDefaultLinkBssIndex()`), resetting the skb cb before setting the flag.

## Audit checklist — confirm each against source, cite path:line

### A. Compile correctness at commit `ce0e095`
1. Every symbol/macro the injection block uses actually exists and is in scope in
   `gl_init.c` at `ce0e095`: `GLUE_SET_PKT_FLAG`, `ENUM_PKT_802_11_MGMT`,
   `IS_BSS_INDEX_VALID`, `aisGetDefaultLinkBssIndex`, `GLUE_INFO.fgIsEnableMon`,
   `prGlueInfo->prAdapter`, `kalResetPacket`, `kalHardStartXmit`, `DBGLOG`,
   `dev_kfree_skb`, `skb_pull`, `le16_to_cpu`, `uint16_t`. Flag any that need an
   include not already pulled in by `precomp.h`.
2. Confirm `aisGetDefaultLinkBssIndex()` is compiled in for this config (not behind
   a disabled `#if`), its return type, and what it returns when no AIS BSS exists —
   does `IS_BSS_INDEX_VALID()` correctly reject that sentinel?
3. Confirm `CFG_SUPPORT_TX_MGMT_USE_DATAQ=1` actually makes `nic_tx.c` set
   `MSDU_INFO.fgIs802_11` for `ENUM_PKT_802_11_MGMT` skbs on this chip, and trace
   that to `HEADER_FORMAT_802_11_*` in `nic_txd_v2.c` for soc7_0. Is there any other
   `#if` gating that path off for CONNAC2/axi?
4. Does setting `-DCFG_SUPPORT_TX_MGMT_USE_DATAQ=1` via ccflags collide with a
   definition elsewhere (config.h uses `#ifndef`), and does enabling it change NORMAL
   management-frame TX in a way that could break association/scan/roam? Quantify.

### B. The injection path actually working
5. In pure monitor mode, does the data path need a valid `STA_RECORD` / `BSS_INFO`
   that a monitor interface lacks? Trace `kalHardStartXmit` → MSDU build → TX for an
   `ENUM_PKT_802_11_MGMT` skb with the AIS-default bss index while NOT associated.
   What happens if AIS is idle/disconnected?
6. Radiotap TX assumptions: is the injected frame expected to carry/omit the FCS?
   Does the driver/firmware expect no radiotap on the data path (we strip it) and a
   bare 802.11 header? Any headroom/tailroom or alignment the data path requires that
   a raw injected skb won't have?
7. Will the firmware transmit a frame with an arbitrary/spoofed source address, or
   does it stamp its own (which breaks aireplay-style deauth)? If unknowable without
   the device, state the exact tester check.

### C. Monitor RX actually working
8. Trace the full RX monitor path for soc7_0: `change_iface`→monitor,
   `mtk_cfg80211_set_monitor_channel`→`wlanoidSetMonitor`→`CMD_ID_SET_MONITOR`, and
   the radiotap RX in `gl_kal.c`/`kal_pdma.c`/`nic_rxd_v2`. Any soc7_0-specific gap?
9. Is `CFG_SUPPORT_PDMA_SCATTER` required/assumed by the RX monitor path, and does it
   have side effects on normal RX?

### D. Build + ABI
10. **Version skew:** find which `kernel_modules` revision the malachite CI build
    actually uses (from `kernel_manifest-6.1`) and check the patches apply and compile
    against THAT, not just `ce0e095`.
11. Full `depends:`/CRC gate: list every symbol `wlan_drv_gen4m_6878.ko` imports and
    confirm the rebuilt module's modversions CRCs match the exact stock module set in
    the test image (cfg80211, mddp, conninfra, connfem, connadp,
    wmt_chrdev_wifi_connac2, …). Exactly how to get `Module.symvers` for the target.
12. Precise Kleaf/Bazel target + config-fragment wiring to enable
    `CONFIG_SNIFFER_RADIOTAP` in the real build, and the toolchain/KMI it must match.

### E. Module + runtime
13. Loader race: confirm when `init.insmod.rc` loads the WLAN driver vs KSU
    post-fs-data; confirm the first-test vendor_dlkm-swap recommendation is right and
    how to verify the loaded driver identity (`srcversion`).
14. SELinux: predict the AVCs when a tester arms monitor and runs the native tools
    enforcing, and the exact targeted `allow` rules (no blanket permissive).
15. `iw` availability on this ROM, and whether `iw … set type monitor` / `set
    channel N HT20` is the right arm sequence for gen4m (vs a driver ioctl), given no
    nexutil.
16. Native tool cross-compile (aarch64/bionic) provenance and that `airodump-ng`/
    `aireplay-ng` accept this driver's radiotap monitor interface directly.

### F. Firmware signing (decides the fallback)
17. From `chips/common/fw_dl.c` and the blob headers, assess whether
    `soc7_0_ram_mcu_*.bin` is hardware-signature-verified (which would block the
    Route-B firmware-RE fallback if data-path injection is refused). State the tester
    check to confirm.

## Output
1. Findings ranked P0 (blocks build/boot), P1 (likely-wrong/unsafe), P2 (polish),
   each with `path:line` evidence and an exact fix (diff or command).
2. A **go/no-go pre-build checklist** — what must be true before spending a build.
3. The **minimal first build** plan (passive `0001` only, vendor_dlkm swap) and the
   exact tester steps to prove monitor RX before anyone touches injection.
4. Anything unverifiable here, with the precise on-device test that would settle it.

Verification should be host-only; make no edits unless I ask.
