// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UnitBase} from "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {LivepeerRewardCaller} from "../../src/LivepeerRewardCaller.sol";
import {MockBondingManager} from "./mocks/MockBondingManager.sol";

contract GasBehaviorTest is UnitBase {
    uint256 internal constant BURN = 2_000_000; // per-success gas burn used to drain a bounded tx

    function _buildBurnPool4() internal returns (address[] memory ts) {
        ts = new address[](4);
        for (uint256 i; i < 4; ++i) {
            ts[i] = address(uint160(0xB001 + i));
            _addBurner(ts[i], 1000 - i, BURN);
        }
    }

    // ---------------------------------------------------------------- gas bomb containment

    function test_GasBomb_MidPool_Contained_LaterItemsRewardedSameTx() public {
        address G1 = address(0xC101);
        address BOMB = address(0xC102);
        address G2 = address(0xC103);
        _addGood(G1, 300);
        _addGood(BOMB, 200);
        _addGood(G2, 100);
        bm.setFailureMode(BOMB, MockBondingManager.FailureMode.GasBomb);

        vm.expectEmit(true, true, true, false, address(rc));
        emit RewardCallSucceeded(ROUND, G1, address(this), 0);
        vm.expectEmit(true, true, true, true, address(rc)); // exact: empty revert data (OOG)
        emit RewardCallFailed(ROUND, BOMB, address(this), "");
        vm.expectEmit(true, true, true, false, address(rc));
        emit RewardCallSucceeded(ROUND, G2, address(this), 0);

        // Bounded outer gas: if the bomb's consumption were NOT capped at
        // gasFloor - CALL_GAS_RESERVE, this entire tx would OOG instead of finishing.
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll{gas: 10_000_000}(0, 0);

        assertEq(rewarded, 2, "items AFTER the bomb still rewarded in the SAME tx");
        assertEq(failed, 1, "the bomb is a caught failure");
        assertTrue(complete, "sweep reached the end of the pool");

        assertEq(bm.rewardCallsLength(), 2);
        (, address t0,,,) = bm.rewardCalls(0);
        (, address t1,,,) = bm.rewardCalls(1);
        assertEq(t0, G1);
        assertEq(t1, G2, "post-bomb node rewarded after the bomb, same tx");
        assertEq(bm.rewardCallCountOf(BOMB), 0);
    }

    // ---------------------------------------------------------------- gas floor: truncation without misattribution

    function test_GasFloor_UnderGassed_PartialSweep_NoFailures_StatelessResume() public {
        address[] memory ts = _buildBurnPool4();

        vm.recordLogs();
        (uint256 r1, uint256 f1, bool c1) = rc.rewardAll{gas: 8_000_000}(0, 0);

        assertEq(f1, 0, "gas-floor truncation must never misattribute failures");
        assertFalse(c1, "under-gassed call must report complete == false");
        assertGe(r1, 1, "some progress must have been made");
        assertLt(r1, 4, "but not all of it");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countLogs(logs, SIG_FAILED), 0, "ZERO RewardCallFailed events on truncation");
        (, uint256 processed1,,, bool bc1) = _batchStats(logs);
        assertEq(processed1, r1, "every processed item was rewarded");
        assertFalse(bc1);

        // stateless resume: a fresh call (ample gas) finishes the tail
        (uint256 r2, uint256 f2, bool c2) = rc.rewardAll(0, 0);
        assertEq(f2, 0);
        assertTrue(c2, "follow-up call completes the pool");
        assertEq(r1 + r2, 4, "the two sweeps cover the pool exactly");
        for (uint256 i; i < 4; ++i) {
            assertEq(bm.rewardCallCountOf(ts[i]), 1, "each node rewarded exactly once across both sweeps");
        }
    }

    // ---------------------------------------------------------------- _minGasPerCall raises the floor

    function test_MinGasPerCall_AboveFloor_TruncatesEarlier() public {
        _buildBurnPool4();
        (uint256 rDefault,, bool cDefault) = rc.rewardAll{gas: 8_000_000}(0, 0);
        assertGe(rDefault, 1);
        assertFalse(cDefault);

        // identical fresh setup, but the caller raises the floor above the outer budget:
        // the sweep cannot afford even ONE attempt, so instead of a silent zero-progress
        // no-op it reverts InsufficientGas (loud signal for estimation-driven keepers).
        _freshDeploy();
        _buildBurnPool4();
        vm.expectRevert(LivepeerRewardCaller.InsufficientGas.selector);
        rc.rewardAll{gas: 8_000_000}(0, 9_000_000);
        assertEq(bm.rewardCallsLength(), 0, "no reward attempt was made");
    }

    function test_MinGasPerCall_BelowBuiltinFloor_ClampedUp() public {
        // A reward burning 1M gas succeeds ONLY because the effective floor stays at
        // MIN_CALL_GAS (forwarding cap 2.35M). If _minGasPerCall=200k could LOWER the
        // floor, the cap would be 50k and this call would OOG-fail.
        address T = address(0xC201);
        _addBurner(T, 100, 1_000_000);

        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 200_000);
        assertEq(rewarded, 1, "floor clamped UP: the 1M-gas reward fit under the cap");
        assertEq(failed, 0);
        assertTrue(complete);
    }

    // ---------------------------------------------------------------- pool-size-aware floor

    function test_PoolSizeAwareFloor_RisesWithPoolSize() public {
        // A reward burning 2.45M gas does NOT fit under the MIN_CALL_GAS-derived
        // forwarding cap (2.5M - 150k = 2.35M) ...
        address B = address(0xC301);
        _addBurner(B, 1, 2_450_000);
        _addT(address(0xC302), 2, false, true, 0);
        _addT(address(0xC303), 3, false, true, 0);
        (uint256 r1, uint256 f1, bool c1) = rc.rewardAll(0, 0);
        assertEq(r1, 0, "small pool: 2.45M burn exceeds the 2.35M cap");
        assertEq(f1, 1, "caught as an (empty-data) failure");
        assertTrue(c1);

        // ... but with 200 pool nodes the floor rises to BASE + 200*margin = 3.5M,
        // forwarding cap 3.35M, and the exact same reward now succeeds.
        _freshDeploy();
        _addBurner(B, 1, 2_450_000); // stake 1: tail of the pool
        for (uint256 i; i < 199; ++i) {
            // ascending stakes -> each insert lands at the head in O(1)
            _addT(address(uint160(0xC400 + i)), 10 + i, false, true, 0);
        }
        assertEq(bm.getTranscoderPoolSize(), 200);

        (uint256 r2, uint256 f2, bool c2) = rc.rewardAll(0, 0);
        assertEq(r2, 1, "big pool: the floor (and forwarding cap) rose with pool size");
        assertEq(f2, 0);
        assertTrue(c2);
        assertEq(bm.rewardCallCountOf(B), 1);
    }
}
