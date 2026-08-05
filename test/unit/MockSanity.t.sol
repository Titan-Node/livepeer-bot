// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UnitBase} from "./Base.t.sol";
import {IBondingManager} from "../../src/interfaces/IBondingManager.sol";
import {MockBondingManager} from "./mocks/MockBondingManager.sol";
import {MockRoundsManager} from "./mocks/MockRoundsManager.sol";

/// @notice Fidelity checks for the mocks themselves, most importantly the storage-slot
///         layout the pre-check ORDER tests decode from vm.record() traces. If these
///         fail, the order tests cannot be trusted.
contract MockSanityTest is UnitBase {
    address internal T = address(0xA11CE);

    // ---------------------------------------------------------------- slot layout
    function test_SlotLayout_MatchesTraceHelpers() public {
        address x = makeAddr("subscriber-target");
        bm.setRewardCallerFor(T, x);
        assertEq(vm.load(address(bm), _slotSubscribed(T)), bytes32(uint256(uint160(x))), "slot 0 mapping mismatch");

        bm.setLastRewardRound(T, 777);
        assertEq(vm.load(address(bm), _slotLastReward(T)), bytes32(uint256(777)), "slot 1 mapping mismatch");

        bm.setActive(T, true);
        assertEq(vm.load(address(bm), _slotActive(T)), bytes32(uint256(1)), "slot 2 mapping mismatch");
        bm.setActive(T, false);
        assertEq(vm.load(address(bm), _slotActive(T)), bytes32(0), "slot 2 clear mismatch");
    }

    // ---------------------------------------------------------------- pool behavior
    function test_Pool_InsertsDescendingByStake() public {
        address A = address(0xA1);
        address B = address(0xB1);
        address C = address(0xC1);
        bm.addToPool(B, 200); // insert out of order on purpose
        bm.addToPool(C, 100);
        bm.addToPool(A, 300);
        address[] memory order = _walkPool();
        assertEq(order.length, 3);
        assertEq(order[0], A);
        assertEq(order[1], B);
        assertEq(order[2], C);
        assertEq(bm.getTranscoderPoolSize(), 3);
        // prev/next neighbors via the interface surface
        assertEq(bm.getFirstTranscoderInPool(), A);
        assertEq(bm.getNextTranscoderInPool(A), B);
        assertEq(bm.getNextTranscoderInPool(C), address(0));
    }

    function test_Pool_MoveOnReward_MovesNodeToHead() public {
        address A = address(0xA1);
        address B = address(0xB1);
        address C = address(0xC1);
        bm.addToPool(A, 300);
        bm.addToPool(B, 200);
        bm.addToPool(C, 100);
        bm.setMoveOnReward(true);
        bm.setRewardCallerFor(C, address(this));

        bm.rewardForTranscoderWithHint(C, address(0), address(0));

        address[] memory order = _walkPool();
        assertEq(order.length, 3);
        assertEq(order[0], C, "rewarded node must move to head");
        assertEq(order[1], A);
        assertEq(order[2], B);

        // and the call was logged with msg.sender + round
        assertEq(bm.rewardCallsLength(), 1);
        (address caller_, address t_,,, uint256 round_) = bm.rewardCalls(0);
        assertEq(caller_, address(this));
        assertEq(t_, C);
        assertEq(round_, ROUND);
        assertEq(bm.lastRewardRoundOf(C), ROUND);
    }

    // ---------------------------------------------------------------- access check
    function test_Reward_AccessCheck_RealRevertString() public {
        bm.addToPool(T, 100);
        // not subscribed to us -> the real LIP-118 revert string
        vm.expectRevert(bytes("caller must be a reward caller set by the transcoder"));
        bm.rewardForTranscoderWithHint(T, address(0), address(0));

        // subscribed to someone else -> still reverts for us
        bm.setRewardCallerFor(T, makeAddr("someone-else"));
        vm.expectRevert(bytes("caller must be a reward caller set by the transcoder"));
        bm.rewardForTranscoderWithHint(T, address(0), address(0));
    }

    // ---------------------------------------------------------------- failure modes
    function test_Reward_FailureModes_RevertShapes() public {
        bm.setRewardCallerFor(T, address(this));

        bm.setFailureMode(T, MockBondingManager.FailureMode.RevertString);
        vm.expectRevert(bytes("MOCK_REWARD_STRING_FAILURE"));
        bm.rewardForTranscoderWithHint(T, address(0), address(0));

        bm.setFailureMode(T, MockBondingManager.FailureMode.RevertCustom);
        vm.expectRevert(abi.encodeWithSelector(MockBondingManager.RewardBroken.selector, T, 42));
        bm.rewardForTranscoderWithHint(T, address(0), address(0));

        bm.setFailureMode(T, MockBondingManager.FailureMode.RevertEmpty);
        vm.expectRevert(bytes(""));
        bm.rewardForTranscoderWithHint(T, address(0), address(0));

        // nothing was ever logged
        assertEq(bm.rewardCallsLength(), 0);
        assertEq(bm.rewardCallCountOf(T), 0);
    }

    function test_Reward_GetTranscoder_TupleShape() public {
        bm.setLastRewardRound(T, 999);
        (uint256 lrr, uint256 f1,,,,,,,, uint256 f9) = bm.getTranscoder(T);
        assertEq(lrr, 999, "lastRewardRound must be the FIRST tuple field");
        assertEq(f1, 1);
        assertEq(f9, 9);
    }

    // ---------------------------------------------------------------- removeFromPool knob
    function test_RemoveFromPool_UnlinksOnly_EligibilityStateUntouched() public {
        address A = address(0xA1);
        address B = address(0xB1);
        address C = address(0xC1);
        bm.addToPool(A, 300);
        bm.addToPool(B, 200);
        bm.addToPool(C, 100);
        bm.setRewardCallerFor(B, address(this));
        bm.setActive(B, true);
        bm.setLastRewardRound(B, 55);

        bm.removeFromPool(B); // middle node
        address[] memory order = _walkPool();
        assertEq(order.length, 2);
        assertEq(order[0], A);
        assertEq(order[1], C);
        assertEq(bm.getTranscoderPoolSize(), 2);
        assertEq(bm.getNextTranscoderInPool(A), C, "neighbors relinked across the hole");
        assertEq(bm.getNextTranscoderInPool(B), address(0), "removed node fully unlinked");
        // eligibility dimensions must be UNTOUCHED (mid-round eviction model)
        assertEq(bm.transcoderToRewardCaller(B), address(this), "subscription untouched");
        assertTrue(bm.isActiveTranscoder(B), "active flag untouched");
        assertEq(bm.lastRewardRoundOf(B), 55, "lastRewardRound untouched");

        bm.removeFromPool(A); // head
        assertEq(bm.getFirstTranscoderInPool(), C);
        bm.removeFromPool(C); // tail (and last node)
        assertEq(bm.getTranscoderPoolSize(), 0);
        assertEq(bm.getFirstTranscoderInPool(), address(0));

        // a removed node may rejoin later (protocol re-entry in a following round)
        bm.addToPool(B, 500);
        assertEq(bm.getFirstTranscoderInPool(), B);
        assertEq(bm.getTranscoderPoolSize(), 1);
    }

    // ---------------------------------------------------------------- getTranscoder drift knobs
    function test_GetTranscoderModes_RawReturndataShapes() public {
        bytes memory callData = abi.encodeCall(IBondingManager.getTranscoder, (T));
        bm.setLastRewardRound(T, 999);

        (bool ok, bytes memory data) = address(bm).staticcall(callData);
        assertTrue(ok);
        assertEq(data.length, 320, "normal mode: full 10-word tuple");

        bm.setGetTranscoderMode(T, MockBondingManager.GetTranscoderMode.Revert);
        (ok, data) = address(bm).staticcall(callData);
        assertFalse(ok, "revert mode: raw staticcall observes ok == false");

        bm.setGetTranscoderMode(T, MockBondingManager.GetTranscoderMode.ShortReturn);
        (ok, data) = address(bm).staticcall(callData);
        assertTrue(ok, "short mode: the call SUCCEEDS");
        assertEq(data.length, 16, "default short length");

        bm.setShortReturnLength(31);
        (ok, data) = address(bm).staticcall(callData);
        assertTrue(ok);
        assertEq(data.length, 31, "31 bytes: one short of a decodable word");

        bm.setShortReturnLength(0);
        (ok, data) = address(bm).staticcall(callData);
        assertTrue(ok);
        assertEq(data.length, 0, "zero-byte returndata");

        bm.setGetTranscoderMode(T, MockBondingManager.GetTranscoderMode.Normal);
        (uint256 lrr,,,,,,,,,) = bm.getTranscoder(T);
        assertEq(lrr, 999, "normal mode restored; first word is lastRewardRound");
    }

    // ---------------------------------------------------------------- rounds mock
    function test_RoundsMock_InitModes() public {
        _setRound(ROUND, false);
        assertFalse(rounds.currentRoundInitialized());
        rounds.initializeRound();
        assertTrue(rounds.currentRoundInitialized());
        assertEq(rounds.initializeRoundCalls(), 1);

        rounds.setInitMode(MockRoundsManager.InitMode.RevertString);
        vm.expectRevert(bytes("MOCK_ROUND_NOT_INITIALIZABLE"));
        rounds.initializeRound();

        rounds.setInitMode(MockRoundsManager.InitMode.RevertCustom);
        vm.expectRevert(abi.encodeWithSelector(MockRoundsManager.InitializeBroken.selector, 123));
        rounds.initializeRound();

        rounds.setInitMode(MockRoundsManager.InitMode.RevertEmpty);
        vm.expectRevert(bytes(""));
        rounds.initializeRound();

        // reverted attempts rolled the counter back
        assertEq(rounds.initializeRoundCalls(), 1);
    }

    function test_ControllerMock_Settable() public {
        controller.setPaused(true);
        assertTrue(controller.paused());
        controller.setPaused(false);
        assertFalse(controller.paused());
        address o = makeAddr("owner");
        controller.setOwner(o);
        assertEq(controller.owner(), o);
        assertEq(controller.getContract(BONDING_MANAGER_ID), address(bm));
        assertEq(controller.getContract(keccak256("Nothing")), address(0));
    }
}
