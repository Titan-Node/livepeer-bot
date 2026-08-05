// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UnitBase} from "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {LivepeerRewardCaller} from "../../src/LivepeerRewardCaller.sol";
import {MockBondingManager} from "./mocks/MockBondingManager.sol";

/// @notice Regressions for OneDollarAudit job #565 (2026-08-05), findings 1, 2 and 4.
contract AuditRegressionsTest is UnitBase {
    uint256 internal constant PREFIX = 60;

    /// @dev 60 in-pool, active, NOT-subscribed nodes (cheap [a]-skips) with one subscriber
    ///      at the tail (lowest stake) — the shape that let scans masquerade as progress.
    function _buildPrefixPool() internal returns (address good) {
        for (uint256 i; i < PREFIX; ++i) {
            _addT(address(uint160(0x2000 + i)), 10_000 - i, false, true, 0);
        }
        good = address(0x2FFF);
        _addGood(good, 1);
    }

    // ------------------------------------------------ finding 2: attempts gate InsufficientGas

    function test_RewardAll_ScanPrefixCannotMaskZeroAttempts_Reverts() public {
        address good = _buildPrefixPool();

        // A 2.8M budget passes the FIRST floor check deterministically (~2.76M >= 2.5M), so
        // the expected revert can only fire on a LATER iteration — i.e. after scanning
        // skippable prefix nodes. Under the audited processed-based gate this exact call
        // returned a silent zero-progress "success"; the attempts-based gate reverts.
        vm.expectRevert(LivepeerRewardCaller.InsufficientGas.selector);
        rc.rewardAll{gas: 2_800_000}(0, 0);
        assertEq(bm.rewardCallsLength(), 0, "no attempt was ever afforded");

        // Contrast: a real budget completes the same pool and rewards the tail subscriber.
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);
        assertEq(rewarded, 1);
        assertEq(failed, 0);
        assertTrue(complete);
        assertEq(bm.lastRewardRoundOf(good), ROUND);
    }

    function test_RewardFor_IneligiblePrefixCannotMaskZeroAttempts_Reverts() public {
        // rewardFor skips are cheaper than rewardAll's (no pool-walk call per item), so use a
        // longer unsubscribed-stranger prefix and a tighter budget. First floor check still
        // passes deterministically (~2.71M >= 2.5M), so the revert must come mid-scan.
        uint256 n = 120;
        address good = address(0x2FFF);
        _addGood(good, 1);
        address[] memory list = new address[](n + 1);
        for (uint256 i; i < n; ++i) {
            list[i] = address(uint160(0x4000 + i)); // not subscribed, not in pool
        }
        list[n] = good;

        vm.expectRevert(LivepeerRewardCaller.InsufficientGas.selector);
        rc.rewardFor{gas: 2_750_000}(list, _zeros(n + 1), _zeros(n + 1), 0);
        assertEq(bm.rewardCallsLength(), 0);

        (uint256 rewarded,, uint256 processed) = rc.rewardFor(list, _zeros(n + 1), _zeros(n + 1), 0);
        assertEq(rewarded, 1);
        assertEq(processed, n + 1, "full list consumed once gas is adequate");
    }

    // ------------------------------------------------ finding 1: huge revert payloads truncated

    function test_HugeRevertPayload_TruncatedTo256_SweepContinues() public {
        assertEq(rc.MAX_REVERT_DATA_BYTES(), 256);

        address g1 = address(0x3101);
        address bomb = address(0x3102);
        address g2 = address(0x3103);
        _addGood(g1, 300);
        _addGood(bomb, 200);
        _addGood(g2, 100);
        bm.setFailureMode(bomb, MockBondingManager.FailureMode.RevertHuge);

        vm.recordLogs();
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);

        assertEq(rewarded, 2, "both healthy nodes rewarded despite the 8KB revert bomb");
        assertEq(failed, 1);
        assertTrue(complete, "outer sweep survives - the failure path cannot OOG");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory emitted;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == SIG_FAILED) {
                emitted = abi.decode(logs[i].data, (bytes));
            }
        }
        assertEq(emitted.length, 256, "revertData truncated to MAX_REVERT_DATA_BYTES");
        for (uint256 i; i < 256; ++i) {
            assertEq(uint8(emitted[i]), uint8(i % 32), "truncated prefix preserved verbatim");
        }
    }

    // ================================================== audit #567 regressions

    /// @dev Finding 1: without MAX_GAS_FLOOR, a ~5,000-member pool implies a 51.5M floor —
    ///      unsatisfiable under Arbitrum's 32M tx cap, permanently bricking every call. With
    ///      the cap, a 20.5M tx still serves subscribers.
    function test_GasFloorCapped_GiantPoolCannotBrickService() public {
        assertEq(rc.MAX_GAS_FLOOR(), 20_000_000);

        address good = address(0x5101);
        _addGood(good, 100);
        bm.setPoolSizeOverride(5_000); // floor math sees a giant pool; the walk stays tiny

        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll{gas: 20_500_000}(0, 0);
        assertEq(rewarded, 1, "capped floor keeps a giant-pool service alive");
        assertEq(failed, 0);
        assertTrue(complete);

        // Clamp-up above the ceiling is still the caller's prerogative (and their own risk):
        _freshDeploy();
        _addGood(good, 100);
        bm.setPoolSizeOverride(5_000);
        vm.expectRevert(LivepeerRewardCaller.InsufficientGas.selector);
        rc.rewardAll{gas: 20_500_000}(0, 21_000_000);
    }

    /// @dev Finding 3: a ~400KB revert bomb whose IMPLICIT returndata copy (high-level `.call`)
    ///      would OOG the frame despite the bounded emit. The assembly zero-output-buffer call
    ///      makes _boundedRevertData the only copy, so the sweep survives.
    function test_MassiveRevertBomb_NoImplicitCopyOOG_SweepContinues() public {
        address g1 = address(0x5201);
        address bomb = address(0x5202);
        address g2 = address(0x5203);
        _addGood(g1, 300);
        _addGood(bomb, 200);
        _addGood(g2, 100);
        bm.setFailureMode(bomb, MockBondingManager.FailureMode.RevertHuge);
        bm.setHugeRevertSize(400_000);

        vm.recordLogs();
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);
        assertEq(rewarded, 2, "sweep survives a 400KB revert bomb");
        assertEq(failed, 1);
        assertTrue(complete);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == SIG_FAILED) {
                bytes memory emitted = abi.decode(logs[i].data, (bytes));
                assertEq(emitted.length, 256, "still truncated to MAX_REVERT_DATA_BYTES");
            }
        }
    }

    /// @dev Finding 6: construction fingerprints the registry binding on-chain.
    function test_DeployedEvent_FingerprintsRegistryBinding() public {
        vm.expectEmit(true, true, true, true);
        emit LivepeerRewardCaller.Deployed(address(controller), address(bm), address(rounds));
        new LivepeerRewardCaller(controller);
    }

    // ------------------------------------------------ finding 4: reserve scales with the floor

    function test_ForwardCap_IncludesEip150ScaledReserve() public {
        // At small pool size the floor is MIN_CALL_GAS (2.5M); the forwarded cap is now
        // 2.5M - (150k + 2.5M/64) ~= 2.311M. A reward burning 2.33M lands between the old
        // flat-reserve cap (2.35M) and the new scaled cap, so it must now be contained.
        address t = address(0x3201);
        _addBurner(t, 100, 2_330_000);

        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);
        assertEq(rewarded, 0, "burner above the scaled cap is contained, not served");
        assertEq(failed, 1);
        assertTrue(complete, "and the sweep still completes");
    }
}
