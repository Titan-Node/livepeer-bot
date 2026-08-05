# LivepeerRewardCaller — livepeer.bot

A shared, trustless reward-calling service for Livepeer orchestrators on **Arbitrum One**.

[LIP-118 (Delegated Reward Calling)](https://github.com/livepeer/LIPs/blob/master/LIPs/LIP-118.md)
lets an orchestrator delegate the daily `reward()` call to another address, so the orchestrator
key can finally live in cold storage. This contract is built to be that address — **for every
orchestrator at once**.

## How it works

```
 orchestrator (cold key, one tx, once):
     BondingManager.setRewardCaller(<LivepeerRewardCaller>)

 anyone, every round (keeper bot / cron / stranger):
     LivepeerRewardCaller.rewardAll(15, 0)
        ├─ initializes the round if nobody has yet
        ├─ walks the 100-orchestrator active pool
        ├─ skips everyone not subscribed / not active / already rewarded
        └─ calls rewardForTranscoderWithHint for each subscriber, isolated
           in try/catch — one bad apple never blocks the rest
```

Repeated / concurrent calls are harmless: the protocol's own `lastRewardRound` makes every
sweep idempotent. If a sweep runs out of gas it truncates gracefully (`complete == false`) —
just call again.

## Why orchestrators can trust it

- **Immutable. No owner. No pause switch. No storage. Holds no funds.**
- Delegation via LIP-118 grants *only* the power to call reward **for you** — your rewards,
  your delegators' shares, and your commission are computed by the protocol exactly as if you
  called it yourself. Reward amounts are fixed at round initialization; the caller cannot
  influence them.
- Your own `reward()` self-call **keeps working** — delegation adds a caller, it never locks
  you out.
- Opt out any time: `setRewardCaller(address(0))` (or point elsewhere).
- Worst possible failure mode of this contract is a *missed reward call* — never loss of funds.
- If a v2 is ever needed, it will be a new address you deliberately re-point to. There is no
  upgrade mechanism anyone could abuse.

## Join (orchestrators)

From your orchestrator (transcoder) key, one transaction:

```bash
cast send 0x35Bcf3c30594191d53231E4FF333E8A770453e40 \
  "setRewardCaller(address)" 0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE \
  --rpc-url https://arb1.arbitrum.io/rpc --ledger
```

Then put your key back in the freezer. That's it.

> Deployed 2026-08-05: **`0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE`** on Arbitrum One
> (verified source on
> [Arbiscan](https://arbiscan.io/address/0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE#code) and
> [Blockscout](https://arbitrum.blockscout.com/address/0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE?tab=contract),
> deploy tx `0x62f18d3882a2681b67946a538614b21a1a83886b17f72ea2c7e0f1029fed465d`).
> Canary run pending; forum announcement after that.

## Keeper recipe (running the daily caller)

Once per round (~21 hours), after the round rolls:

1. `getPendingRewardCalls()` (free staticcall) — empty and round initialized? Check step 4,
   then done.
2. Send `rewardAll(15, 0)` with a **hardcoded ~25M gas limit** (don't trust bare
   eth_estimateGas: estimates cover the work but not the ≥2.5M per-iteration safety floor —
   add that floor on top if you must estimate; a tx that can't afford even one attempt
   reverts `InsufficientGas` instead of silently doing nothing). The first call of a round
   also initializes it.
3. Repeat until `BatchProcessed.complete == true` **and** pending is empty. If pending is
   unchanged across two consecutive txs that each made progress (`processed > 0`), stop and
   alert (persistent failer). On `InsufficientGas`, raise the gas limit.
4. **Eviction edge**: a subscriber pushed out of the pool mid-round (out-competed, resigned,
   or slashed) stays reward-eligible until round end but becomes invisible to the pool views.
   Watch BondingManager `TranscoderDeactivated` events with
   `deactivationRound == currentRound + 1`, confirm via `filterPendingRewardCalls(candidates)`,
   rescue via `rewardFor(candidates, zeros, zeros, 0)` before round end.
5. Alert on: any `RewardCallFailed` event (pre-checks filter every expected failure, so any
   occurrence means protocol drift); repeated `InsufficientGas` after raising gas; pending
   non-empty past ~80% of the round.

Cost at typical Arbitrum prices (0.02 gwei): **~$0.15–0.30/day** at 5 subscribers, ~$1–4/day
if all 100 orchestrators subscribe (3–7 txs/round at full subscription — Arbitrum caps a
single tx at 32M gas).

Efficiency lane (optional, ~15% measured total gas savings): `getHints(pending)` off-chain,
then `rewardFor(chunkOf30, prevs, nexts, 0)`.

## Contract surface

| Function | Who calls | What |
|---|---|---|
| `rewardAll(maxRewards, minGasPerCall)` | anyone | hintless pool sweep; `maxRewards` bounds attempts (0 = unbounded — estimating bots must pass a bound); `minGasPerCall` can only *raise* the safety floor |
| `rewardFor(transcoders[], prevs[], nexts[], minGasPerCall)` | anyone | explicit list with optional per-item hints; `(0,0)` = hintless |
| `getPendingRewardCalls()` | keepers (view) | who a pool sweep would attempt right now (blind to mid-round evictees — see keeper recipe step 4) |
| `filterPendingRewardCalls(candidates[])` | keepers (view) | same predicate over an explicit candidate list — the evictee rescue check |
| `getHints(transcoders[])` | keepers (view) | current pool neighbors as insertion hints |
| `version()` | anyone (view) | `"LivepeerRewardCaller/1.0.0"` |

Events: `RoundInitialized`, `RewardCallSucceeded` (with per-call gas), `RewardCallFailed`
(with raw revert data — the alert channel), `BatchProcessed` (the resume/stop signal).

## Development

```bash
# unit tests (mocks, fast)
forge test

# mainnet fork tests against the real deployed LIP-118 target (slow first run; RPC cached)
FOUNDRY_PROFILE=fork forge test
# custom RPC: ARBITRUM_RPC_URL=https://... FOUNDRY_PROFILE=fork forge test
```

Verified against the live LIP-118 deployment on Arbitrum One: BondingManager target
`0xbe197fcBfe74DE8F10460EA61644B006cC0f0Bd2` (protocol commit `ccc82f43`), registered at
block 489,354,275 behind proxy `0x35Bcf3c30594191d53231E4FF333E8A770453e40`.

## Audits & review

- Multi-agent adversarial review (pre-audit, 22 agents): confirmed findings — mid-round
  eviction blind spot, estimation-stall semantics, drift-branch coverage — all fixed and
  regression-tested.
- [OneDollarAudit #565](audits/2026-08-05-onedollaraudit-565.md) (2026-08-05, automated): no
  critical/high findings; 2 medium + 2 low, all fixed or documented — see the response doc for
  the finding-by-finding disposition and regression tests.
- [OneDollarAudit #567](audits/2026-08-05-onedollaraudit-567.md) (2026-08-05, automated
  re-audit at pinned commit `8e5bac59…`): 1 high (latent availability: gas-floor growth could
  brick the service in a far-future giant pool — fixed with `MAX_GAS_FLOOR`), plus fixes for the
  implicit returndata copy and a `Deployed` fingerprint event; reentrancy-guard and
  dynamic-forwarding suggestions rejected with reasons on record.

No third-party human audit yet; the contract is small (~470 lines) and deliberately boring —
read it.

## Deployment checklist

1. Full unit + fork suites green at a current pinned block; empirical gas table reviewed
   (worst hintless call must sit comfortably under the 2.35M forwarded cap).
2. Deploy with CREATE2, constructor arg = Controller `0xD8E8328501E9645d16Cf49539efC04f734606ee4`.
3. Verify source on Blockscout (Arbiscan is currently failing to index Livepeer targets;
   verify there too once fixed).
4. Canary: one real orchestrator subscribes → `rewardAll(1, 0)` → confirm
   `RewardCallSucceeded` on-chain.
5. Publish address here + livepeer.bot + forum post. Landing page + keeper bot: separate repos.
