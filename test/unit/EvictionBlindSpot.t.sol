// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UnitBase} from "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The mid-round eviction blind spot, documented AND its mitigation covered.
///
///         The real BondingManager (tryToJoinActiveSet tail-kick, resignTranscoder,
///         slashing) removes a transcoder from the pool IMMEDIATELY while leaving it
///         `isActiveTranscoder() == true` and reward-eligible for the rest of the round
///         (deactivationRound == currentRound + 1). The pool this contract walks is the
///         NEXT-round set, so:
///           * rewardAll / getPendingRewardCalls CANNOT see the evictee (blind spot), and
///           * filterPendingRewardCalls + rewardFor form the rescue lane keepers use
///             after discovering the evictee off-chain.
contract EvictionBlindSpotTest is UnitBase {
    address internal HEAD_T = address(0xEB01); // stays in pool, eligible
    address internal EVICTEE = address(0xEB02); // kicked out mid-round, still eligible
    address internal TAIL_T = address(0xEB03); // stays in pool, eligible

    /// @dev Three eligible nodes; the middle one is then unlinked from the pool the way
    ///      the protocol does it mid-round: pool removal ONLY — subscription, active
    ///      flag, and lastRewardRound are untouched.
    function _buildEvictedScenario() internal {
        _addGood(HEAD_T, 600);
        _addGood(EVICTEE, 400);
        _addGood(TAIL_T, 200);
        bm.removeFromPool(EVICTEE);

        // the modeled protocol state: reward-eligible yet invisible to the pool walk
        assertTrue(bm.isActiveTranscoder(EVICTEE), "evictee stays active until the round ends");
        assertEq(bm.transcoderToRewardCaller(EVICTEE), address(rc), "evictee stays subscribed");
        assertEq(bm.lastRewardRoundOf(EVICTEE), 0, "evictee not yet rewarded");
        assertEq(bm.getTranscoderPoolSize(), 2, "pool walk can no longer reach the evictee");
    }

    // ---------------------------------------------------------------- the blind spot itself

    function test_Eviction_RewardAllFullSweep_MissesEvictee_CompleteTrueZeroFailures() public {
        _buildEvictedScenario();

        vm.recordLogs();
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);

        assertEq(rewarded, 2, "only the two still-in-pool nodes rewarded");
        assertEq(failed, 0, "the miss is a BLIND SPOT, not a failure");
        assertTrue(complete, "sweep believes it is done - nothing signals the evictee");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countLogs(logs, SIG_SUCCEEDED), 2);
        assertEq(_countLogs(logs, SIG_FAILED), 0, "zero RewardCallFailed events");
        (, uint256 processed,,, bool bc) = _batchStats(logs);
        assertEq(processed, 2, "the evictee was never even scanned");
        assertTrue(bc);

        assertEq(bm.rewardCallCountOf(HEAD_T), 1);
        assertEq(bm.rewardCallCountOf(TAIL_T), 1);
        assertEq(bm.rewardCallCountOf(EVICTEE), 0, "documented: rewardAll does NOT reward the evictee");
        assertEq(bm.lastRewardRoundOf(EVICTEE), 0, "evictee still unrewarded after a full sweep");
    }

    function test_Eviction_GetPendingRewardCalls_OmitsEvictee() public {
        _buildEvictedScenario();

        address[] memory pending = rc.getPendingRewardCalls();
        address[] memory expected = new address[](2);
        expected[0] = HEAD_T;
        expected[1] = TAIL_T;
        assertEq(pending, expected, "pool-walk view is blind to the eligible evictee");
    }

    // ---------------------------------------------------------------- the mitigation lane

    function test_Eviction_FilterPendingRewardCalls_ExactEligibleSubset_WithDuplicates() public {
        _buildEvictedScenario();
        // extra ineligible candidates, each failing exactly one predicate leg
        address STRANGER = address(0xEB10); // never seen: unsubscribed, inactive, no pool state
        address REWARDED = address(0xEB11); // subscribed + active, already rewarded this round
        address INACTIVE = address(0xEB12); // subscribed, inactive
        address UNSUB = address(0xEB13); // active, not subscribed
        _addT(REWARDED, 150, true, true, ROUND);
        _addT(INACTIVE, 140, true, false, 0);
        _addT(UNSUB, 130, false, true, 0);

        address[] memory candidates = new address[](7);
        candidates[0] = EVICTEE;
        candidates[1] = STRANGER;
        candidates[2] = REWARDED;
        candidates[3] = HEAD_T; // eligible in-pool node passes too
        candidates[4] = INACTIVE;
        candidates[5] = EVICTEE; // duplicate eligible candidate -> duplicate entry
        candidates[6] = UNSUB;

        address[] memory expected = new address[](3);
        expected[0] = EVICTEE;
        expected[1] = HEAD_T;
        expected[2] = EVICTEE;

        assertEq(
            rc.filterPendingRewardCalls(candidates),
            expected,
            "exact eligible subset: evictee visible (no pool walk), duplicates preserved, ineligible dropped"
        );
    }

    function test_Eviction_RewardFor_RescuePath_RewardsEvictee() public {
        _buildEvictedScenario();

        vm.expectEmit(true, true, true, false, address(rc));
        emit RewardCallSucceeded(ROUND, EVICTEE, address(this), 0);
        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, address(this), 1, 1, 0, true);

        (uint256 rewarded, uint256 failed, uint256 processed) = rc.rewardFor(_arr(EVICTEE), _zeros(1), _zeros(1), 0);

        assertEq(rewarded, 1, "rewardFor CAN reward the evictee - the rescue path");
        assertEq(failed, 0);
        assertEq(processed, 1);
        assertEq(bm.rewardCallCountOf(EVICTEE), 1);
        assertEq(bm.lastRewardRoundOf(EVICTEE), ROUND, "protocol state stamped");

        // rescued once -> the filter no longer lists it (dedup by effect)
        assertEq(rc.filterPendingRewardCalls(_arr(EVICTEE)).length, 0, "rescued evictee no longer pending");

        // and the in-pool nodes were never affected by the rescue
        address[] memory pending = rc.getPendingRewardCalls();
        address[] memory expected = new address[](2);
        expected[0] = HEAD_T;
        expected[1] = TAIL_T;
        assertEq(pending, expected);
    }
}
