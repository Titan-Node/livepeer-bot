// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {LivepeerRewardCaller} from "../../src/LivepeerRewardCaller.sol";
import {IController} from "../../src/interfaces/IController.sol";
import {IBondingManager} from "../../src/interfaces/IBondingManager.sol";
import {IRoundsManager} from "../../src/interfaces/IRoundsManager.sol";

/// @notice Public storage getters on the DEPLOYED RoundsManager that the src interface omits.
///         Existence is verified with raw staticcalls in setUp before use.
interface IRoundsManagerExt {
    function lastRoundLengthUpdateRound() external view returns (uint256);
    function lastRoundLengthUpdateStartBlock() external view returns (uint256);
    function lastInitializedRound() external view returns (uint256);
}

/// @notice Deployed BondingManager entry points the src interface omits: the orchestrator
///         self-call lane (trust test) and the no-hint delegated variant (access-check test).
interface IBondingManagerExt {
    function reward() external;
    function rewardWithHint(address _newPosPrev, address _newPosNext) external;
    function rewardForTranscoder(address _transcoder) external;
}

interface IControllerExt {
    function pause() external;
}

/// @notice Mainnet-fork suite against the REAL LIP-118 BondingManager on Arbitrum One.
///
///         Round-advance technique: Livepeer derives currentRound() purely from block.number:
///           currentRound = lastRoundLengthUpdateRound
///                        + (block.number - lastRoundLengthUpdateStartBlock) / roundLength
///         On an Arbitrum fork block.number is the L2 header number (~491M), while the
///         RoundsManager's stored frame is L1-ish (start block ~15.7M). All round math is
///         therefore done in the CONTRACT's frame: we read the two public storage vars and
///         vm.roll(startBlock + (target - lastUpdateRound) * roundLength), then assert
///         rm.currentRound() == target before proceeding.
contract ForkRewardCallerTest is Test {
    // ------------------------------------------------ deployed Arbitrum One addresses
    IController internal constant CONTROLLER = IController(0xD8E8328501E9645d16Cf49539efC04f734606ee4);
    address internal constant BONDING_MANAGER = 0x35Bcf3c30594191d53231E4FF333E8A770453e40;
    address internal constant ROUNDS_MANAGER = 0xdd6f56DcC28D3F5f27084381fE8Df634985cc39f;

    /// LIP-118 target registered at block 489,354,275; this pin is past it and was verified to
    /// serve state. Pinning keeps foundry's RPC cache hot so reruns are fast and deterministic.
    uint256 internal constant PIN_BLOCK = 491_100_000;

    uint256 internal constant SWEEP_TX_GAS = 25_000_000; // keeper-recipe per-tx gas limit
    uint256 internal constant MAX_REWARDS_PER_TX = 15; // keeper-recipe attempt bound
    /// Effective per-call forwarding cap: MIN_CALL_GAS (2.5M floor at pool size 100) - 150k reserve.
    uint256 internal constant FORWARD_CAP = 2_350_000;
    string internal constant ACCESS_REVERT = "caller must be a reward caller set by the transcoder";

    bytes32 internal constant SIG_ROUND_INITIALIZED = keccak256("RoundInitialized(uint256,address)");
    bytes32 internal constant SIG_REWARD_SUCCEEDED = keccak256("RewardCallSucceeded(uint256,address,address,uint256)");
    bytes32 internal constant SIG_REWARD_FAILED = keccak256("RewardCallFailed(uint256,address,address,bytes)");

    LivepeerRewardCaller internal rc;
    IBondingManager internal bm;
    IRoundsManager internal rm;

    uint256 internal roundLen;
    uint256 internal lur; // RoundsManager.lastRoundLengthUpdateRound (contract frame)
    uint256 internal lsb; // RoundsManager.lastRoundLengthUpdateStartBlock (contract frame)
    uint256 internal T0; // first synthetic fresh round: nobody rewarded, round uninitialized
    uint256 internal maxLRR; // max lastRewardRound across the pool at PIN_BLOCK

    address[] internal members; // full active pool at PIN_BLOCK, descending-stake order

    // Per-sweep RewardCallSucceeded capture (rank order == success order == pool order).
    address[] internal rankTranscoder;
    uint256[] internal rankGas;

    function setUp() public {
        // Default is a public ARCHIVE endpoint: the canonical https://arb1.arbitrum.io/rpc prunes
        // state aggressively and stopped serving PIN_BLOCK ("missing trie node", observed 2026-08-04).
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string("https://arbitrum-one.public.blastapi.io"));
        vm.createSelectFork(rpc, PIN_BLOCK);

        bm = IBondingManager(CONTROLLER.getContract(keccak256("BondingManager")));
        rm = IRoundsManager(CONTROLLER.getContract(keccak256("RoundsManager")));
        assertEq(address(bm), BONDING_MANAGER, "registry BondingManager != known proxy");
        assertEq(address(rm), ROUNDS_MANAGER, "registry RoundsManager != known address");

        rc = new LivepeerRewardCaller(CONTROLLER);

        // Verify the extension getters actually exist on the deployed RoundsManager before use.
        (bool okR, bytes memory dR) = ROUNDS_MANAGER.staticcall(abi.encodeWithSignature("lastRoundLengthUpdateRound()"));
        require(okR && dR.length >= 32, "lastRoundLengthUpdateRound() missing on deployed RoundsManager");
        (bool okS, bytes memory dS) =
            ROUNDS_MANAGER.staticcall(abi.encodeWithSignature("lastRoundLengthUpdateStartBlock()"));
        require(okS && dS.length >= 32, "lastRoundLengthUpdateStartBlock() missing on deployed RoundsManager");
        lur = abi.decode(dR, (uint256));
        lsb = abi.decode(dS, (uint256));
        roundLen = rm.roundLength();
        assertEq(roundLen, 6377, "roundLength drifted from the verified on-chain value");

        // One pool walk: membership (descending stake) + the freshest lastRewardRound.
        address t = bm.getFirstTranscoderInPool();
        while (t != address(0)) {
            members.push(t);
            (uint256 lrr,,,,,,,,,) = bm.getTranscoder(t);
            if (lrr > maxLRR) maxLRR = lrr;
            t = bm.getNextTranscoderInPool(t);
        }
        assertEq(members.length, bm.getTranscoderPoolSize(), "pool walk length != pool size");
        assertGt(members.length, 0, "empty transcoder pool at pin block");

        // Fresh synthetic round: above every lastRewardRound AND above lastInitializedRound,
        // so nobody is rewarded yet and the round starts uninitialized.
        uint256 t0 = maxLRR;
        uint256 lastInit = IRoundsManagerExt(ROUNDS_MANAGER).lastInitializedRound();
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

    /// @dev Impersonate every pool member and delegate reward calling to our contract.
    function _subscribeAll() internal {
        for (uint256 i; i < members.length; ++i) {
            vm.prank(members[i]);
            bm.setRewardCaller(address(rc));
            assertEq(bm.transcoderToRewardCaller(members[i]), address(rc), "subscription did not stick");
        }
    }

    function _countActive() internal view returns (uint256 n) {
        for (uint256 i; i < members.length; ++i) {
            if (bm.isActiveTranscoder(members[i])) ++n;
        }
    }

    function _lastRewardRound(address t) internal view returns (uint256 lrr) {
        (lrr,,,,,,,,,) = bm.getTranscoder(t);
    }

    /// @dev Drain recorded logs; collect RewardCallSucceeded gas samples emitted by our contract
    ///      into rankTranscoder/rankGas; return whether RoundInitialized(round) was seen.
    function _collectLogs(uint256 round) internal returns (bool sawInit) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rc)) continue;
            bytes32 sig = logs[i].topics[0];
            if (sig == SIG_REWARD_SUCCEEDED) {
                assertEq(uint256(logs[i].topics[1]), round, "RewardCallSucceeded round mismatch");
                rankTranscoder.push(address(uint160(uint256(logs[i].topics[2]))));
                rankGas.push(abi.decode(logs[i].data, (uint256)));
            } else if (sig == SIG_ROUND_INITIALIZED) {
                assertEq(uint256(logs[i].topics[1]), round, "RoundInitialized round mismatch");
                sawInit = true;
            } else if (sig == SIG_REWARD_FAILED) {
                console2.log("RewardCallFailed for", address(uint160(uint256(logs[i].topics[2]))));
                console2.logBytes(abi.decode(logs[i].data, (bytes)));
            }
        }
    }

    /// @dev The keeper recipe verbatim: rewardAll(15, 0) at a 25M gas limit, repeated until
    ///      complete == true. Captures per-call gas via recordLogs; asserts zero failures and
    ///      that every tx stays under Arbitrum's 32M per-tx cap.
    function _runSweep(uint256 round, bool expectInit) internal returns (uint256 txCount, uint256 totalRewarded) {
        delete rankTranscoder;
        delete rankGas;
        bool complete;
        bool firstTx = true;
        while (!complete) {
            vm.recordLogs();
            uint256 g0 = gasleft();
            (uint256 rewarded, uint256 failed, bool c) = rc.rewardAll{gas: SWEEP_TX_GAS}(MAX_REWARDS_PER_TX, 0);
            uint256 used = g0 - gasleft();
            assertLt(used, 32_000_000, "per-tx gas must stay under Arbitrum's 32M cap");
            bool sawInit = _collectLogs(round);
            if (firstTx && expectInit) {
                assertTrue(sawInit, "first tx of a fresh round must emit RoundInitialized");
            }
            assertEq(failed, 0, "unexpected RewardCallFailed during sweep");
            assertLe(rewarded + failed, MAX_REWARDS_PER_TX, "attempt bound not respected");
            totalRewarded += rewarded;
            complete = c;
            firstTx = false;
            ++txCount;
            require(txCount <= 64, "sweep did not converge");
        }
    }

    /// @dev min / median / max / total over the captured per-call gas samples.
    function _gasStats() internal view returns (uint256 min_, uint256 med_, uint256 max_, uint256 total_) {
        uint256 n = rankGas.length;
        require(n > 0, "no gas samples captured");
        uint256[] memory s = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            s[i] = rankGas[i];
            total_ += rankGas[i];
        }
        // insertion sort (n <= pool size)
        for (uint256 i = 1; i < n; ++i) {
            uint256 key = s[i];
            uint256 j = i;
            while (j > 0 && s[j - 1] > key) {
                s[j] = s[j - 1];
                --j;
            }
            s[j] = key;
        }
        min_ = s[0];
        max_ = s[n - 1];
        med_ = s[n / 2];
    }

    function _slice(address[] memory arr, uint256 start, uint256 n) internal pure returns (address[] memory out) {
        out = new address[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = arr[start + i];
        }
    }

    function _emptyRewardFor() internal {
        rc.rewardFor(new address[](0), new address[](0), new address[](0), 0);
    }

    // ================================================================ A + B + D + E
    /// A: full-pool sweep on a fresh round via the exact keeper recipe.
    /// B: empirical rank -> gasUsed table (the deliverable gating deploy constants).
    /// D: idempotent re-sweep immediately after completion.
    /// E: longevity — the next round works identically through auto-initialize (zero state).
    function test_forkABDE_fullSweep_gasTable_idempotentResweep_longevity() public {
        // ---------------- A
        _rollToRound(T0);
        assertFalse(rm.currentRoundInitialized(), "rolled-to round must start uninitialized");
        _subscribeAll();

        uint256 active = _countActive();
        assertGt(active, 0, "no active transcoders at T0");
        address[] memory pending = rc.getPendingRewardCalls();
        assertEq(pending.length, active, "pending set must equal the subscribed active set");

        (uint256 txCount, uint256 totalRewarded) = _runSweep(T0, true);
        assertEq(totalRewarded, active, "every subscribed active transcoder must be rewarded");
        assertEq(rc.getPendingRewardCalls().length, 0, "nothing may remain pending after a complete sweep");
        for (uint256 i; i < members.length; ++i) {
            uint256 lrr = _lastRewardRound(members[i]);
            if (bm.isActiveTranscoder(members[i])) {
                assertEq(lrr, T0, "subscribed active transcoder missed by the sweep");
            } else {
                assertNotEq(lrr, T0, "inactive transcoder must not be rewarded");
            }
        }
        console2.log("A: eligible active transcoders:", active);
        console2.log("A: txs needed (rewardAll(15,0) @ 25M):", txCount);
        assertLe(txCount, 20, "sweep should complete in a bounded number of txs");

        // ---------------- B
        console2.log("B: rank | transcoder | RewardCallSucceeded.gasUsed");
        for (uint256 i; i < rankGas.length; ++i) {
            console2.log(i + 1, rankTranscoder[i], rankGas[i]);
        }
        (uint256 gMin, uint256 gMed, uint256 gMax, uint256 gTot) = _gasStats();
        console2.log("B: per-call gas min   :", gMin);
        console2.log("B: per-call gas median:", gMed);
        console2.log("B: per-call gas max   :", gMax);
        console2.log("B: hintless total (sum gasUsed):", gTot);
        console2.log("B: forwarded cap (floor - reserve):", FORWARD_CAP);
        assertLt(gMax, FORWARD_CAP, "max per-call gas must sit below the forwarded cap (2.5M - 150k)");
        if (gMax > 2_000_000) {
            console2.log("!!! WARNING: max per-call gas exceeds 2M - deploy gas constants need review !!!");
        }

        // ---------------- D
        uint256 g0 = gasleft();
        (uint256 r2, uint256 f2, bool c2) = rc.rewardAll(0, 0);
        uint256 resweepGas = g0 - gasleft();
        assertEq(r2, 0, "idempotent re-sweep must reward nothing");
        assertEq(f2, 0, "idempotent re-sweep must fail nothing");
        assertTrue(c2, "idempotent re-sweep must scan the whole pool");
        console2.log("D: idempotent full-pool re-sweep gas:", resweepGas);
        assertLt(resweepGas, 5_000_000, "idempotent full-pool re-sweep must cost well under ~5M");

        // ---------------- E
        _rollToRound(T0 + 1);
        assertFalse(rm.currentRoundInitialized(), "next round must start uninitialized");
        uint256 activeNext = _countActive();
        (uint256 txs2, uint256 rewarded2) = _runSweep(T0 + 1, true);
        assertEq(rewarded2, activeNext, "next-round sweep must reward the full active set again");
        for (uint256 i; i < members.length; ++i) {
            if (bm.isActiveTranscoder(members[i])) {
                assertEq(_lastRewardRound(members[i]), T0 + 1, "longevity: active transcoder missed in round T0+1");
            }
        }
        console2.log("E: txs needed for round T0+1 sweep:", txs2);
    }

    // ================================================================ C
    /// Hinted lane: getPendingRewardCalls + getHints -> rewardFor in chunks of 30 must reach
    /// the identical end state for strictly less total gas than the hintless sweep (intra-batch
    /// hint drift included — earlier rewards reorder the list under later hints, and everything
    /// must still succeed). Then adversarial hints must degrade gracefully, never break.
    function test_forkC_hintedLane_beatsHintless_and_survivesAdversarialHints() public {
        _rollToRound(T0);
        _subscribeAll();
        uint256 snap = vm.snapshotState();

        // Hintless baseline on identical state.
        (, uint256 baselineRewarded) = _runSweep(T0, true);
        (,, uint256 hintlessMax, uint256 hintlessTotal) = _gasStats();

        assertTrue(vm.revertToState(snap), "state revert failed");

        // Hinted lane.
        address[] memory pending = rc.getPendingRewardCalls();
        assertEq(pending.length, baselineRewarded, "identical starting state expected after revert");
        (address[] memory prevs, address[] memory nexts) = rc.getHints(pending);

        delete rankTranscoder;
        delete rankGas;
        uint256 hintedRewarded;
        uint256 idx;
        bool first = true;
        while (idx < pending.length) {
            uint256 n = pending.length - idx;
            if (n > 30) n = 30;
            vm.recordLogs();
            (uint256 r, uint256 f, uint256 p) = rc.rewardFor{gas: 30_000_000}(
                _slice(pending, idx, n), _slice(prevs, idx, n), _slice(nexts, idx, n), 0
            );
            bool sawInit = _collectLogs(T0);
            if (first) {
                assertTrue(sawInit, "first hinted call must auto-initialize the round");
                first = false;
            }
            assertEq(f, 0, "stale-hint robustness: intra-batch drift must never cause failures");
            assertGt(p, 0, "hinted chunk made no progress");
            hintedRewarded += r;
            idx += p;
        }
        assertEq(hintedRewarded, baselineRewarded, "hinted lane must reward the identical set");
        for (uint256 i; i < members.length; ++i) {
            if (bm.isActiveTranscoder(members[i])) {
                assertEq(_lastRewardRound(members[i]), T0, "hinted lane end state mismatch");
            }
        }
        uint256 hintedTotal;
        for (uint256 i; i < rankGas.length; ++i) {
            hintedTotal += rankGas[i];
        }
        console2.log("C: hintless total gas (sum gasUsed):", hintlessTotal);
        console2.log("C: hinted   total gas (sum gasUsed):", hintedTotal);
        assertLt(hintedTotal, hintlessTotal, "hinted lane must cost strictly less than hintless");

        // Adversarial hints on identical state: (self,self), reversed (tail,head) extremes,
        // two random non-pool addresses, (address(rewardCaller), address(0)).
        assertTrue(vm.revertToState(snap), "state revert failed");
        pending = rc.getPendingRewardCalls();
        require(pending.length >= 4, "need at least 4 pending transcoders for the adversarial matrix");
        address head = bm.getFirstTranscoderInPool();
        address tail = members[members.length - 1];

        address[] memory ts = new address[](4);
        address[] memory ps = new address[](4);
        address[] memory ns = new address[](4);
        ts[0] = pending[0];
        ps[0] = pending[0]; // (self, self)
        ns[0] = pending[0];
        ts[1] = pending[1];
        ps[1] = tail; // (head, tail) reversed
        ns[1] = head;
        ts[2] = pending[(2 * pending.length) / 3];
        ps[2] = makeAddr("notInPool1"); // two random non-pool addresses
        ns[2] = makeAddr("notInPool2");
        ts[3] = pending[pending.length - 1]; // deepest rank = worst case walk
        ps[3] = address(rc); // (address(rewardCaller), address(0))
        ns[3] = address(0);

        delete rankTranscoder;
        delete rankGas;
        vm.recordLogs();
        (uint256 ra, uint256 fa, uint256 pa) = rc.rewardFor(ts, ps, ns, 0);
        bool sawInitAdv = _collectLogs(T0);
        assertTrue(sawInitAdv, "adversarial call still auto-initializes the round");
        assertEq(ra, 4, "all adversarially-hinted rewards must succeed");
        assertEq(fa, 0, "adversarial hints must never cause failures");
        assertEq(pa, 4, "all adversarial items must be consumed");
        for (uint256 i; i < rankGas.length; ++i) {
            console2.log("C: adversarial-hint gasUsed:", rankGas[i]);
            assertLt(rankGas[i], FORWARD_CAP, "adversarial call must fit under the forwarded cap");
            assertLe(rankGas[i], (hintlessMax * 13) / 10, "adversarial hint gas must stay near the hintless worst case");
        }
    }

    // ================================================================ F
    /// Governance pause: rewardAll / rewardFor must revert SystemPaused.
    function test_forkF_pausedProtocol_revertsSystemPaused() public {
        _rollToRound(T0);
        _subscribeAll();

        address gov = CONTROLLER.owner();
        vm.prank(gov);
        IControllerExt(address(CONTROLLER)).pause();
        assertTrue(CONTROLLER.paused(), "controller must report paused after owner pause()");

        vm.expectRevert(LivepeerRewardCaller.SystemPaused.selector);
        rc.rewardAll(MAX_REWARDS_PER_TX, 0);

        vm.expectRevert(LivepeerRewardCaller.SystemPaused.selector);
        rc.rewardFor(new address[](0), new address[](0), new address[](0), 0);
    }

    // ================================================================ G
    /// Opt-out mid-round is silently skipped by the next sweep; an inactive pool member
    /// (found at the pin, or constructed by rolling to a member's deactivationRound) is
    /// silently skipped as well. failed == 0 throughout — skips, not failures.
    function test_forkG_optOutMidRound_and_inactiveMember_silentlySkipped() public {
        // Find (or construct) an inactive pool member in a fresh round.
        uint256 target = T0;
        address inactiveMember;
        uint256 minFiniteDeact = type(uint256).max;
        address minDeactMember;
        for (uint256 i; i < members.length; ++i) {
            (,,,, uint256 act, uint256 deact,,,,) = bm.getTranscoder(members[i]);
            if (act > T0 || deact <= T0) inactiveMember = members[i];
            if (deact != type(uint256).max && deact > maxLRR && deact < minFiniteDeact) {
                minFiniteDeact = deact;
                minDeactMember = members[i];
            }
        }
        if (inactiveMember != address(0)) {
            console2.log("G: naturally inactive pool member at T0:", inactiveMember);
        } else if (minDeactMember != address(0)) {
            target = minFiniteDeact > T0 ? minFiniteDeact : T0;
            inactiveMember = minDeactMember;
            console2.log("G: constructed inactive member by rolling to its deactivationRound:", inactiveMember);
        } else {
            console2.log("G: no inactive pool member exists or is constructible at the pin - opt-out only");
        }

        _rollToRound(target);
        assertFalse(rm.currentRoundInitialized(), "target round must start uninitialized");
        _subscribeAll();
        if (inactiveMember != address(0)) {
            assertFalse(bm.isActiveTranscoder(inactiveMember), "chosen member must be inactive at target round");
        }

        // Opt out mid-round: subscribed above, now re-points to address(0) before the sweep.
        address optOut;
        for (uint256 i; i < members.length; ++i) {
            if (members[i] != inactiveMember && bm.isActiveTranscoder(members[i])) {
                optOut = members[i];
                break;
            }
        }
        require(optOut != address(0), "no active member available to opt out");
        vm.prank(optOut);
        bm.setRewardCaller(address(0));
        assertEq(bm.transcoderToRewardCaller(optOut), address(0), "opt-out did not stick");

        address[] memory pending = rc.getPendingRewardCalls();
        for (uint256 i; i < pending.length; ++i) {
            assertTrue(pending[i] != optOut, "opted-out transcoder must not be pending");
            assertTrue(pending[i] != inactiveMember, "inactive transcoder must not be pending");
        }

        uint256 active = _countActive();
        (, uint256 rewarded) = _runSweep(target, true);
        assertEq(rewarded, active - 1, "sweep must reward every subscribed active except the opt-out");

        assertNotEq(_lastRewardRound(optOut), target, "opted-out transcoder must be silently skipped");
        if (inactiveMember != address(0)) {
            assertNotEq(_lastRewardRound(inactiveMember), target, "inactive transcoder must be silently skipped");
        }
    }

    // ================================================================ H
    /// THE TRUST TEST: delegation can never harm you.
    ///  1) While subscribed to our contract, the orchestrator's own reward() self-call works.
    ///  2) setRewardCaller(address(0)) then self reward() in the SAME round works.
    function test_forkH_trust_selfRewardNeverHarmedByDelegation() public {
        _rollToRound(T0);

        address x;
        address y;
        for (uint256 i; i < members.length; ++i) {
            if (bm.isActiveTranscoder(members[i])) {
                if (x == address(0)) {
                    x = members[i];
                } else {
                    y = members[i];
                    break;
                }
            }
        }
        require(x != address(0) && y != address(0), "need two active transcoders");

        vm.prank(x);
        bm.setRewardCaller(address(rc));
        vm.prank(y);
        bm.setRewardCaller(address(rc));

        // Initialize the round through the contract's empty-batch path.
        _emptyRewardFor();
        assertTrue(rm.currentRoundInitialized(), "empty rewardFor must auto-initialize the round");

        // 1) Self reward() MUST still succeed while delegated to our contract.
        vm.prank(x);
        IBondingManagerExt(address(bm)).reward();
        assertEq(_lastRewardRound(x), T0, "SELF reward() MUST SUCCEED WHILE DELEGATED");

        // 2) Opt out, then self reward() in the SAME round MUST succeed.
        vm.prank(y);
        bm.setRewardCaller(address(0));
        vm.prank(y);
        IBondingManagerExt(address(bm)).reward();
        assertEq(_lastRewardRound(y), T0, "SELF reward() MUST SUCCEED AFTER SAME-ROUND OPT-OUT");

        // A follow-up sweep neither double-rewards x nor touches unsubscribed y.
        (uint256 r, uint256 f, bool c) = rc.rewardAll(0, 0);
        assertEq(r, 0, "already-self-rewarded transcoder must be skipped");
        assertEq(f, 0, "no failures expected");
        assertTrue(c, "full scan expected");
    }

    // ================================================================ I
    /// The protocol's access check stays intact through our whole flow: direct
    /// rewardForTranscoder[WithHint] from any non-designated caller reverts with the known string.
    function test_forkI_directRewardForTranscoder_accessCheckIntact() public {
        _rollToRound(T0);

        address t;
        address u;
        for (uint256 i; i < members.length; ++i) {
            if (bm.isActiveTranscoder(members[i])) {
                if (t == address(0)) {
                    t = members[i];
                } else {
                    u = members[i];
                    break;
                }
            }
        }
        require(t != address(0) && u != address(0), "need two active transcoders");

        // t delegates to our contract; round initialized through our flow — the only failing
        // condition left for a stranger is the protocol's reward-caller check itself.
        vm.prank(t);
        bm.setRewardCaller(address(rc));
        _emptyRewardFor();
        assertTrue(rm.currentRoundInitialized(), "round must be initialized");

        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(bytes(ACCESS_REVERT));
        bm.rewardForTranscoderWithHint(t, address(0), address(0));

        vm.prank(rando);
        vm.expectRevert(bytes(ACCESS_REVERT));
        IBondingManagerExt(address(bm)).rewardForTranscoder(t);

        // Even our contract's own address cannot reward a transcoder that never delegated to it.
        vm.prank(address(rc));
        vm.expectRevert(bytes(ACCESS_REVERT));
        bm.rewardForTranscoderWithHint(u, address(0), address(0));
    }
}
