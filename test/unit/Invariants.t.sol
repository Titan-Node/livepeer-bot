// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UnitBase} from "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Self-destructing ETH donor: force-feeds balance to a target that has no
///      payable surface at all.
contract Donor {
    constructor() payable {}

    function detonate(address payable _target) external {
        selfdestruct(_target);
    }
}

contract InvariantsTest is UnitBase {
    struct FuzzPool {
        address[] ts;
        bool[] eligible;
        uint256[] lrr0;
        uint256 expectedCount;
    }

    FuzzPool internal fp;

    /// @dev Build a random pool: composition, subscription, active and pre-rewarded
    ///      flags all derived from the seed. Stored in `fp` to keep test frames shallow.
    function _buildFuzzPool(bytes32 seed, uint256 n) internal {
        delete fp;
        for (uint256 i; i < n; ++i) {
            address t = address(uint160(0xA000 + i));
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            bool subscribed = h & 1 != 0;
            bool active = h & 2 != 0;
            bool preRewarded = h & 4 != 0;
            uint256 lrr = preRewarded ? ROUND : ((h & 8 != 0) ? ROUND - 1 : 0);
            _addT(t, (h >> 200), subscribed, active, lrr);
            fp.ts.push(t);
            fp.lrr0.push(lrr);
            bool ok = subscribed && active && !preRewarded;
            fp.eligible.push(ok);
            if (ok) fp.expectedCount++;
        }
    }

    function _assertCallerStateless() internal {
        (bytes32[] memory selfReads, bytes32[] memory selfWrites) = vm.accesses(address(rc));
        assertEq(selfWrites.length, 0, "reward caller must NEVER write its own storage");
        assertEq(selfReads.length, 0, "reward caller has no storage to read");
    }

    function _assertBatchLogs(uint256 n, uint256 rewarded, uint256 failed) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 batches, uint256 processed, uint256 evRewarded, uint256 evFailed, bool evComplete) = _batchStats(logs);
        assertEq(batches, 1, "exactly one BatchProcessed per invocation");
        assertEq(processed, n, "every pool node scanned exactly once");
        assertEq(evRewarded, rewarded);
        assertEq(evFailed, failed);
        assertTrue(evComplete);
        // accounting identity: rewarded + failed + skips == processed
        assertEq(processed - rewarded - failed, n - fp.expectedCount, "skip accounting");
        assertEq(_countLogs(logs, SIG_SUCCEEDED), fp.expectedCount);
        assertEq(_countLogs(logs, SIG_FAILED), 0);
    }

    function _assertPerNodeState() internal view {
        for (uint256 i; i < fp.ts.length; ++i) {
            if (fp.eligible[i]) {
                assertEq(bm.lastRewardRoundOf(fp.ts[i]), ROUND, "eligible node stamped with the round");
                assertEq(bm.rewardCallCountOf(fp.ts[i]), 1, "rewarded exactly once");
            } else {
                assertEq(bm.rewardCallCountOf(fp.ts[i]), 0, "ineligible node never called");
                assertEq(bm.lastRewardRoundOf(fp.ts[i]), fp.lrr0[i], "ineligible node state untouched");
            }
        }
    }

    /// @notice Random pool composition + subscription + pre-rewarded flags + optional
    ///         re-sorting + force-fed ETH: after rewardAll(0,0) with ample gas, every
    ///         subscribed+active+unrewarded transcoder has lastRewardRound == round,
    ///         the accounting identity holds, and the caller wrote ZERO storage.
    function testFuzz_RewardAll_SweepInvariants(bytes32 seed, bool moveOnReward, bool feedEth) public {
        uint256 n = uint256(seed) % 17; // 0..16
        _buildFuzzPool(seed, n);
        bm.setMoveOnReward(moveOnReward);
        if (feedEth) vm.deal(address(rc), 33 ether);

        vm.recordLogs();
        vm.record();
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);

        _assertCallerStateless();
        assertTrue(complete);
        assertEq(failed, 0);
        assertEq(rewarded, fp.expectedCount, "exactly the eligible set rewarded");
        _assertBatchLogs(n, rewarded, failed);
        _assertPerNodeState();

        // idempotency under fuzz: the immediate repeat does zero work
        (uint256 r2, uint256 f2, bool c2) = rc.rewardAll(0, 0);
        assertEq(r2, 0);
        assertEq(f2, 0);
        assertTrue(c2);
        assertEq(bm.rewardCallsLength(), fp.expectedCount, "no new reward calls on repeat");

        if (feedEth) {
            assertEq(address(rc).balance, 33 ether, "balance never moves");
        }
    }

    // ---------------------------------------------------------------- rewardFor with junk hints

    function _buildGoodPool(bytes32 seed, uint256 n) internal returns (address[] memory ts) {
        ts = new address[](n);
        for (uint256 i; i < n; ++i) {
            ts[i] = address(uint160(0xB000 + i));
            _addGood(ts[i], uint256(keccak256(abi.encode(seed, "s", i))) % 1e9);
        }
    }

    function _junkHintLists(bytes32 seed, address[] memory ts)
        internal
        pure
        returns (address[] memory list, address[] memory prevs, address[] memory nexts)
    {
        uint256 n = ts.length;
        uint256 len = n + 2;
        list = new address[](len);
        prevs = new address[](len);
        nexts = new address[](len);
        for (uint256 i; i < n; ++i) {
            list[i] = ts[i];
        }
        list[n] = ts[0]; // duplicate
        list[n + 1] = address(0xF00D); // stranger: not in pool, not subscribed
        for (uint256 i; i < len; ++i) {
            prevs[i] = address(uint160(uint256(keccak256(abi.encode(seed, "p", i)))));
            nexts[i] = address(uint160(uint256(keccak256(abi.encode(seed, "n", i)))));
        }
    }

    /// @notice rewardFor with junk hints, a duplicate, and a stranger mixed in: hints are
    ///         pass-through, every real transcoder is rewarded exactly once, no failures.
    function testFuzz_RewardFor_JunkHintsSafe(bytes32 seed) public {
        uint256 n = 1 + (uint256(seed) % 12);
        address[] memory ts = _buildGoodPool(seed, n);
        (address[] memory list, address[] memory prevs, address[] memory nexts) = _junkHintLists(seed, ts);

        vm.record();
        (uint256 rewarded, uint256 failed, uint256 processed) = rc.rewardFor(list, prevs, nexts, 0);

        _assertCallerStateless();
        assertEq(processed, n + 2, "all items consumed");
        assertEq(failed, 0, "junk hints can never cause a failure (mock is hint-agnostic)");
        assertEq(rewarded, n, "every real transcoder once; duplicate and stranger skipped");
        assertEq(bm.rewardCallsLength(), n);
        for (uint256 i; i < n; ++i) {
            assertEq(bm.rewardCallCountOf(ts[i]), 1);
            // hints recorded verbatim, in call order
            (,, address p, address x,) = bm.rewardCalls(i);
            assertEq(p, prevs[i], "junk prev hint forwarded untouched");
            assertEq(x, nexts[i], "junk next hint forwarded untouched");
        }
        assertEq(bm.rewardCallCountOf(address(0xF00D)), 0);
    }

    // ---------------------------------------------------------------- statelessness, explicitly

    function test_NoStorageWrites_EvenAcrossInitFailuresAndSkips() public {
        _setRound(ROUND, false); // forces the initializeRound path too
        _addGood(address(0xA1), 300);
        _addT(address(0xB1), 200, false, true, 0);
        _addT(address(0xC1), 100, true, false, 0);

        vm.record();
        rc.rewardAll(0, 0);
        rc.rewardFor(_arr(address(0xA1)), _zeros(1), _zeros(1), 0);
        rc.getPendingRewardCalls();
        rc.getHints(_arr(address(0xA1)));

        _assertCallerStateless();
    }

    // ---------------------------------------------------------------- force-fed ETH

    function test_ForceFedEther_ViaSelfdestruct_BehaviorIdentical() public {
        address A = address(0xA1);
        address B = address(0xB1);
        _addGood(A, 200);
        _addT(B, 100, true, true, ROUND); // skip case stays a skip case

        Donor donor = new Donor{value: 1 ether}();
        donor.detonate(payable(address(rc)));
        assertEq(address(rc).balance, 1 ether, "balance force-fed");

        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, address(this), 2, 1, 0, true);
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);
        assertEq(rewarded, 1);
        assertEq(failed, 0);
        assertTrue(complete);
        assertEq(bm.rewardCallCountOf(A), 1);
        assertEq(address(rc).balance, 1 ether, "balance never affects or is affected by anything");

        // views unaffected as well
        assertEq(rc.getPendingRewardCalls().length, 0);
    }
}
