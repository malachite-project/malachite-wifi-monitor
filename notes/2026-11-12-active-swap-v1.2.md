# 2026-11-12 — active driver swap (module v1.1 → v1.2)

## Why the file-overlay approach (v0.1/v1.0) failed

The first tester build shipped the three source-built modules (wlan + cfg80211 +
mac80211, vermagic 6.1.167) and swapped them via a KSU **file overlay**
(`post-fs-data.sh` bind-mounting our `.ko` over the stock ones).

`iw dev wlan0 set type monitor` returned **-95 (EOPNOTSUPP)**. On-device diag
showed the stock driver was still the one resident in the kernel:

- the stock gen4m stack loads **at boot, before KSU's overlay is mounted**, so the
  overlay can never replace the *running* module;
- `modinfo` read the overlaid on-disk **file** (6.1.167), not the loaded module —
  a red herring that made v1.0 look correct.

GKI tolerates the sublevel gap (stock 6.1.115 modules already run on the shipped
6.1.166 Image), so the module *version* was not the blocker — the **delivery
mechanism** was.

## v1.2: active runtime swap (KSU module only, no fastboot)

`service.sh` backgrounds `swap.sh`, which on each boot:

1. waits for `sys.boot_completed` and the stock `wlan_drv_gen4m_6878` to be loaded;
2. **refuses to proceed unless** a complete restorable stock set
   (wlan + cfg80211 + mac80211) *and* our full payload both exist — otherwise it
   leaves the stock driver untouched (no restore path ⇒ no unload);
3. matches our `.ko` SELinux context to the stock `.ko` (best-effort);
4. quiesces Wi-Fi, unloads stock (wlan is a refcount-0 leaf, then mac80211, then
   cfg80211), and `insmod`s ours in dependency order;
5. re-enables Wi-Fi and **confirms `wlan0` actually comes up** — if it doesn't,
   or if any `insmod` fails, it **auto-restores the stock stack**.

Worst realistic outcome is "plain stock Wi-Fi after a reboot", never "Wi-Fi dead".

A per-boot lock keeps the Action button from poking Wi-Fi mid-swap; the log
rotates (`swap.log.1`) so a boot-loop keeps its evidence; and any SELinux
`module_load` / `sys_module` AVC denial is captured into `swap.log` so the exact
rule (if any) can be added to `sepolicy.rule` — which stays empty by design, no
blanket permissive.

## Open items (tester confirms)

- Does `insmod` of the 6.1.167 modules pass vermagic/CRC on the running 6.1.166
  kernel? (stock-115-on-166 strongly suggests yes.) If not → rebuild gen4m against
  the exact 6.1.166 KMI as a single-module swap.
- Does monitor RX actually deliver frames, and does injection transmit a spoofed
  source address? Both still unverified on hardware.

## Shipping note

A boot-time rmmod/insmod swap is a **tester tool**, not a ship-to-everyone
mechanism. The harmless path for all users is folding the patched driver into the
device tree so the ROM builds it in — no runtime swap at all.
