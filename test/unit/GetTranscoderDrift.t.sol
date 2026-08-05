// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UnitBase} from "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockBondingManager} from "./mocks/MockBondingManager.sol";

/// @notice Locks the defensive raw-staticcall decode in `_shouldAttempt` pre-check [b]:
///         when `getTranscoder(t)` REVERTS or returns FEWER than 32 bytes, the
///         transcoder is SILENTLY skipped — no reward attempt, no failure, no event —
///         and the sweep continues to later pool nodes in the same tx.
///
///         These tests fail loudly if `_shouldAttempt` is ever refactored to a typed
///         `bm.getTranscoder(t)` call: a typed call BUBBLES the revert / decode error,
///         which would abort the whole sweep instead of skipping one node.
contract GetTranscoderDriftTest is UnitBase {
    address internal G1 = address(0xD001); // eligible, before the broken node
    address internal X = address(0xD002); // eligible EXCEPT getTranscoder is broken
    address internal G2 = address(0xD003); // eligible, after the broken node

    function _buildDriftPool() internal {
        _addGood(G1, 300);
        _addGood(X, 200);
        _addGood(G2, 100);
    }

    /// @dev Shared assertion block: X silently skipped, neighbors rewarded same tx.
    function _sweepAndAssertSilentSkip() internal {
        vm.recordLogs();
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);

        assertEq(rewarded, 2, "later pool nodes still rewarded in the SAME tx");
        assertEq(failed, 0, "a broken getTranscoder is a silent skip, never a failure");
        assertTrue(complete);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countLogs(logs, SIG_FAILED), 0, "no RewardCallFailed for the broken node");
        assertEq(_countLogs(logs, SIG_SUCCEEDED), 2);
        (, uint256 processed,,,) = _batchStats(logs);
        assertEq(processed, 3, "the broken node IS scanned, then silently skipped");

        assertEq(bm.rewardCallCountOf(G1), 1);
        assertEq(bm.rewardCallCountOf(G2), 1, "node AFTER the broken one rewarded");
        assertEq(bm.rewardCallCountOf(X), 0, "no reward attempt for the broken node");
        assertEq(bm.lastRewardRoundOf(X), 0, "broken node's protocol state untouched");
    }

    /// @dev Shared assertion block: both views omit X, keep G1/G2.
    function _assertViewsOmitX() internal view {
        address[] memory expected = new address[](2);
        expected[0] = G1;
        expected[1] = G2;
        assertEq(rc.getPendingRewardCalls(), expected, "pending view silently omits the broken node");
        assertEq(
            rc.filterPendingRewardCalls(_arr(G1, X, G2)), expected, "filter view silently omits the broken node"
        );
    }

    // ---------------------------------------------------------------- getTranscoder REVERTS

    function test_GetTranscoderReverts_MidPool_SilentSkip_LaterNodesRewardedSameTx() public {
        _buildDriftPool();
        bm.setGetTranscoderMode(X, MockBondingManager.GetTranscoderMode.Revert);
        _sweepAndAssertSilentSkip();
    }

    function test_GetTranscoderReverts_ViewsOmitBrokenNode() public {
        _buildDriftPool();
        bm.setGetTranscoderMode(X, MockBondingManager.GetTranscoderMode.Revert);
        _assertViewsOmitX();
    }

    // ---------------------------------------------------------------- getTranscoder returns < 32 bytes

    function test_GetTranscoderShortReturndata_MidPool_SilentSkip_LaterNodesRewardedSameTx() public {
        _buildDriftPool();
        bm.setGetTranscoderMode(X, MockBondingManager.GetTranscoderMode.ShortReturn);
        bm.setShortReturnLength(31); // strictest boundary: one byte short of a decodable word
        _sweepAndAssertSilentSkip();

        // empty returndata is skipped just the same on a repeat sweep
        bm.setShortReturnLength(0);
        (uint256 r2, uint256 f2, bool c2) = rc.rewardAll(0, 0);
        assertEq(r2, 0, "G1/G2 already rewarded; X still skipped");
        assertEq(f2, 0);
        assertTrue(c2);
        assertEq(bm.rewardCallCountOf(X), 0);
    }

    function test_GetTranscoderShortReturndata_ViewsOmitBrokenNode() public {
        _buildDriftPool();
        bm.setGetTranscoderMode(X, MockBondingManager.GetTranscoderMode.ShortReturn);
        bm.setShortReturnLength(31);
        _assertViewsOmitX();

        bm.setShortReturnLength(0);
        _assertViewsOmitX();
    }
}
