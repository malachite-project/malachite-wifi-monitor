# Codex task — make Wi-Fi packet injection work on malachite (MT6878 gen4m)

(Paste everything below the line into Codex running in this workspace,
`E:\LineageOS-23.2-Malachite`.)

---

## Purpose and authorization

This is authorized security-research and educational work on the maintainer's **own
device** and **own ROM** (the Malachite LineageOS/crDroid project for the Xiaomi
`malachite`, MediaTek MT6878). The objective — native 802.11 monitor mode and frame
injection on the device's **internal** Wi-Fi — is standard wireless-security tooling
(the aircrack-ng / radiotap capability set), built here from first principles for the
maintainer's hardware. All on-device testing is performed by the project's testers
against **networks they own or are explicitly authorized to test**, never against third
parties. Keep that discipline in every instruction and example you produce: authorized
targets only, reversible changes, and no capability framed for unauthorized use.

## Objective

Make **packet injection actually work** on the internal gen4m (CONNAC2) Wi-Fi — i.e. a
tester can run `aireplay-ng -9 wlan0` and see "Injection is working!", and perform a
targeted deauth → WPA2 4-way-handshake capture against an authorized test AP. Monitor-mode
**capture** is already solved (see below); your job is the transmit path. Work the problem
until injection is real and tester-verified, not merely compiling.

## Ground rules

- **Verify everything against the actual source; cite `path:line`.** Do not assume. Where a
  fact can only be settled on-device, say so and specify the exact tester check.
- **No phone here.** The maintainer has no malachite; a third-party tester runs all on-device
  checks. Capture is never proof of injection — only a frame confirmed on the air is.
- **Do not break Wi-Fi.** Every change must be reversible; never blanket-set SELinux
  permissive; keep the device recoverable.
- **Gate builds.** Do not launch a CI or long build until the change is ABI-checked against
  the shipped image (method below). State build time/cost before asking to build.
- Follow the repo's engineering norms: fix root causes, no hand-edited binaries, commits name
  the source commit/build/config, and carry the maintainer's own git identity only (no AI
  attribution).

## Current state (established, 2026-11-12)

- **Monitor (capture) is solved.** A from-source passive build exists at WSL
  `~/android/malachite-monitor-kernel/` (vermagic **6.1.167**). It applies
  `patches/malachite-wlan-passive-monitor.patch` (`CONFIG_SNIFFER_RADIOTAP` + a monitor
  TX-drop guard). The ABI gap against the shipped 6.1.166 image is resolved by shipping a
  **3-module matched swap** — `wlan_drv_gen4m_6878.ko` + `cfg80211.ko` + `mac80211.ko`, all
  6.1.167 from that build (verified internally consistent and image-compatible). This is the
  capture baseline; do not regress it.
- **Injection is blocked by two confirmed issues** (reference source:
  `src/ref_mt6878devs_kernel_modules/connectivity/wlan/core/gen4m`, commit `ce0e095`):
  1. **Will not compile.** The data-queue 802.11-TX path uses `ENUM_PKT_802_11_MGMT`, which is
     **not a member of `enum ENUM_PKT_FLAG`** at this commit (`os/linux/include/gl_os.h`,
     ~447–468). Enabling `CFG_SUPPORT_TX_MGMT_USE_DATAQ` activates code in `nic/nic_tx.c`
     (~3437–3545) that references it → build error. The feature was added in a later gen4m
     release.
  2. **No transmit context in monitor mode.** Switching the interface to monitor calls
     `mtk_uninit_sta_role()` (`os/linux/gl_cfg80211.c`, ~6789), tearing down the AIS STA role.
     So `aisGetDefaultLinkBssIndex()` returns no valid BSS and the firmware 802.11 data path
     drops a frame that has no BSS context before it reaches the air.
- The current injection draft is quarantined at
  `wifi-monitor-injection/patches/blocked/0002-gen4m-packet-injection.patch` with
  `wifi-monitor-injection/patches/blocked/README.md`. Full analysis:
  `wifi-monitor-injection/FINDINGS-2026-11-12.md` and
  `wifi-monitor-injection/notes/2026-11-10-wifi-injection-handoff.md`.

## Required work

### 1. Choose a gen4m base that has the 802.11 data-queue TX path
Survey newer gen4m sources for a revision where `ENUM_PKT_802_11_MGMT` and the
`CFG_SUPPORT_TX_MGMT_USE_DATAQ` data path are fully implemented and compile:
- newer `mt6878-devs/android_vendor_mediatek_kernel_modules` revisions, and
- the NothingOSS gen4m export (noted ~2026-09-20 in the handoff).
Decide whether to (a) move the build to that base or (b) backport the enum + data-queue
mgmt-TX implementation onto `ce0e095`. Justify the choice against the shipped firmware/driver
coupling, and keep it ABI-compatible with the 6.1.167 module set.

### 2. Provide a valid transmit context in monitor mode
Design and implement a TX context so an injected 802.11 frame has a BSS the firmware accepts
while the interface is in monitor mode. Options to evaluate against the source:
- keep the AIS BSS allocated (detached from the netdev) across the monitor switch instead of
  fully uninit-ing the STA role, or
- create a dedicated monitor BSS/band context and bind injected MSDUs to it (the monitor band
  is already tracked for RX — `fgIsEnableMon`, `ucBandIdx`, `CFG_MONITOR_BAND_NUM`).
Then wire `wlanHardStartXmit` so that in monitor mode it strips the radiotap header, builds an
`MSDU_INFO` with `fgIs802_11 = TRUE` on that context, and submits it (reset `skb->cb` **before**
setting the packet flag — `kalResetPacket` zeroes `skb->cb`). Handle the disconnected/idle case
safely (drop + log, never hand the firmware an invalid index).

### 3. Build, ABI-verify, and tester-validate
- Build the module set from source. Do **not** regress the monitor capture path.
- Run the ABI check before proposing a flash: reproduce
  `~/android/malachite-monitor-kernel/verify-monitor-abi.py` (or the equivalent symbol-CRC
  comparison) with the **actual candidate** against the shipped image + module set; the
  comparison oracle for image-provided CRCs is the stock driver, which loads on the shipped
  image. Resolve any new mismatches before building further. (`tools/build_disk.sh up` mounts
  the prebuilts at `/mnt/wsl/malachite-build/crdroid-17.0/...`.)
- Deliver the matched module set via a test ROM's `vendor_dlkm` (the ROM's loader beats a KSU
  bind mount), and have the tester confirm the loaded `srcversion`.
- Tester validation, in order (authorized AP only): (a) boots, normal Wi-Fi works; (b) monitor
  capture still works (regression); (c) `aireplay-ng -9 wlan0` reports injection working;
  (d) targeted deauth → handshake capture succeeds. Watch specifically for the firmware
  **stamping its own source address** (would defeat spoofed deauth) and report it precisely.
- Capture real SELinux AVCs with enforcing on and write targeted `allow` rules
  (`wifi-monitor-injection/ksu-module/malachite-wifi-monitor/sepolicy.rule`); no blanket
  permissive.

### 4. If the firmware refuses driver-side injection
If, on-device, the firmware will not transmit an injected/spoofed frame regardless of a valid
BSS context, document the exact evidence and switch to the firmware track: identify the running
Wi-Fi executable and load path (tester cold-boot + first-Wi-Fi `dmesg`, the `fw_dl` version
string and section layout), per `FINDINGS-2026-11-12.md` §4. Treat byte-matching and firmware
signature verification as separate questions.

## Definition of done
Injection is "done" only when a tester confirms a crafted frame reached the air on an authorized
network (injection self-test plus a real deauth), monitor capture still works, Wi-Fi restores
cleanly, and the change is reversible with recovery available. Report factually at each step;
make no completion claim before that tester evidence exists.

## Output
Keep a running, evidence-backed log: the chosen base and why, the exact driver changes
(`path:line`, diffs), the ABI-check result against the real candidate, the tester steps and
their outcomes, and any firmware findings. Update the files under `wifi-monitor-injection/`
(patches, `FINDINGS`, module) as the single source of truth.
