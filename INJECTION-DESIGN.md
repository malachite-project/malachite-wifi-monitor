# Injection design — feasible on the current base (ce0e095)

Worked the injection prompt. Main result: **injection does not need a newer gen4m base.**
The earlier blocker (the `ENUM_PKT_802_11_MGMT` data-queue path, absent at `ce0e095`) is
avoidable — the driver already has a management-frame TX path that compiles and transmits raw
802.11 frames. The whole problem reduces to giving that path a valid BSS context while the
interface is in monitor mode.

Status: **design + draft, not built, not tester-verified.** Build is gated; firmware TX
behaviour is the remaining empirical unknown. Authorized testing only.

## Why the mgmt-TX path is the right mechanism

`_mtk_cfg80211_mgmt_tx()` (`os/linux/gl_cfg80211.c` ~2785–2920) sends an arbitrary 802.11
frame today, with **no** dependency on `ENUM_PKT_802_11_MGMT` or `CFG_SUPPORT_TX_MGMT_USE_DATAQ`:

1. `cnmMgtPktAlloc(prAdapter, len + sizeof(uint64_t) + MAC_TX_RESERVED_FIELD)` → a mgmt MSDU.
2. Copy the raw frame to `prPacket + MAC_TX_RESERVED_FIELD`; set `u2FrameLength`, `ucBssIndex`.
3. Build a `MSG_MGMT_TX_REQUEST` with `eMsgId = MID_MNY_AIS_MGMT_TX`, `ucBssIdx = <valid bss>`.
4. `mboxSendMsg(prAdapter, MBOX_ID_0, &prMsgTxReq->rMsgHdr, MSG_SEND_METHOD_BUF)`.

This is the exact path we reuse for injection — so **blocker 1 (won't compile) is gone.**

## The one real blocker: BSS context in monitor mode

Monitor switch calls `mtk_uninit_sta_role()` (`gl_cfg80211.c` ~5984), which runs
`aisFsmUninit(prAdapter, ucBssIndex)` and sets the netdev `ucBssIdx = 0xff`. So after the switch
the AIS FSM/BSS is gone and `MID_MNY_AIS_MGMT_TX` has nowhere to go. Fix: **keep the AIS BSS
alive across the monitor switch** so the mgmt path has a context.

## Draft change A — keep AIS alive on monitor switch

In `mtk_cfg_change_iface()` monitor branch (`gl_cfg80211.c` ~6788):

```c
} else if (type == NL80211_IFTYPE_MONITOR) {
-       if (ndev->ieee80211_ptr->iftype == NL80211_IFTYPE_STATION)
-               mtk_uninit_sta_role(prAdapter, ndev);
-       else if (ndev->ieee80211_ptr->iftype == NL80211_IFTYPE_AP)
+       /* Injection: keep the AIS STA role/BSS allocated so monitor-mode TX has a
+        * valid BSS context (do NOT aisFsmUninit). Only tear down AP/P2P. The netdev
+        * keeps its AIS ucBssIdx; RX monitor still works via fgIsEnableMon. */
+       if (ndev->ieee80211_ptr->iftype == NL80211_IFTYPE_AP)
                mtk_uninit_ap_role(prGlueInfo, ndev);
        mtk_init_monitor_role(wiphy, ndev);
}
```

Open risk (tester): with the AIS FSM still up, it must not fight monitor mode (scan/connect
attempts, power save). If it does, pause AIS activity while keeping the BSS allocated instead of
leaving it fully active — investigate `aisFsmRunEventAbort`/scan-pause rather than a full uninit.

## Draft change B — route injected frames through mgmt TX

In `wlanHardStartXmit()` (`os/linux/gl_init.c`), guarded by `CFG_SUPPORT_SNIFFER_RADIOTAP`, when
`prGlueInfo->fgIsEnableMon`: strip the radiotap header, then build and send a mgmt MSDU exactly as
`_mtk_cfg80211_mgmt_tx()` does (no `ENUM_PKT_802_11_MGMT`):

```c
if (prGlueInfo->fgIsEnableMon) {
        struct ADAPTER *prAdapter = prGlueInfo->prAdapter;
        struct MSG_MGMT_TX_REQUEST *prMsgTxReq;
        struct MSDU_INFO *prMgmtFrame;
        uint16_t u2RtapLen;
        uint8_t *pucFrameBuf, ucBssIndex = prNetDevPrivate->ucBssIdx;
        uint32_t u4Len;

        if (prSkb->len < 4) { dev_kfree_skb(prSkb); return NETDEV_TX_OK; }
        u2RtapLen = le16_to_cpu(*(uint16_t *)(prSkb->data + 2));
        if (u2RtapLen >= prSkb->len) { dev_kfree_skb(prSkb); return NETDEV_TX_OK; }
        skb_pull(prSkb, u2RtapLen);
        u4Len = prSkb->len;

        if (!IS_BSS_INDEX_VALID(ucBssIndex)) {         /* kept-alive AIS bss */
                DBGLOG(TX, WARN, "inject: no BSS context, drop\n");
                dev_kfree_skb(prSkb); return NETDEV_TX_OK;
        }
        prMsgTxReq = cnmMemAlloc(prAdapter, RAM_TYPE_MSG,
                                 sizeof(struct MSG_MGMT_TX_REQUEST));
        if (!prMsgTxReq) { dev_kfree_skb(prSkb); return NETDEV_TX_OK; }
        prMgmtFrame = cnmMgtPktAlloc(prAdapter,
                        (int32_t)(u4Len + MAC_TX_RESERVED_FIELD));
        if (!prMgmtFrame) { cnmMemFree(prAdapter, prMsgTxReq);
                            dev_kfree_skb(prSkb); return NETDEV_TX_OK; }
        prMsgTxReq->rMsgHdr.eMsgId = MID_MNY_AIS_MGMT_TX;
        prMsgTxReq->prMgmtMsduInfo = prMgmtFrame;
        prMsgTxReq->ucBssIdx = ucBssIndex;
        prMsgTxReq->fgIsOffChannel = FALSE;
        prMsgTxReq->fgNoneCckRate = TRUE;
        prMsgTxReq->fgIsWaitRsp = FALSE;
        prMsgTxReq->u8Cookie = 0;
        pucFrameBuf = (uint8_t *)((unsigned long)prMgmtFrame->prPacket
                        + MAC_TX_RESERVED_FIELD);
        kalMemCopy(pucFrameBuf, prSkb->data, u4Len);
        prMgmtFrame->u2FrameLength = u4Len;
        prMgmtFrame->ucBssIndex = ucBssIndex;
        mboxSendMsg(prAdapter, MBOX_ID_0, (struct MSG_HDR *)prMsgTxReq,
                    MSG_SEND_METHOD_BUF);
        dev_kfree_skb(prSkb);           /* firmware TX owns a copy */
        return NETDEV_TX_OK;
}
```

(Fields trimmed vs the cfg80211 version — no channel/duration; verify every field against
`struct MSG_MGMT_TX_REQUEST` when compiling.)

## What is and isn't proven
- **Compiles on `ce0e095`:** the APIs used (`cnmMemAlloc`, `cnmMgtPktAlloc`, `mboxSendMsg`,
  `MSG_MGMT_TX_REQUEST`, `MID_MNY_AIS_MGMT_TX`, `MAC_TX_RESERVED_FIELD`) all exist in the default
  build. **This is a draft — it has not been compiled; verify field names/types in a build.**
- **Not proven (needs a tester phone):** (1) that the AIS-alive-in-monitor change is stable;
  (2) that `MID_MNY_AIS_MGMT_TX` actually transmits while the device is in monitor mode;
  (3) that the firmware emits the crafted/spoofed addresses (deauth) rather than stamping its own.
  (3) is the make-or-break; if it stamps its own address, injection needs firmware work
  (FINDINGS-2026-11-12.md §4).

## Next steps (gated)
1. Apply changes A+B on the monitor build tree (`~/android/malachite-monitor-kernel`, which uses
   `ce0e095`), compile the gen4m module (kleaf). **Build is gated — needs the go-ahead.**
2. ABI: no change (same module set as the passive 3-module swap).
3. Tester: on an authorized AP — boot, Wi-Fi OK, capture OK, `aireplay-ng -9` injection test,
   deauth→handshake. Report whether frames carry the spoofed source address.
