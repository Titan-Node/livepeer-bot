// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UnitBase} from "./Base.t.sol";
import {LivepeerRewardCaller} from "../../src/LivepeerRewardCaller.sol";

/// @notice Registry resolution is PER CALL (never pinned), so a governance
///         re-registration to address(0) AFTER a healthy deploy must make every
///         entrypoint revert ZeroAddress — and a later re-registration heals the same
///         deployment without any admin action on this contract.
contract RuntimeZeroAddressTest is UnitBase {
    address internal GOOD = address(0x2A01);

    function setUp() public override {
        super.setUp(); // healthy deploy: both ids resolved at construction time
        _addGood(GOOD, 100);
    }

    function test_BondingManagerUnregistered_AllEntrypointsRevertZeroAddress_ThenHeal() public {
        controller.setContract(BONDING_MANAGER_ID, address(0));

        vm.expectRevert(LivepeerRewardCaller.ZeroAddress.selector);
        rc.rewardAll(0, 0);

        vm.expectRevert(LivepeerRewardCaller.ZeroAddress.selector);
        rc.rewardFor(_arr(GOOD), _zeros(1), _zeros(1), 0);

        vm.expectRevert(LivepeerRewardCaller.ZeroAddress.selector);
        rc.getPendingRewardCalls();

        vm.expectRevert(LivepeerRewardCaller.ZeroAddress.selector);
        rc.filterPendingRewardCalls(_arr(GOOD));

        assertEq(bm.rewardCallsLength(), 0, "no reward attempt under a broken registry");

        // re-registration heals the SAME deployment (per-call resolution, no pinning)
        controller.setContract(BONDING_MANAGER_ID, address(bm));
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);
        assertEq(rewarded, 1);
        assertEq(failed, 0);
        assertTrue(complete);
    }

    function test_RoundsManagerUnregistered_AllEntrypointsRevertZeroAddress_ThenHeal() public {
        controller.setContract(ROUNDS_MANAGER_ID, address(0));

        vm.expectRevert(LivepeerRewardCaller.ZeroAddress.selector);
        rc.rewardAll(0, 0);

        vm.expectRevert(LivepeerRewardCaller.ZeroAddress.selector);
        rc.rewardFor(_arr(GOOD), _zeros(1), _zeros(1), 0);

        // BondingManager resolves first here; RoundsManager resolution must still gate the view
        vm.expectRevert(LivepeerRewardCaller.ZeroAddress.selector);
        rc.getPendingRewardCalls();

        vm.expectRevert(LivepeerRewardCaller.ZeroAddress.selector);
        rc.filterPendingRewardCalls(_arr(GOOD));

        assertEq(bm.rewardCallsLength(), 0, "no reward attempt under a broken registry");

        controller.setContract(ROUNDS_MANAGER_ID, address(rounds));
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);
        assertEq(rewarded, 1);
        assertEq(failed, 0);
        assertTrue(complete);
    }
}
