// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IBondingManager} from "../../../src/interfaces/IBondingManager.sol";

/// @notice Instrumented model of the LIP-118 BondingManager surface used by
///         LivepeerRewardCaller: a descending-stake sorted doubly linked pool,
///         the transcoderToRewardCaller registry with the REAL access-check revert
///         string, per-address failure modes for the reward call, and an
///         inspectable log of every reward invocation (msg.sender, hints, order).
///
///         STORAGE LAYOUT CONTRACT (relied on by UnitBase slot helpers — do NOT reorder):
///           slot 0: _rewardCallerOf    -> pre-check [a] transcoderToRewardCaller
///           slot 1: _lastRewardRoundOf -> pre-check [b] getTranscoder word 0
///           slot 2: _activeFlag        -> pre-check [c] isActiveTranscoder
///         Each of the three pre-check views reads EXACTLY ONE distinguishing mapping
///         slot (plus the fixed-slot poison flag). The caller invokes them via
///         STATICCALL, where the mock cannot write a log, so tests reconstruct
///         pre-check invocation ORDER from vm.record()/vm.accesses() read traces
///         over these slots instead.
contract MockBondingManager is IBondingManager {
    // -------------------------------------------------- pre-check slots (0,1,2)
    mapping(address => address) internal _rewardCallerOf; // slot 0
    mapping(address => uint256) internal _lastRewardRoundOf; // slot 1
    mapping(address => uint256) internal _activeFlag; // slot 2 (1 = active)

    // -------------------------------------------------- pool (descending stake)
    mapping(address => address) internal _next; // slot 3
    mapping(address => address) internal _prev; // slot 4
    mapping(address => bool) internal _inPool; // slot 5
    address internal _head; // slot 6
    uint256 internal _poolSize; // slot 7
    mapping(address => uint256) internal _stake; // slot 8

    // -------------------------------------------------- behavior config
    enum FailureMode {
        None, // reward succeeds
        RevertString, // revert with Error(string)
        RevertCustom, // revert with a custom error
        RevertEmpty, // revert with empty data
        GasBomb, // consume ALL forwarded gas (infinite loop)
        BurnThenSucceed, // burn a configured amount of gas, then succeed
        RevertHuge // revert with a HUGE_REVERT_SIZE payload (audit #565 finding 1 regression)
    }

    /// @notice Size of the RevertHuge payload — far beyond MAX_REVERT_DATA_BYTES.
    uint256 public constant HUGE_REVERT_SIZE = 8192;

    error RewardBroken(address transcoder, uint256 code);

    /// @notice Exact access-check revert string of the deployed LIP-118 BondingManager
    ///         (impl 0xbe197fcBfe74DE8F10460EA61644B006cC0f0Bd2, git commit ccc82f43).
    string public constant ACCESS_REVERT = "caller must be a reward caller set by the transcoder";
    uint256 public constant CUSTOM_ERROR_CODE = 42;

    mapping(address => FailureMode) internal _failureMode;
    mapping(address => uint256) internal _burnAmount;
    string internal _rewardFailReason = "MOCK_REWARD_STRING_FAILURE";
    bool internal _moveOnReward; // model the protocol re-sort: move rewarded node to head
    bool internal _poisonViews; // make every view revert (proves a code path never reads the pool)
    uint256 internal _currentRound; // kept in sync with MockRoundsManager by the test harness

    // -------------------------------------------------- reward-call log
    struct RewardCall {
        address caller;
        address transcoder;
        address prevHint;
        address nextHint;
        uint256 round;
    }

    RewardCall[] public rewardCalls;
    mapping(address => uint256) public rewardCallCountOf;

    // ================================================== IBondingManager: views
    function transcoderToRewardCaller(address _transcoder) external view returns (address) {
        if (_poisonViews) revert("POISONED_VIEW");
        return _rewardCallerOf[_transcoder];
    }

    /// @dev lastRewardRound FIRST; the other nine fields are non-zero sentinels so a
    ///      caller that decoded the wrong word would be caught by the tests.
    ///      Per-transcoder drift knobs (see GetTranscoderMode) can make this view revert
    ///      or return FEWER than 32 raw bytes; the extra mode-mapping read lives on a
    ///      slot the UnitBase trace helpers do not match, so pre-check ORDER decoding
    ///      over slots 0/1/2 is unaffected.
    function getTranscoder(address _transcoder)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
    {
        if (_poisonViews) revert("POISONED_VIEW");
        GetTranscoderMode mode = _getTranscoderMode[_transcoder];
        if (mode == GetTranscoderMode.Revert) revert("GET_TRANSCODER_BROKEN");
        if (mode == GetTranscoderMode.ShortReturn) {
            uint256 len = _shortReturnLength;
            assembly ("memory-safe") {
                mstore(0x00, not(0)) // garbage payload: a sloppy decoder would read junk, not zero
                return(0x00, len)
            }
        }
        return (_lastRewardRoundOf[_transcoder], 1, 2, 3, 4, 5, 6, 7, 8, 9);
    }

    function isActiveTranscoder(address _transcoder) external view returns (bool) {
        if (_poisonViews) revert("POISONED_VIEW");
        return _activeFlag[_transcoder] == 1;
    }

    function getTranscoderPoolSize() external view returns (uint256) {
        if (_poisonViews) revert("POISONED_VIEW");
        return _poolSize;
    }

    function getFirstTranscoderInPool() external view returns (address) {
        if (_poisonViews) revert("POISONED_VIEW");
        return _head;
    }

    function getNextTranscoderInPool(address _transcoder) external view returns (address) {
        if (_poisonViews) revert("POISONED_VIEW");
        return _next[_transcoder];
    }

    // ================================================== IBondingManager: writes
    /// @notice Real opt-in path: msg.sender is the transcoder key.
    function setRewardCaller(address _rewardCaller) external {
        _rewardCallerOf[msg.sender] = _rewardCaller;
    }

    function rewardForTranscoderWithHint(address _transcoder, address _newPosPrev, address _newPosNext) external {
        // Real LIP-118 access check with the real revert string.
        require(_rewardCallerOf[_transcoder] == msg.sender, ACCESS_REVERT);

        FailureMode mode = _failureMode[_transcoder];
        if (mode == FailureMode.RevertString) revert(_rewardFailReason);
        if (mode == FailureMode.RevertCustom) revert RewardBroken(_transcoder, CUSTOM_ERROR_CODE);
        if (mode == FailureMode.RevertEmpty) revert();
        if (mode == FailureMode.GasBomb) {
            // Consume every unit of forwarded gas. Inline assembly so no optimizer
            // can reason the loop away.
            assembly ("memory-safe") {
                for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
            }
        }
        if (mode == FailureMode.BurnThenSucceed) _burnGas(_burnAmount[_transcoder]);
        if (mode == FailureMode.RevertHuge) {
            // Deterministic byte pattern so tests can assert the exact truncated prefix.
            bytes memory big = new bytes(HUGE_REVERT_SIZE);
            for (uint256 i; i < big.length; ++i) {
                big[i] = bytes1(uint8(i));
            }
            assembly ("memory-safe") {
                revert(add(big, 0x20), mload(big))
            }
        }

        rewardCalls.push(
            RewardCall({
                caller: msg.sender,
                transcoder: _transcoder,
                prevHint: _newPosPrev,
                nextHint: _newPosNext,
                round: _currentRound
            })
        );
        rewardCallCountOf[_transcoder]++;
        _lastRewardRoundOf[_transcoder] = _currentRound;

        if (_moveOnReward) _moveToHead(_transcoder);
    }

    // ================================================== test knobs
    function addToPool(address _transcoder, uint256 _stakeAmount) external {
        require(_transcoder != address(0), "zero transcoder");
        require(!_inPool[_transcoder], "already in pool");
        _stake[_transcoder] = _stakeAmount;
        _insertSorted(_transcoder, _stakeAmount);
        _inPool[_transcoder] = true;
        _poolSize++;
    }

    /// @notice Unlink a node from the pool WITHOUT touching its active flag,
    ///         lastRewardRound, or reward-caller subscription — the exact state the real
    ///         BondingManager leaves behind when `tryToJoinActiveSet` kicks the tail
    ///         mid-round (or on resignTranscoder / slashing): the evictee stays
    ///         `isActiveTranscoder() == true` and reward-eligible until the round ends,
    ///         but the pool walk can no longer see it.
    function removeFromPool(address _transcoder) external {
        require(_inPool[_transcoder], "not in pool");
        address p = _prev[_transcoder];
        address n = _next[_transcoder];
        if (p == address(0)) _head = n;
        else _next[p] = n;
        if (n != address(0)) _prev[n] = p;
        _next[_transcoder] = address(0);
        _prev[_transcoder] = address(0);
        _inPool[_transcoder] = false;
        _poolSize--;
    }

    function setRewardCallerFor(address _transcoder, address _caller) external {
        _rewardCallerOf[_transcoder] = _caller;
    }

    function setLastRewardRound(address _transcoder, uint256 _r) external {
        _lastRewardRoundOf[_transcoder] = _r;
    }

    function setActive(address _transcoder, bool _active) external {
        _activeFlag[_transcoder] = _active ? 1 : 0;
    }

    function setFailureMode(address _transcoder, FailureMode _mode) external {
        _failureMode[_transcoder] = _mode;
    }

    function setBurnAmount(address _transcoder, uint256 _amount) external {
        _burnAmount[_transcoder] = _amount;
    }

    function setRewardFailReason(string calldata _reason) external {
        _rewardFailReason = _reason;
    }

    function setMoveOnReward(bool _move) external {
        _moveOnReward = _move;
    }

    function setPoisonViews(bool _poison) external {
        _poisonViews = _poison;
    }

    function setCurrentRound(uint256 _r) external {
        _currentRound = _r;
    }

    // ================================================== getTranscoder drift knobs
    // State declared AFTER every pre-existing variable so the trace-decoded slots
    // (0, 1, 2 — see the layout contract above) never move.

    enum GetTranscoderMode {
        Normal, // regular full-tuple return
        Revert, // getTranscoder reverts -> a raw staticcall observes ok == false
        ShortReturn // getTranscoder returns `_shortReturnLength` (< 32) raw bytes
    }

    mapping(address => GetTranscoderMode) internal _getTranscoderMode;
    uint256 internal _shortReturnLength = 16;

    function setGetTranscoderMode(address _transcoder, GetTranscoderMode _mode) external {
        _getTranscoderMode[_transcoder] = _mode;
    }

    /// @dev Raw returndata length used in ShortReturn mode; must stay below one word.
    function setShortReturnLength(uint256 _len) external {
        require(_len < 32, "not short");
        _shortReturnLength = _len;
    }

    // ================================================== inspection helpers
    function rewardCallsLength() external view returns (uint256) {
        return rewardCalls.length;
    }

    function lastRewardRoundOf(address _transcoder) external view returns (uint256) {
        return _lastRewardRoundOf[_transcoder];
    }

    function rewardFailReason() external view returns (string memory) {
        return _rewardFailReason;
    }

    function stakeOf(address _transcoder) external view returns (uint256) {
        return _stake[_transcoder];
    }

    // ================================================== internals
    function _insertSorted(address _t, uint256 _stakeAmount) internal {
        address cur = _head;
        address p = address(0);
        while (cur != address(0) && _stake[cur] >= _stakeAmount) {
            p = cur;
            cur = _next[cur];
        }
        _next[_t] = cur;
        _prev[_t] = p;
        if (p == address(0)) _head = _t;
        else _next[p] = _t;
        if (cur != address(0)) _prev[cur] = _t;
    }

    /// @dev Models the protocol's post-reward re-sort as the maximal up-list move.
    function _moveToHead(address _t) internal {
        if (_head == _t) return;
        address p = _prev[_t];
        address n = _next[_t];
        if (p != address(0)) _next[p] = n;
        if (n != address(0)) _prev[n] = p;
        _prev[_t] = address(0);
        _next[_t] = _head;
        _prev[_head] = _t;
        _head = _t;
    }

    /// @dev Burn ~`_amount` gas; OOGs the current frame if less than that is available.
    function _burnGas(uint256 _amount) internal view {
        uint256 g0 = gasleft();
        while (g0 - gasleft() < _amount) {
            assembly ("memory-safe") {
                mstore(0x00, keccak256(0x00, 0x20))
            }
        }
    }
}
