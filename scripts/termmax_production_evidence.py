#!/usr/bin/env python3
"""Read-only TermMax V2 production evidence collector.

The script uses public Ethereum JSON-RPC endpoints and performs only eth_call,
eth_getLogs, and transaction/receipt reads. It does not send transactions.
"""

from __future__ import annotations

import itertools
import json
import os
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

from eth_abi import decode
from eth_utils import keccak, to_checksum_address
from web3 import HTTPProvider, Web3

VAULT = to_checksum_address("0xF488ccdf04079cC03183cDB6A147d12Cf97F9317")
DEPLOYMENT_BLOCK = 23_490_022
KNOWN_REDEEM_TX = "0xfd90c3e14fa8c97160a3673bb90657e233b66061c70b5b2e6bccfcd1fa66aab4"
LIQUIDATION_WINDOW = 2 * 60 * 60
USD_BASE = 10**8

RPC_URLS = [
    os.getenv("ETH_RPC_URL", "").strip(),
    "https://ethereum-rpc.publicnode.com",
    "https://eth.llamarpc.com",
    "https://1rpc.io/eth",
    "https://rpc.ankr.com/eth",
]
RPC_URLS = [url for url in RPC_URLS if url]

VAULT_ABI = [
    {"type": "function", "name": "orderMaturity", "stateMutability": "view", "inputs": [{"name": "order", "type": "address"}], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "totalAssets", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "totalSupply", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "maxDeposit", "stateMutability": "view", "inputs": [{"name": "receiver", "type": "address"}], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "asset", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
    {"type": "function", "name": "previewWithdraw", "stateMutability": "view", "inputs": [{"name": "assets", "type": "uint256"}], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "previewMint", "stateMutability": "view", "inputs": [{"name": "shares", "type": "uint256"}], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "paused", "stateMutability": "view", "inputs": [], "outputs": [{"type": "bool"}]},
]
ORDER_ABI = [
    {"type": "function", "name": "market", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
]
MARKET_ABI = [
    {"type": "function", "name": "tokens", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}, {"type": "address"}, {"type": "address"}, {"type": "address"}, {"type": "address"}]},
    {"type": "function", "name": "previewRedeem", "stateMutability": "view", "inputs": [{"name": "ftAmount", "type": "uint256"}], "outputs": [{"type": "uint256"}, {"type": "bytes"}]},
]
GT_ABI = [
    {"type": "function", "name": "getCollateralValue", "stateMutability": "view", "inputs": [{"name": "collateralData", "type": "bytes"}], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "liquidatable", "stateMutability": "view", "inputs": [], "outputs": [{"type": "bool"}]},
]
ERC20_ABI = [
    {"type": "function", "name": "balanceOf", "stateMutability": "view", "inputs": [{"name": "account", "type": "address"}], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "totalSupply", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "decimals", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint8"}]},
    {"type": "function", "name": "symbol", "stateMutability": "view", "inputs": [], "outputs": [{"type": "string"}]},
]

TOPIC_NEW_ORDER = Web3.keccak(text="NewOrderCreated(address,address,address)").hex()
TOPIC_REDEEM_ORDER = Web3.keccak(text="RedeemOrder(address,address,uint256,uint256)").hex()
TOPIC_WITHDRAW_FTS = Web3.keccak(text="WithdrawFts(address,address,address,uint256,uint256)").hex()


def connect() -> tuple[Web3, str]:
    errors: list[str] = []
    for url in RPC_URLS:
        try:
            w3 = Web3(HTTPProvider(url, request_kwargs={"timeout": 45}))
            chain_id = w3.eth.chain_id
            latest = w3.eth.block_number
            if chain_id != 1:
                raise RuntimeError(f"unexpected chain id {chain_id}")
            print(f"Connected to {url}; latest block {latest}")
            return w3, url
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{url}: {exc}")
    raise RuntimeError("No Ethereum RPC endpoint succeeded:\n" + "\n".join(errors))


def topic_address(topic: Any) -> str:
    raw = bytes(topic)
    return to_checksum_address(raw[-20:])


def ceil_div(a: int, b: int) -> int:
    if b <= 0:
        raise ValueError("denominator must be positive")
    return (a + b - 1) // b


def exact_fresh_mint_capital(face_assets: int, total_assets: int, total_supply: int) -> dict[str, int]:
    """Solve the OpenZeppelin ERC-4626 +1/+1 mint→withdraw fixed point.

    The vault uses the default decimals offset (zero), so virtual assets and
    shares are both one raw unit. The returned capital is conservative and the
    resulting minted shares are sufficient after the mint changes NAV/supply.
    """
    if face_assets == 0:
        return {"shares_to_mint": 0, "capital": 0, "shares_burned": 0, "residual_shares": 0}
    shares = ceil_div(face_assets * (total_supply + 1), total_assets + 1)
    for _ in range(256):
        capital = ceil_div(shares * (total_assets + 1), total_supply + 1)
        after_assets = total_assets + capital
        after_supply = total_supply + shares
        burned = ceil_div(face_assets * (after_supply + 1), after_assets + 1)
        if shares >= burned:
            return {
                "shares_to_mint": shares,
                "capital": capital,
                "shares_burned": burned,
                "residual_shares": shares - burned,
            }
        shares = burned
    raise RuntimeError("ERC-4626 fixed-point solver did not converge")


def call_symbol(token: Any, block: int | str) -> str:
    try:
        return token.functions.symbol().call(block_identifier=block)
    except Exception:  # noqa: BLE001
        return "UNKNOWN"


def get_logs_chunked(w3: Web3, address: str, topic0: str, start: int, end: int) -> list[Any]:
    logs: list[Any] = []
    cursor = start
    chunk = 20_000
    while cursor <= end:
        stop = min(end, cursor + chunk - 1)
        try:
            batch = w3.eth.get_logs({"address": address, "topics": [topic0], "fromBlock": cursor, "toBlock": stop})
            logs.extend(batch)
            cursor = stop + 1
            if chunk < 50_000:
                chunk = min(50_000, chunk * 2)
        except Exception as exc:  # noqa: BLE001
            if chunk <= 500:
                raise RuntimeError(f"eth_getLogs failed for {cursor}-{stop}: {exc}") from exc
            chunk = max(500, chunk // 2)
            print(f"Reducing log chunk to {chunk} after RPC error: {exc}")
    return logs


def decode_delivery_amount(delivery_data: bytes) -> int:
    if not delivery_data:
        return 0
    try:
        return int(decode(["uint256"], delivery_data)[0])
    except Exception:  # noqa: BLE001
        return 0


def inspect_order(w3: Web3, order_address: str, block: int, face_override: int | None = None) -> dict[str, Any]:
    vault = w3.eth.contract(address=VAULT, abi=VAULT_ABI)
    order = w3.eth.contract(address=to_checksum_address(order_address), abi=ORDER_ABI)
    market_address = to_checksum_address(order.functions.market().call(block_identifier=block))
    market = w3.eth.contract(address=market_address, abi=MARKET_ABI)
    ft_addr, xt_addr, gt_addr, collateral_addr, debt_addr = [to_checksum_address(x) for x in market.functions.tokens().call(block_identifier=block)]
    ft = w3.eth.contract(address=ft_addr, abi=ERC20_ABI)
    gt = w3.eth.contract(address=gt_addr, abi=GT_ABI)
    collateral = w3.eth.contract(address=collateral_addr, abi=ERC20_ABI)
    debt = w3.eth.contract(address=debt_addr, abi=ERC20_ABI)

    face = int(face_override if face_override is not None else ft.functions.balanceOf(order.address).call(block_identifier=block))
    maturity = int(vault.functions.orderMaturity(order.address).call(block_identifier=block))
    liquidatable = bool(gt.functions.liquidatable().call(block_identifier=block))
    final_deadline = maturity + (LIQUIDATION_WINDOW if liquidatable else 0)
    block_timestamp = int(w3.eth.get_block(block)["timestamp"])
    debt_decimals = int(debt.functions.decimals().call(block_identifier=block))
    collateral_decimals = int(collateral.functions.decimals().call(block_identifier=block))

    result: dict[str, Any] = {
        "block": block,
        "block_timestamp": block_timestamp,
        "order": order.address,
        "market": market_address,
        "ft": ft_addr,
        "gt": gt_addr,
        "collateral": collateral_addr,
        "debt_token": debt_addr,
        "debt_symbol": call_symbol(debt, block),
        "collateral_symbol": call_symbol(collateral, block),
        "debt_decimals": debt_decimals,
        "collateral_decimals": collateral_decimals,
        "maturity": maturity,
        "liquidatable": liquidatable,
        "final_deadline": final_deadline,
        "deadline_passed": maturity != 0 and block_timestamp >= final_deadline,
        "ft_face_raw": face,
    }

    if face == 0 or maturity == 0 or block_timestamp < final_deadline:
        result["preview_available"] = False
        return result

    try:
        debt_out, delivery_data = market.functions.previewRedeem(face).call(block_identifier=block)
        delivery_bytes = bytes(delivery_data)
        collateral_out = decode_delivery_amount(delivery_bytes)
        collateral_value_usd = int(gt.functions.getCollateralValue(delivery_bytes).call(block_identifier=block)) if delivery_bytes else 0
        collateral_value_debt_raw = collateral_value_usd * (10**debt_decimals) // USD_BASE
        recovery = int(debt_out) + collateral_value_debt_raw
        result.update(
            {
                "preview_available": True,
                "debt_out_raw": int(debt_out),
                "collateral_out_raw": collateral_out,
                "collateral_value_usd_1e8": collateral_value_usd,
                "collateral_value_debt_raw_at_usd_par": collateral_value_debt_raw,
                "economic_recovery_raw": recovery,
                "premium_over_face_raw": recovery - face,
            }
        )
    except Exception as exc:  # noqa: BLE001
        result.update({"preview_available": False, "preview_error": str(exc)})
    return result


def inspect_redeem_event(w3: Web3, log: Any) -> dict[str, Any]:
    block = int(log["blockNumber"])
    preblock = block - 1
    caller = topic_address(log["topics"][1])
    order = topic_address(log["topics"][2])
    bad_debt, delivery_collateral = decode(["uint256", "uint256"], bytes(log["data"]))
    tx_hash = log["transactionHash"].hex()

    entry: dict[str, Any] = {
        "tx_hash": tx_hash,
        "block": block,
        "preblock": preblock,
        "caller": caller,
        "order": order,
        "event_bad_debt_raw": int(bad_debt),
        "event_delivery_collateral_raw": int(delivery_collateral),
    }
    try:
        state = inspect_order(w3, order, preblock)
        entry["prestate"] = state
        if state.get("preview_available"):
            vault = w3.eth.contract(address=VAULT, abi=VAULT_ABI)
            total_assets = int(vault.functions.totalAssets().call(block_identifier=preblock))
            total_supply = int(vault.functions.totalSupply().call(block_identifier=preblock))
            max_deposit = int(vault.functions.maxDeposit("0x000000000000000000000000000000000000dEaD").call(block_identifier=preblock))
            exact = exact_fresh_mint_capital(int(state["ft_face_raw"]), total_assets, total_supply)
            recovery = int(state["economic_recovery_raw"])
            entry.update(
                {
                    "vault_total_assets_raw": total_assets,
                    "vault_total_supply_raw": total_supply,
                    "vault_max_deposit_raw": max_deposit,
                    "fresh_attack": exact,
                    "fresh_attack_full_amount_feasible": exact["capital"] <= max_deposit,
                    "fresh_attack_conservative_profit_raw": recovery - exact["capital"],
                    "old_lp_loss_raw": recovery - exact["capital"],
                }
            )
    except Exception as exc:  # noqa: BLE001
        entry["inspection_error"] = str(exc)
    return entry


def markdown_amount(raw: int | None, decimals: int) -> str:
    if raw is None:
        return "n/a"
    return f"{raw / (10**decimals):,.{min(decimals, 8)}f}"


def main() -> int:
    out_dir = Path(os.getenv("OUTPUT_DIR", "production-evidence"))
    out_dir.mkdir(parents=True, exist_ok=True)
    w3, rpc_url = connect()
    latest = w3.eth.block_number
    latest_block = w3.eth.get_block(latest)
    vault = w3.eth.contract(address=VAULT, abi=VAULT_ABI)
    asset_addr = to_checksum_address(vault.functions.asset().call())
    asset = w3.eth.contract(address=asset_addr, abi=ERC20_ABI)
    asset_decimals = int(asset.functions.decimals().call())
    asset_symbol = call_symbol(asset, "latest")

    print("Scanning NewOrderCreated logs...")
    new_order_logs = get_logs_chunked(w3, VAULT, TOPIC_NEW_ORDER, DEPLOYMENT_BLOCK, latest)
    print("Scanning RedeemOrder logs...")
    redeem_logs = get_logs_chunked(w3, VAULT, TOPIC_REDEEM_ORDER, DEPLOYMENT_BLOCK, latest)
    print("Scanning WithdrawFts logs...")
    withdraw_ft_logs = get_logs_chunked(w3, VAULT, TOPIC_WITHDRAW_FTS, DEPLOYMENT_BLOCK, latest)

    orders: list[dict[str, Any]] = []
    seen_orders: set[str] = set()
    for log in new_order_logs:
        caller = topic_address(log["topics"][1])
        market = topic_address(log["topics"][2])
        order = topic_address(log["topics"][3])
        if order in seen_orders:
            continue
        seen_orders.add(order)
        orders.append({"creation_block": int(log["blockNumber"]), "caller": caller, "market_from_event": market, "order": order})

    historical: list[dict[str, Any]] = []
    for idx, log in enumerate(redeem_logs, 1):
        print(f"Inspecting historical RedeemOrder {idx}/{len(redeem_logs)}")
        historical.append(inspect_redeem_event(w3, log))

    current_orders: list[dict[str, Any]] = []
    for idx, meta in enumerate(orders, 1):
        print(f"Inspecting current order {idx}/{len(orders)}: {meta['order']}")
        try:
            state = inspect_order(w3, meta["order"], latest)
            state.update(meta)
            current_orders.append(state)
        except Exception as exc:  # noqa: BLE001
            current_orders.append({**meta, "inspection_error": str(exc)})

    current_candidates = [x for x in current_orders if x.get("preview_available") and int(x.get("premium_over_face_raw", 0)) > 0]

    # Group by market because the attacker can collect FT from multiple orders and
    # redeem the combined amount once, avoiding double-counting shared reserves.
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in current_candidates:
        grouped[item["market"]].append(item)

    group_evidence: list[dict[str, Any]] = []
    total_face = 0
    total_recovery = 0
    for market_addr, items in grouped.items():
        face = sum(int(x["ft_face_raw"]) for x in items)
        representative = items[0]
        combined = inspect_order(w3, representative["order"], latest, face_override=face)
        # inspect_order uses the representative order only for market discovery;
        # face_override is the aggregate FT amount collected from all vault orders.
        group = {
            "market": market_addr,
            "orders": [x["order"] for x in items],
            "aggregate_ft_face_raw": face,
            "aggregate_preview": combined,
        }
        group_evidence.append(group)
        if combined.get("preview_available") and int(combined.get("premium_over_face_raw", 0)) > 0:
            total_face += face
            total_recovery += int(combined["economic_recovery_raw"])

    current_batch: dict[str, Any] = {
        "profitable_market_groups": len(group_evidence),
        "total_face_raw": total_face,
        "total_recovery_raw": total_recovery,
    }
    if total_face > 0:
        total_assets = int(vault.functions.totalAssets().call())
        total_supply = int(vault.functions.totalSupply().call())
        max_deposit = int(vault.functions.maxDeposit("0x000000000000000000000000000000000000dEaD").call())
        exact = exact_fresh_mint_capital(total_face, total_assets, total_supply)
        current_batch.update(
            {
                "vault_total_assets_raw": total_assets,
                "vault_total_supply_raw": total_supply,
                "vault_max_deposit_raw": max_deposit,
                "fresh_attack": exact,
                "full_batch_fresh_entry_feasible": exact["capital"] <= max_deposit,
                "maximum_full_batch_loss_raw": total_recovery - exact["capital"],
                "maximum_full_batch_attacker_profit_raw": total_recovery - exact["capital"],
            }
        )

    known_tx: dict[str, Any] = {}
    try:
        tx = w3.eth.get_transaction(KNOWN_REDEEM_TX)
        receipt = w3.eth.get_transaction_receipt(KNOWN_REDEEM_TX)
        input_hex = tx["input"].hex() if hasattr(tx["input"], "hex") else str(tx["input"])
        known_tx = {
            "hash": KNOWN_REDEEM_TX,
            "block": int(tx["blockNumber"]),
            "from": tx["from"],
            "to": tx["to"],
            "input": input_hex,
            "status": int(receipt["status"]),
        }
        if len(input_hex) >= 8 + 64:
            known_tx["decoded_first_address_argument"] = to_checksum_address("0x" + input_hex[-40:])
    except Exception as exc:  # noqa: BLE001
        known_tx = {"hash": KNOWN_REDEEM_TX, "error": str(exc)}

    evidence = {
        "generated_at_unix": int(time.time()),
        "rpc_url_used": rpc_url,
        "chain_id": w3.eth.chain_id,
        "latest_block": latest,
        "latest_timestamp": int(latest_block["timestamp"]),
        "vault": VAULT,
        "vault_deployment_block": DEPLOYMENT_BLOCK,
        "asset": asset_addr,
        "asset_symbol": asset_symbol,
        "asset_decimals": asset_decimals,
        "known_redeem_transaction": known_tx,
        "counts": {
            "new_orders": len(orders),
            "redeem_orders": len(historical),
            "withdraw_fts_events": len(withdraw_ft_logs),
            "currently_registered_orders": sum(1 for x in current_orders if int(x.get("maturity", 0)) != 0),
            "current_profitable_orders": len(current_candidates),
        },
        "historical_redeem_orders": historical,
        "current_orders": current_orders,
        "current_profitable_market_groups": group_evidence,
        "current_first_attack_batch": current_batch,
        "withdraw_fts_events": [
            {
                "block": int(log["blockNumber"]),
                "tx_hash": log["transactionHash"].hex(),
                "caller": topic_address(log["topics"][1]),
                "recipient": topic_address(log["topics"][2]),
                "order": topic_address(log["topics"][3]),
                "amount_raw": int(decode(["uint256", "uint256"], bytes(log["data"]))[0]),
                "shares_raw": int(decode(["uint256", "uint256"], bytes(log["data"]))[1]),
            }
            for log in withdraw_ft_logs
        ],
    }

    json_path = out_dir / "production_evidence.json"
    json_path.write_text(json.dumps(evidence, indent=2, sort_keys=True), encoding="utf-8")

    lines = [
        "# TermMax V2 production evidence",
        "",
        f"- Vault: `{VAULT}`",
        f"- Snapshot block: `{latest}`",
        f"- Asset: `{asset_symbol}` (`{asset_addr}`), decimals `{asset_decimals}`",
        f"- NewOrderCreated events: `{len(orders)}`",
        f"- RedeemOrder events: `{len(historical)}`",
        f"- WithdrawFts events: `{len(withdraw_ft_logs)}`",
        f"- Currently registered orders: `{evidence['counts']['currently_registered_orders']}`",
        f"- Currently profitable matured orders: `{len(current_candidates)}`",
        "",
        "## Historical RedeemOrder states",
        "",
        "| block | tx | order | FT face | recovery | fresh capital | conservative P&L | full fresh entry |",
        "|---:|---|---|---:|---:|---:|---:|:---:|",
    ]
    for item in historical:
        state = item.get("prestate", {})
        dec = int(state.get("debt_decimals", asset_decimals))
        attack = item.get("fresh_attack", {})
        lines.append(
            "| {block} | `{tx}` | `{order}` | {face} | {rec} | {cap} | {pnl} | {feasible} |".format(
                block=item.get("block", "?"),
                tx=str(item.get("tx_hash", ""))[:12] + "…",
                order=str(item.get("order", ""))[:12] + "…",
                face=markdown_amount(state.get("ft_face_raw"), dec),
                rec=markdown_amount(state.get("economic_recovery_raw"), dec),
                cap=markdown_amount(attack.get("capital"), dec),
                pnl=markdown_amount(item.get("fresh_attack_conservative_profit_raw"), dec),
                feasible="yes" if item.get("fresh_attack_full_amount_feasible") else "no/unknown",
            )
        )

    lines.extend(["", "## Current one-transaction batch", "", "```json", json.dumps(current_batch, indent=2, sort_keys=True), "```", ""])
    md_path = out_dir / "production_evidence.md"
    md_path.write_text("\n".join(lines), encoding="utf-8")

    print(f"Wrote {json_path}")
    print(f"Wrote {md_path}")
    print(json.dumps(evidence["counts"], indent=2))
    if historical:
        best = max((int(x.get("fresh_attack_conservative_profit_raw", -10**100)), x) for x in historical)
        print(f"Best historical conservative P&L raw: {best[0]}")
    print(f"Current maximum full-batch loss raw: {current_batch.get('maximum_full_batch_loss_raw', 0)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"FATAL: {exc}", file=sys.stderr)
        raise
