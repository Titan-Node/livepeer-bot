// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IController} from "./interfaces/IController.sol";
import {IBondingManager} from "./interfaces/IBondingManager.sol";
import {IRoundsManager} from "./interfaces/IRoundsManager.sol";

/// @title  LivepeerRewardCaller — livepeer.bot
/// @notice A shared, trustless reward-calling service for Livepeer orchestrators on Arbitrum One.
///
///         LIP-118 lets an orchestrator delegate reward calling to a single address via
///         `BondingManager.setRewardCaller(addr)` so the orchestrator key can stay in cold
///         storage. This contract is designed to be that address for ANY number of
///         orchestrators at once:
///
///           * Opt in:  from your orchestrator key, call `setRewardCaller(<this contract>)`. Once.
///           * Opt out: `setRewardCaller(address(0))` (or point it anywhere else). Any time.
///           * Your own `reward()` self-call keeps working regardless — delegation only ADDS a caller.
///
///         Every round, anyone — a keeper bot, another orchestrator, a stranger — calls
///         `rewardAll` and this contract attempts reward for every subscribed active
///         orchestrator that hasn't been rewarded yet this round.
///
///         Trust posture: this contract is immutable, has NO owner, NO pause switch, NO storage,
///         holds NO funds, and can only ever call `rewardForTranscoderWithHint` for orchestrators
///         who explicitly delegated to it. Reward amounts are fixed by the protocol at round
///         initialization, so nothing about WHO triggers the call or WHEN within the round
///         changes what an orchestrator earns. Worst possible failure is a missed reward call —
///         never loss of funds. Migration path if a v2 is ever wanted: orchestrators re-point
///         `setRewardCaller`.
///
/// @dev    KEEPER RECIPE (once per round, after the round rolls):
///           1. staticcall `getPendingRewardCalls()`; if empty and the round is initialized,
///              check the EVICTION EDGE below, then done.
///           2. send `rewardAll(15, 0)` with a ~25M gas limit. The first call of a round also
///              initializes the round automatically.
///           3. repeat until the `BatchProcessed` event reports `complete == true` AND the pending
///              view is empty. If pending is unchanged across two consecutive txs that each made
///              progress (`processed > 0`), STOP and alert — a persistently failing transcoder
///              would keep you retrying forever. If a tx reverts `InsufficientGas`, RAISE the gas
///              limit — the tx could not afford even one attempt.
///           4. EVICTION EDGE: the pool views cannot see a subscriber who was pushed OUT of the
///              pool mid-round (out-competed by a new bond, resigned, or slashed) — the protocol
///              keeps them reward-eligible until the round ends, but they are no longer in the
///              pool this contract walks. Watch BondingManager `TranscoderDeactivated` events
///              where `deactivationRound == currentRound + 1` (or diff the pool set against the
///              round start), confirm with `filterPendingRewardCalls(candidates)`, and rescue via
///              `rewardFor(candidates, zeros, zeros, 0)` before the round ends.
///           5. alert on: any `RewardCallFailed` (pre-checks filter every expected failure, so a
///              failure means protocol drift — investigate); repeated `InsufficientGas` after
///              raising gas; pending still non-empty past ~80% of the round.
///
///         GAS LIMITS: hardcode ~25M and pass `rewardAll(15, 0)` — simplest and robust. If you
///         must rely on eth_estimateGas: estimates cover the WORK a call happens to do during
///         simulation but NOT the per-iteration safety floor this contract insists on before
///         attempting anything (>= 2.5M headroom, see MIN_CALL_GAS); add that floor on top of the
///         estimate or the tx may afford zero attempts. A tx that cannot afford even ONE attempt
///         reverts `InsufficientGas` (it will not silently no-op), so estimators converge on a
///         workable limit. Mid-sweep the gas floor still truncates gracefully (`complete ==
///         false` → just call again; already-rewarded orchestrators are skipped for ~25k gas
///         each, so repeat calls are idempotent and concurrent callers never conflict).
///
///         Efficiency lane (optional): `getPendingRewardCalls()` + `getHints()` off-chain, then
///         `rewardFor(chunkOf30, prevs, nexts, 0)` — hinted insertion skips the hintless
///         head-scan (measured ~15% total savings on the real 100-pool; grows if the pool
///         reorders more). At Arbitrum's ~0.02 gwei floor this is pennies and entirely optional.
contract LivepeerRewardCaller {
    // ---------------------------------------------------------------- errors

    /// @notice A zero address was supplied or the Controller registry failed to resolve.
    error ZeroAddress();
    /// @notice The Livepeer protocol is paused; nothing can be rewarded.
    error SystemPaused();
    /// @notice The current round is not initialized and initializeRound() reverted.
    /// @param reason Raw revert data from RoundsManager.initializeRound(). An EMPTY reason
    ///        usually means the initializeRound subcall itself ran out of gas (the caller
    ///        under-provisioned the tx) — raise the gas limit before suspecting protocol drift.
    error RoundNotInitializable(bytes reason);
    /// @notice rewardFor array arguments differ in length.
    error LengthMismatch();
    /// @notice The tx could not afford even ONE reward attempt (gas fell below the
    ///         per-iteration floor before any attempt was made — scanning skippable pool nodes
    ///         does not count as progress). Raise the gas limit; without this revert,
    ///         estimation-sized gas limits could produce silent zero-progress transactions.
    error InsufficientGas();

    // ---------------------------------------------------------------- events

    /// @notice This contract's opportunistic RoundsManager.initializeRound() succeeded.
    event RoundInitialized(uint256 indexed round, address indexed caller);

    /// @notice A delegated reward call landed for `transcoder`.
    /// @param gasUsed Gas consumed by the BondingManager call — feeds ongoing chunk-size calibration.
    event RewardCallSucceeded(
        uint256 indexed round, address indexed transcoder, address indexed caller, uint256 gasUsed
    );

    /// @notice A delegated reward call reverted AFTER passing every pre-check.
    /// @dev    Pre-checks mirror the protocol's own require conditions, so any occurrence of this
    ///         event indicates protocol drift or an unexpected state edge — alert on it.
    /// @param revertData Raw revert payload (Error(string), custom error, or empty for OOG).
    event RewardCallFailed(uint256 indexed round, address indexed transcoder, address indexed caller, bytes revertData);

    /// @notice One-time deployment fingerprint: the registry this instance is permanently bound
    ///         to and the managers it resolved at construction — on-chain verifiability that the
    ///         immutable binding targets the canonical Livepeer deployment (audit #567, finding 6).
    event Deployed(address indexed controller, address bondingManager, address roundsManager);

    /// @notice Exactly one per rewardAll/rewardFor invocation — the keeper's resume/stop signal.
    /// @param processed Pool nodes scanned (rewardAll) or array items consumed (rewardFor).
    /// @param complete  True when the sweep reached the end of the pool/array; false when it was
    ///                  truncated by the gas floor or `_maxRewards` — call again to resume.
    event BatchProcessed(
        uint256 indexed round,
        address indexed caller,
        uint256 processed,
        uint256 rewarded,
        uint256 failed,
        bool complete
    );

    // ------------------------------------------------------- constants / immutables

    /// @notice The Livepeer Controller (registry + pause switch). The only stored value.
    IController public immutable CONTROLLER;

    bytes32 private constant BONDING_MANAGER_ID = keccak256("BondingManager");
    bytes32 private constant ROUNDS_MANAGER_ID = keccak256("RoundsManager");

    /// @notice Hard minimum of the per-iteration gas floor. > 2x the worst observed hintless
    ///         reward call (~1.2M incl. treasury cut + BondingVotes checkpoint), so an honest
    ///         reward can never OOG inside the capped subcall.
    uint256 public constant MIN_CALL_GAS = 2_500_000;

    /// @notice Pool-size-aware floor component: BASE_CALL_GAS + poolSize * PER_NODE_MARGIN.
    ///         Keeps the hintless O(rank) head-scan safe if governance ever raises the 100 cap.
    uint256 public constant BASE_CALL_GAS = 1_500_000;
    uint256 public constant PER_NODE_MARGIN = 10_000;

    /// @notice Ceiling on the AUTOMATIC gas floor. Without it, pool growth past ~3,050 members
    ///         would push the floor beyond Arbitrum's 32M per-tx cap and every call would revert
    ///         unconditionally — permanently bricking an immutable contract (audit #567,
    ///         finding 1). 20M still forwards ~19.5M to a single reward call, which covers a
    ///         hintless tail reward even in a ~3,000-node pool. The caller-supplied
    ///         `_minGasPerCall` may still raise the floor above this ceiling explicitly.
    uint256 public constant MAX_GAS_FLOOR = 20_000_000;

    /// @notice Base gas retained (not forwarded to the reward call) for pre-checks already
    ///         spent, result events, and loop bookkeeping. The effective reserve scales with the
    ///         gas floor (`CALL_GAS_RESERVE + gasFloor/64`) so the explicit gas request stays
    ///         grantable under EIP-150's 63/64 rule even if governance grows the pool far beyond
    ///         today's cap. Forwarding is CAPPED at floor - reserve so a pathologically expensive
    ///         item burns a bounded amount and the sweep continues past it.
    uint256 public constant CALL_GAS_RESERVE = 150_000;

    /// @notice Revert payloads from a failed reward call are truncated to this many bytes before
    ///         being emitted in RewardCallFailed. Enough for any error selector or Error(string)
    ///         prefix; prevents a hostile/drifted callee from OOG-ing the catch path with a huge
    ///         payload and reverting the whole sweep.
    uint256 public constant MAX_REVERT_DATA_BYTES = 256;

    // ---------------------------------------------------------------- constructor

    /// @param _controller The Livepeer Controller (Arbitrum One: 0xD8E8328501E9645d16Cf49539efC04f734606ee4).
    constructor(IController _controller) {
        if (address(_controller) == address(0)) revert ZeroAddress();
        // Deploy-time sanity check: both registry ids must resolve (catches wrong-network deploys).
        address bm = _controller.getContract(BONDING_MANAGER_ID);
        address rm = _controller.getContract(ROUNDS_MANAGER_ID);
        if (bm == address(0) || rm == address(0)) revert ZeroAddress();
        CONTROLLER = _controller;
        emit Deployed(address(_controller), bm, rm);
    }

    // ---------------------------------------------------------------- write layer

    /// @notice Sweep the active transcoder pool head-to-tail and attempt a (hintless) reward call
    ///         for every subscribed, active, not-yet-rewarded transcoder. Permissionless.
    /// @param _maxRewards    Max reward ATTEMPTS (successes + failures) this tx; 0 = unbounded.
    ///                       Estimating bots must pass a bound (15 recommended).
    /// @param _minGasPerCall Raises (never lowers) the per-iteration gas floor above the built-in
    ///                       minimum — future-proofing if protocol upgrades make reward costlier.
    /// @return rewarded  Successful reward calls.
    /// @return failed    Reward calls that reverted after passing pre-checks (alert condition).
    /// @return complete  True if the whole pool was scanned; false if truncated — call again.
    function rewardAll(uint256 _maxRewards, uint256 _minGasPerCall)
        external
        returns (uint256 rewarded, uint256 failed, bool complete)
    {
        uint256 round = _preflight();
        IBondingManager bm = _bondingManager();
        uint256 gasFloor = _effectiveGasFloor(bm, _minGasPerCall);
        uint256 maxAttempts = _maxRewards == 0 ? type(uint256).max : _maxRewards;

        uint256 processed;
        complete = true;
        address t = bm.getFirstTranscoderInPool();
        while (t != address(0)) {
            if (rewarded + failed >= maxAttempts) {
                complete = false;
                break;
            }
            if (gasleft() < gasFloor) {
                // Attempts are the progress that matters: scanning skippable nodes must not
                // mask a tx that can never afford a reward call (audit #565, finding 2).
                if (rewarded + failed == 0) revert InsufficientGas();
                complete = false;
                break;
            }
            // Capture the next pointer BEFORE rewarding: a successful reward moves `t` up-list
            // in the descending sorted pool, but never disturbs the node it pointed down to.
            address nxt = bm.getNextTranscoderInPool(t);
            unchecked {
                ++processed;
            }
            if (_shouldAttempt(bm, t, round)) {
                if (_attemptReward(bm, t, round, gasFloor, address(0), address(0))) {
                    unchecked {
                        ++rewarded;
                    }
                } else {
                    unchecked {
                        ++failed;
                    }
                }
            }
            t = nxt;
        }

        emit BatchProcessed(round, msg.sender, processed, rewarded, failed, complete);
    }

    /// @notice Attempt reward calls for an explicit list, with optional per-item pool-position
    ///         hints ((address(0), address(0)) = hintless for that item). Permissionless.
    /// @dev    Hints are forwarded verbatim and unvalidated: the BondingManager validates hint
    ///         positions itself and degrades gracefully to a list walk, so a wrong hint at worst
    ///         costs the hintless price for that one item. Already-rewarded entries are silently
    ///         skipped, so duplicates of a SUCCESSFUL entry are idempotent — but a duplicate whose
    ///         first attempt FAILED is re-attempted, emitting one RewardCallFailed per occurrence
    ///         (dedupe client-side if that matters for your alerting; failures here should be
    ///         protocol-drift-rare anyway). Empty arrays are a valid "just initialize the round"
    ///         call.
    /// @param _minGasPerCall Raises (never lowers) the per-iteration gas floor.
    /// @return rewarded  Successful reward calls.
    /// @return failed    Reward calls that reverted after passing pre-checks.
    /// @return processed Items consumed from the front of the arrays; on truncation, resubmit the
    ///                   tail `_transcoders[processed:]` (resubmitting everything is equally safe).
    function rewardFor(
        address[] calldata _transcoders,
        address[] calldata _newPosPrevs,
        address[] calldata _newPosNexts,
        uint256 _minGasPerCall
    ) external returns (uint256 rewarded, uint256 failed, uint256 processed) {
        uint256 len = _transcoders.length;
        if (_newPosPrevs.length != len || _newPosNexts.length != len) revert LengthMismatch();

        uint256 round = _preflight();
        IBondingManager bm = _bondingManager();
        uint256 gasFloor = _effectiveGasFloor(bm, _minGasPerCall);

        for (uint256 i; i < len; ++i) {
            if (gasleft() < gasFloor) {
                if (rewarded + failed == 0) revert InsufficientGas();
                break;
            }
            address t = _transcoders[i];
            unchecked {
                ++processed;
            }
            if (_shouldAttempt(bm, t, round)) {
                if (_attemptReward(bm, t, round, gasFloor, _newPosPrevs[i], _newPosNexts[i])) {
                    unchecked {
                        ++rewarded;
                    }
                } else {
                    unchecked {
                        ++failed;
                    }
                }
            }
        }

        emit BatchProcessed(round, msg.sender, processed, rewarded, failed, processed == len);
    }

    // ---------------------------------------------------------------- view layer

    /// @notice Every POOL transcoder a sweep would attempt right now: subscribed to this
    ///         contract, active this round, and not yet rewarded this round. Pool
    ///         (descending-stake) order.
    /// @dev    The predicate is EXACTLY the write path's, but the enumeration is the pool walk —
    ///         which is the protocol's NEXT-round set. A subscriber evicted/resigned/slashed out
    ///         of the pool mid-round remains reward-eligible until the round ends yet is INVISIBLE
    ///         here and to rewardAll. Keepers must discover such transcoders off-chain
    ///         (BondingManager `TranscoderDeactivated` with deactivationRound == currentRound+1,
    ///         or a pool-set diff), confirm via `filterPendingRewardCalls`, and rescue via
    ///         `rewardFor`. Note: at the top of a fresh round (before initialization) this
    ///         correctly lists the full subscribed set; rewardAll/rewardFor initialize the round
    ///         themselves. In a far-future giant pool this O(poolSize) walk could exceed an RPC's
    ///         eth_call gas cap — prefer RewardCallerSet event discovery plus batched
    ///         `filterPendingRewardCalls` (the documented keeper recipe already does exactly that).
    function getPendingRewardCalls() external view returns (address[] memory pending) {
        IBondingManager bm = _bondingManager();
        uint256 round = _roundsManager().currentRound();
        pending = new address[](bm.getTranscoderPoolSize());
        uint256 n;
        address t = bm.getFirstTranscoderInPool();
        while (t != address(0)) {
            if (_shouldAttempt(bm, t, round)) {
                pending[n++] = t;
            }
            t = bm.getNextTranscoderInPool(t);
        }
        assembly {
            mstore(pending, n) // truncate to n entries
        }
    }

    /// @notice The subset of `_candidates` that a reward attempt would be made for right now
    ///         (subscribed to this contract, active this round, not yet rewarded this round) —
    ///         the same predicate as the sweep, WITHOUT the pool-walk enumeration blind spot.
    /// @dev    Companion to the eviction edge documented on getPendingRewardCalls: feed it
    ///         mid-round-deactivated subscribers discovered off-chain, then `rewardFor` whatever
    ///         it returns. Duplicate candidates yield duplicate entries (rewardFor dedups by
    ///         effect: the second occurrence is skipped once lastRewardRound is set).
    function filterPendingRewardCalls(address[] calldata _candidates) external view returns (address[] memory pending) {
        IBondingManager bm = _bondingManager();
        uint256 round = _roundsManager().currentRound();
        uint256 len = _candidates.length;
        pending = new address[](len);
        uint256 n;
        for (uint256 i; i < len; ++i) {
            if (_shouldAttempt(bm, _candidates[i], round)) {
                pending[n++] = _candidates[i];
            }
        }
        assembly {
            mstore(pending, n) // truncate to n entries
        }
    }

    /// @notice Current (prev, next) pool neighbors for each requested transcoder, from one pool
    ///         walk — near-optimal insertion hints for `rewardFor`. Not-in-pool → (0,0) = hintless.
    /// @dev    Deliberately does NOT predict post-reward positions: current neighbors are close
    ///         enough (the protocol walks from the hint node) and prediction would replicate
    ///         reward math that can change under protocol upgrades.
    function getHints(address[] calldata _transcoders)
        external
        view
        returns (address[] memory newPosPrevs, address[] memory newPosNexts)
    {
        IBondingManager bm = _bondingManager();
        uint256 len = _transcoders.length;
        newPosPrevs = new address[](len);
        newPosNexts = new address[](len);

        address prev = address(0);
        address t = bm.getFirstTranscoderInPool();
        while (t != address(0)) {
            address nxt = bm.getNextTranscoderInPool(t);
            for (uint256 i; i < len; ++i) {
                if (_transcoders[i] == t) {
                    newPosPrevs[i] = prev;
                    newPosNexts[i] = nxt;
                }
            }
            prev = t;
            t = nxt;
        }
    }

    /// @notice Contract identity for dashboards; v2+ would be a NEW address orchestrators re-point to.
    function version() external pure returns (string memory) {
        return "LivepeerRewardCaller/1.0.0";
    }

    // ---------------------------------------------------------------- internals

    /// @dev Shared entry gate: revert when nothing could possibly succeed (so keeper gas
    ///      estimation fails pre-send instead of landing doomed txs), opportunistically
    ///      initialize the round, and read currentRound EXACTLY once per external call.
    function _preflight() private returns (uint256 round) {
        if (CONTROLLER.paused()) revert SystemPaused();
        IRoundsManager rm = _roundsManager();
        bool wasInitialized = rm.currentRoundInitialized();
        if (!wasInitialized) {
            try rm.initializeRound() {}
            catch (bytes memory reason) {
                revert RoundNotInitializable(reason);
            }
        }
        round = rm.currentRound();
        if (!wasInitialized) {
            emit RoundInitialized(round, msg.sender);
        }
    }

    /// @dev Per-iteration gas floor: max(caller-raised, pool-size-aware term, hard minimum),
    ///      with the automatic part capped at MAX_GAS_FLOOR so pool growth can never make the
    ///      floor unsatisfiable under Arbitrum's per-tx gas cap. Clamp-up-only — no caller can
    ///      lower it to induce misattributed OOG failures.
    function _effectiveGasFloor(IBondingManager bm, uint256 _minGasPerCall) private view returns (uint256 gasFloor) {
        gasFloor = BASE_CALL_GAS + bm.getTranscoderPoolSize() * PER_NODE_MARGIN;
        if (gasFloor < MIN_CALL_GAS) gasFloor = MIN_CALL_GAS;
        if (gasFloor > MAX_GAS_FLOOR) gasFloor = MAX_GAS_FLOOR;
        if (gasFloor < _minGasPerCall) gasFloor = _minGasPerCall;
    }

    /// @dev The exact attempt predicate, cheapest-and-most-selective first; every miss is a
    ///      silent skip. Mirrors the protocol's own require conditions so that any revert that
    ///      still reaches the actual reward call is a true alert signal.
    function _shouldAttempt(IBondingManager bm, address t, uint256 round) private view returns (bool) {
        // [a] subscribed to this contract?
        if (bm.transcoderToRewardCaller(t) != address(this)) return false;
        // [b] not yet rewarded this round? lastRewardRound is the first return word of
        //     getTranscoder; decoded raw so a future tuple EXTENSION cannot break us.
        (bool ok, bytes memory data) = address(bm).staticcall(abi.encodeCall(IBondingManager.getTranscoder, (t)));
        if (!ok || data.length < 32) return false;
        uint256 lastRewardRound;
        assembly {
            lastRewardRound := mload(add(data, 0x20))
        }
        if (lastRewardRound == round) return false;
        // [c] active in the current round? (pool membership alone means active NEXT round)
        if (!bm.isActiveTranscoder(t)) return false;
        return true;
    }

    /// @dev One guarded reward call. Gas forwarding is CAPPED (never the 63/64 default) so a
    ///      pathologically expensive item burns at most gasFloor - reserve, gets caught, and the
    ///      sweep continues past it. The reserve scales with the floor so the explicit gas
    ///      request is always actually grantable under EIP-150 (audit #565, finding 4). A raw
    ///      call + bounded revert-data copy replaces try/catch so a huge revert payload cannot
    ///      OOG the failure path and revert the whole sweep (audit #565, finding 1). Failures
    ///      (incl. subcall OOG) are absorbed either way; pre-check [a] runs a typed staticcall
    ///      against the same target first, so a codeless target hard-reverts the entrypoint
    ///      before this vacuous-success path could ever be reached.
    function _attemptReward(
        IBondingManager bm,
        address t,
        uint256 round,
        uint256 gasFloor,
        address prevHint,
        address nextHint
    ) private returns (bool ok) {
        uint256 fwd = gasFloor - (CALL_GAS_RESERVE + gasFloor / 64);
        uint256 g0 = gasleft();
        // Assembly call with a ZERO-LENGTH output buffer: a high-level `(ok,) = .call(...)`
        // would still materialize the callee's full returndata in this frame before discarding
        // it, so a multi-hundred-KB revert bomb could OOG us on memory expansion despite the
        // bounded copy below (audit #567, finding 3). This way _boundedRevertData() is the ONLY
        // copy that ever happens.
        bytes memory payload = abi.encodeCall(IBondingManager.rewardForTranscoderWithHint, (t, prevHint, nextHint));
        assembly ("memory-safe") {
            ok := call(fwd, bm, 0, add(payload, 0x20), mload(payload), 0, 0)
        }
        if (ok) {
            emit RewardCallSucceeded(round, t, msg.sender, g0 - gasleft());
        } else {
            emit RewardCallFailed(round, t, msg.sender, _boundedRevertData());
        }
    }

    /// @dev Copy at most MAX_REVERT_DATA_BYTES of the last call's revert data. Must run before
    ///      any other external call clobbers the returndata buffer.
    function _boundedRevertData() private pure returns (bytes memory data) {
        assembly ("memory-safe") {
            let size := returndatasize()
            if gt(size, 256) { size := 256 } // keep literal in sync with MAX_REVERT_DATA_BYTES
            data := mload(0x40)
            mstore(data, size)
            returndatacopy(add(data, 0x20), 0, size)
            mstore(0x40, add(add(data, 0x20), and(add(size, 0x1f), not(0x1f))))
        }
    }

    /// @dev Registry resolution, once per external call. Per-call (rather than immutable proxy
    ///      pins) so a governance re-registration can never strand this zero-admin contract.
    function _bondingManager() private view returns (IBondingManager bm) {
        address a = CONTROLLER.getContract(BONDING_MANAGER_ID);
        if (a == address(0)) revert ZeroAddress();
        bm = IBondingManager(a);
    }

    function _roundsManager() private view returns (IRoundsManager rm) {
        address a = CONTROLLER.getContract(ROUNDS_MANAGER_ID);
        if (a == address(0)) revert ZeroAddress();
        rm = IRoundsManager(a);
    }
}
