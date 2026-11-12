# malachite Wi-Fi monitor mode + packet injection

Everything for giving malachite's **internal** Wi-Fi (MediaTek MT6878 / CONNAC2
"gen4m") native **monitor mode** (radiotap RX) and **packet injection** (raw
802.11 TX) — the capability the Galaxy S21 (o1s) got from Nexmon, done here on the
built-in radio, with **no external USB adapter**. For authorized security testing
on the user's own hardware.

## Status (2026-11-10)

Code-complete and staged; **not built, not verified**. The driver `.ko` must come
from a kernel-source build (no local pipeline), and a tester must verify it (we
have no phone).

| Piece | State |
| --- | --- |
| Monitor RX (patch 0001) | **Built from source** (6.1.167, monitor confirmed). Uses `CONFIG_SNIFFER_RADIOTAP` + a TX-drop guard (capture only, TX dropped in monitor mode). Not yet ABI-matched or phone-verified. |
| ABI gap | Candidate (6.1.167) mismatches the shipped **6.1.166** Image on 3 cfg80211 symbols. Resolution and the hold-the-CI reason: `FINDINGS-2026-11-12.md`. |
| Injection TX (patch 0002) | **BLOCKED — do not build.** `ENUM_PKT_802_11_MGMT` isn't in the enum at this commit (won't compile), and monitor mode tears down the AIS BSS (no context to TX on). Moved to `patches/blocked/`. |
| KSU module | Scaffold complete and hardened; for the first test prefer a **vendor_dlkm swap** (loader race). |

> **Read `FINDINGS-2026-11-12.md` first** — it supersedes the status below with what was
> learned from the actual build and audit (passive `.ko` exists, the 3-symbol ABI gap and
> its fix, why injection is blocked, and the firmware-identification plan).

> Reviewed 2026-11-10 (external): fixed a compile blocker (`prAisBssInfo` →
> `aisGetDefaultLinkBssIndex()`) and a flag-wipe ordering bug (`kalResetPacket`
> zeroes `skb->cb`, so the 802.11 flag is now set after it); split monitor (0001)
> from injection (0002) so the first build is passive-only; hardened the module
> (iw resolution, persistent Wi-Fi state, HT20, failure rollback, root-owned
> `/data/adb` paths, AArch64-ELF install guard). "Code-complete" earlier overstated
> it — the code is written and apply-verified, not compiled or phone-tested.

## Layout

```
wifi-monitor-injection/
├── README.md                 ← this index
├── FINDINGS-2026-11-12.md     ← current status: build done, ABI gap, injection blocked
├── notes/
│   ├── 2026-11-10-wifi-injection-handoff.md   ← full guide: device facts, how o1s
│   │                                             did it, routes, blockers, §10 staged work
│   └── 2026-11-10-wifi-monitor-mode.md         ← the original analysis
├── patches/
│   ├── 0001-gen4m-passive-monitor.patch        ← passive monitor RX (BUILT; TX-drop guard)
│   ├── blocked/0002-gen4m-packet-injection.patch ← injection (BLOCKED, do not build)
│   ├── sniffer.fragment.config
│   └── BUILD.md              ← how to apply, build the .ko, and verify on-device
└── ksu-module/
    └── malachite-wifi-monitor/   ← the test module (payload slots empty)
```

## Where to start

1. Read `notes/2026-11-10-wifi-injection-handoff.md` — the complete engineering guide.
2. Follow `patches/BUILD.md` to apply the patches, build the `.ko`, and verify.
3. Drop the built `.ko` + native tools into `ksu-module/malachite-wifi-monitor/`
   (`modules/` and `tools/`) and package.

## The one mechanism fact to keep in mind

CONNAC2's TX descriptor supports `HEADER_FORMAT_802_11_*`, and the gen4m driver
already transmits raw 802.11 frames for `ENUM_PKT_802_11_MGMT` skbs
(`nic_tx.c:3459`, gated by `CFG_SUPPORT_TX_MGMT_USE_DATAQ`). Injection reuses that
proven path, so **no firmware patch is required for the mechanism** — the open
question is whether the firmware emits a spoofed/arbitrary source address. If it
refuses, the fallback is firmware reverse-engineering (handoff §5, Route B), which
may be hard-blocked by firmware signing.

> The patches target the gen4m source
> (`src/ref_mt6878devs_kernel_modules`, branch `lineage-23.2`); both are
> `git apply --ignore-whitespace`-verified. The source tree itself is not part of
> this folder.
