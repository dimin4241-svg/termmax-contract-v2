#!/usr/bin/env python3
"""Run the production scanner with exact debt-token oracle conversion.

The base collector records GT collateral value in the protocol's USD base.
This wrapper converts that USD value to debt-token raw units using the same
GtConfig oracle's debt-token price at the same block instead of assuming $1.
"""

from __future__ import annotations

import os
from typing import Any

from eth_utils import to_checksum_address
from web3 import HTTPProvider as BaseHTTPProvider

import scripts.termmax_production_evidence as scanner

GT_CONFIG_ABI = [
    {
        "type": "function",
        "name": "getGtConfig",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [
            {
                "name": "",
                "type": "tuple",
                "components": [
                    {"name": "collateral", "type": "address"},
                    {"name": "debtToken", "type": "address"},
                    {"name": "ft", "type": "address"},
                    {"name": "treasurer", "type": "address"},
                    {"name": "maturity", "type": "uint64"},
                    {
                        "name": "loanConfig",
                        "type": "tuple",
                        "components": [
                            {"name": "oracle", "type": "address"},
                            {"name": "liquidationLtv", "type": "uint32"},
                            {"name": "maxLtv", "type": "uint32"},
                            {"name": "liquidatable", "type": "bool"},
                        ],
                    },
                ],
            }
        ],
    }
]
ORACLE_ABI = [
    {
        "type": "function",
        "name": "getPrice",
        "stateMutability": "view",
        "inputs": [{"name": "asset", "type": "address"}],
        "outputs": [{"name": "price", "type": "uint256"}, {"name": "decimals", "type": "uint8"}],
    }
]


def provider(url: str, request_kwargs: dict[str, Any] | None = None) -> BaseHTTPProvider:
    kwargs = dict(request_kwargs or {})
    headers = dict(kwargs.pop("headers", {}) or {})
    headers.update(
        {
            "User-Agent": "curl/8.5.0",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
    )
    return BaseHTTPProvider(url, request_kwargs={**kwargs, "headers": headers})


scanner.HTTPProvider = provider
if os.getenv("ETH_RPC_URL"):
    scanner.RPC_URLS = [os.environ["ETH_RPC_URL"]]
for topic_name in ("TOPIC_NEW_ORDER", "TOPIC_REDEEM_ORDER", "TOPIC_WITHDRAW_FTS"):
    value = getattr(scanner, topic_name)
    if not value.startswith("0x"):
        setattr(scanner, topic_name, "0x" + value)

_base_inspect_order = scanner.inspect_order


def inspect_order_exact_debt_oracle(w3: Any, order_address: str, block: int, face_override: int | None = None) -> dict[str, Any]:
    result = _base_inspect_order(w3, order_address, block, face_override)
    if not result.get("preview_available"):
        return result

    usd_value = int(result.get("collateral_value_usd_1e8", 0))
    debt_out = int(result.get("debt_out_raw", 0))
    face = int(result.get("ft_face_raw", 0))
    debt_decimals = int(result["debt_decimals"])

    gt = w3.eth.contract(address=to_checksum_address(result["gt"]), abi=GT_CONFIG_ABI)
    config = gt.functions.getGtConfig().call(block_identifier=block)
    loan_config = config[5]
    oracle_address = to_checksum_address(loan_config[0])
    oracle = w3.eth.contract(address=oracle_address, abi=ORACLE_ABI)
    debt_price, debt_price_decimals = oracle.functions.getPrice(result["debt_token"]).call(block_identifier=block)
    debt_price = int(debt_price)
    debt_price_decimals = int(debt_price_decimals)
    if debt_price <= 0:
        raise RuntimeError(f"non-positive protocol debt-token price at block {block}")

    collateral_value_debt_raw = (
        usd_value * (10**debt_decimals) * (10**debt_price_decimals)
        // (scanner.USD_BASE * debt_price)
    )
    economic_recovery = debt_out + collateral_value_debt_raw

    result.update(
        {
            "protocol_oracle": oracle_address,
            "debt_price_raw": debt_price,
            "debt_price_decimals": debt_price_decimals,
            "collateral_value_debt_raw_protocol_oracle": collateral_value_debt_raw,
            "economic_recovery_raw": economic_recovery,
            "premium_over_face_raw": economic_recovery - face,
            "valuation_method": "GT USD collateral value divided by same protocol oracle debt-token price",
        }
    )
    return result


scanner.inspect_order = inspect_order_exact_debt_oracle

if __name__ == "__main__":
    raise SystemExit(scanner.main())
