# Automation — keeping the sweep alive without trusting anyone

This document is the operator's guide to firing `LivepeerRewardCaller.rewardAll` every
round (~21 h) with **defense in depth**: a primary keeper, a decentralized backstop, and
a permissionless community lane. The contract was built so that redundancy is free —
every sweep is idempotent (the protocol's `lastRewardRound` makes repeat and concurrent
calls skip for ~25k gas each), so extra callers can only ever waste pennies, never
break anything.

> **Deployed.** LivepeerRewardCaller v1 is live on Arbitrum One at
> `0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE`
> ([verified source](https://arbitrum.blockscout.com/address/0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE?tab=contract)).
> `<UPKEEP_ID>` remains a TODO placeholder until the Chainlink upkeep is registered.

---

## The posture: three independent layers

| Layer | Who runs it | What it does | Funded by |
|---|---|---|---|
| 1. Python keeper | livepeer.bot operator | Full 25M-gas sweeps until done, eviction rescue, alerting | Keeper EOA (donations: `<KEEPER_DONATION_EOA>` — TODO placeholder) |
| 2. Chainlink time-based upkeep | Chainlink Automation network (decentralized) | Partial 4.85M-gas sweeps, 6 firings/day | LINK — **anyone can top up** |
| 3. Community crons | Anyone with an RPC and a few cents | Ad-hoc full sweeps | The caller (pennies) |

All three run **concurrently and safely**. A collision costs each redundant caller a
scan of already-rewarded nodes (~25k gas per skip — pennies at Arbitrum's ~0.02 gwei
floor). There is no coordination protocol because none is needed.

---

## Layer 1 — the Python keeper (primary)

The full recipe lives in the repo README and the contract NatSpec (`src/LivepeerRewardCaller.sol`);
this is the operational summary plus the duties that only a stateful off-chain keeper
can perform.

Once per round, after the round rolls:

1. Staticcall `getPendingRewardCalls()`. Empty and round initialized → go to step 4.
2. Send `rewardAll(15, 0)` with a **hardcoded 25M gas limit**. Do not trust bare
   `eth_estimateGas` — estimates cover the work a simulation happens to do, not the
   ≥ 2.5M per-iteration safety floor the contract insists on. A tx that cannot afford
   even one attempt reverts `InsufficientGas` (it never silently no-ops); mid-sweep the
   floor truncates gracefully (`BatchProcessed.complete == false` → call again).
3. Repeat until `complete == true` **and** the pending view is empty. If pending is
   unchanged across two consecutive txs that each made progress (`processed > 0`),
   stop and alert — a persistently failing transcoder would keep you retrying forever.
4. **Eviction rescue** (the duty no on-chain sweep can perform): a subscriber pushed
   out of the pool mid-round (out-competed, resigned, slashed) stays reward-eligible
   until round end but is invisible to `getPendingRewardCalls`/`rewardAll`. Watch
   BondingManager (`0x35Bcf3c30594191d53231E4FF333E8A770453e40`) `TranscoderDeactivated`
   events where `deactivationRound == currentRound + 1` — **verify the exact event
   signature against the verified LIP-118 target source
   (impl `0xbe197fcBfe74DE8F10460EA61644B006cC0f0Bd2` on arbitrum.blockscout.com)
   before hardcoding a topic** — confirm candidates with
   `filterPendingRewardCalls(candidates)`, rescue with
   `rewardFor(candidates, zeros, zeros, 0)` before the round ends.
5. Alert on: any `RewardCallFailed` event (the pre-checks filter every expected
   failure, so an occurrence means protocol drift — investigate); repeated
   `InsufficientGas` after raising the gas limit; pending non-empty past ~80% of the
   round; **and the Chainlink upkeep's LINK balance dropping below 3x its minimum**
   (see Layer 2 — execution stops silently below minimum).

**Be sentinel-aware.** With three layers firing, the keeper must treat "pending shrank
but we sent nothing" as success, not an anomaly — another layer got there first. Only
alert on the conditions above, never on someone else's sweep doing your job.

---

## Layer 2 — Chainlink Automation (the decentralized backstop)

Chainlink Automation on Arbitrum One supports **time-based upkeeps**: the network calls
an arbitrary function on your contract on a CRON schedule, no adapter contract needed —
registration auto-deploys a thin CronUpkeep wrapper (~110–150k gas overhead per firing).
Registration at [automation.chain.link](https://automation.chain.link) is transaction-based
and auto-approved: no forms, no gatekeepers.

### Addresses (Arbitrum One)

| What | Address |
|---|---|
| Automation Registry | `0x37D9dC70bfcd8BC77Ec2858836B923c560E891D1` |
| Automation Registrar | `0x86EFBD0b6736Bed994962f9797049422A3A8E8Ad` |
| LINK token (ERC-677) | `0xf97f4df75117a78c1A5a0DBb814Af92458539FB4` |
| Upkeep target | `0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE` (LivepeerRewardCaller v1) |
| Our upkeep ID | `<UPKEEP_ID>` — TODO: published after registration |

### Economics — read this before registering

- **Perform gas cap: 5,000,000.** Register with **4,850,000** usable — the CronUpkeep
  wrapper's ~110–150k overhead comes out of the cap.
- **Payment** per performed upkeep = gas used + 80k gas overhead, **+ 50% premium**,
  paid in LINK.
- **Minimum balance is dynamic**: roughly fast gas price × gas limit × a 5x multiplier,
  converted at the LINK/ETH rate. When the balance falls below minimum, **execution
  silently stops** — no revert, no event on your side, the upkeep just goes dark.
  Keep **3–5x the displayed minimum** funded and have Layer 1 monitor the balance.
- **Funding is permissionless**: `addFunds(upkeepId, amount)` on the registry can be
  called by anyone, for any upkeep
  ([docs.chain.link/chainlink-automation/overview/automation-economics](https://docs.chain.link/chainlink-automation/overview/automation-economics)).
  This is what makes the upkeep community-sustainable: nobody needs the admin key to
  keep it alive.
- **The admin key never goes away.** The registering wallet permanently keeps
  pause/cancel/withdraw over the upkeep (withdraw requires cancel first). An upkeep
  cannot be made ownerless. Honest framing: the upkeep is community-fundable but
  admin-controlled — if the admin disappears, anyone can simply register a fresh
  upkeep against the same contract, because the target is permissionless.

### Registration walkthrough (time-based upkeep)

1. Go to [automation.chain.link](https://automation.chain.link), connect a wallet on
   Arbitrum One, choose **Register new upkeep** → **Time-based**.
2. Target contract: `0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE`. If the UI cannot
   auto-fetch the ABI, paste it from the verified source.
3. Function: `rewardAll`. Arguments: `_maxRewards = 0`, `_minGasPerCall = 0`.
   `0` (unbounded attempts) is correct **here** because the registered gas limit is
   fixed — the contract's own ≥ 2.5M per-iteration floor truncates the sweep
   gracefully (`complete == false`), and the "estimating bots must pass a bound"
   NatSpec warning does not apply to a fixed-limit executor.
4. Gas limit: **4,850,000**.
5. CRON schedule: `0 */4 * * *` — every 4 hours, 6 firings/day. Rounds are ~21 h, so
   wall-clock CRON drifts against round boundaries; that is harmless (see below), and
   6/day guarantees a firing lands within 4 h of every round roll.
6. Name it (e.g. `livepeer-reward-caller-backstop`), fund with **5–10 LINK** initial
   balance.
7. Confirm the registration transaction. Time-based upkeeps are auto-approved; the
   upkeep ID is minted immediately.
8. Publish the upkeep ID here and on livepeer.bot: `<UPKEEP_ID>` (TODO placeholder).

**Why CRON drift is harmless:** a firing that lands mid-round on an already-swept pool
runs the preflight and skip-scan, rewards nobody, and costs pennies. Idempotency turns
schedule mismatch from a correctness problem into a rounding error on the LINK budget.

### Topping up the upkeep — anyone can, no permission needed

Easiest: open the upkeep page at automation.chain.link (search `<UPKEEP_ID>`), press
**Add funds**, approve the LINK spend, done. Any wallet works — you do not need to be
the admin.

One-transaction CLI route via ERC-677 `transferAndCall` (verified against the registry's
source on arbitrum.blockscout.com — `KeeperRegistry2_1` implements
`onTokenTransfer(address,uint256,bytes)` where `data` is the ABI-encoded upkeep ID):

```bash
# top up 5 LINK (amount is in 18-decimal wei)
cast send 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4 \
  "transferAndCall(address,uint256,bytes)" \
  0x37D9dC70bfcd8BC77Ec2858836B923c560E891D1 \
  5000000000000000000 \
  $(cast abi-encode "f(uint256)" <UPKEEP_ID>) \
  --rpc-url https://arb1.arbitrum.io/rpc --private-key <YOUR_KEY>
```

Two-transaction alternative using the documented `addFunds` entrypoint (served through
the registry's Chainable fallback to its logic contract; requires a prior LINK
`approve` to the registry):

```bash
cast send 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4 \
  "approve(address,uint256)" \
  0x37D9dC70bfcd8BC77Ec2858836B923c560E891D1 5000000000000000000 \
  --rpc-url https://arb1.arbitrum.io/rpc --private-key <YOUR_KEY>

cast send 0x37D9dC70bfcd8BC77Ec2858836B923c560E891D1 \
  "addFunds(uint256,uint96)" <UPKEEP_ID> 5000000000000000000 \
  --rpc-url https://arb1.arbitrum.io/rpc --private-key <YOUR_KEY>
```

Note the LINK on Arbitrum at the address above is already ERC-677; no PegSwap
conversion is needed.

### Honest limits — what a 4.85M firing can and cannot do

> **Chainlink is a backstop, not the whole answer.**
>
> The contract refuses to start an iteration with less than 2.5M gas in hand (the
> per-iteration safety floor that guarantees an honest reward call can never OOG
> inside the capped subcall). With a 4.85M limit, that leaves roughly **2.3M of
> scan-plus-work budget** above the floor. In practice:
>
> - A hintless reward call costs 355k–515k (median 440k, measured on the real pool),
>   so a firing lands roughly **4–5 rewards near the head of the pool** before the
>   floor truncates it (`complete == false`).
> - Skipping a node (not subscribed, or already rewarded) costs up to ~25k. A
>   subscriber sitting at the **tail of the 100-node pool behind a long skip-scan**
>   (~90 skips ≈ 2.25M gas of pure scanning) can exhaust the budget before the loop
>   ever reaches them — and because every firing restarts from the head, successive
>   firings die at roughly the same depth. **A tail subscriber may never be rewarded
>   by the Chainlink lane alone.**
> - Corollary: on a fully-swept 100-node pool, a firing may not even finish the scan
>   (`complete == false`, zero rewards). Harmless — it did nothing and cost pennies.
>
> The Python keeper's 25M transactions and the community cron lane close this gap:
> a 25M tx has ~22.5M of budget above the floor, enough to scan the whole pool and
> reward dozens of subscribers in one go.

---

## Layer 3 — community crons

Anyone can run the sweep from any machine with any funded EOA. The whole job is one
command, safe to run at any time, any number of times, by any number of people:

```bash
cast send 0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE "rewardAll(uint256,uint256)" 15 0 \
  --gas-limit 25000000 \
  --rpc-url https://arb1.arbitrum.io/rpc \
  --private-key <YOUR_KEY>
```

(Deployed and verified — see the header note for explorer links.)

Semantics worth knowing before you cron this: if the tx cannot afford even one reward
attempt it **reverts `InsufficientGas`** rather than silently doing nothing — at a
hardcoded 25M limit you will never see it. If the sweep is truncated mid-pool it
returns `complete == false` and simply needs another call. If someone else already
swept, your tx skips everything and costs pennies. Put it in a crontab firing every
few hours and you are a useful part of the mesh.

---

## The 2026 automation landscape (why Chainlink)

The managed-automation category had a brutal 12 months. Survey as of August 2026:

| Service | Status (2026) | Arbitrum One | Verdict for this job |
|---|---|---|---|
| **Chainlink Automation** | Live, time-based upkeeps, auto-approved registration | Yes | **Recommended backstop** (5M perform cap → partial sweeps only) |
| Gelato Automate / Web3 Functions | **Dead** — EOL 2026-03-31, pivoted to rollup-as-a-service; Arbitrum Automate contract silent since March | Was | Do not use |
| OpenZeppelin Defender (hosted) | **Retired 2026-07-01**; the open-source self-hosted Relayer lives on | Self-hosted only | Viable DIY alternative to the Python keeper if you prefer Docker |
| Keep3r Network | Live | **No** — Ethereum mainnet only | N/A |
| Ava Protocol (EigenLayer AVS) | Live on other chains | **No** Arbitrum support yet | Watch |
| ERC-4337 / Safe scheduled txs | Live | Yes | No gain — still needs a centralized cranker, and funding is owner-scoped, not community-fundable |
| GitHub Actions cron | Live | n/a (off-chain) | Emergency backup at best — documented 2–4 h+ scheduler delays, dropped runs, 60-day auto-disable on inactive repos |
| PowerPool PowerAgent v2 | Live (claimed) | Per docs, yes | Watch list — verify before adopting (below) |
| Reactive Network | Live (claimed) | Callback proxy deployed | Watch list — verify before adopting (below) |

**The category lesson:** two of the three biggest names in managed automation exited
within four months of each other. Gelato's Automate was the canonical "Chainlink
alternative" right up until the EOL notice; Defender's hosted service was
enterprise-grade right up until retirement. Prefer services whose liveness is
verifiable on-chain and whose funding is permissionless — and always assume any single
service can vanish, which is exactly why this document describes three layers instead
of one.

### Watch list — candidates for a future fourth layer

Both look promising on paper; **neither should be adopted without the verification
steps below**, performed against live chain state, not docs.

**PowerPool PowerAgent v2** — deployed on Arbitrum per its docs; jobs prepay execution
in ETH-denominated job credits; `depositJobCredits(jobKey)` is verified permissionless
(anyone can fund any job — the same community-sustainability property as Chainlink's
`addFunds`). Before adopting:

1. Confirm the Arbitrum agent contract has **recent job executions on-chain** (within
   the last week — a deployed-but-idle agent network executes nobody's jobs).
2. Register a throwaway job calling a view-safe target and measure actual execution
   latency and reliability across several days.
3. Confirm the per-execution gas ceiling fits at least a 4.85M call, ideally 25M.

**Reactive Network** — cron-driven callbacks executed on Arbitrum through destination
callback proxy `0x4730c58FDA9d78f60c987039aEaB7d261aAd942E`; `depositTo()` funding is
permissionless. Before adopting:

1. **Max callback gas is UNVERIFIED — confirm it is at least 5M** (ideally enough for
   a 25M full sweep) before writing a single line of integration. If callbacks cap
   below 5M, it adds nothing over Chainlink.
2. Confirm the proxy shows recent successful callback executions on-chain.
3. Test the cron trigger end-to-end on a throwaway contract and measure drift.

---

## Future note

Everything above assumes today's protocol shape: a 100-node active set that one 25M
transaction can sweep. If Livepeer 2.0 uncaps the node set, per-round work stops being
bounded and altruistic funding stops scaling. The clean upgrade path is a v2 contract
(a **new address** orchestrators deliberately re-point `setRewardCaller` to — v1 is
immutable and has no upgrade mechanism) that adds a small tip per successful reward
call, making keeper networks like PowerAgent, and even anonymous cron runners,
self-funding. Until then, three redundant layers at pennies per day is the cheaper and
simpler answer.
