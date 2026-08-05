// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UnitBase} from "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {LivepeerRewardCaller} from "../../src/LivepeerRewardCaller.sol";

/// @notice The InsufficientGas boundary: a tx that cannot afford even ONE reward
///         attempt (gas floor broken with processed == 0) REVERTS loudly instead of
///         silently no-opping — but mid-sweep truncation (processed > 0) and genuinely
///         empty work sets still return gracefully.
contract InsufficientGasTest is UnitBase {
    uint256 internal constant BURN = 2_000_000; // per-success burn used to drain a bounded tx

    // For small pools the effective floor is MIN_CALL_GAS (2.5M); an outer budget of
    // 2.4M reaches the first floor check with processed == 0 and gasleft() < floor.
    uint256 internal constant BELOW_FLOOR_GAS = 2_400_000;
    // Far below the floor yet ample for preflight + an empty walk + the batch event.
    uint256 internal constant TINY_GAS = 300_000;

    // ---------------------------------------------------------------- zero-progress -> revert

    function test_RewardAll_CannotAffordOneAttempt_RevertsInsufficientGas_NoCallsRecorded() public {
        _addGood(address(0x1601), 100); // non-empty pool

        vm.expectRevert(LivepeerRewardCaller.InsufficientGas.selector);
        rc.rewardAll{gas: BELOW_FLOOR_GAS}(0, 0);

        assertEq(bm.rewardCallsLength(), 0, "zero reward calls recorded");
        assertEq(bm.lastRewardRoundOf(address(0x1601)), 0, "no protocol state advanced");
    }

    function test_RewardFor_CannotAffordOneItem_RevertsInsufficientGas_NoCallsRecorded() public {
        address T = address(0x1602);
        _addGood(T, 100);

        vm.expectRevert(LivepeerRewardCaller.InsufficientGas.selector);
        rc.rewardFor{gas: BELOW_FLOOR_GAS}(_arr(T), _zeros(1), _zeros(1), 0);

        assertEq(bm.rewardCallsLength(), 0, "zero reward calls recorded");
        assertEq(bm.lastRewardRoundOf(T), 0, "no protocol state advanced");
    }

    // ---------------------------------------------------------------- progress made -> graceful truncation

    function test_RewardAll_MidSweepFloorBreak_TruncatesGracefully_NoRevert() public {
        // 4 burner nodes at ~2M each: an 8M budget affords >= 1 but < 4 attempts, so the
        // floor breaks MID-sweep — the contrast case to the reverts above.
        address[] memory ts = new address[](4);
        for (uint256 i; i < 4; ++i) {
            ts[i] = address(uint160(0x1611 + i));
            _addBurner(ts[i], 1000 - i, BURN);
        }

        vm.recordLogs();
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll{gas: 8_000_000}(0, 0);

        assertGe(rewarded, 1, "at least one attempt was afforded");
        assertLt(rewarded, 4, "the floor then truncated the sweep");
        assertEq(failed, 0, "truncation misattributes nothing");
        assertFalse(complete, "graceful signal: complete == false, NO revert");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countLogs(logs, SIG_FAILED), 0);
        (uint256 batches,,,, bool bc) = _batchStats(logs);
        assertEq(batches, 1, "BatchProcessed still emitted on truncation");
        assertFalse(bc);
    }

    // ---------------------------------------------------------------- empty work sets -> clean return, never revert

    function test_RewardAll_EmptyPool_TinyButPreflightSufficientGas_CleanReturn() public {
        // gasleft() is far below the 2.5M floor for the entire call, but the empty pool
        // never consults the floor: this must NOT revert.
        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, address(this), 0, 0, 0, true);
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll{gas: TINY_GAS}(0, 0);

        assertEq(rewarded, 0);
        assertEq(failed, 0);
        assertTrue(complete, "empty pool: clean rewarded=0 / complete=true return");
    }

    function test_RewardFor_EmptyArrays_TinyButPreflightSufficientGas_CleanNoop() public {
        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND, address(this), 0, 0, 0, true);
        (uint256 rewarded, uint256 failed, uint256 processed) =
            rc.rewardFor{gas: TINY_GAS}(_zeros(0), _zeros(0), _zeros(0), 0);

        assertEq(rewarded, 0);
        assertEq(failed, 0);
        assertEq(processed, 0, "empty arrays: clean no-op, no revert");
    }
}
