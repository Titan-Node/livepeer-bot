# Audit: OneDollarAudit job #565 — LivepeerRewardCaller

- **Date:** 2026-08-05
- **Auditor:** OneDollarAudit (automated multi-agent review; three-phase methodology: context
  mapping → breadth checklist → 12-agent blind attack → reconciliation)
- **Scope:** `src/LivepeerRewardCaller.sol` (submitted as a source link to this repo)
- **Report (IPFS):** https://bafkreibnbqscfx34i3u2gvk7unxwircdbjfxvdwg65p4gxihsubd2xjlpu.ipfs.community.bgipfs.com/
- **Report (HTML):** https://leftclaw.services/result/565.html
- **Job tracker:** https://onedollaraudit.com/audit/565
- **Headline:** no Critical or High fund-loss findings; 2 Medium, 2 Low, 6 unscored leads.

> Note on commit references: the repo's git history was rewritten (squashed) after this audit
> for a contributor-privacy scrub, so the commit hash named in the report no longer exists.
> The audited source is verifiable content-wise: the report's findings quote the pre-fix code,
> and every fix below is present in the current tree with a regression test.

## Findings and our response

### 1 (Medium) — Unbounded revert-data copy could OOG the failure path
A hostile or drifted future BondingManager target could revert with a multi-KB payload; the
`catch (bytes memory)` copy + event LOG costs came out of the fixed 150k reserve, so the catch
handler itself could out-of-gas and revert the whole sweep — breaking the "one bad item never
blocks the rest" guarantee.

**FIXED.** `_attemptReward` now uses a gas-capped raw call and truncates revert data to
`MAX_REVERT_DATA_BYTES = 256` (enough for any error selector / `Error(string)` prefix) via a
bounded `returndatacopy`. Regression: `test_HugeRevertPayload_TruncatedTo256_SweepContinues`
(8KB revert bomb mid-pool; sweep completes, event carries exactly the 256-byte prefix).

### 2 (Medium) — `InsufficientGas` gate counted scans, not attempts
The zero-progress guard checked `processed == 0`, but `processed` also counts nodes cheaply
skipped by pre-checks. A tx could scan a skippable prefix, dip under the gas floor before
affording a single reward attempt, and return a silent zero-progress "success" — the exact
stall the error exists to prevent. **This was a genuine bug** in the behavior we had shipped
tests for; the audit's analysis was correct.

**FIXED.** Both `rewardAll` and `rewardFor` now gate on `rewarded + failed == 0` (attempts).
All-skip natural completions still return cleanly, preserving harmless keeper races.
Regressions: `test_RewardAll_ScanPrefixCannotMaskZeroAttempts_Reverts`,
`test_RewardFor_IneligiblePrefixCannotMaskZeroAttempts_Reverts`.

### 3 (Low) — Duplicate entries whose attempt FAILS are re-attempted
Dedup rides on the protocol's `lastRewardRound`, which is only set on success, so duplicates of
a *failing* entry each emit `RewardCallFailed`. No fund risk; alert noise only, and failures
past the pre-checks are protocol-drift-rare by construction.

**Documented** (NatSpec on `rewardFor` corrected; in-contract dedup deliberately not added —
memory bookkeeping on an immutable artifact isn't worth a noise-only case; dedupe client-side).

### 4 (Low, latent) — Flat `CALL_GAS_RESERVE` didn't scale with EIP-150
With the pool-size-aware gas floor, a pool grown several-fold beyond today's 100 would make the
explicit `{gas: fwd}` request exceed 63/64 of available gas, silently under-forwarding and
risking misattributed OOG failures for honest tail rewards.

**FIXED.** The effective reserve is now `CALL_GAS_RESERVE + gasFloor / 64`, scaling with the
floor. Regression: `test_ForwardCap_IncludesEip150ScaledReserve`.

## Leads (unscored) — disposition

All six leads correspond to decisions made and adversarially reviewed pre-audit:

| Lead | Disposition |
|---|---|
| Unvalidated hint forwarding | Deliberate: the protocol validates hints itself; a bad hint costs the hintless price for that item only. Fork-tested with adversarial hints. |
| Asymmetric revert handling in `_shouldAttempt` | Accepted: a reverting registry getter means protocol drift; the sweep hard-reverts → contract goes inert (never harmful), detectable via estimation failures. |
| Silent skip on failed `getTranscoder` decode | Deliberate defensive behavior; unit-tested (revert + short-returndata knobs). |
| Traversal order (lowest stake last) | Documented; `rewardFor` allows targeted ordering. |
| View staleness pre-initialization | Documented on `getPendingRewardCalls`; entrypoints auto-initialize. |
| No resume cursor | Deliberate: a cursor is unsound under re-sorting; idempotent re-scan costs ~pennies. |

## Assessment

For a $1 automated review it found one real shipped bug (finding 2) and two worthwhile
hardening gaps consistent with our own design philosophy — money well spent. It is not a
substitute for the project's primary assurance: the 90-test suite (82 unit + 8 mainnet-fork
against the live LIP-118 deployment) and the pre-audit multi-agent adversarial review whose
confirmed findings (mid-round eviction blind spot, estimation-stall semantics, drift-branch
coverage) are all reflected in the current code and tests.
