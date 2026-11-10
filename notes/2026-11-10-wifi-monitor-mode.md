# Wi-Fi monitor mode (2026-11-10)

Question: can monitor mode fully work on malachite?

## What ships today

- `device/xiaomi/malachite-kernel/vendor_dlkm/wlan_drv_gen4m_6878.ko` is Xiaomi's prebuilt
  (vermagic `6.1.115-android14-11`, depends on `wmt_chrdev_wifi_connac2, connadp, conninfra,
  connfem, cfg80211, ...`).
- It was built **without** `CFG_SUPPORT_SNIFFER_RADIOTAP`. It has no `mtk_init_monitor_role`,
  no "enable sniffer mode" string, and it does not advertise `NL80211_IFTYPE_MONITOR`.
  `iw ... type monitor` cannot work on it, and no prop, overlay or userspace change can fix that.
- What it does have is MediaTek's ICS sniffer (`wlanoidSetIcsSniffer`, `fw_log_ics` char dev),
  which captures in firmware and writes to a log. It is not a monitor interface.

## What the source can do

Reference: `src/ref_mt6878devs_kernel_modules` (mt6878-devs, head `ce0e095`, 2026-04-14),
`connectivity/wlan/core/gen4m`.

- `Kbuild.main` turns on `-DCFG_SUPPORT_SNIFFER_RADIOTAP -DCFG_SUPPORT_PDMA_SCATTER` when
  `CONFIG_SNIFFER_RADIOTAP=y`. `Kbuild.6878` does not set it.
- With it on, you get: `NL80211_IFTYPE_MONITOR` in `interface_modes`, `change_iface` to monitor
  (`mtk_init_monitor_role`), `set_monitor_channel` (2.4 and 5 GHz only, 20 to 160 MHz, through
  `wlanoidSetMonitor`, so the firmware has to support it), and radiotap RX in `gl_kal.c` and
  `kal_pdma.c`.
- **RX only.** The driver has no injection code at all: no radiotap TX parsing, and
  `wlanHardStartXmit` sends Ethernet frames. There is no 6 GHz monitor channel either.

## What "fully working" would take

1. Build `wlan_drv_gen4m_6878.ko` from source with `CONFIG_SNIFFER_RADIOTAP=y`, against our ACK
   6.1.166 KMI, with symbol CRCs that match the stock `conninfra`, `connfem`, `connadp` and
   `wmt_chrdev_wifi_connac2`. It would replace the prebuilt, so it carries every other source
   difference too. That is the risk flagged in `notes/2026-09-21-ecosystem-research.md`
   (firmware and calibration coupling).
2. Firmware support for the monitor command is unproven on the 6878 RAM code.
3. Injection would be new driver code, plus firmware raw-TX support nobody has shown on CONNAC2 SoC.
4. Only testers can prove any of it. Wi-Fi breaking would hit every user of the build.

## Why the o1s (Galaxy S21) monitor-mode work does NOT transfer

Ref: a separate Galaxy S21 (o1s) monitor-mode effort using the public Nexmon project.

That phone is an Exynos 2100 S21 with a **Broadcom FullMAC** Wi-Fi chip (bcm4375). Its full
monitor + injection comes from **Nexmon**:
- A **patched Broadcom firmware** blob that implements capture and raw injection in the chip.
- A **kernel driver (bcmdhd) patch** (FlopKernel PR #10) that exposes wlan0 as radiotap,
  translates channel ops, and forwards injection frames. Armed with `nexutil`.
- The KSU module there (`bcm_mon_boot`) only **mounts the patched firmware** over
  `/vendor/firmware/bcmdhd_sta.bin_b1` at boot; the kernel patch is baked into the kernel.

None of this applies to malachite:
- **Nexmon is Broadcom-only.** There is no Nexmon for MediaTek. The whole framework is built
  around Broadcom's FullMAC firmware internals; MT6878 uses MediaTek's CONNAC2 firmware, a
  completely different closed blob with no public RE framework or injection patch.
- malachite's injection would require reverse-engineering MediaTek's closed RAM firmware from
  scratch — nobody has published this for CONNAC2 SoC Wi-Fi. (The open `mt76` driver injects,
  but it is for standalone mt79xx USB/PCIe cards, not the gen4m SoC Wi-Fi in phones.)
- Capture is the one thing MediaTek's own driver already supports in source (`CMD_ID_SET_MONITOR`
  to firmware), which is why RX is plausible and TX is not.

## KSU module as a test vehicle

- A KSU module **can** deliver a capture-capable driver for testing, like `bcm_mon_boot` did —
  but the file to swap is `wlan_drv_gen4m_6878.ko` in `vendor_dlkm`, which is loaded at early
  boot. A boot-time overlay alone won't take effect on an already-loaded module, so the module
  would have to unload the wlan stack (+ its dependents: `wmt_chrdev_wifi_connac2`, `connadp`,
  `connfem`, `conninfra`) and reload the rebuilt `.ko`. Fragile but testable.
- Simpler for a controlled test: build a one-off variant with `CONFIG_SNIFFER_RADIOTAP=y` and
  swap the `.ko` in a test image, prove capture on a tester's phone, then decide on shipping.
- **A KSU module cannot add injection.** It only swaps files; injection needs firmware TX that
  does not exist for this chip. No module, driver flag, or nexutil-style tool changes that.
