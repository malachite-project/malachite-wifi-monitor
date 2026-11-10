# HANDOFF — Native monitor mode + packet injection on malachite's internal Wi-Fi

Date: 2026-11-10. Audience: an AI engineer who should pick this up and work **autonomously
until a working KSU module exists** that gives the Xiaomi malachite's **internal** Wi-Fi chip
native monitor mode **and** packet injection — the same capability the Galaxy S21 (o1s) got from
Nexmon. This document is self-contained: device facts, how o1s did it, why it does not port
as-is, the realistic routes, a milestone plan, the hard blockers, and a test protocol.

**The objective is explicit and non-negotiable in scope:** native monitor + injection on the
**built-in adapter**. An external USB adapter is *out of scope* — the user does not want it.
Capture-only is a milestone, not the finish line. The finish line is injection working on the
internal radio, delivered as a KSU module that testers can install and that can be shipped.

> Legitimacy: this is the user's own device and own ROM project (Malachite, a LineageOS/crDroid
> maintainer build). Monitor + injection is authorized security-testing tooling for their own
> hardware. Keep all live testing against **authorized networks only**, exactly as the o1s work
> did (it used a dedicated test AP the operator owned).

---

## 1. Target device facts (malachite)

| Item | Value |
| --- | --- |
| Phone | Xiaomi, codename **malachite** (POCO/Redmi MT6878 class) |
| SoC | **MediaTek MT6878** (Dimensity), `ro.board.platform=mt6878`, `ro.product.vendor.device=mgvi_64_armv82` |
| Stock base | HyperOS **OS2.0.208.0** (`stock-208` dump) |
| ROM | crDroid 17.0 (main line since 2026-11-10) / also LOS 23.2, EvolutionX 24.0 ports |
| Kernel | **our own ACK 6.1.166 Image** (GKI `android14`) + stock-206 vendor modules. We build the Image and already rebuild some modules (`panel-o16u`, `system_dlkm`). Kernel sources present (`kernel_manifest-6.1` + 3 repos). The stock wlan module's vermagic is `6.1.115-android14-11`; it loads on our 6.1.166 Image via GKI KMI/modversions compatibility. |
| Root (user side) | KernelSU-Next **LKM** + maxsteeel/nomount LKM. **No SUSFS.** Our own builds ship stock kernel, unpatched init_boot. |
| Phone access | **None for us.** All on-device evidence comes from testers. Never assume a value; have a tester capture it. |

### Internal Wi-Fi chip

| Item | Value |
| --- | --- |
| Family | MediaTek **CONNAC2** "**gen4m**" — a **FullMAC** design (802.11 MAC + TX frame-building run inside chip firmware, not in the Linux driver) |
| Build identity | `WLAN_CHIP_ID=6878`, `MTK_COMBO_CHIP=CONNAC2X2_SOC7_0`, `CONNAC_VER=2_0`, HIF=`axi`, `MODULE_NAME=wlan_drv_gen4m_6878` |
| Driver module | `wlan_drv_gen4m_6878.ko` — **Xiaomi prebuilt**, built WITHOUT monitor support |
| Module path | `device/xiaomi/malachite-kernel/vendor_dlkm/wlan_drv_gen4m_6878.ko` (in the build tree); on device `/vendor/lib/modules/` loaded into vendor_dlkm |
| Firmware blobs | `/vendor/firmware/soc7_0_ram_mcu_1_1_hdr.bin`, `..._1a_1_hdr.bin`, `..._1b_1_hdr.bin` (Wi-Fi MCU RAM code), `soc7_0_ram_bt_*_hdr.bin` (BT). Config: `/vendor/firmware/{wifi.cfg,conninfra.cfg,connfem.cfg}`. NVRAM via `libwifinvram*.so`. |
| Module load order (`modules.load.vendor`) | `cfg80211.ko` → `mac80211.ko` → … → `connadp.ko` → `connscp.ko` → `connfem.ko` → `conninfra.ko` → `wmt_chrdev_wifi_connac2.ko` → **`wlan_drv_gen4m_6878.ko`** → `fmradio_drv_connac2x.ko` |
| Dependency chain | `wlan_drv_gen4m_6878` depends on: `wmt_chrdev_wifi_connac2, connadp, cfg80211, mtk_disp_notify, pmic_lbat_service, conninfra, aee_aed, ccci_md_all, mddp, connfem` |

> Note: `mac80211.ko` ships but gen4m registers with **cfg80211 directly** (FullMAC), it does NOT
> ride mac80211's softmac TX. mac80211's presence does **not** open an injection path. Do not be
> misled by it.

### Driver source (for rebuilding the module)

- Reference tree: `E:\LineageOS-23.2-Malachite\src\ref_mt6878devs_kernel_modules`
  (repo `github.com/mt6878-devs/android_vendor_mediatek_kernel_modules`, commit **`ce0e095`**,
  2026-04-14). Driver at `connectivity/wlan/core/gen4m`.
- This is MediaTek's own gen4m source; it is what the prebuilt is built from (same family).
  NothingOSS gen4m (updated 2026-09-20) is a newer alternative base if needed.

---

## 2. How o1s (Galaxy S21) achieved native monitor + injection

Based on a separate Galaxy S21 (o1s) monitor-mode effort built on the public **Nexmon**
project (github.com/seemoo-lab/nexmon) plus a community kernel monitor-mode patch. Summarised
here for comparison; all the facts below are from public upstreams.

**Device:** Galaxy S21 Exynos 2100, Wi-Fi chip **Broadcom bcm4375** (also a FullMAC chip).

**The mechanism — Nexmon:**
1. **Patched Broadcom firmware.** Nexmon is a C-based patching framework for Broadcom FullMAC
   firmware. The patched blob (`/vendor/firmware/bcmdhd_sta.bin_b1`) implements **both monitor
   capture and raw frame injection inside the chip**.
2. **Kernel driver patch** (FlopKernel PR #10, `flop_exynos2100_kernel`). The patched `bcmdhd`
   driver: exposes wlan0 as **radiotap** (ARPHRD type flips 1→803 on arm), reports monitor state,
   translates WEXT/nl80211 channel ops, and **forwards injection frames** to the firmware. Kernel
   notes `WLC_GET_MONITOR` is untrustworthy.
3. **Delivery = KSU module** `bcm_mon_boot`: at boot it **mounts the patched firmware** over
   `/vendor/firmware/bcmdhd_sta.bin_b1` and runs `setenforce 0`. (The kernel patch itself is baked
   into the kernel, not the module.)
4. **Arming sequence** (the kernel author's recommended path):
   - Enable: `svc wifi disable` → `ifconfig wlan0 up` → `nexutil -k<channel>` (e.g. 1 or 36) →
     `nexutil -g0x613 -i -v2`.
   - Disable: `ifconfig wlan0 up` → `nexutil -g0x613 -i -v0`.
   - Band change: disarm, select the other band's channel, rearm. Generic cross-band hopping hangs
     firmware. `-g` and `-s` are equivalent for this firmware command.
   - **Warm-up quirk:** first arm right after `svc wifi disable` often yields 0 frames; two
     arm/disarm cycles then a final arm makes capture reliable (~2000 frames/run). Baked into
     `MonitorManager.monitorCommandFor()`.
5. **Userspace tools:** Android-native (bionic, static) **aircrack-ng** suite (`airodump-ng`,
   `aireplay-ng`) + `wireless_tools`, cross-compiled with NDK r27c against cross-built openssl
   3.0.15 + zlib (libnl omitted; channels driven by `nexutil`). Plus OneShot-Extended (WPS) and
   wifite. aircrack osdep was patched to recognise the Nexmon interface and to gate radio ops
   behind `AIRCRACK_NEXMON=1` (so the tools only bind/read/inject and leave the nexutil-armed radio
   alone — `iw set channel` on wlan0 disrupts the Nexmon monitor). Our own equivalent native build
   already exists in WSL `~/native-wireless/` (aircrack-ng 1.7, aireplay/airodump/iwconfig/… as
   gzipped assets).

**Verified on o1s:** passive capture on ch 6 and ch 36; **injection working** (`aireplay-ng -9`
"Injection is working!", 93% directed-probe); **full targeted deauth → WPA2 4-way handshake
capture** against an authorized test AP. WPA3/SAE+PMF correctly defeats deauth (ACKed but ignored —
universal, expected, not a bug).

**The one-sentence takeaway:** o1s works because a mature, **Broadcom-specific** firmware-patching
framework (Nexmon) already existed for that exact chip, and someone wrote the matching kernel
driver patch. The hard capability — raw TX — lives in the **firmware**, and Nexmon is how you edit
Broadcom firmware.

---

## 3. Why it does not port as-is, and where the real work is

**Nexmon is Broadcom-only.** There is no Nexmon for MediaTek. The entire framework is built around
Broadcom FullMAC firmware internals. malachite's radio runs MediaTek **CONNAC2** firmware
(`soc7_0_ram_mcu_*.bin`), a completely different closed blob. So there is no existing patched
firmware and no existing kernel patch to port — those are exactly what has to be **created**.

**The physics of this FullMAC chip:** the 802.11 MAC state machine, ACKs, sequence numbering,
address stamping, **and TX frame construction** all run on the chip's firmware MCU. The gen4m
Linux driver hands the firmware **Ethernet payloads** + command structs; the firmware builds the
real 802.11 frames. Therefore:
- **Capture (RX monitor) is the easy half** — the firmware already has a monitor command and the
  driver already has the code (behind a build flag). See §4.
- **Injection is the hard half** — there is **no raw-TX capability exposed** by the firmware or the
  driver. This is not a flag. It requires either new firmware capability (RE/patch) or exploiting
  an existing firmware TX path. See §5.

### What the gen4m source actually contains (verified at commit `ce0e095`)

Monitor / RX (present, gated off):
- Build flag: `Kbuild.main` enables `-DCFG_SUPPORT_SNIFFER_RADIOTAP -DCFG_SUPPORT_PDMA_SCATTER`
  when `CONFIG_SNIFFER_RADIOTAP=y`. **`Kbuild.6878` does not set it** → prebuilt has monitor OFF.
- `os/linux/gl_cfg80211.c`: `mtk_init_monitor_role` / `mtk_uninit_monitor_role` (~line 6008),
  change_iface → monitor (~6788), `mtk_cfg80211_set_monitor_channel` (~8513).
- `os/linux/gl_init.c`: `BIT(NL80211_IFTYPE_MONITOR)` added to `interface_modes` (~4253).
- `common/wlan_oid.c`: `wlanoidSetMonitor` (~14942) → sends **`CMD_ID_SET_MONITOR`** to firmware
  (fields: enable, band, pri channel, SCO, channel width, S1/S2, bandIdx, AID, dropFcsErrorFrame).
- RX radiotap: `os/linux/gl_kal.c` (~2017, sets `fgIsEnableMon` skb handling) and
  `os/linux/hif/common/kal_pdma.c` (monitor RX ring handling).
- **Bands:** 2.4 + 5 GHz only in `set_monitor_channel`; **no 6 GHz** monitor channel path.

Injection (ABSENT):
- `wlanHardStartXmit` (`os/linux/gl_init.c:3939` ndo) sends **Ethernet** frames only.
- **No radiotap TX parse, no raw-frame TX, no injection OID.** Confirmed by grep: nothing in the
  driver takes a crafted 802.11 frame to the air.

Management-frame TX path (PRESENT — the injection lead):
- `os/linux/gl_cfg80211.c`: `_mtk_cfg80211_mgmt_tx` (~2785) and
  `_mtk_cfg80211_mgmt_tx_via_data_path` (~2750), dispatched as `mtk_cfg80211_mgmt_tx` (~2938) →
  message `MID_MNY_AIS_MGMT_TX`. This is the firmware path used for P2P/action-frame TX. It is the
  **only existing way to make the firmware transmit a management frame**, and a deauth is a
  management frame. See §5 route A.

---

## 4. Milestone 1 — native monitor capture on the internal chip (the proven-feasible half)

Goal: `wlan0` (or a `mon0`) enters `NL80211_IFTYPE_MONITOR`, radiotap RX works, airodump sees
frames. Deliver as a test build first, then a module.

1. **Rebuild `wlan_drv_gen4m_6878.ko` from source with monitor on.**
   - In the 6878 build config set `CONFIG_SNIFFER_RADIOTAP=y` (it feeds `Kbuild.main`'s
     `-DCFG_SUPPORT_SNIFFER_RADIOTAP`). `Kbuild.6878` is where the per-chip flags live.
   - Build against **our ACK 6.1.166** KMI with **symbol CRCs matching** the stock
     `conninfra/connfem/connadp/wmt_chrdev_wifi_connac2` (the module depends on them). A CRC
     mismatch → module refuses to load. This is the main build-integration risk.
   - The module replaces the prebuilt, so it carries **every other source delta** vs. Xiaomi's
     build too — diff carefully; this is the coupling risk flagged in
     `../../notes/2026-09-21-ecosystem-research.md`.
2. **Confirm the firmware honours `CMD_ID_SET_MONITOR`.** The stock `soc7_0_ram_mcu_*.bin` may or
   may not implement monitor. If the command is NAK'd / ignored, capture won't work even with the
   driver flag on — and then Milestone 1 itself needs a firmware angle (§5). **Unknown until a
   tester tries it.** Check `dmesg` for the `wlanoidSetMonitor` DBGLOG line and whether frames land.
3. **Arming:** mirror the o1s discipline — disable Android Wi-Fi first, bring the iface up, set the
   monitor channel, watch for a warm-up quirk. Expect to discover a MediaTek-specific arm sequence
   (there is no `nexutil` here; channel is set via `set_monitor_channel` / the driver, not WEXT).
4. **Userspace:** reuse WSL `~/native-wireless/` aircrack build. The osdep "nexmon" recognition
   patch is Broadcom-specific; for MediaTek, airodump should accept a standard radiotap monitor
   iface directly (the driver sets `ARPHRD_IEEE80211_RADIOTAP`). Verify `iw dev` shows type monitor.

**Module-delivery caveat (important):** unlike the Broadcom firmware case (firmware is read lazily
when Wi-Fi first turns on, so a boot-time file overlay "just works"), the **`.ko` is loaded at
early boot** by the init from vendor_dlkm. A KSU post-fs-data overlay of the file will NOT take
effect on the already-loaded module. The module must therefore **unload the whole wlan stack and
reload the rebuilt `.ko`**: `rmmod` in reverse dependency order (`fmradio_drv_connac2x`,
`wlan_drv_gen4m_6878`, `wmt_chrdev_wifi_connac2`, …) with Wi-Fi off, overlay the replacement, then
`insmod`/`modprobe` back. Fragile; must be reversible; test with recovery available. (A cleaner
alternative for *our own* shipped build is to just put the rebuilt `.ko` in the ROM's vendor_dlkm —
but the user asked for a module so testers can try before shipping.)

---

## 5. Milestone 2 — injection on the internal chip (the actual objective)

Three routes, ranked by realism. **Route A is where to start.**

### Route A — deauth/partial injection via the existing `mgmt_tx` firmware path
The firmware already transmits management frames (P2P/action). A deauth is a management frame.
- Investigate driving `MID_MNY_AIS_MGMT_TX` / `_mtk_cfg80211_mgmt_tx[_via_data_path]` with a
  crafted deauth (or disassoc) frame, via `NL80211_CMD_FRAME` (cfg80211 `mgmt_tx`) from userspace,
  and/or an added test OID in the driver.
- **Known limits to probe:** (1) the firmware likely **stamps the source/TA** and may reject or
  rewrite a frame spoofing *another* AP's BSSID (aireplay-style); (2) it may allow only **action**
  subtypes and silently drop deauth; (3) off-channel / arbitrary-DA TX may be refused.
- If it works even partially, you get the **single most useful pentest primitive** (targeted deauth
  → handshake forcing) on the internal radio, with **no firmware patch**. This is the highest
  value-per-effort path and the first thing to prove on a tester phone.
- Verdict needed: confirm on-device whether a deauth actually knocks a client off an **authorized**
  test AP (like the o1s Moto G Play test). Never treat RX/capture as proof of TX.

### Route B — firmware reverse-engineering (the "Nexmon for MediaTek") — the only route to FULL arbitrary injection
This is what truly matches o1s's capability (arbitrary raw TX: fakeauth, replay, fragmentation).
- Extract and disassemble `soc7_0_ram_mcu_*.bin` (CONNAC2 connsys MCU — identify core/ISA first).
- Locate the TX descriptor / frame-build path; write a patch that accepts a raw 802.11 frame from
  the driver and transmits it verbatim (bypassing MAC state/address stamping). Add the matching
  driver code (radiotap TX parse → new firmware command) and a radiotap TX ndo.
- **HARD BLOCKER to resolve first:** is the firmware **signature-verified in hardware**? CONNAC/
  connsys can authenticate firmware via the chip bootloader/eFuses. The gen4m driver's FW download
  code (`chips/common/fw_dl.c`) shows section/region handling but **no obvious crypto verification**
  on the host side — that does NOT prove the chip doesn't enforce it. If the hardware verifies the
  blob, a patched firmware **will not load at all** and Route B is dead without a secure-boot
  bypass. **Determine this early** (have a tester load a trivially-modified blob and see if Wi-Fi
  still comes up).
- Effort: this is a **multi-month reverse-engineering project**, no public prior art for CONNAC2
  SoC Wi-Fi. It is far outside the project's normal "source fixes" scope. Treat as research, not a
  sprint task, and keep it off the shipping ROM until proven.

### Route C — factory RF test mode (ATE / HQA / `iwpriv` QA) — NOT real injection
The driver has the HQA/ATE test harness (`HQA_GetRxStatistics…`, `wlanoidRftestSetTestMode`). It can
transmit **calibration tones / canned packets**, but cannot aim a crafted deauth at a specific
client. Useful only to prove the TX hardware can be driven outside normal operation; **not** a
pentest injection path. Document and move on.

---

## 6. KSU module shape (end deliverable)

Model it on o1s's `bcm_mon_boot` but adapted to MediaTek's module-load reality:
- **Payload:** the rebuilt monitor-capable `wlan_drv_gen4m_6878.ko` (+ any patched firmware once
  Route A/B lands), plus the native userspace tools (reuse `~/native-wireless/` assets).
- **Install guard:** verify actual hardware (`ro.board.platform=mt6878`, chip id) — note getprop is
  spoofed on this ROM, so read `build.prop`/bootconfig, per `phone-state-spoofing-gapps`.
- **Activation:** stop Android Wi-Fi, unload+reload the wlan stack with the replacement module
  (see §4 caveat), arm monitor, expose the native tools. Provide a clean **disarm/restore** that
  puts the stock module and managed `wlan0` back. Record/restore Wi-Fi + SELinux state exactly as
  o1s did; never blanket `setenforce 0` — investigate real AVCs/labels instead.
- **Safety:** test with recovery available; never disable the old path before the new one is
  verified; offer rollback; keep SELinux enforcing if achievable.
- Build with the existing `tools/make_ksu_module.py` scaffold. Per project policy
  (`root-setup-ksun-nomount`, `contributor-policy`) a module is fine **because the user explicitly
  asked for one** here.

---

## 7. Hard blockers to settle first (do these before deep work)

1. **Does stock firmware honour `CMD_ID_SET_MONITOR`?** → decides whether Milestone 1 (capture)
   works at all without touching firmware. (Tester test with a source-built module.)
2. **Is `soc7_0_ram_mcu_*.bin` hardware signature-verified?** → decides whether Route B (full
   injection) is even possible. (Tester test with a trivially-altered blob.)
3. **Can the `mgmt_tx` path emit a spoofed-BSSID deauth that actually deauths a client?** → decides
   whether Route A gives usable injection cheaply. (Tester test vs. an authorized AP.)

All three need a tester; we have **no phone**. Gate the effort order on these answers.

---

## 8. Key paths and references

- Driver source: `E:\LineageOS-23.2-Malachite\src\ref_mt6878devs_kernel_modules\connectivity\wlan\core\gen4m` (commit `ce0e095`).
  - Monitor: `os/linux/gl_cfg80211.c` (~6008, ~6788, ~8513), `os/linux/gl_init.c` (~4253),
    `common/wlan_oid.c` (`wlanoidSetMonitor` ~14942), `os/linux/gl_kal.c` (~2017),
    `os/linux/hif/common/kal_pdma.c`.
  - mgmt TX: `os/linux/gl_cfg80211.c` (~2750–2951).
  - FW download: `chips/common/fw_dl.c`.
  - Build flags: `Kbuild.main` (`CONFIG_SNIFFER_RADIOTAP`), `Kbuild.6878` (per-chip).
- Build tree: WSL `/mnt/wsl/malachite-build/crdroid-17.0`, kernel out at
  `device/xiaomi/malachite-kernel/` (`Image.lz4`, `vendor_dlkm/`, `modules.load.vendor`). Attach with
  `tools/build_disk.sh up`.
- Stock dump: WSL `~/stock-208` (firmware blobs in `fs_vendor/firmware/`).
- o1s reference (how the Broadcom path was done): the public **Nexmon** project
  (github.com/seemoo-lab/nexmon) and the Galaxy S21 community monitor-mode kernel patch.
- Native wireless tools (reusable): WSL `~/native-wireless/out/assets/` (aircrack-ng 1.7 suite).
- Background analysis: `2026-11-10-wifi-monitor-mode.md`, `../../notes/2026-09-21-ecosystem-research.md`,
  `../../notes/2026-11-06-kernel-compare.md`.

## 9. Working rules for whoever picks this up

- The goal is **internal-adapter monitor + injection**, no external dongle. Capture is a milestone,
  not the deliverable.
- We have **no phone**; every on-device claim must come from a tester, and capture is never proof of
  injection. Keep live tests on **authorized networks only**.
- Source fixes preferred; a **KSU module is wanted here** (user asked). Keep everything reversible
  and brick-safe; test with recovery available.
- Report facts, not completion claims. Monitor is "done" only when a tester captures frames;
  injection is "done" only when a tester confirms a frame hit the air (e.g. a real deauth).

## 10. Work already staged (2026-11-10)

The driver changes and module are written and staged (not built — no local kernel
pipeline, see §7):
- `../patches/0001-gen4m-enable-monitor-rx.patch` — `Kbuild.6878`:
  `CFG_SUPPORT_SNIFFER_RADIOTAP` + `CFG_SUPPORT_PDMA_SCATTER` (monitor RX only;
  passive first-test build). `git apply`-verified.
- `../patches/0002-gen4m-packet-injection.patch` — adds
  `CFG_SUPPORT_TX_MGMT_USE_DATAQ` + `gl_init.c` `wlanHardStartXmit` injection
  (strip radiotap, reset cb, flag `ENUM_PKT_802_11_MGMT`, submit via the firmware
  802.11 data path). BSS index via `aisGetDefaultLinkBssIndex()`. Apply on top of
  0001. `git apply`-verified in sequence.
- `../patches/sniffer.fragment.config` + `BUILD.md` (build + verify guide).
- `../ksu-module/malachite-wifi-monitor/` — KSU module scaffold: boot-time driver
  bind-mount (`post-fs-data.sh`), arm/disarm/status + injection self-test
  (`common.sh`/`action.sh`), device guard reading build.prop (spoof-safe),
  minimal non-permissive `sepolicy.rule`, payload slots `modules/` + `tools/`.
  Shell scripts syntax-checked. **Payload `.ko` and native tools pending the
  kernel build.**

Mechanism confirmed in source: CONNAC2 TXD supports `HEADER_FORMAT_802_11_*`, and
the driver already sends raw 802.11 frames for `ENUM_PKT_802_11_MGMT` skbs
(`nic_tx.c:3459`, gated by `CFG_SUPPORT_TX_MGMT_USE_DATAQ`) — so injection needs
**no firmware patch for the mechanism**; the open question is whether firmware
emits a spoofed/arbitrary source address (tester test), else fall back to §5 Route B.

## 11. External review fixes (2026-11-10)

An external review caught issues in the first draft; resolved:
- **P0 compile blocker:** patch used `prAdapter->prAisBssInfo` — not a member of
  `struct ADAPTER` at `ce0e095` (the two refs in the tree are disabled legacy
  paths). Fixed to `aisGetDefaultLinkBssIndex(prAdapter)`.
- **P0 logic:** the 802.11 packet flag was set before `kalResetPacket()`, which
  zeroes `skb->cb` where the flag lives — it was being wiped. Reordered: reset
  first, then `GLUE_SET_PKT_FLAG`.
- **Passive/injection split:** 0001 is now monitor-RX only (no TX behaviour
  change); 0002 adds the data-path flag + injection code. First test = 0001 only.
- **Loader race:** a KSU post-fs-data bind mount is not guaranteed to beat the
  ROM's early module loader → first test should swap the `.ko` in `vendor_dlkm`
  and verify the loaded driver's `srcversion`. Module logs the payload srcversion
  so a false pass is visible.
- **Compatibility gate:** validate CRCs for the module's FULL `depends:` list
  (cfg80211, mddp, … not just the four connectivity modules); keep the first
  build to one WLAN replacement.
- **Module safety:** `common.sh`/`action.sh` now resolve `iw` before touching
  Wi-Fi and report real failures; original Wi-Fi state is persisted in a root-
  owned `/data/adb/malachite_wifi_monitor` (0700) dir so Disarm can restore it;
  channel uses explicit `HT20` (bare set defaults to NOHT, rejected); arm rolls
  back on failure; installer requires an AArch64 ELF payload.

Still true: unbuilt, unverified, no phone. Monitor channel success and injection
(esp. firmware source-address stamping) are on-device unknowns.
