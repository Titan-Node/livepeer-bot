// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LivepeerRewardCaller} from "../../src/LivepeerRewardCaller.sol";
import {IController} from "../../src/interfaces/IController.sol";
import {IBondingManager} from "../../src/interfaces/IBondingManager.sol";
import {IRoundsManager} from "../../src/interfaces/IRoundsManager.sol";

/// @notice Public storage getters on the DEPLOYED RoundsManager the src interface omits,
///         needed for round math in the CONTRACT's block frame (see ForkRewardCaller.t.sol).
interface IRoundsManagerSmokeExt {
    function lastRoundLengthUpdateRound() external view returns (uint256);
    function lastRoundLengthUpdateStartBlock() external view returns (uint256);
}

/// @notice Smoke test against the real deployed LIP-118 target on Arbitrum One at the LATEST
///         block (deliberately unpinned - this is the live-HEAD drift detector). After
///         subscribing a pick it ADVANCES to a fresh round in the contract's block frame so the
///         strong end-to-end branch (reward actually lands) executes on every run, then checks
///         the InsufficientGas floor revert.
contract SmokeForkTest is Test {
    IController constant CONTROLLER = IController(0xD8E8328501E9645d16Cf49539efC04f734606ee4);
    address constant BONDING_MANAGER = 0x35Bcf3c30594191d53231E4FF333E8A770453e40;

    LivepeerRewardCaller caller;
    IBondingManager bm;
    IRoundsManager rm;

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc"));
        vm.createSelectFork(rpc);
        caller = new LivepeerRewardCaller(CONTROLLER);
        bm = IBondingManager(CONTROLLER.getContract(keccak256("BondingManager")));
        rm = IRoundsManager(CONTROLLER.getContract(keccak256("RoundsManager")));
        assertEq(address(bm), BONDING_MANAGER, "registry BondingManager != known proxy");
    }

    function test_smoke_subscribeAndRewardOne() public {
        uint256 targetRound = rm.currentRound() + 1; // the fresh round we will advance to

        // pick a low-ranked active transcoder that has NOT delegated to anyone and that stays
        // active at targetRound (deactivationRound beyond it)
        address t = bm.getFirstTranscoderInPool();
        address pick = address(0);
        while (t != address(0)) {
            (,,,,, uint256 deact,,,,) = bm.getTranscoder(t);
            if (bm.isActiveTranscoder(t) && bm.transcoderToRewardCaller(t) == address(0) && deact > targetRound) {
                pick = t; // keep last found (low-ranked = worst-case hintless gas)
            }
            t = bm.getNextTranscoderInPool(t);
        }
        assertTrue(pick != address(0), "no eligible transcoder found");

        // subscribe it to our contract
        vm.prank(pick);
        bm.setRewardCaller(address(caller));
        assertEq(bm.transcoderToRewardCaller(pick), address(caller));

        // ADVANCE to the fresh round in the CONTRACT's block frame:
        //   currentRound = lastRoundLengthUpdateRound
        //                + (block.number - lastRoundLengthUpdateStartBlock) / roundLength
        uint256 lur = IRoundsManagerSmokeExt(address(rm)).lastRoundLengthUpdateRound();
        uint256 lsb = IRoundsManagerSmokeExt(address(rm)).lastRoundLengthUpdateStartBlock();
        uint256 roundLen = rm.roundLength();
        assertGt(roundLen, 0, "roundLength must be nonzero");
        vm.roll(lsb + (targetRound - lur) * roundLen);
        assertEq(rm.currentRound(), targetRound, "roll must land exactly on the fresh round (contract frame)");

        // fresh round: nobody (in particular our pick) can already be rewarded for it
        (uint256 lastRewardRound,,,,,,,,,) = bm.getTranscoder(pick);
        assertTrue(lastRewardRound != targetRound, "pick cannot be rewarded for a round that just started");

        address[] memory pending = caller.getPendingRewardCalls();
        bool found;
        for (uint256 i; i < pending.length; ++i) {
            if (pending[i] == pick) found = true;
        }
        assertTrue(found, "subscribed+unrewarded transcoder must be pending");

        // the sweep must reward it (auto-initializing the fresh round on the way)
        (uint256 rewarded, uint256 failed, bool complete) = caller.rewardAll(0, 0);
        assertEq(failed, 0, "no failures expected");
        assertTrue(complete, "full scan expected");
        assertGe(rewarded, 1, "our transcoder must be rewarded");
        (uint256 lrrAfter,,,,,,,,,) = bm.getTranscoder(pick);
        assertEq(lrrAfter, targetRound, "lastRewardRound must equal current round after sweep");

        // InsufficientGas sanity: on the (now initialized) fresh round, a rewardAll tx that
        // cannot afford even ONE attempt must revert InsufficientGas instead of silently
        // no-opping. 1.5M gas sits below the 2.5M per-iteration floor at pool size 100.
        // expectRevert with an explicit gas stipend is finicky, so assert via a low-level call.
        (bool ok, bytes memory ret) =
            address(caller).call{gas: 1_500_000}(abi.encodeCall(LivepeerRewardCaller.rewardAll, (0, 0)));
        assertFalse(ok, "under-gassed rewardAll must revert, never silently no-op");
        assertEq(
            ret,
            abi.encodePacked(LivepeerRewardCaller.InsufficientGas.selector),
            "revert data must be exactly the InsufficientGas selector"
        );
    }
}
