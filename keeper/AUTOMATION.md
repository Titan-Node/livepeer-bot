# Automation — keeping the sweep alive without trusting anyone

This document is the operator's guide to firing `LivepeerRewardCaller.rewardAll` every
round (~21 h) with **defense in depth**: a primary keeper, a permissionless community
lane, and (when one worth having exists again) a decentralized backstop. The contract
was built so that redundancy is free — every sweep is idempotent (the protocol's
`lastRewardRound` makes repeat and concurrent calls skip for ~25k gas each), so extra
callers can only ever waste pennies, never break anything.

> **Deployed.** LivepeerRewardCaller v1 is live on Arbitrum One at
> `0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE`
> (verified source on
> [Arbiscan](https://arbiscan.io/address/0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE#code)
> and
> [Blockscout](https://arbitrum.blockscout.com/address/0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE?tab=contract)).

> **Landscape note (2026-08-05).** Chainlink Automation — the decentralized backstop
> this document originally recommended — was **sunset industry-wide in mid-2026**
> before we could register an upkeep. The section below documents what replaced it,
> what we verified, and the current posture. History is preserved because the category
> keeps proving the lesson: *any single automation service can vanish.*

---

## The posture: three independent layers

| Layer | Who runs it | What it does | Funded by |
|---|---|---|---|
| 1. Python keeper | livepeer.bot operator | Full 25M-gas sweeps until done, eviction rescue, alerting | Keeper EOA (donations: `<KEEPER_DONATION_EOA>` — TODO placeholder) |
| 2. Community crons | Anyone with an RPC and a few cents | Ad-hoc full sweeps of a permissionless function | The caller (pennies) |
| 3. Decentralized backstop | — | **Under evaluation post-sunset** (Chainlink CRE Early Access; Reactive Network experiment) | see below |

All layers run **concurrently and safely**. A collision costs each redundant caller a
scan of already-rewarded nodes (~25k gas per skip — pennies at Arbitrum's ~0.02 gwei
floor). There is no coordination protocol because none is needed.

With Automation gone, the most decentralized scheduler left standing is the one built
into the contract itself: **`rewardAll` is permissionless and idempotent, so every
subscriber is one crontab line away from being their own backstop.** Layer 2 is not a
consolation prize; it is the only layer whose liveness no company can sunset.

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
   events where `deactivationRound == currentRound + 1` — topic0
   `0xfee3e693fc72d0a0a673805f3e606c551f4c677b9072444b90dd2d0406bc995c`, verified
   against the deployed LIP-118 target source — confirm candidates with
   `filterPendingRewardCalls(candidates)`, rescue with
   `rewardFor(candidates, zeros, zeros, 0)` before the round ends.
5. Alert on: any `RewardCallFailed` event (the pre-checks filter every expected
   failure, so an occurrence means protocol drift — investigate); repeated
   `InsufficientGas` after raising the gas limit; pending non-empty past ~80% of the
   round.

**Be sentinel-aware.** With multiple layers firing, the keeper must treat "pending
shrank but we sent nothing" as success, not an anomaly — another layer got there
first. Only alert on the conditions above, never on someone else's sweep doing your
job.

---

## Layer 2 — community crons (the permissionless lane)

Anyone can run the sweep from any machine with any funded EOA. The whole job is one
command, safe to run at any time, any number of times, by any number of people:

```bash
cast send 0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE "rewardAll(uint256,uint256)" 15 0 \
  --gas-limit 25000000 \
  --rpc-url https://arb1.arbitrum.io/rpc \
  --private-key <YOUR_KEY>
```

Semantics worth knowing before you cron this: if the tx cannot afford even one reward
attempt it **reverts `InsufficientGas`** rather than silently doing nothing — at a
hardcoded 25M limit you will never see it. If the sweep is truncated mid-pool it
returns `complete == false` and simply needs another call. If someone else already
swept, your tx skips everything and costs pennies. Put it in a crontab firing every
few hours and you are a useful part of the mesh.

---

## Layer 3 — the decentralized backstop (status: rebuilding after the sunset)

### What happened to Chainlink Automation

Verbatim banner from automation.chain.link: *"Chainlink Automation v1.x sunsets
June 30, 2026 | v2.1 sunsets July 31, 2026"* — v2.1 was the only registry generation
on Arbitrum One, so the operative date has passed. Verified on-chain (2026-08-05): the
last new upkeep registration on the Arbitrum registrar was **June 15, 2026**; a
residual trickle of performs continued days past the sunset date, but the docs are
explicit that unmigrated upkeeps "will not be performed anymore". Registering the
time-based upkeep this document once recommended is **no longer possible**. (Admins of
existing upkeeps can still recover LINK: cancel → wait the block delay → withdraw;
withdrawals were still succeeding on-chain within the last week.)

### The official successor: Chainlink Runtime Environment (CRE)

CRE can express our job — a TypeScript/Go workflow compiled to WASM, a cron trigger
(min 30s interval; `0 0 */4 * * *` is fine), and an EVM write on Arbitrum One. The
process, from the official migration guide
([docs.chain.link/cre/reference/cla-migration-ts](https://docs.chain.link/cre/reference/cla-migration-ts)):

1. Account at app.chain.link/cre, CLI install, `cre account link-key` (linked wallet;
   registry gas is paid in ETH **on Ethereum Mainnet**).
2. `cre init --template=automation-migration-ts` — scaffolds the workflow AND an
   `AutomationReceiver.sol` you deploy on Arbitrum: CRE writes are DON-signed reports
   delivered via their KeystoneForwarder to YOUR receiver, which forwards the call
   (`setCallAllowed(target, selector)`) to `rewardAll(0,0)`. Our function is
   permissionless, so the receiver-as-msg.sender indirection is harmless.
3. `cre workflow simulate ... --target=test-settings` (open to everyone), then
   `cre workflow deploy` — **gated: production deployment is Early Access**
   (`cre account access` / app.chain.link/cre/request-access, use-case form).

**Why we have not adopted it (2026-08-05):**

- **Early Access gate** — approval latency outside our control.
- **EVM write gas quota: 5,000,000 per transaction** (docs.chain.link/cre/service-quotas)
  — a partial-sweep backstop at best (see the box below); the 25M full sweep is
  impossible on CRE.
- **No permissionless funding.** Automation's `addFunds` — *anyone* could extend an
  upkeep's runway — has no CRE equivalent. Billing runs through the org's Chainlink
  account (model undisclosed during Early Access), and deployment costs ETH on
  Ethereum Mainnet from the org's linked wallet. The community-sustainability property
  this project prizes is gone from the product.

**Status (2026-08-05): built and simulating.** A working CRE workflow lives in this
repo at [`cre/reward-sweeper`](../cre/) — keeper-bot pattern: cron every 4h →
`getPendingRewardCalls()` read against the live contract → skip when empty →
signed-report sweep via a receiver bridge (bridge contract not yet deployed; the
workflow logs intent until it is). Simulation passes against real Arbitrum state
(`cre workflow simulate reward-sweeper --target staging-settings`). Deployment
still gated on Early Access approval + public billing; nothing about launch blocks
on it.

### What a ~5M-capped firing can and cannot do (applies to CRE's quota)

> The contract refuses to start an iteration with less than 2.5M gas in hand (the
> per-iteration safety floor). A 5M-capped executor leaves roughly **2.3M of
> scan-plus-work budget** above the floor. In practice: a hintless reward costs
> 355k–515k (measured), so a firing lands roughly **4–5 rewards near the head of the
> pool**; a subscriber at the tail of a fully-scanned 100-node pool (~2.25M of pure
> skip-scanning) may **never be reached by a 5M lane alone** — successive firings die
> at the same depth. The 25M keeper and community lanes close this gap; any 5M-capped
> service is a backstop, not the whole answer.

### The genuinely-permissionless candidate: Reactive Network

Philosophically the closest thing to old Automation that still exists: cron events on
its own chain drive callbacks that its network executes on Arbitrum One (destination
callback proxy `0x4730c58FDA9d78f60c987039aEaB7d261aAd942E`), and funding is
**verifiably permissionless** — anyone can call `depositTo()` for any callback
contract (dev.reactive.network/economy). Verified from the proxy's source: it forwards
`gasleft()` minus ~200k, so there is **no on-chain maximum** — the effective cap is
whatever gas Reactive's relayers attach, which is undocumented (examples use 1–3M).

**Adoption gate (unchanged):** a cheap experiment proving relayers execute a ≥5M-gas
callback (ideally more), plus recent successful callbacks on-chain, plus an
end-to-end cron test measuring drift. If it passes, Reactive becomes the layer-3
backstop *and* restores the anyone-can-fund story. If callbacks cap low, it adds
nothing.

---

## The 2026 automation landscape (post-mortem edition)

The managed-automation category collapsed within twelve months. Survey as of
August 2026:

| Service | Status (2026) | Arbitrum One | Verdict for this job |
|---|---|---|---|
| Chainlink Automation | **Dead** — v2.1 sunset 2026-07-31; no new registrations since June | Was | Was the recommended backstop; see CRE |
| **Chainlink CRE** | Live; deployment Early Access | Yes (writes) | Candidate backstop — gated, 5M write quota, no permissionless funding |
| Gelato Automate / Web3 Functions | **Dead** — EOL 2026-03-31, pivoted to rollup-as-a-service | Was | Do not use |
| OpenZeppelin Defender (hosted) | **Retired 2026-07-01**; open-source self-hosted Relayer lives on | Self-hosted only | Viable DIY alternative to the Python keeper if you prefer Docker |
| PowerPool PowerAgent v2 | **Dead on Arbitrum** — zero transactions on any of its ten contracts since 2024-08-10 (verified on-chain) | No | Ruled out |
| Keep3r Network | Live | No — Ethereum mainnet only | N/A |
| Ava Protocol (EigenLayer AVS) | Live on other chains | No Arbitrum support yet | Watch |
| **Reactive Network** | Live; permissionless `depositTo()` funding | Yes (callback destination) | **Best candidate** — pending the ≥5M callback-gas experiment |
| KeeperHub / Mimic (2026 entrants) | Live, courting ex-Automation/Gelato users | Yes | Centralized managed services, subscription-funded — optional third redundancy leg at most |
| ERC-4337 / Safe scheduled txs | Live | Yes | No gain — still needs a centralized cranker; owner-scoped funding |
| GitHub Actions cron | Live | n/a (off-chain) | Emergency backup at best — documented multi-hour delays, dropped runs |

**The category lesson, now thrice-taught:** Gelato exited in March, hosted Defender in
July, and Chainlink Automation — the canonical answer, the one this document
recommended — in July. Prefer mechanisms whose liveness is verifiable on-chain and
whose funding is permissionless; assume any single service can vanish. That is exactly
why the load-bearing layers here are a keeper anyone can re-run from a public repo and
a contract call anyone can make.

---

## Future note

Everything above assumes today's protocol shape: a 100-node active set that one 25M
transaction can sweep. If Livepeer 2.0 uncaps the node set, per-round work stops being
bounded and altruistic funding stops scaling. The clean upgrade path is a v2 contract
(a **new address** orchestrators deliberately re-point `setRewardCaller` to — v1 is
immutable and has no upgrade mechanism) that adds a small tip per successful reward
call, making keeper networks — and even anonymous cron runners — self-funding. Until
then, redundant layers at pennies per day is the cheaper and simpler answer.
