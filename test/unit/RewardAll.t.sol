// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UnitBase} from "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockBondingManager} from "./mocks/MockBondingManager.sol";

contract RewardAllTest is UnitBase {
    // mixed-pool cast
    address internal A = address(0xA1); // subscribed + active + unrewarded -> reward
    address internal B = address(0xB1); // NOT subscribed                   -> skip
    address internal C = address(0xC1); // subscribed, already rewarded     -> skip
    address internal D = address(0xD1); // subscribed, inactive             -> skip
    address internal E = address(0xE1); // subscribed + active + unrewarded -> reward
    address internal F = address(0xF1); // subscribed to a DIFFERENT caller -> skip

    function _buildMixedPool() internal {
        _addT(A, 600, true, true, 0);
        _addT(B, 500, false, true, 0);
        _addT(C, 400, true, true, ROUND); // rewarded this round already
        _addT(D, 300, true, false, 0); // inactive this round
        _addT(E, 200, true, true, ROUND - 1); // last rewarded previous round
        _addT(F, 100, false, true, 0);
        bm.setRewardCallerFor(F, makeAddr("other-reward-caller"));
    }

    // ---------------------------------------------------------------- happy path

    function test_HappyPath_MixedPool_ExactReturnsEventsAndLog() public {
        _buildMixedPool();

        vm.expectEmit(true, true, true, false, address(rc)); // gasUsed unchecked
        emit RewardCallSucceeded(ROUND, A, keeper, 0);
        vm.expectEmit(true, true, true, false, address(rc));
        emit RewardCallSucceeded(ROUND, E, keeper, 0);
        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, keeper, 6, 2, 0, true);

        vm.prank(keeper);
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);

        assertEq(rewarded, 2, "exactly the two eligible transcoders");
        assertEq(failed, 0);
        assertTrue(complete);

        // exactly-once semantics, straight from the mock's log
        assertEq(bm.rewardCallsLength(), 2);
        (address c0, address t0, address p0, address n0, uint256 r0) = bm.rewardCalls(0);
        assertEq(c0, address(rc), "reward must be called BY the reward caller contract");
        assertEq(t0, A, "pool order: A first");
        assertEq(p0, address(0), "rewardAll is hintless");
        assertEq(n0, address(0), "rewardAll is hintless");
        assertEq(r0, ROUND);
        (, address t1, address p1, address n1,) = bm.rewardCalls(1);
        assertEq(t1, E, "pool order: E second");
        assertEq(p1, address(0));
        assertEq(n1, address(0));

        assertEq(bm.rewardCallCountOf(A), 1);
        assertEq(bm.rewardCallCountOf(E), 1);
        assertEq(bm.rewardCallCountOf(B), 0);
        assertEq(bm.rewardCallCountOf(C), 0);
        assertEq(bm.rewardCallCountOf(D), 0);
        assertEq(bm.rewardCallCountOf(F), 0);

        // protocol state advanced only for the rewarded pair
        assertEq(bm.lastRewardRoundOf(A), ROUND);
        assertEq(bm.lastRewardRoundOf(E), ROUND);
        assertEq(bm.lastRewardRoundOf(B), 0);
        assertEq(bm.lastRewardRoundOf(C), ROUND); // unchanged (was already ROUND)
        assertEq(bm.lastRewardRoundOf(D), 0);
        assertEq(bm.lastRewardRoundOf(F), 0);
    }

    // ---------------------------------------------------------------- idempotency

    function test_Idempotent_ImmediateRepeat_ZeroWorkCompleteTrue() public {
        _buildMixedPool();
        rc.rewardAll(0, 0);
        assertEq(bm.rewardCallsLength(), 2);

        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, address(this), 6, 0, 0, true);
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);

        assertEq(rewarded, 0, "repeat sweep must reward nothing");
        assertEq(failed, 0, "repeat sweep must fail nothing");
        assertTrue(complete);
        assertEq(bm.rewardCallsLength(), 2, "zero reward calls recorded on repeat");
    }

    // ---------------------------------------------------------------- skip matrix + pre-check order

    function test_SkipMatrix_AllSkipped_DoomedCallNeverMade_TraceOrdered() public {
        address U = address(0xAA01); // unsubscribed
        address R = address(0xAA02); // already rewarded
        address I = address(0xAA03); // inactive
        _addT(U, 300, false, true, 0);
        _addT(R, 200, true, true, ROUND);
        _addT(I, 100, true, false, 0);

        vm.record();
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(bm));

        assertEq(rewarded, 0);
        assertEq(failed, 0, "skips are silent, never failures");
        assertTrue(complete);
        assertEq(bm.rewardCallsLength(), 0, "doomed rewardForTranscoderWithHint must NEVER be made");
        assertEq(writes.length, 0, "a fully-skipped sweep must not write the BondingManager at all");

        // pre-check invocation order, per node, from the storage-read trace:
        //   U: [a] only; R: [a][b]; I: [a][b][c]
        (uint8[] memory tags, address[] memory whos) = _precheckTrace(reads, _arr(U, R, I));
        assertEq(tags.length, 6, "exact number of pre-check reads");
        assertEq(tags[0], 1);
        assertEq(whos[0], U);
        assertEq(tags[1], 1);
        assertEq(whos[1], R);
        assertEq(tags[2], 2);
        assertEq(whos[2], R);
        assertEq(tags[3], 1);
        assertEq(whos[3], I);
        assertEq(tags[4], 2);
        assertEq(whos[4], I);
        assertEq(tags[5], 3);
        assertEq(whos[5], I);
    }

    function test_PrecheckOrder_FullChain_A_then_B_then_C() public {
        address T = address(0xAB01);
        _addT(T, 100, true, true, 0); // passes all three -> attempted
        vm.record();
        (uint256 rewarded,,) = rc.rewardAll(0, 0);
        (bytes32[] memory reads,) = vm.accesses(address(bm));
        assertEq(rewarded, 1);
        (uint8[] memory tags, address[] memory whos) = _precheckTrace(reads, _arr(T));
        // pre-checks [a][b][c] strictly first; the reward call itself then re-touches
        // the access-check slot [a] and finally WRITES lastRewardRound (a write records
        // as a read too), giving the tail ...,1,2.
        assertGe(tags.length, 3);
        assertEq(tags[0], 1, "[a] transcoderToRewardCaller first");
        assertEq(tags[1], 2, "[b] getTranscoder second");
        assertEq(tags[2], 3, "[c] isActiveTranscoder third");
        for (uint256 i; i < 3; ++i) {
            assertEq(whos[i], T);
        }
    }

    function test_PrecheckOrder_ShortCircuit_AlreadyRewarded_SkipsC() public {
        address T = address(0xAB02);
        _addT(T, 100, true, true, ROUND); // [b] short-circuits
        vm.record();
        rc.rewardAll(0, 0);
        (bytes32[] memory reads,) = vm.accesses(address(bm));
        (uint8[] memory tags,) = _precheckTrace(reads, _arr(T));
        assertEq(tags.length, 2, "[c] must not be invoked when [b] short-circuits");
        assertEq(tags[0], 1);
        assertEq(tags[1], 2);
        assertEq(bm.rewardCallsLength(), 0);
    }

    function test_PrecheckOrder_ShortCircuit_NotSubscribed_SkipsBandC() public {
        address T = address(0xAB03);
        _addT(T, 100, false, true, 0); // [a] short-circuits
        vm.record();
        rc.rewardAll(0, 0);
        (bytes32[] memory reads,) = vm.accesses(address(bm));
        (uint8[] memory tags,) = _precheckTrace(reads, _arr(T));
        assertEq(tags.length, 1, "[b] and [c] must not be invoked when [a] short-circuits");
        assertEq(tags[0], 1);
        assertEq(bm.rewardCallsLength(), 0);
    }

    // ---------------------------------------------------------------- failure isolation

    function test_FailureIsolation_MixedRevertShapes_ExactBytes_BatchNeverReverts() public {
        address G1 = address(0xF001);
        address RS = address(0xF002); // Error(string)
        address G2 = address(0xF003);
        address RC_ = address(0xF004); // custom error
        address G3 = address(0xF005);
        _addGood(G1, 500);
        _addGood(RS, 400);
        _addGood(G2, 300);
        _addGood(RC_, 200);
        _addGood(G3, 100);
        bm.setFailureMode(RS, MockBondingManager.FailureMode.RevertString);
        bm.setFailureMode(RC_, MockBondingManager.FailureMode.RevertCustom);

        vm.expectEmit(true, true, true, false, address(rc));
        emit RewardCallSucceeded(ROUND, G1, address(this), 0);
        vm.expectEmit(true, true, true, true, address(rc));
        emit RewardCallFailed(
            ROUND, RS, address(this), abi.encodeWithSignature("Error(string)", "MOCK_REWARD_STRING_FAILURE")
        );
        vm.expectEmit(true, true, true, false, address(rc));
        emit RewardCallSucceeded(ROUND, G2, address(this), 0);
        vm.expectEmit(true, true, true, true, address(rc));
        emit RewardCallFailed(
            ROUND, RC_, address(this), abi.encodeWithSelector(MockBondingManager.RewardBroken.selector, RC_, 42)
        );
        vm.expectEmit(true, true, true, false, address(rc));
        emit RewardCallSucceeded(ROUND, G3, address(this), 0);
        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, address(this), 5, 3, 2, true);

        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);
        assertEq(rewarded, 3);
        assertEq(failed, 2);
        assertTrue(complete, "failures must not stop the sweep");

        // only the successes reached the mock's bookkeeping
        assertEq(bm.rewardCallsLength(), 3);
        assertEq(bm.rewardCallCountOf(RS), 0);
        assertEq(bm.rewardCallCountOf(RC_), 0);
        // failed transcoders remain pending (protocol state untouched)
        assertEq(bm.lastRewardRoundOf(RS), 0);
        assertEq(bm.lastRewardRoundOf(RC_), 0);
    }

    function test_FailureIsolation_EmptyRevertData() public {
        address T = address(0xF010);
        _addGood(T, 100);
        bm.setFailureMode(T, MockBondingManager.FailureMode.RevertEmpty);

        vm.expectEmit(true, true, true, true, address(rc));
        emit RewardCallFailed(ROUND, T, address(this), "");
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);
        assertEq(rewarded, 0);
        assertEq(failed, 1);
        assertTrue(complete);
    }

    // ---------------------------------------------------------------- _maxRewards semantics

    function test_MaxRewards_BoundsAttempts_AllFailingPool() public {
        // 5 all-failing transcoders; _maxRewards = 3 must yield EXACTLY 3 attempts.
        for (uint256 i; i < 5; ++i) {
            address t = address(uint160(0xE000 + i));
            _addGood(t, 1000 - i);
            bm.setFailureMode(t, MockBondingManager.FailureMode.RevertString);
        }

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, address(this), 3, 0, 3, false);
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(3, 0);

        assertEq(rewarded, 0);
        assertEq(failed, 3, "attempts (rewarded+failed) capped at _maxRewards");
        assertFalse(complete, "truncation by _maxRewards must report complete == false");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countLogs(logs, SIG_FAILED), 3, "exactly 3 attempts were made");
    }

    function test_MaxRewards_Zero_MeansUnbounded() public {
        for (uint256 i; i < 5; ++i) {
            address t = address(uint160(0xE100 + i));
            _addGood(t, 1000 - i);
            bm.setFailureMode(t, MockBondingManager.FailureMode.RevertString);
        }
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);
        assertEq(rewarded, 0);
        assertEq(failed, 5, "0 = unbounded: all five attempted");
        assertTrue(complete);
    }

    function test_MaxRewards_SkipsDoNotConsumeAttempts() public {
        address U1 = address(0xE201); // unsubscribed
        address U2 = address(0xE202); // unsubscribed
        address G = address(0xE203); // good
        address G2 = address(0xE204); // good, but beyond the attempt budget
        _addT(U1, 400, false, true, 0);
        _addT(U2, 300, false, true, 0);
        _addGood(G, 200);
        _addGood(G2, 100);

        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, address(this), 3, 1, 0, false);
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(1, 0);

        assertEq(rewarded, 1, "the two skips must not consume the single attempt");
        assertEq(failed, 0);
        assertFalse(complete, "budget exhausted before G2");
        assertEq(bm.rewardCallCountOf(G), 1);
        assertEq(bm.rewardCallCountOf(G2), 0);
    }

    // ---------------------------------------------------------------- empty pool

    function test_EmptyPool_CompleteTrueZeroWork() public {
        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, address(this), 0, 0, 0, true);
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);
        assertEq(rewarded, 0);
        assertEq(failed, 0);
        assertTrue(complete);
    }

    // ---------------------------------------------------------------- re-sort safety

    function test_ResortSafety_MovedNodesStillRewardedExactlyOnce() public {
        address[5] memory ts = [address(0xD001), address(0xD002), address(0xD003), address(0xD004), address(0xD005)];
        for (uint256 i; i < 5; ++i) {
            _addGood(ts[i], 500 - i * 100);
        }
        bm.setMoveOnReward(true); // every reward moves the node to the pool head

        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);
        assertEq(rewarded, 5, "every subscribed node rewarded despite re-sorting");
        assertEq(failed, 0);
        assertTrue(complete);
        assertEq(bm.rewardCallsLength(), 5);
        for (uint256 i; i < 5; ++i) {
            assertEq(bm.rewardCallCountOf(ts[i]), 1, "exactly once");
            // sweep visited in ORIGINAL pool order thanks to next-before-reward capture
            (, address t_,,,) = bm.rewardCalls(i);
            assertEq(t_, ts[i]);
        }

        // prove the re-sort actually happened: final order is fully reversed
        address[] memory order = _walkPool();
        for (uint256 i; i < 5; ++i) {
            assertEq(order[i], ts[4 - i], "mock must have moved every rewarded node to head");
        }

        // and the follow-up sweep is a no-op
        (uint256 r2, uint256 f2, bool c2) = rc.rewardAll(0, 0);
        assertEq(r2, 0);
        assertEq(f2, 0);
        assertTrue(c2);
    }

    // ---------------------------------------------------------------- real opt-in / opt-out path

    function test_SubscribeAndUnsubscribe_ViaRealSetRewardCaller() public {
        address T = address(0xD100);
        _addT(T, 100, false, true, 0);

        // opt in from the transcoder key
        vm.prank(T);
        bm.setRewardCaller(address(rc));
        (uint256 rewarded,,) = rc.rewardAll(0, 0);
        assertEq(rewarded, 1);
        assertEq(bm.rewardCallCountOf(T), 1);

        // opt out, next round: nothing to do
        vm.prank(T);
        bm.setRewardCaller(address(0));
        _setRound(ROUND + 1, true);
        (uint256 r2, uint256 f2, bool c2) = rc.rewardAll(0, 0);
        assertEq(r2, 0);
        assertEq(f2, 0);
        assertTrue(c2);
        assertEq(bm.rewardCallCountOf(T), 1, "no further calls after opt-out");
    }
}
