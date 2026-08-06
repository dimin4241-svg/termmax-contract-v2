#!/usr/bin/env python3
"""Narrow read-only dump of TermMax V2 RedeemOrder production events."""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

from eth_abi import decode
from web3 import HTTPProvider, Web3

import scripts.termmax_production_evidence as scanner

VAULT = Web3.to_checksum_address("0xF488ccdf04079cC03183cDB6A147d12Cf97F9317")
START = 23_490_022
TOPIC = "0x21f71f6609f50b01dbe90a67add86958b134ef6fa7e8c668df45730004806242"


def _address(topic):
    return Web3.to_checksum_address("0x" + bytes(topic)[-20:].hex())


def _main() -> int:
    url = os.getenv("ETH_RPC_URL", "https://eth.drpc.org")
    w3 = Web3(HTTPProvider(url, request_kwargs={"timeout": 45, "headers": {"User-Agent": "curl/8.5.0"}}))
    assert w3.eth.chain_id == 1
    end = w3.eth.block_number
    cursor, chunk, logs = START, 10_000, []
    while cursor <= end:
        stop = min(end, cursor + chunk - 1)
        try:
            batch = w3.eth.get_logs({"address": VAULT, "topics": [TOPIC], "fromBlock": cursor, "toBlock": stop})
            logs.extend(batch)
            for log in batch:
                bad_debt, delivery = decode(["uint256", "uint256"], bytes(log["data"]))
                print("REDEEM_EVENT " + json.dumps({
                    "block": int(log["blockNumber"]),
                    "tx_hash": log["transactionHash"].hex(),
                    "caller": _address(log["topics"][1]),
                    "order": _address(log["topics"][2]),
                    "bad_debt_raw": int(bad_debt),
                    "delivery_collateral_raw": int(delivery),
                }, sort_keys=True), flush=True)
            cursor = stop + 1
            chunk = min(20_000, chunk * 2)
        except Exception as exc:
            if chunk > 500:
                chunk = max(500, chunk // 2)
            else:
                time.sleep(2)
            print(f"retry cursor={cursor} chunk={chunk}: {exc}", flush=True)

    events = []
    for log in logs:
        bad_debt, delivery = decode(["uint256", "uint256"], bytes(log["data"]))
        events.append({
            "block": int(log["blockNumber"]),
            "log_index": int(log["logIndex"]),
            "tx_hash": log["transactionHash"].hex(),
            "caller": _address(log["topics"][1]),
            "order": _address(log["topics"][2]),
            "bad_debt_raw": int(bad_debt),
            "delivery_collateral_raw": int(delivery),
        })
    events.sort(key=lambda x: (x["block"], x["log_index"]))
    positive = [x for x in events if x["bad_debt_raw"] > 0]
    out = Path("production-evidence")
    out.mkdir(exist_ok=True)
    (out / "redeem_events.json").write_text(json.dumps({"events": events}, indent=2), encoding="utf-8")
    (out / "production_evidence.md").write_text(
        "# RedeemOrder event dump\n\n"
        + f"Events: {len(events)}\n\nPositive bad debt: {len(positive)}\n",
        encoding="utf-8",
    )
    print("POSITIVE_BAD_DEBT_EVENTS=" + json.dumps(positive, sort_keys=True), flush=True)
    print(f"REDEEM_EVENT_COUNT={len(events)}", flush=True)
    if len(events) != 52:
        raise RuntimeError(f"expected 52 events, got {len(events)}")
    return 0


scanner.main = _main
