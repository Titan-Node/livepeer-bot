// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UnitBase} from "./Base.t.sol";

contract ViewsTest is UnitBase {
    // ---------------------------------------------------------------- getPendingRewardCalls

    /// @notice Exact-set (and exact-order) equality against a randomized pool.
    function testFuzz_GetPendingRewardCalls_ExactSet(bytes32 seed) public {
        uint256 n = uint256(seed) % 17; // 0..16 transcoders
        for (uint256 i; i < n; ++i) {
            address t = address(uint160(0xA000 + i));
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            bool subscribed = h & 1 != 0;
            bool active = h & 2 != 0;
            bool preRewarded = h & 4 != 0;
            uint256 lrr = preRewarded ? ROUND : ((h & 8 != 0) ? ROUND - 1 : 0);
            _addT(t, (h >> 200), subscribed, active, lrr);
        }

        // mirror of the documented predicate, walked in pool order
        address[] memory expected = new address[](bm.getTranscoderPoolSize());
        uint256 m;
        address cur = bm.getFirstTranscoderInPool();
        while (cur != address(0)) {
            if (
                bm.transcoderToRewardCaller(cur) == address(rc) && bm.lastRewardRoundOf(cur) != ROUND
                    && bm.isActiveTranscoder(cur)
            ) {
                expected[m++] = cur;
            }
            cur = bm.getNextTranscoderInPool(cur);
        }
        assembly ("memory-safe") {
            mstore(expected, m)
        }

        address[] memory actual = rc.getPendingRewardCalls();
        assertEq(actual, expected, "pending set must EXACTLY match the eligible set, in pool order");
    }

    function test_GetPendingRewardCalls_EmptyPool() public view {
        assertEq(rc.getPendingRewardCalls().length, 0);
    }

    function test_GetPendingRewardCalls_FreshUninitializedRound_ListsFullSubscribedSet() public {
        address A = address(0xA1);
        address B = address(0xB1);
        _addGood(A, 200);
        _addGood(B, 100);
        _setRound(ROUND + 1, false); // new round, nobody initialized it yet

        address[] memory pending = rc.getPendingRewardCalls();
        assertEq(pending.length, 2, "pre-initialization the full subscribed set is pending");
        assertEq(pending[0], A);
        assertEq(pending[1], B);
    }

    function test_GetPendingRewardCalls_DropsRewardedAsRoundAdvances() public {
        address A = address(0xA1);
        _addGood(A, 100);
        rc.rewardAll(0, 0);
        assertEq(rc.getPendingRewardCalls().length, 0, "rewarded -> no longer pending");

        _setRound(ROUND + 1, true);
        address[] memory pending = rc.getPendingRewardCalls();
        assertEq(pending.length, 1, "new round -> pending again");
        assertEq(pending[0], A);
    }

    // ---------------------------------------------------------------- getHints

    function test_GetHints_HeadMiddleTailAbsentAndDuplicates() public {
        address A = address(0xA1);
        address B = address(0xB1);
        address C = address(0xC1);
        address D = address(0xD1); // absent from the pool
        bm.addToPool(A, 300);
        bm.addToPool(B, 200);
        bm.addToPool(C, 100);

        address[] memory query = new address[](5);
        query[0] = A;
        query[1] = B;
        query[2] = C;
        query[3] = D;
        query[4] = A; // duplicate query entry: filled too

        (address[] memory prevs, address[] memory nexts) = rc.getHints(query);
        assertEq(prevs.length, 5);
        assertEq(nexts.length, 5);

        assertEq(prevs[0], address(0), "head: prev = 0");
        assertEq(nexts[0], B);
        assertEq(prevs[1], A, "middle: exact neighbors");
        assertEq(nexts[1], C);
        assertEq(prevs[2], B, "tail: next = 0");
        assertEq(nexts[2], address(0));
        assertEq(prevs[3], address(0), "absent -> (0,0) = hintless");
        assertEq(nexts[3], address(0));
        assertEq(prevs[4], address(0), "duplicate query entry filled identically");
        assertEq(nexts[4], B);
    }

    function test_GetHints_EmptyQuery() public view {
        (address[] memory prevs, address[] memory nexts) = rc.getHints(new address[](0));
        assertEq(prevs.length, 0);
        assertEq(nexts.length, 0);
    }

    function test_GetHints_EmptyPool_AllHintless() public {
        (address[] memory prevs, address[] memory nexts) = rc.getHints(_arr(address(0xA1), address(0xB1)));
        assertEq(prevs[0], address(0));
        assertEq(nexts[0], address(0));
        assertEq(prevs[1], address(0));
        assertEq(nexts[1], address(0));
    }

    // ---------------------------------------------------------------- version

    function test_Version() public view {
        assertEq(rc.version(), "LivepeerRewardCaller/1.0.0");
    }
}
