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
| Monitor RX (patch 0001) | Written; enables MediaTek's own support. Works if firmware honours `CMD_ID_SET_MONITOR` — unverified. The first test build. |
| Injection TX (patch 0002) | Written, first implementation via the chip's raw-802.11 data path (no firmware patch needed for the mechanism). Not built/verified. Monitor-mode BSS binding needs on-device bring-up; firmware address-stamping is the open hardware question. |
| KSU module | Scaffold complete and hardened; payload `.ko` + native tools pending the build. For the first test prefer a vendor_dlkm swap (see below). |
| The `.ko` build | **Not done** — needs a `kernel_manifest-6.1` build + ABI/CRC match. |

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
├── notes/
│   ├── 2026-11-10-wifi-injection-handoff.md   ← full guide: device facts, how o1s
│   │                                             did it, routes, blockers, §10 staged work
│   └── 2026-11-10-wifi-monitor-mode.md         ← the original analysis
├── patches/
│   ├── 0001-gen4m-enable-monitor-rx.patch      ← passive monitor RX (first test)
│   ├── 0002-gen4m-packet-injection.patch       ← injection, apply on top of 0001
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
