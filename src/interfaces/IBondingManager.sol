// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal interface to the Livepeer BondingManager, restricted to what
///         reward calling needs. Verified against the deployed LIP-118 target
///         (impl 0xbe197fcBfe74DE8F10460EA61644B006cC0f0Bd2, git commit ccc82f43,
///         behind proxy 0x35Bcf3c30594191d53231E4FF333E8A770453e40 on Arbitrum One).
interface IBondingManager {
    /// @notice Call reward on behalf of `_transcoder` with sorted-pool insertion hints.
    /// @dev Reverts unless transcoderToRewardCaller[_transcoder] == msg.sender.
    ///      (address(0), address(0)) hints are legal and mean "no hint" (O(rank) head scan).
    function rewardForTranscoderWithHint(address _transcoder, address _newPosPrev, address _newPosNext) external;

    /// @notice Transcoder opt-in/out: set the single address allowed to call reward on its behalf.
    /// @dev Used by orchestrators (and tests), never by this contract.
    function setRewardCaller(address _rewardCaller) external;

    /// @notice The reward caller a transcoder has delegated to (address(0) = none).
    function transcoderToRewardCaller(address _transcoder) external view returns (address);

    /// @notice Transcoder state; lastRewardRound is the FIRST tuple field (verified on-chain).
    function getTranscoder(address _transcoder)
        external
        view
        returns (
            uint256 lastRewardRound,
            uint256 rewardCut,
            uint256 feeShare,
            uint256 lastActiveStakeUpdateRound,
            uint256 activationRound,
            uint256 deactivationRound,
            uint256 activeCumulativeRewards,
            uint256 cumulativeRewards,
            uint256 cumulativeFees,
            uint256 lastFeeRound
        );

    /// @notice True when `_transcoder` is active in the CURRENT round (the reward precondition).
    function isActiveTranscoder(address _transcoder) external view returns (bool);

    /// @notice Number of transcoders in the active pool (<= getTranscoderPoolMaxSize, currently 100).
    function getTranscoderPoolSize() external view returns (uint256);

    /// @notice Head of the descending-stake sorted pool.
    function getFirstTranscoderInPool() external view returns (address);

    /// @notice Next node after `_transcoder` in the sorted pool; address(0) past the tail.
    function getNextTranscoderInPool(address _transcoder) external view returns (address);
}
