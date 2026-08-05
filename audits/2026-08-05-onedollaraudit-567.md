# Audit: OneDollarAudit job #567 — LivepeerRewardCaller (pinned-commit re-audit)

- **Date:** 2026-08-05
- **Auditor:** OneDollarAudit / LeftClaw (automated three-phase multi-agent review)
- **Scope:** `src/LivepeerRewardCaller.sol` at pinned commit
  [`8e5bac59…b84a`](https://github.com/Titan-Node/livepeer-bot/blob/8e5bac599650e5da5ab563ecd206479c07b3b84a/src/LivepeerRewardCaller.sol)
  — i.e. the post-audit-#565 code; the audited hash matches this repo's public history.
- **Report (IPFS):** https://bafkreidaoqdu7fbjuc6dty5qvee4c6bezjee62gnlubnwsy7p2d7c3nucy.ipfs.community.bgipfs.com/
- **Report (HTML):** https://leftclaw.services/result/567.html
- **Job tracker:** https://onedollaraudit.com/audit/567
- **Headline:** no fund-theft path identified; 1 High (availability), 1 Medium, 4 Low, 1 Info.
- **Fixes applied in:** the commit introducing this document.

## Findings and our response

### 1 (High) — Unbounded linear gas-floor growth could brick the service — **FIXED**
The pool-size-aware floor (`1.5M + 10k × poolSize`) had no ceiling; past ~3,050 pool members it
exceeds Arbitrum's 32M per-tx cap, making every call revert unconditionally — an immutable
contract permanently dead. The sharpest finding across both audits: our audit-#565 scaling fix
introduced an unbounded-growth failure mode.

Fix: `MAX_GAS_FLOOR = 20M` caps the AUTOMATIC floor (still forwards ~19.5M — covers a hintless
tail reward even in a ~3,000-node pool); the caller's clamp-up `_minGasPerCall` may still exceed
it deliberately. Regression: `test_GasFloorCapped_GiantPoolCannotBrickService`.

### 2 (Medium) — No reentrancy guard — **REJECTED, with reasons**
A guard would defend nothing here: the contract holds zero mutable state (there is nothing to
protect, an invariant we test via `vm.record`); the real reward path calls only protocol
contracts with no user-controlled callbacks (verified in fork tests against the deployed
BondingManager); and the hypothesized double-mint requires a BondingManager that updates
`lastRewardRound` after an external callback — a protocol bug an attacker could exploit
directly, without this contract as a vector. Adding a lock slot would break the zero-storage
invariant for no defensive gain.

### 3 (Low) — Implicit `returndatacopy` before the 256-byte cap — **FIXED**
Correct and sharp: `(ok,) = address(bm).call(...)` still materializes the callee's FULL revert
payload in our frame before discarding it, so a multi-hundred-KB revert bomb could OOG us on
memory expansion despite the audit-#565 bounded-emit fix. Now an assembly call with a
zero-length output buffer makes `_boundedRevertData()` the only copy that ever occurs.
Regression: `test_MassiveRevertBomb_NoImplicitCopyOOG_SweepContinues` (400KB bomb).

### 4 (Low) — View helpers unusable on far-future giant pools — **DOCUMENTED**
`getPendingRewardCalls`/`getHints` are O(poolSize) walks that could exceed RPC eth_call caps if
the pool grew ~30×. The documented keeper recipe already uses the immune path
(`RewardCallerSet` event discovery + batched `filterPendingRewardCalls`); NatSpec now says so
explicitly. No pagination added — extra surface on an immutable artifact for a hypothetical.

### 5 (Low) — Static forwarded gas wastes caller headroom — **REJECTED, by design**
The static cap IS the containment guarantee (audit #565 / pre-audit red team): forwarding
`gasleft()`-scaled gas would let one pathological item consume an entire 25M batch — the exact
failure the cap exists to prevent. Callers who know rewards legitimately cost more can raise
the floor (and thus the cap) via `_minGasPerCall`.

### 6 (Low) — Constructor verification / no deployment event — **FIXED (event)**
`event Deployed(controller, bondingManager, roundsManager)` now emitted at construction — a
permanent on-chain fingerprint of the registry binding. Hardcoding canonical mainnet addresses
was rejected (would break fork/mock testing and adds nothing a public constructor arg +
Deployed event doesn't). Regression: `test_DeployedEvent_FingerprintsRegistryBinding`.

### 7 (Info) — Empty `RoundNotInitializable` reason ambiguity — **DOCUMENTED**
NatSpec on the error now states: an empty reason usually means the `initializeRound` subcall
ran out of gas (caller under-provisioned), not protocol drift.

## Leads — all four were verified against the REAL BondingManager before this audit

A file-only review necessarily flags external assumptions; ours are already evidence-backed:

| Lead | Evidence |
|---|---|
| Hint trust boundary | Fork tests pass adversarial hints (self/self, reversed, non-pool, this-contract) against the deployed BondingManager; worst case = hintless price for that item. |
| Unwrapped `_shouldAttempt` staticcalls | Accepted (audit #565 disposition): a reverting registry getter = protocol drift → sweep hard-reverts → contract inert, never harmful; detectable via estimation failures. |
| `getTranscoder` word-0 decode | Tuple layout verified on-chain against the deployed target; revert/short-return drift is silently skipped (unit-tested); a reorder would surface as protocol-side reverts, alerting via `RewardCallFailed`. |
| Pool-reorder-during-traversal | Proven on the deployed contract: full-pool fork sweeps reward every subscriber exactly once; protocol source (commit `ccc82f43`) confirms reward only raises the rewarded node's own key. |

## Assessment

Finding 1 alone justified the re-audit: a real, if latent, bricking scenario introduced by our
own previous hardening — exactly the class of error immutable contracts can't afford. Findings
3 and 6 were cheap, genuine improvements. The rejections (2, 5) are deliberate design decisions,
now argued on the record. Post-fix suite: **93 tests green** (85 unit + 8 Arbitrum mainnet-fork).
