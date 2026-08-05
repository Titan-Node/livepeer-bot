// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UnitBase} from "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {LivepeerRewardCaller} from "../../src/LivepeerRewardCaller.sol";
import {MockBondingManager} from "./mocks/MockBondingManager.sol";

contract RewardForTest is UnitBase {
    uint256 internal constant BURN = 2_000_000;

    // ---------------------------------------------------------------- argument validation

    function test_RevertWhen_PrevsLengthMismatch() public {
        vm.expectRevert(LivepeerRewardCaller.LengthMismatch.selector);
        rc.rewardFor(_zeros(2), _zeros(1), _zeros(2), 0);
    }

    function test_RevertWhen_NextsLengthMismatch() public {
        vm.expectRevert(LivepeerRewardCaller.LengthMismatch.selector);
        rc.rewardFor(_zeros(2), _zeros(2), _zeros(3), 0);
    }

    // ---------------------------------------------------------------- hint forwarding

    function test_Hints_ForwardedVerbatim_MixedZeroAndReal() public {
        address A = address(0xA1);
        address B = address(0xB1);
        _addGood(A, 200);
        _addGood(B, 100);
        address X = address(0x1111); // junk hints: forwarded unvalidated
        address Y = address(0x2222);

        address[] memory list = _arr(A, B);
        address[] memory prevs = _zeros(2);
        address[] memory nexts = _zeros(2);
        prevs[0] = X;
        nexts[0] = Y;

        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, address(this), 2, 2, 0, true);
        (uint256 rewarded, uint256 failed, uint256 processed) = rc.rewardFor(list, prevs, nexts, 0);

        assertEq(rewarded, 2);
        assertEq(failed, 0);
        assertEq(processed, 2);

        assertEq(bm.rewardCallsLength(), 2);
        (address c0, address t0, address p0, address n0,) = bm.rewardCalls(0);
        assertEq(c0, address(rc));
        assertEq(t0, A);
        assertEq(p0, X, "prev hint forwarded verbatim");
        assertEq(n0, Y, "next hint forwarded verbatim");
        (, address t1, address p1, address n1,) = bm.rewardCalls(1);
        assertEq(t1, B);
        assertEq(p1, address(0), "(0,0) = hintless, forwarded as-is");
        assertEq(n1, address(0));
    }

    // ---------------------------------------------------------------- duplicates

    function test_DuplicateAddress_SecondOccurrenceSilentlySkipped() public {
        address A = address(0xA1);
        _addGood(A, 100);
        address[] memory list = _arr(A, A);

        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, address(this), 2, 1, 0, true);
        (uint256 rewarded, uint256 failed, uint256 processed) = rc.rewardFor(list, _zeros(2), _zeros(2), 0);

        assertEq(rewarded, 1, "duplicate rewarded only once");
        assertEq(failed, 0, "second occurrence is a silent skip, not a failure");
        assertEq(processed, 2, "both items consumed");
        assertEq(bm.rewardCallCountOf(A), 1);
    }

    // ---------------------------------------------------------------- empty arrays

    function test_EmptyArrays_ValidNoop_StillRunsPreflight() public {
        _setRound(ROUND, false); // round needs initializing

        vm.expectEmit(true, true, true, true, address(rc));
        emit RoundInitialized(ROUND, address(this));
        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, address(this), 0, 0, 0, true);
        (uint256 rewarded, uint256 failed, uint256 processed) = rc.rewardFor(_zeros(0), _zeros(0), _zeros(0), 0);

        assertEq(rewarded, 0);
        assertEq(failed, 0);
        assertEq(processed, 0);
        assertEq(rounds.initializeRoundCalls(), 1, "empty call still initialized the round");
        assertTrue(rounds.currentRoundInitialized());
    }

    // ---------------------------------------------------------------- skips

    function test_UnknownAndIneligibleAddresses_SilentlySkipped() public {
        address STRANGER = address(0xDEAD1); // never added to the pool, no flags at all
        address INACTIVE = address(0xA2);
        address REWARDED = address(0xA3);
        address GOOD = address(0xA4);
        _addT(INACTIVE, 300, true, false, 0);
        _addT(REWARDED, 200, true, true, ROUND);
        _addGood(GOOD, 100);

        address[] memory list = _arr(STRANGER, INACTIVE, REWARDED, GOOD);
        (uint256 rewarded, uint256 failed, uint256 processed) = rc.rewardFor(list, _zeros(4), _zeros(4), 0);

        assertEq(rewarded, 1);
        assertEq(failed, 0, "skips are silent");
        assertEq(processed, 4);
        assertEq(bm.rewardCallsLength(), 1);
        assertEq(bm.rewardCallCountOf(GOOD), 1);
    }

    function test_FailuresCounted_BatchStillCompletes() public {
        address G = address(0xA1);
        address F = address(0xB1);
        _addGood(G, 200);
        _addGood(F, 100);
        bm.setFailureMode(F, MockBondingManager.FailureMode.RevertString);

        address[] memory list = _arr(G, F);
        vm.expectEmit(true, true, true, true, address(rc));
        emit RewardCallFailed(
            ROUND, F, address(this), abi.encodeWithSignature("Error(string)", "MOCK_REWARD_STRING_FAILURE")
        );
        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, address(this), 2, 1, 1, true);
        (uint256 rewarded, uint256 failed, uint256 processed) = rc.rewardFor(list, _zeros(2), _zeros(2), 0);
        assertEq(rewarded, 1);
        assertEq(failed, 1);
        assertEq(processed, 2);
    }

    // ---------------------------------------------------------------- gas-floor truncation + exact tail resubmission

    function test_Truncation_ProcessedSupportsExactTailResubmission() public {
        address[] memory ts = new address[](4);
        for (uint256 i; i < 4; ++i) {
            ts[i] = address(uint160(0xB001 + i));
            _addBurner(ts[i], 1000 - i, BURN);
        }

        vm.recordLogs();
        (uint256 r1, uint256 f1, uint256 p1) = rc.rewardFor{gas: 8_000_000}(ts, _zeros(4), _zeros(4), 0);

        assertEq(f1, 0);
        assertGe(p1, 1);
        assertLt(p1, 4, "under-gassed call must truncate");
        assertEq(r1, p1, "every consumed item was rewarded");
        (, uint256 bp1,,, bool bc1) = _batchStats(vm.getRecordedLogs());
        assertEq(bp1, p1, "BatchProcessed.processed == returned processed");
        assertFalse(bc1, "BatchProcessed.complete == (processed == len) == false");

        // resubmit EXACTLY the tail _transcoders[processed:]
        uint256 tailLen = 4 - p1;
        address[] memory tail = new address[](tailLen);
        for (uint256 i; i < tailLen; ++i) {
            tail[i] = ts[p1 + i];
        }
        vm.recordLogs();
        (uint256 r2, uint256 f2, uint256 p2) = rc.rewardFor(tail, _zeros(tailLen), _zeros(tailLen), 0);

        assertEq(p2, tailLen);
        assertEq(f2, 0);
        assertEq(r2, tailLen, "the exact tail finishes the job - nothing missed, nothing repeated");
        (,,,, bool bc2) = _batchStats(vm.getRecordedLogs());
        assertTrue(bc2, "BatchProcessed.complete == (processed == len) == true");
        for (uint256 i; i < 4; ++i) {
            assertEq(bm.rewardCallCountOf(ts[i]), 1, "each transcoder rewarded exactly once across the two calls");
        }
    }
}
