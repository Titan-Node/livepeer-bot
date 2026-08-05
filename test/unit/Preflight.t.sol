// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UnitBase} from "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {LivepeerRewardCaller} from "../../src/LivepeerRewardCaller.sol";
import {IRoundsManager} from "../../src/interfaces/IRoundsManager.sol";
import {MockRoundsManager} from "./mocks/MockRoundsManager.sol";

contract PreflightTest is UnitBase {
    // ---------------------------------------------------------------- pause gate

    function test_Paused_RewardAll_RevertsBeforeAnyPoolInteraction() public {
        _addGood(address(0xA1), 100);
        controller.setPaused(true);
        // poison-pill every BondingManager view: if the contract touched the pool
        // (or even the pool size) before the pause check, we would see POISONED_VIEW
        // instead of SystemPaused.
        bm.setPoisonViews(true);

        vm.expectRevert(LivepeerRewardCaller.SystemPaused.selector);
        rc.rewardAll(0, 0);
        assertEq(bm.rewardCallsLength(), 0);
    }

    function test_Paused_RewardFor_RevertsBeforeAnyPoolInteraction() public {
        controller.setPaused(true);
        bm.setPoisonViews(true);
        vm.expectRevert(LivepeerRewardCaller.SystemPaused.selector);
        rc.rewardFor(_zeros(0), _zeros(0), _zeros(0), 0);
    }

    // ---------------------------------------------------------------- opportunistic initialization

    function test_UninitializedRound_InitializedOnce_RoundReadAfterInit_SweepProceeds() public {
        address T = address(0xA1);
        _addGood(T, 100);
        // Round rolls to ROUND+1 only when initializeRound() lands: if the contract
        // read currentRound BEFORE initializing, it would see and emit ROUND.
        _setRound(ROUND, false);
        rounds.setBumpRoundOnInit(true);
        bm.setCurrentRound(ROUND + 1); // BondingManager stamps the post-init round

        vm.expectEmit(true, true, true, true, address(rc));
        emit RoundInitialized(ROUND + 1, keeper);
        vm.expectEmit(true, true, true, false, address(rc));
        emit RewardCallSucceeded(ROUND + 1, T, keeper, 0);
        vm.expectEmit(true, true, true, true, address(rc));
        emit BatchProcessed(ROUND + 1, keeper, 1, 1, 0, true);

        vm.prank(keeper);
        (uint256 rewarded, uint256 failed, bool complete) = rc.rewardAll(0, 0);

        assertEq(rewarded, 1, "sweep proceeds in the same tx that initialized");
        assertEq(failed, 0);
        assertTrue(complete);
        assertEq(rounds.initializeRoundCalls(), 1, "initializeRound called exactly once");
        assertTrue(rounds.currentRoundInitialized());
        assertEq(bm.lastRewardRoundOf(T), ROUND + 1);

        // second call in the now-initialized round: no further init attempts
        rc.rewardAll(0, 0);
        assertEq(rounds.initializeRoundCalls(), 1);
    }

    function test_InitializedRound_NoInitCall_NoRoundInitializedEvent() public {
        _addGood(address(0xA1), 100);
        vm.recordLogs();
        rc.rewardAll(0, 0);
        assertEq(rounds.initializeRoundCalls(), 0);
        assertEq(_countLogs(vm.getRecordedLogs(), SIG_ROUND_INITIALIZED), 0);
    }

    // ---------------------------------------------------------------- init failure -> typed revert with inner reason

    function test_InitializeRoundReverts_String_WrappedInRoundNotInitializable() public {
        _setRound(ROUND, false);
        rounds.setInitMode(MockRoundsManager.InitMode.RevertString);
        vm.expectRevert(
            abi.encodeWithSelector(
                LivepeerRewardCaller.RoundNotInitializable.selector,
                abi.encodeWithSignature("Error(string)", "MOCK_ROUND_NOT_INITIALIZABLE")
            )
        );
        rc.rewardAll(0, 0);
    }

    function test_InitializeRoundReverts_CustomError_WrappedInRoundNotInitializable() public {
        _setRound(ROUND, false);
        rounds.setInitMode(MockRoundsManager.InitMode.RevertCustom);
        vm.expectRevert(
            abi.encodeWithSelector(
                LivepeerRewardCaller.RoundNotInitializable.selector,
                abi.encodeWithSelector(MockRoundsManager.InitializeBroken.selector, 123)
            )
        );
        rc.rewardAll(0, 0);
    }

    function test_InitializeRoundReverts_EmptyData_WrappedInRoundNotInitializable() public {
        _setRound(ROUND, false);
        rounds.setInitMode(MockRoundsManager.InitMode.RevertEmpty);
        vm.expectRevert(abi.encodeWithSelector(LivepeerRewardCaller.RoundNotInitializable.selector, bytes("")));
        rc.rewardAll(0, 0);
    }

    function test_InitializeRoundReverts_AppliesToRewardForToo() public {
        _setRound(ROUND, false);
        rounds.setInitMode(MockRoundsManager.InitMode.RevertString);
        rounds.setInitRevertReason("EARLY");
        vm.expectRevert(
            abi.encodeWithSelector(
                LivepeerRewardCaller.RoundNotInitializable.selector, abi.encodeWithSignature("Error(string)", "EARLY")
            )
        );
        rc.rewardFor(_zeros(0), _zeros(0), _zeros(0), 0);
    }

    // ---------------------------------------------------------------- currentRound read exactly once

    function test_CurrentRound_ReadExactlyOnce_RewardAll() public {
        // several pool nodes so a per-iteration re-read would be caught
        _addGood(address(0xA1), 300);
        _addT(address(0xB1), 200, false, true, 0);
        _addGood(address(0xC1), 100);

        vm.expectCall(address(rounds), abi.encodeCall(IRoundsManager.currentRound, ()), 1);
        (uint256 rewarded,,) = rc.rewardAll(0, 0);
        assertEq(rewarded, 2);
    }

    function test_CurrentRound_ReadExactlyOnce_RewardFor() public {
        _addGood(address(0xA1), 300);
        _addGood(address(0xB1), 200);
        address[] memory list = _arr(address(0xA1), address(0xB1));

        vm.expectCall(address(rounds), abi.encodeCall(IRoundsManager.currentRound, ()), 1);
        (uint256 rewarded,, uint256 processed) = rc.rewardFor(list, _zeros(2), _zeros(2), 0);
        assertEq(rewarded, 2);
        assertEq(processed, 2);
    }
}
