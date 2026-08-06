#!/usr/bin/env python3
"""Static source-path and economic validation for the bad-debt capture PoC."""

from __future__ import annotations

from decimal import Decimal, getcontext
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VAULT = ROOT / "contracts/v2/vault/TermMaxVaultV2.sol"
MANAGER = ROOT / "contracts/v2/vault/OrderManagerV2.sol"
POC = ROOT / "test/v2/VaultBadDebtPostDefaultDepositPoC.t.sol"

getcontext().prec = 80


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"[FAIL] {message}")
    print(f"[PASS] {message}")


def function_slice(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"found source function: {signature}")

    next_function = source.find("\n    function ", start + len(signature))
    if next_function < 0:
        next_function = len(source)
    return source[start:next_function]


def ordered(text: str, needles: list[str], message: str) -> None:
    positions = [text.find(needle) for needle in needles]
    require(all(position >= 0 for position in positions), f"{message}: all steps exist")
    require(positions == sorted(positions), f"{message}: steps are ordered")


vault = VAULT.read_text(encoding="utf-8")
manager = MANAGER.read_text(encoding="utf-8")
poc = POC.read_text(encoding="utf-8")

# 1. Bad debt is recognized, but the recognized loss is not applied to NAV.
redeem_order = function_slice(manager, "function redeemOrder(IERC20 asset, address order)")
require("_badDebtMapping[collateral] += badDebt" in redeem_order, "redeemOrder records bad debt")
require("_accretingPrincipal -=" not in redeem_order, "redeemOrder does not reduce principal for recognized bad debt")
require("_totalFt -=" not in redeem_order, "redeemOrder does not reduce total FT for recognized bad debt")

# 2. ERC-4626 NAV remains based on accreting principal and ignores recovery collateral.
total_assets = function_slice(vault, "function totalAssets() public view override")
require("_previewAccruedInterest()" in total_assets, "totalAssets is derived from accreting principal")
require("_badDebtMapping" not in total_assets, "totalAssets does not deduct outstanding bad debt")
require("balanceOf(address(this))" not in total_assets, "totalAssets does not value delivered collateral balances")

# 3. New shares remain permissionlessly mintable while recovery is outstanding.
deposit_path = function_slice(vault, "function _deposit(address caller, address recipient, uint256 assets, uint256 shares)")
require("_badDebtMapping" not in deposit_path, "deposit path has no outstanding-bad-debt guard")
require("whenNotPaused" in deposit_path, "deposit path is gated only by ordinary pause control")

# 4. dealBadDebt accepts current shares and transfers collateral at nominal bad debt.
deal_vault = function_slice(vault, "function dealBadDebt(address collateral, uint256 badDebtAmt, address recipient, address owner)")
ordered(
    deal_vault,
    [
        "shares = previewWithdraw(badDebtAmt)",
        "_burn(owner, shares)",
        "IOrderManager.dealBadDebt",
    ],
    "vault settlement burns current shares before releasing recovery collateral",
)
require("snapshot" not in deal_vault.lower(), "dealBadDebt has no pre-default ownership snapshot")

# 5. The manager distributes the entire collateral balance pro rata and only then removes nominal principal.
deal_manager = function_slice(manager, "function dealBadDebt(address recipient, address collateral, uint256 amount)")
ordered(
    deal_manager,
    [
        "uint256 collateralBalance = IERC20(collateral).balanceOf(address(this))",
        "collateralOut = (amount * collateralBalance) / badDebtAmt",
        "IERC20(collateral).safeTransfer(recipient, collateralOut)",
        "_accretingPrincipal -= amplifiedAmt",
        "_totalFt -= amplifiedAmt",
    ],
    "manager exchanges nominal bad debt for recovery collateral",
)

# 6. The focused PoC preserves attacker reachability and strong controls.
ordered(
    poc,
    [
        "vault.redeemOrder(res.order)",
        "vm.snapshot()",
        "oldLpCollateralOut",
        "assertEq(vault.balanceOf(address(sniper)), 0)",
        "vm.expectRevert()",
        "sniper.attack(sharesToMint, badDebt, attacker)",
        "assertEq(attackerCollateralOut, recoveryCollateral)",
        "assertEq(vault.balanceOf(deployer), oldLpSharesBefore)",
        "conservativeRoiBps",
    ],
    "PoC orders default, old-LP control, zero-share control, atomic attack and profit proof",
)
require("vault.mint(sharesToMint, address(this))" in poc, "attacker mints shares after default")
require("vault.dealBadDebt" in poc, "attacker consumes recovery through the real public entrypoint")

# 7. Algebraic proof. R and F scale amounts but cancel from the recovery-value ratio.
R = Decimal("1000")
D = Decimal("1000")
F = Decimal("999")
V = Decimal("2000")
p = F / (R + D)
bad_debt = F - p * R
recovery_value = p * V
ratio = recovery_value / bad_debt

require(bad_debt > 0, "economic model creates positive bad debt")
require(recovery_value > bad_debt, "recovery value exceeds nominal bad debt")
require(ratio == V / D, "market reserves and order size cancel from recovery-value ratio")
require(ratio == Decimal("2"), "first-party 50% LTV fixture produces 2x recovery value")

print()
print("MODEL")
print(f"  matched_reserve_R       = {R}")
print(f"  unpaid_debt_D           = {D}")
print(f"  order_ft_F              = {F}")
print(f"  collateral_value_V      = {V}")
print(f"  bad_debt_B              = {bad_debt}")
print(f"  recovery_value_C        = {recovery_value}")
print(f"  recovery_to_bad_debt    = {ratio}")
print(f"  gross_roi               = {(ratio - 1) * 100}%")
print()
print("RESULT=source path and economics support a reportable post-default recovery-capture finding")
