#!/usr/bin/env python3
"""
Read-only production-state scanner for the TermMax V2 stale-NAV / bad-debt path.

The scanner discovers vaults from VaultFactoryV2.VaultCreated logs, finds historical
RedeemOrder events that introduced bad debt, reads the CURRENT badDebtMapping,
prices remaining delivery collateral with the protocol's OracleAggregatorV2 when
available, reconstructs current ERC-20 share holders, and estimates the largest
cross-LP value shift that a nominal ERC-4626 redemption could realize.

No transactions are sent. All chain interaction is eth_call / eth_getLogs only.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from collections import defaultdict
from dataclasses import dataclass
from decimal import Decimal, getcontext
from pathlib import Path
from typing import Any, Iterable

from eth_abi import decode
from web3 import Web3
from web3.exceptions import ContractLogicError

getcontext().prec = 100
ZERO = "0x0000000000000000000000000000000000000000"


NETWORKS: dict[str, dict[str, Any]] = {
    "bera": {
        "name": "Berachain mainnet",
        "chain_id": 80094,
        "rpcs": ["https://rpc.berachain.com"],
        "from_block": 19609794,
        "vault_factory": "0xd427EBAF1D269b397C454b22791b63534F1ae5B2",
        "oracle": "0xf5c6664c5b33e3FC16afA43621650652FcD85d65",
        "initial_log_chunk": 250_000,
        "minimum_log_chunk": 100,
        "max_log_queries": 20_000,
    },
    "hyperevm": {
        "name": "HyperEVM mainnet",
        "chain_id": 999,
        # HypurrScan is tried first because the official HyperEVM RPC documents a
        # very small eth_getLogs range. The official endpoint remains the fallback.
        "rpcs": ["https://rpc.hypurrscan.io", "https://rpc.hyperliquid.xyz/evm"],
        "from_block": 15997130,
        "vault_factory": "0xA0E0702b701cCaC329732Bb409681612f43E41AD",
        "oracle": "0x8b2ae4e2070b3E9bf9625FC61290700a2E24A808",
        "initial_log_chunk": 250_000,
        "minimum_log_chunk": 50,
        # Avoid silently spending hours if every provider enforces the official 50-block cap.
        "max_log_queries": 8_000,
    },
    "b2": {
        "name": "B2 mainnet",
        "chain_id": 223,
        "rpcs": ["https://rpc.bsquared.network", "https://mainnet.b2-rpc.com"],
        "from_block": 31535305,
        "vault_factory": "0x3Ebb9e9C855Bd03b275167DD2418193E3b69C22f",
        "oracle": "0x3B798263e9eAE3254d86AC30b198F7AA2F82Fd82",
        "initial_log_chunk": 250_000,
        "minimum_log_chunk": 100,
        "max_log_queries": 20_000,
    },
    "pharos": {
        "name": "Pharos mainnet",
        "chain_id": 1672,
        # Public Pharos mainnet endpoint. Chain-id is verified before it is trusted.
        "rpcs": ["https://rpc.pharos.xyz"],
        "from_block": 5278169,
        "vault_factory": "0x5316b0d2Ee13C81E243226D6BB93CF29FBf95837",
        "oracle": "0x490df22f542e778fAfAB441beB19d358bE048A20",
        "initial_log_chunk": 250_000,
        "minimum_log_chunk": 100,
        "max_log_queries": 20_000,
    },
}

VAULT_CREATED_SIG = "VaultCreated(address,address,(address,address,address,uint256,address,address,uint256,string,string,uint64,uint64))"
REDEEM_ORDER_SIG = "RedeemOrder(address,address,uint256,uint256)"
TRANSFER_SIG = "Transfer(address,address,uint256)"

VAULT_CREATED_TOPIC = Web3.keccak(text=VAULT_CREATED_SIG).hex()
REDEEM_ORDER_TOPIC = Web3.keccak(text=REDEEM_ORDER_SIG).hex()
TRANSFER_TOPIC = Web3.keccak(text=TRANSFER_SIG).hex()

VAULT_ABI = [
    {"type": "function", "name": "asset", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
    {"type": "function", "name": "pool", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
    {"type": "function", "name": "totalSupply", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "totalAssets", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "totalFt", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "accretingPrincipal", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "performanceFee", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "badDebtMapping", "stateMutability": "view", "inputs": [{"type": "address"}], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "previewRedeem", "stateMutability": "view", "inputs": [{"type": "uint256"}], "outputs": [{"type": "uint256"}]},
]

ERC20_ABI = [
    {"type": "function", "name": "balanceOf", "stateMutability": "view", "inputs": [{"type": "address"}], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "decimals", "stateMutability": "view", "inputs": [], "outputs": [{"type": "uint8"}]},
    {"type": "function", "name": "symbol", "stateMutability": "view", "inputs": [], "outputs": [{"type": "string"}]},
]

POOL_ABI = [
    {"type": "function", "name": "maxWithdraw", "stateMutability": "view", "inputs": [{"type": "address"}], "outputs": [{"type": "uint256"}]},
    {"type": "function", "name": "asset", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
]

ORDER_ABI = [
    {"type": "function", "name": "market", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
]

MARKET_ABI = [
    {
        "type": "function",
        "name": "tokens",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [
            {"type": "address"}, {"type": "address"}, {"type": "address"}, {"type": "address"}, {"type": "address"}
        ],
    },
]

ORACLE_ABI = [
    {
        "type": "function",
        "name": "getPrice",
        "stateMutability": "view",
        "inputs": [{"type": "address"}],
        "outputs": [{"type": "uint256"}, {"type": "uint8"}],
    },
]


@dataclass
class LogScanStats:
    queries: int = 0
    retries: int = 0
    smallest_successful_chunk: int | None = None
    largest_successful_chunk: int = 0


class LogScanLimit(RuntimeError):
    pass


def topic_address(topic: Any) -> str:
    h = topic.hex() if hasattr(topic, "hex") else str(topic)
    h = h[2:] if h.startswith("0x") else h
    return Web3.to_checksum_address("0x" + h[-40:])


def as_hex_topic(topic: str) -> str:
    return topic if topic.startswith("0x") else "0x" + topic


def connect(cfg: dict[str, Any]) -> tuple[Web3, str, list[dict[str, Any]]]:
    attempts: list[dict[str, Any]] = []
    for rpc in cfg["rpcs"]:
        started = time.time()
        try:
            w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": 30}))
            chain_id = int(w3.eth.chain_id)
            block = int(w3.eth.block_number)
            ok = chain_id == int(cfg["chain_id"])
            attempts.append({
                "rpc": rpc,
                "ok": ok,
                "chain_id": chain_id,
                "block": block,
                "elapsed_s": round(time.time() - started, 3),
            })
            if ok:
                return w3, rpc, attempts
        except Exception as exc:  # noqa: BLE001 - evidence collector must record provider failures
            attempts.append({
                "rpc": rpc,
                "ok": False,
                "error": f"{type(exc).__name__}: {exc}",
                "elapsed_s": round(time.time() - started, 3),
            })
    raise RuntimeError(f"No usable RPC for {cfg['name']}: {attempts}")


def get_logs_adaptive(
    w3: Web3,
    *,
    address: str,
    topic0: str,
    start_block: int,
    end_block: int,
    initial_chunk: int,
    minimum_chunk: int,
    max_queries: int,
) -> tuple[list[Any], LogScanStats]:
    if start_block > end_block:
        return [], LogScanStats()

    address = Web3.to_checksum_address(address)
    out: list[Any] = []
    stats = LogScanStats()
    cursor = int(start_block)
    chunk = max(int(initial_chunk), int(minimum_chunk))
    max_chunk = chunk

    while cursor <= end_block:
        if stats.queries >= max_queries:
            raise LogScanLimit(
                f"eth_getLogs query cap reached ({max_queries}) at block {cursor}/{end_block}; "
                f"provider's allowed range is too small for an exhaustive scan"
            )
        to_block = min(end_block, cursor + chunk - 1)
        params = {
            "fromBlock": cursor,
            "toBlock": to_block,
            "address": address,
            "topics": [as_hex_topic(topic0)],
        }
        stats.queries += 1
        try:
            logs = w3.eth.get_logs(params)
            out.extend(logs)
            success_size = to_block - cursor + 1
            stats.smallest_successful_chunk = (
                success_size
                if stats.smallest_successful_chunk is None
                else min(stats.smallest_successful_chunk, success_size)
            )
            stats.largest_successful_chunk = max(stats.largest_successful_chunk, success_size)
            cursor = to_block + 1
            if chunk < max_chunk:
                chunk = min(max_chunk, max(chunk + 1, chunk * 2))
        except Exception as exc:  # noqa: BLE001
            stats.retries += 1
            if chunk <= minimum_chunk:
                raise RuntimeError(
                    f"eth_getLogs failed even at minimum chunk={minimum_chunk}, "
                    f"range={cursor}-{to_block}: {type(exc).__name__}: {exc}"
                ) from exc
            chunk = max(minimum_chunk, chunk // 2)
            time.sleep(0.15)

    out.sort(key=lambda x: (int(x["blockNumber"]), int(x["logIndex"])))
    return out, stats


def safe_call(fn, default=None):
    try:
        return fn.call()
    except Exception:  # noqa: BLE001
        return default


def token_meta(w3: Web3, token: str) -> dict[str, Any]:
    token = Web3.to_checksum_address(token)
    c = w3.eth.contract(address=token, abi=ERC20_ABI)
    dec = safe_call(c.functions.decimals(), 18)
    symbol = safe_call(c.functions.symbol(), token[:10])
    return {"address": token, "decimals": int(dec), "symbol": str(symbol)}


def oracle_price(w3: Web3, oracle_addr: str, token: str) -> dict[str, Any] | None:
    try:
        oracle = w3.eth.contract(address=Web3.to_checksum_address(oracle_addr), abi=ORACLE_ABI)
        raw, decimals = oracle.functions.getPrice(Web3.to_checksum_address(token)).call()
        return {
            "raw": int(raw),
            "decimals": int(decimals),
            "decimal": str(Decimal(int(raw)) / (Decimal(10) ** int(decimals))),
        }
    except Exception:  # noqa: BLE001
        return None


def collateral_value_in_asset_raw(
    collateral_balance_raw: int,
    collateral_decimals: int,
    collateral_price: dict[str, Any],
    asset_decimals: int,
    asset_price: dict[str, Any],
) -> int:
    coll_amount = Decimal(collateral_balance_raw) / (Decimal(10) ** collateral_decimals)
    coll_usd = coll_amount * Decimal(collateral_price["raw"]) / (Decimal(10) ** collateral_price["decimals"])
    asset_usd = Decimal(asset_price["raw"]) / (Decimal(10) ** asset_price["decimals"])
    if asset_usd <= 0:
        raise ValueError("asset oracle price is zero")
    raw = coll_usd / asset_usd * (Decimal(10) ** asset_decimals)
    # Flooring collateral coverage is conservative for proving a deficit.
    return max(0, int(raw))


def discover_vaults(w3: Web3, cfg: dict[str, Any], end_block: int) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    logs, stats = get_logs_adaptive(
        w3,
        address=cfg["vault_factory"],
        topic0=VAULT_CREATED_TOPIC,
        start_block=int(cfg["from_block"]),
        end_block=end_block,
        initial_chunk=int(cfg["initial_log_chunk"]),
        minimum_chunk=int(cfg["minimum_log_chunk"]),
        max_queries=int(cfg["max_log_queries"]),
    )
    seen: dict[str, dict[str, Any]] = {}
    for log in logs:
        if len(log["topics"]) < 2:
            continue
        vault = topic_address(log["topics"][1])
        seen[vault.lower()] = {
            "vault": vault,
            "created_block": int(log["blockNumber"]),
            "created_tx": log["transactionHash"].hex(),
        }
    return list(seen.values()), stats.__dict__


def positive_bad_debt_collaterals(
    w3: Web3,
    cfg: dict[str, Any],
    vault: str,
    created_block: int,
    end_block: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    logs, stats = get_logs_adaptive(
        w3,
        address=vault,
        topic0=REDEEM_ORDER_TOPIC,
        start_block=created_block,
        end_block=end_block,
        initial_chunk=int(cfg["initial_log_chunk"]),
        minimum_chunk=int(cfg["minimum_log_chunk"]),
        max_queries=int(cfg["max_log_queries"]),
    )
    orders: dict[str, dict[str, Any]] = {}
    for log in logs:
        if len(log["topics"]) < 3:
            continue
        data = bytes(log["data"])
        if len(data) < 64:
            continue
        bad_debt, delivery = decode(["uint256", "uint256"], data[:64])
        if int(bad_debt) == 0:
            continue
        order = topic_address(log["topics"][2])
        orders[order.lower()] = {
            "order": order,
            "event_bad_debt": int(bad_debt),
            "event_delivery": int(delivery),
            "block": int(log["blockNumber"]),
            "tx": log["transactionHash"].hex(),
        }

    vault_contract = w3.eth.contract(address=Web3.to_checksum_address(vault), abi=VAULT_ABI)
    by_collateral: dict[str, dict[str, Any]] = {}
    for item in orders.values():
        try:
            order_c = w3.eth.contract(address=Web3.to_checksum_address(item["order"]), abi=ORDER_ABI)
            market = Web3.to_checksum_address(order_c.functions.market().call())
            market_c = w3.eth.contract(address=market, abi=MARKET_ABI)
            tokens = market_c.functions.tokens().call()
            collateral = Web3.to_checksum_address(tokens[3])
            current_bad_debt = int(vault_contract.functions.badDebtMapping(collateral).call())
            entry = by_collateral.setdefault(collateral.lower(), {
                "collateral": collateral,
                "market_examples": [],
                "redeem_events": [],
                "current_bad_debt_raw": current_bad_debt,
            })
            entry["current_bad_debt_raw"] = current_bad_debt
            if market not in entry["market_examples"]:
                entry["market_examples"].append(market)
            entry["redeem_events"].append(item)
        except Exception as exc:  # noqa: BLE001
            item["resolution_error"] = f"{type(exc).__name__}: {exc}"

    active = [x for x in by_collateral.values() if int(x["current_bad_debt_raw"]) > 0]
    active.sort(key=lambda x: int(x["current_bad_debt_raw"]), reverse=True)
    return active, {**stats.__dict__, "positive_redeem_events": len(orders)}


def reconstruct_holders(
    w3: Web3,
    cfg: dict[str, Any],
    vault: str,
    created_block: int,
    end_block: int,
    total_supply: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    logs, stats = get_logs_adaptive(
        w3,
        address=vault,
        topic0=TRANSFER_TOPIC,
        start_block=created_block,
        end_block=end_block,
        initial_chunk=int(cfg["initial_log_chunk"]),
        minimum_chunk=int(cfg["minimum_log_chunk"]),
        max_queries=int(cfg["max_log_queries"]),
    )
    balances: defaultdict[str, int] = defaultdict(int)
    for log in logs:
        if len(log["topics"]) < 3:
            continue
        from_addr = topic_address(log["topics"][1]).lower()
        to_addr = topic_address(log["topics"][2]).lower()
        data = bytes(log["data"])
        if len(data) < 32:
            continue
        value = int.from_bytes(data[-32:], "big")
        if from_addr != ZERO.lower():
            balances[from_addr] -= value
        if to_addr != ZERO.lower():
            balances[to_addr] += value

    positive = [(Web3.to_checksum_address(a), b) for a, b in balances.items() if b > 0]
    positive.sort(key=lambda x: x[1], reverse=True)
    reconstructed = sum(b for _, b in positive)
    return {
        "holder_count": len(positive),
        "reconstructed_supply_raw": reconstructed,
        "reported_total_supply_raw": total_supply,
        "supply_matches": reconstructed == total_supply,
        "top_holders": [{"address": a, "shares_raw": b} for a, b in positive[:20]],
    }, stats.__dict__


def analyze_vault(w3: Web3, cfg: dict[str, Any], item: dict[str, Any], end_block: int) -> dict[str, Any]:
    vault = Web3.to_checksum_address(item["vault"])
    vc = w3.eth.contract(address=vault, abi=VAULT_ABI)
    result: dict[str, Any] = dict(item)
    result["vault"] = vault

    asset = safe_call(vc.functions.asset())
    total_supply = safe_call(vc.functions.totalSupply())
    total_assets = safe_call(vc.functions.totalAssets())
    if asset is None or total_supply is None or total_assets is None:
        result["status"] = "unreadable_vault"
        return result

    asset = Web3.to_checksum_address(asset)
    asset_meta = token_meta(w3, asset)
    result.update({
        "status": "read",
        "asset": asset_meta,
        "total_supply_raw": int(total_supply),
        "total_assets_raw": int(total_assets),
        "total_ft_raw": int(safe_call(vc.functions.totalFt(), 0) or 0),
        "accreting_principal_raw": int(safe_call(vc.functions.accretingPrincipal(), 0) or 0),
        "performance_fee_raw": int(safe_call(vc.functions.performanceFee(), 0) or 0),
    })

    pool = safe_call(vc.functions.pool(), ZERO) or ZERO
    pool = Web3.to_checksum_address(pool)
    result["pool"] = pool

    asset_c = w3.eth.contract(address=asset, abi=ERC20_ABI)
    direct_asset_balance = int(safe_call(asset_c.functions.balanceOf(vault), 0) or 0)
    result["direct_asset_balance_raw"] = direct_asset_balance

    if pool != Web3.to_checksum_address(ZERO):
        pc = w3.eth.contract(address=pool, abi=POOL_ABI)
        liquid_capacity = int(safe_call(pc.functions.maxWithdraw(vault), 0) or 0)
        pool_asset = safe_call(pc.functions.asset(), None)
        result["pool_asset"] = Web3.to_checksum_address(pool_asset) if pool_asset else None
        result["liquid_capacity_raw"] = liquid_capacity
        result["liquidity_source"] = "pool.maxWithdraw(vault)"
    else:
        result["liquid_capacity_raw"] = direct_asset_balance
        result["liquidity_source"] = "asset.balanceOf(vault)"

    try:
        bad_collaterals, redeem_stats = positive_bad_debt_collaterals(
            w3, cfg, vault, int(item["created_block"]), end_block
        )
        result["redeem_log_scan"] = redeem_stats
    except Exception as exc:  # noqa: BLE001
        result["redeem_log_scan_error"] = f"{type(exc).__name__}: {exc}"
        bad_collaterals = []

    result["bad_debt_collaterals"] = bad_collaterals
    if not bad_collaterals:
        result["current_bad_debt_raw"] = 0
        result["candidate"] = False
        return result

    asset_price = oracle_price(w3, cfg["oracle"], asset)
    result["asset_oracle_price"] = asset_price
    total_bad_debt = 0
    total_collateral_value_raw = 0
    all_priced = asset_price is not None

    for entry in bad_collaterals:
        collateral = Web3.to_checksum_address(entry["collateral"])
        cm = token_meta(w3, collateral)
        cc = w3.eth.contract(address=collateral, abi=ERC20_ABI)
        balance = int(safe_call(cc.functions.balanceOf(vault), 0) or 0)
        cp = oracle_price(w3, cfg["oracle"], collateral)
        entry["token"] = cm
        entry["vault_collateral_balance_raw"] = balance
        entry["oracle_price"] = cp
        total_bad_debt += int(entry["current_bad_debt_raw"])
        if asset_price is not None and cp is not None:
            try:
                value_raw = collateral_value_in_asset_raw(
                    balance, int(cm["decimals"]), cp, int(asset_meta["decimals"]), asset_price
                )
                entry["collateral_value_in_asset_raw"] = value_raw
                total_collateral_value_raw += value_raw
            except Exception as exc:  # noqa: BLE001
                entry["pricing_error"] = f"{type(exc).__name__}: {exc}"
                all_priced = False
        else:
            all_priced = False

    result["current_bad_debt_raw"] = total_bad_debt
    result["all_collateral_priced"] = all_priced
    if all_priced:
        hidden_deficit = max(0, total_bad_debt - total_collateral_value_raw)
        economic_assets = max(0, int(total_assets) - total_bad_debt + total_collateral_value_raw)
        result["total_collateral_value_in_asset_raw"] = total_collateral_value_raw
        result["hidden_deficit_raw"] = hidden_deficit
        result["economic_assets_raw"] = economic_assets
        result["candidate"] = bool(hidden_deficit > 0 and int(total_supply) > 0)
    else:
        result["candidate"] = bool(total_bad_debt > 0 and int(total_supply) > 0)
        result["candidate_unpriced"] = True

    if not result["candidate"]:
        return result

    try:
        holders, holder_stats = reconstruct_holders(
            w3, cfg, vault, int(item["created_block"]), end_block, int(total_supply)
        )
        result["holders"] = holders
        result["holder_log_scan"] = holder_stats
    except Exception as exc:  # noqa: BLE001
        result["holder_scan_error"] = f"{type(exc).__name__}: {exc}"
        return result

    if not all_priced or int(total_assets) == 0:
        return result

    hidden_deficit = int(result["hidden_deficit_raw"])
    liquid_capacity = int(result["liquid_capacity_raw"])
    estimates: list[dict[str, Any]] = []
    for holder in result["holders"]["top_holders"]:
        shares = int(holder["shares_raw"])
        nominal = int(safe_call(vc.functions.previewRedeem(shares), 0) or 0)
        if nominal <= 0:
            continue
        executable_nominal = min(nominal, liquid_capacity)
        fraction = Decimal(executable_nominal) / Decimal(int(total_assets))
        if fraction > 1:
            fraction = Decimal(1)
        estimated_excess = int(Decimal(hidden_deficit) * fraction)
        estimates.append({
            "holder": holder["address"],
            "shares_raw": shares,
            "full_preview_redeem_raw": nominal,
            "liquidity_capped_nominal_raw": executable_nominal,
            "estimated_excess_over_economic_value_raw": estimated_excess,
        })
    estimates.sort(key=lambda x: x["estimated_excess_over_economic_value_raw"], reverse=True)
    result["holder_exit_estimates"] = estimates[:20]
    result["max_estimated_cross_lp_shift_raw"] = (
        int(estimates[0]["estimated_excess_over_economic_value_raw"]) if estimates else 0
    )
    return result


def human_amount(raw: int | None, decimals: int) -> str | None:
    if raw is None:
        return None
    return format(Decimal(int(raw)) / (Decimal(10) ** decimals), "f")


def add_human_fields(vault: dict[str, Any]) -> None:
    asset = vault.get("asset")
    if not asset:
        return
    d = int(asset.get("decimals", 18))
    for key in [
        "total_assets_raw", "total_ft_raw", "accreting_principal_raw", "performance_fee_raw",
        "direct_asset_balance_raw", "liquid_capacity_raw", "current_bad_debt_raw",
        "total_collateral_value_in_asset_raw", "hidden_deficit_raw", "economic_assets_raw",
        "max_estimated_cross_lp_shift_raw",
    ]:
        if key in vault:
            vault[key.removesuffix("_raw")] = human_amount(vault.get(key), d)
    for e in vault.get("holder_exit_estimates", []):
        for key in ["full_preview_redeem_raw", "liquidity_capped_nominal_raw", "estimated_excess_over_economic_value_raw"]:
            e[key.removesuffix("_raw")] = human_amount(e.get(key), d)
    for c in vault.get("bad_debt_collaterals", []):
        if "current_bad_debt_raw" in c:
            c["current_bad_debt"] = human_amount(c["current_bad_debt_raw"], d)
        if "collateral_value_in_asset_raw" in c:
            c["collateral_value_in_asset"] = human_amount(c["collateral_value_in_asset_raw"], d)
        token = c.get("token")
        if token and "vault_collateral_balance_raw" in c:
            c["vault_collateral_balance"] = human_amount(c["vault_collateral_balance_raw"], int(token["decimals"]))


def run_network(key: str) -> dict[str, Any]:
    cfg = NETWORKS[key]
    result: dict[str, Any] = {
        "network_key": key,
        "network": cfg["name"],
        "expected_chain_id": cfg["chain_id"],
        "vault_factory": cfg["vault_factory"],
        "oracle": cfg["oracle"],
        "configured_from_block": cfg["from_block"],
        "vault_created_topic": VAULT_CREATED_TOPIC,
        "redeem_order_topic": REDEEM_ORDER_TOPIC,
        "transfer_topic": TRANSFER_TOPIC,
        "started_unix": int(time.time()),
    }
    try:
        w3, rpc, attempts = connect(cfg)
        result["rpc"] = rpc
        result["rpc_attempts"] = attempts
        start_head = int(w3.eth.block_number)
        result["scan_end_block"] = start_head
        factory_code = w3.eth.get_code(Web3.to_checksum_address(cfg["vault_factory"]))
        result["vault_factory_code_bytes"] = len(factory_code)
        if len(factory_code) == 0:
            result["status"] = "factory_not_deployed_at_head"
            return result

        try:
            vaults, factory_stats = discover_vaults(w3, cfg, start_head)
            result["factory_log_scan"] = factory_stats
        except LogScanLimit as exc:
            result["status"] = "partial_factory_log_scan"
            result["error"] = str(exc)
            return result
        except Exception as exc:  # noqa: BLE001
            result["status"] = "factory_log_scan_failed"
            result["error"] = f"{type(exc).__name__}: {exc}"
            return result

        result["vault_count"] = len(vaults)
        analyzed: list[dict[str, Any]] = []
        for i, vault in enumerate(vaults, start=1):
            print(f"[{key}] vault {i}/{len(vaults)} {vault['vault']}", flush=True)
            analyzed.append(analyze_vault(w3, cfg, vault, start_head))
        for v in analyzed:
            add_human_fields(v)
        result["vaults"] = analyzed
        candidates = [v for v in analyzed if v.get("candidate")]
        candidates.sort(key=lambda x: int(x.get("max_estimated_cross_lp_shift_raw", 0)), reverse=True)
        result["candidate_count"] = len(candidates)
        result["candidate_vaults"] = [v["vault"] for v in candidates]
        if candidates:
            result["best_candidate"] = {
                "vault": candidates[0]["vault"],
                "asset": candidates[0].get("asset"),
                "hidden_deficit": candidates[0].get("hidden_deficit"),
                "current_bad_debt": candidates[0].get("current_bad_debt"),
                "liquid_capacity": candidates[0].get("liquid_capacity"),
                "holder_count": candidates[0].get("holders", {}).get("holder_count"),
                "max_estimated_cross_lp_shift": candidates[0].get("max_estimated_cross_lp_shift"),
            }
        result["status"] = "complete"
        result["ending_head_block"] = int(w3.eth.block_number)
        return result
    except Exception as exc:  # noqa: BLE001
        result["status"] = "fatal"
        result["error"] = f"{type(exc).__name__}: {exc}"
        return result
    finally:
        result["finished_unix"] = int(time.time())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--network", choices=sorted(NETWORKS), required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    result = run_network(args.network)
    path = Path(args.output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=2, sort_keys=False), encoding="utf-8")

    print(json.dumps({
        "network": result.get("network"),
        "status": result.get("status"),
        "rpc": result.get("rpc"),
        "scan_end_block": result.get("scan_end_block"),
        "vault_count": result.get("vault_count"),
        "candidate_count": result.get("candidate_count"),
        "best_candidate": result.get("best_candidate"),
        "error": result.get("error"),
        "output": str(path),
    }, indent=2), flush=True)
    # Evidence collection should preserve partial results as artifacts rather than
    # suppress them by failing before upload.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
