// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {LivepeerRewardCaller} from "../../src/LivepeerRewardCaller.sol";
import {IController} from "../../src/interfaces/IController.sol";
import {IBondingManager} from "../../src/interfaces/IBondingManager.sol";
import {IRoundsManager} from "../../src/interfaces/IRoundsManager.sol";

/// @notice Public getters on the DEPLOYED RoundsManager that the src interface omits
///         (round-frame math + lock check). Same technique as ForkRewardCaller.t.sol.
interface IRoundsManagerEvictExt {
    function lastRoundLengthUpdateRound() external view returns (uint256);
    function lastRoundLengthUpdateStartBlock() external view returns (uint256);
    function lastInitializedRound() external view returns (uint256);
    function currentRoundLocked() external view returns (bool);
}

/// @notice Deployed BondingManager entry points needed to stage a REAL eviction:
///         a fresh EOA bonds more stake than the pool tail and registers as a transcoder,
///         so BondingManager.tryToJoinActiveSet removes the tail immediately.
interface IBondingManagerEvictExt {
    function transcoderTotalStake(address _transcoder) external view returns (uint256);
    function bond(uint256 _amount, address _to) external;
    function transcoder(uint256 _rewardCut, uint256 _feeShare) external;
    function getTranscoderPoolMaxSize() external view returns (uint256);
}

interface IERC20Like {
    function approve(address _spender, uint256 _amount) external returns (bool);
    function balanceOf(address _owner) external view returns (uint256);
}

/// @notice End-to-end fork proof of the EVICTION BLIND SPOT against the REAL BondingManager
///         on Arbitrum One, and of its documented mitigation lane:
///
///           * The pool this contract walks is the protocol's NEXT-round set.
///             tryToJoinActiveSet evicts the tail IMMEDIATELY (transcoderPool.remove +
///             deactivationRound = currentRound + 1) when a new bond out-competes it, yet the
///             evictee stays isActiveTranscoder() == true and reward-eligible until round end.
///           * Consequence: getPendingRewardCalls() and a COMPLETE rewardAll sweep can never
///             see the evictee — a fully silent miss (no RewardCallFailed alert fires).
///           * Mitigation: filterPendingRewardCalls (predicate WITHOUT the pool walk) still
///             sees it, and rewardFor rescues it — the reward was real and mintable all along.
///           * One round later the evictee is inactive: an unrescued miss would be permanent.
contract ForkEvictionTest is Test {
    // ------------------------------------------------ deployed Arbitrum One addresses
    IController internal constant CONTROLLER = IController(0xD8E8328501E9645d16Cf49539efC04f734606ee4);
    address internal constant BONDING_MANAGER = 0x35Bcf3c30594191d53231E4FF333E8A770453e40;
    address internal constant ROUNDS_MANAGER = 0xdd6f56DcC28D3F5f27084381fE8Df634985cc39f;

    /// Same pin as ForkRewardCaller.t.sol: past the LIP-118 target registration, verified served.
    uint256 internal constant PIN_BLOCK = 491_100_000;

    bytes32 internal constant SIG_REWARD_SUCCEEDED = keccak256("RewardCallSucceeded(uint256,address,address,uint256)");
    bytes32 internal constant SIG_REWARD_FAILED = keccak256("RewardCallFailed(uint256,address,address,bytes)");

    LivepeerRewardCaller internal rc;
    IBondingManager internal bm;
    IRoundsManager internal rm;
    address internal lpt;

    uint256 internal roundLen;
    uint256 internal lur; // RoundsManager.lastRoundLengthUpdateRound (contract frame)
    uint256 internal lsb; // RoundsManager.lastRoundLengthUpdateStartBlock (contract frame)
    uint256 internal T0; // fresh synthetic round: nobody rewarded, round uninitialized

    function setUp() public {
        // Default is a public ARCHIVE endpoint: the canonical https://arb1.arbitrum.io/rpc prunes
        // state aggressively and stopped serving PIN_BLOCK ("missing trie node", observed 2026-08-04).
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string("https://arbitrum-one.public.blastapi.io"));
        vm.createSelectFork(rpc, PIN_BLOCK);

        bm = IBondingManager(CONTROLLER.getContract(keccak256("BondingManager")));
        rm = IRoundsManager(CONTROLLER.getContract(keccak256("RoundsManager")));
        assertEq(address(bm), BONDING_MANAGER, "registry BondingManager != known proxy");
        assertEq(address(rm), ROUNDS_MANAGER, "registry RoundsManager != known address");

        lpt = CONTROLLER.getContract(keccak256("LivepeerToken"));
        assertTrue(lpt != address(0), "LivepeerToken id must resolve via the Controller");

        rc = new LivepeerRewardCaller(CONTROLLER);

        lur = IRoundsManagerEvictExt(ROUNDS_MANAGER).lastRoundLengthUpdateRound();
        lsb = IRoundsManagerEvictExt(ROUNDS_MANAGER).lastRoundLengthUpdateStartBlock();
        roundLen = rm.roundLength();

        // Fresh synthetic round: above every lastRewardRound AND above lastInitializedRound.
        uint256 maxLRR;
        address t = bm.getFirstTranscoderInPool();
        while (t != address(0)) {
            (uint256 lrr,,,,,,,,,) = bm.getTranscoder(t);
            if (lrr > maxLRR) maxLRR = lrr;
            t = bm.getNextTranscoderInPool(t);
        }
        uint256 t0 = maxLRR;
        uint256 lastInit = IRoundsManagerEvictExt(ROUNDS_MANAGER).lastInitializedRound();
        if (lastInit > t0) t0 = lastInit;
        if (lur > t0) t0 = lur;
        T0 = t0 + 1;
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Roll in the CONTRACT's block frame and prove we landed exactly on `target`.
    function _rollToRound(uint256 target) internal {
        require(target >= lur, "target below lastRoundLengthUpdateRound");
        vm.roll(lsb + (target - lur) * roundLen);
        assertEq(rm.currentRound(), target, "roll math must land exactly on the target round (contract frame)");
    }

    function _poolContains(address a) internal view returns (bool) {
        address t = bm.getFirstTranscoderInPool();
        while (t != address(0)) {
            if (t == a) return true;
            t = bm.getNextTranscoderInPool(t);
        }
        return false;
    }

    function _poolTail() internal view returns (address last) {
        address t = bm.getFirstTranscoderInPool();
        while (t != address(0)) {
            last = t;
            t = bm.getNextTranscoderInPool(t);
        }
    }

    function _lrr(address t) internal view returns (uint256 x) {
        (x,,,,,,,,,) = bm.getTranscoder(t);
    }

    function _deact(address t) internal view returns (uint256 x) {
        (,,,,, x,,,,) = bm.getTranscoder(t);
    }

    /// @dev The keeper recipe verbatim (rewardAll(15, 0) @ 25M) until complete == true.
    function _sweepToCompletion() internal returns (uint256 totalRewarded, uint256 totalFailed) {
        bool complete;
        uint256 txs;
        while (!complete) {
            (uint256 r, uint256 f, bool c) = rc.rewardAll{gas: 25_000_000}(15, 0);
            totalRewarded += r;
            totalFailed += f;
            complete = c;
            require(++txs <= 64, "sweep did not converge");
        }
    }

    // ================================================================ the blind spot, end to end
    function test_forkEviction_evicteeInvisibleToSweep_filterAndRewardForRescue() public {
        // ---- 1. fresh round, initialized THROUGH the contract's empty-batch path -------------
        _rollToRound(T0);
        assertFalse(rm.currentRoundInitialized(), "fresh round must start uninitialized");
        uint256 poolMax = IBondingManagerEvictExt(address(bm)).getTranscoderPoolMaxSize();
        assertEq(bm.getTranscoderPoolSize(), poolMax, "pool must be FULL for a new bond to evict the tail");
        assertFalse(IRoundsManagerEvictExt(ROUNDS_MANAGER).currentRoundLocked(), "round must be unlocked");

        rc.rewardFor(new address[](0), new address[](0), new address[](0), 0);
        assertTrue(rm.currentRoundInitialized(), "empty rewardFor must auto-initialize the round");

        // ---- 2. subscribe the pool TAIL to this contract -------------------------------------
        address tail = _poolTail();
        assertTrue(tail != address(0), "pool tail must exist");
        assertTrue(bm.isActiveTranscoder(tail), "pin assumption: pool tail is active this round");
        assertTrue(_lrr(tail) != T0, "tail must be unrewarded on the fresh round");

        vm.prank(tail);
        bm.setRewardCaller(address(rc));
        assertEq(bm.transcoderToRewardCaller(tail), address(rc), "subscription did not stick");

        address[] memory pending = rc.getPendingRewardCalls();
        assertEq(pending.length, 1, "tail must be the ONLY pending subscriber before eviction");
        assertEq(pending[0], tail, "subscribed tail must appear in getPendingRewardCalls");

        // ---- 3. REAL eviction: fresh EOA out-competes the tail via BondingManager.bond -------
        uint256 tailStake = IBondingManagerEvictExt(address(bm)).transcoderTotalStake(tail);
        assertGt(tailStake, 0, "tail must have nonzero stake");
        address joiner = makeAddr("evictingOrchestrator");
        uint256 amount = tailStake + 1e18; // out-compete with a 1 LPT margin

        deal(lpt, joiner, amount);
        assertEq(IERC20Like(lpt).balanceOf(joiner), amount, "LPT funding did not stick");

        vm.startPrank(joiner);
        IERC20Like(lpt).approve(address(bm), type(uint256).max);
        IBondingManagerEvictExt(address(bm)).bond(amount, joiner); // self-bond
        if (!_poolContains(joiner)) {
            // Register as transcoder -> tryToJoinActiveSet evicts the min-stake member (the tail).
            IBondingManagerEvictExt(address(bm)).transcoder(500_000, 500_000);
        }
        vm.stopPrank();
        assertTrue(_poolContains(joiner), "joiner must have entered the pool");
        assertEq(bm.getTranscoderPoolSize(), poolMax, "pool must stay full after the swap");

        // Protocol state the review confirmed: OUT of the pool, yet STILL active and eligible.
        assertFalse(_poolContains(tail), "tail must be evicted from the (next-round) pool immediately");
        assertTrue(bm.isActiveTranscoder(tail), "evictee stays isActiveTranscoder for the rest of the round");
        assertEq(_deact(tail), T0 + 1, "evictee deactivationRound must be currentRound + 1");
        assertEq(bm.transcoderToRewardCaller(tail), address(rc), "evictee stays subscribed");
        assertTrue(_lrr(tail) != T0, "evictee still unrewarded");

        // ---- 4. the blind spot on the REAL chain ---------------------------------------------
        assertEq(rc.getPendingRewardCalls().length, 0, "pool-walk view must be blind to the evictee");

        vm.recordLogs();
        (uint256 rewarded, uint256 failed) = _sweepToCompletion();
        assertEq(rewarded, 0, "a COMPLETE rewardAll sweep must never reward the evictee");
        assertEq(failed, 0, "and it fails nothing either - the miss is fully silent (no alert)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rc)) continue;
            bytes32 sig = logs[i].topics[0];
            if (sig == SIG_REWARD_SUCCEEDED || sig == SIG_REWARD_FAILED) {
                assertTrue(
                    address(uint160(uint256(logs[i].topics[2]))) != tail,
                    "no reward event may mention the evictee during the sweep"
                );
            }
        }
        assertTrue(_lrr(tail) != T0, "evictee remains unrewarded after the complete sweep");
        assertEq(rc.getPendingRewardCalls().length, 0, "pending view reports DONE while a reward is still owed");

        // ---- 5. permanence of the miss in the UNRESCUED world --------------------------------
        // Checked on a snapshot BEFORE the rescue: the rescue itself raises the evictee's stake,
        // which makes tryToJoinActiveSet re-admit it to the pool (deactivationRound reset), so
        // the rescued world cannot demonstrate the closing window.
        address[] memory cand = new address[](1);
        cand[0] = tail;
        uint256 snap = vm.snapshotState();
        _rollToRound(T0 + 1);
        assertFalse(bm.isActiveTranscoder(tail), "unrescued evictee must be inactive one round later");
        assertEq(rc.filterPendingRewardCalls(cand).length, 0, "mitigation window is closed at T0+1");
        assertTrue(_lrr(tail) != T0, "the round-T0 reward is permanently missed without a rescue");
        assertTrue(vm.revertToState(snap), "state revert failed");
        assertEq(rm.currentRound(), T0, "back at round T0 for the rescue");

        // ---- 6. the mitigation lane: filterPendingRewardCalls -> rewardFor -------------------
        address[] memory filtered = rc.filterPendingRewardCalls(cand);
        assertEq(filtered.length, 1, "filterPendingRewardCalls must still see the evictee (no pool walk)");
        assertEq(filtered[0], tail, "filtered candidate must be the evictee");

        (uint256 r2, uint256 f2, uint256 p2) = rc.rewardFor(cand, new address[](1), new address[](1), 0);
        assertEq(r2, 1, "rewardFor must rescue the evictee - the reward was real and mintable all along");
        assertEq(f2, 0, "rescue must not fail");
        assertEq(p2, 1, "rescue must consume the single item");
        assertEq(_lrr(tail), T0, "evictee lastRewardRound must equal the current round after rescue");
        console2.log("evictee rescued via rewardFor for round:", T0);
    }
}
