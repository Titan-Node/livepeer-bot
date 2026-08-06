# reward_keeper — the livepeer.bot keeper

A single-file Python keeper for the shared
[`LivepeerRewardCaller`](../src/LivepeerRewardCaller.sol) contract on **Arbitrum One**.
Once per Livepeer round (~21 h) it discovers every orchestrator that delegated reward
calling to the contract, checks who still needs a reward call, and sends
`rewardAll(15, 0)` (plus an eviction-rescue `rewardFor` when needed) — with multi-RPC
failover, a primary/backup gas wallet, stuck-tx fee bumping, and SMTP / Telegram /
console alerting.

> **Live:** `reward_caller = 0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE` on Arbitrum One
> (verified on
> [Arbiscan](https://arbiscan.io/address/0x2F5901C6D8EB0181FA4f2b75EAAd0344a916fdDE#code)
> and Blockscout) — `config.example.toml` ships with it filled in, so the only thing you
> must supply is a funded gas wallet.

## Setup

```bash
cd keeper
python -m venv .venv
# Linux/macOS:            source .venv/bin/activate
# Windows (PowerShell):   .venv\Scripts\Activate.ps1
pip install -r requirements.txt

cp config.example.toml config.toml     # then edit (see walkthrough below)
export KEEPER_PRIMARY_KEY=0x...        # or use a keystore, see Key management

python reward_keeper.py --config config.toml --once --verbose
```

Python 3.11+ is required (the config parser uses stdlib `tomllib`). The only
third-party dependency is `web3` (v7).

Exit codes: `0` ok / no work, `1` alert-worthy failure, `2` config error — cron and
systemd can key off these directly.

## Config walkthrough

Every field lives in `config.toml` (annotated in `config.example.toml`). The
important choices:

| Field | Meaning |
|---|---|
| `rpc_urls` | Ordered list; the keeper rotates to the next on transport failure and alerts `ALL_RPCS_DOWN` when none respond. |
| `reward_caller` | The deployed LivepeerRewardCaller. The keeper refuses to run against an address with no code (catches the placeholder). |
| `controller` | Livepeer Controller; BondingManager/RoundsManager are resolved through it at runtime, exactly like the contract does. |
| `sentinel_delay_fraction` | `0` = act as soon as reward calls are pending. `0.25` = only act after 25% of the round has elapsed (see Sentinel mode). |
| `max_txs_per_round` | Hard spend cap per round, persisted across invocations. |
| `subscribers_static` | Extra candidate addresses merged with log-discovered subscribers. Harmless if not actually subscribed (the on-chain filter drops them). |
| `initial_scan_from_block` | Start of the first `RewardCallerSet` log scan. Defaults to the LIP-118 registration block (489,354,275). On an anvil fork, set it to the fork block — anvil serves logs only from the fork point forward. |
| `[wallet]` | Primary/backup keys + balance thresholds (see below). |
| `[smtp]` / `[telegram]` | Optional alert channels; both best-effort — a notification failure is logged and never crashes the keeper. Console logging is the always-on fallback. |
| `healthcheck_ping_url` | healthchecks.io-style watchdog (see Liveness). |
| `[tx]` | Gas limit is **hardcoded at 25M** per the contract's keeper recipe — do not "optimize" it with `eth_estimateGas`, which cannot see the contract's ≥2.5M per-iteration safety floor. |

Secrets are never stored in the file: config fields name the **environment variables**
that hold them (`primary_key_env`, `pass_env`, `bot_token_env`, ...). A few
non-secret fields also accept direct env overrides: `KEEPER_RPC_URLS` (comma-sep),
`KEEPER_REWARD_CALLER`, `KEEPER_STATE_FILE`, `KEEPER_DRY_RUN`.

## Key management

The gas wallet only pays gas. It holds **no protocol role**: `rewardAll` is
permissionless, so the worst a leaked keeper key enables is spending its own ETH on
gas for other people's rewards. Still, keep it clean:

| Option | How | Tradeoff |
|---|---|---|
| Env var (`primary_key_env`) | Raw hex key in an env var, e.g. injected by systemd `LoadCredential`/`Environment=`, Task Scheduler, or a secrets manager | Simplest; key is in process env — fine for a dedicated keeper box/user, weak on shared machines |
| Keystore (`primary_keystore` + `primary_keystore_pass_env`) | geth/UTC JSON keystore on disk, password via env | Key encrypted at rest; password still in env, slightly more moving parts |

Use a **dedicated EOA** funded with a few weeks of gas (~0.01–0.05 ETH covers months
at typical Arbitrum prices), never a wallet that holds anything else. The optional
backup wallet is a second such EOA — the keeper switches to it automatically when the
primary can no longer afford a tx, and alerts immediately.

**Donations:** the gas EOA address is safe to publish. Anyone can send ETH to it, and
topping it up is a direct donation of keeper runtime — there is nothing else the
address can do.

## Scheduling

One `--once` pass every 30 minutes is plenty (a round lasts ~21 hours; repeated
passes are idempotent and cost nothing when there is no work).

**cron**

```cron
*/30 * * * * cd /opt/livepeer-keeper && ./.venv/bin/python reward_keeper.py --config config.toml --once >> keeper.log 2>&1
```

**systemd timer** (`/etc/systemd/system/livepeer-keeper.service` + `.timer`)

```ini
# livepeer-keeper.service
[Unit]
Description=livepeer.bot reward keeper (single pass)
[Service]
Type=oneshot
WorkingDirectory=/opt/livepeer-keeper
Environment=KEEPER_PRIMARY_KEY=...   # better: EnvironmentFile=/etc/livepeer-keeper.env (chmod 600)
ExecStart=/opt/livepeer-keeper/.venv/bin/python reward_keeper.py --config config.toml --once

# livepeer-keeper.timer
[Unit]
Description=Run the livepeer.bot reward keeper every 30 minutes
[Timer]
OnCalendar=*:0/30
RandomizedDelaySec=300
Persistent=true
[Install]
WantedBy=timers.target
```

```bash
systemctl enable --now livepeer-keeper.timer
```

**Windows Task Scheduler**

```powershell
$action = New-ScheduledTaskAction -Execute "C:\livepeer-keeper\.venv\Scripts\python.exe" `
  -Argument "reward_keeper.py --config config.toml --once" -WorkingDirectory "C:\livepeer-keeper"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration ([TimeSpan]::MaxValue)
Register-ScheduledTask -TaskName "LivepeerRewardKeeper" -Action $action -Trigger $trigger
```

(Set `KEEPER_PRIMARY_KEY` as a user environment variable for the task's account, or
switch to the keystore option.)

Alternatively `--daemon` runs the same pass in an internal loop
(`[daemon] interval_seconds` + random jitter) for container deployments.

## Sentinel mode

If a Chainlink Automation upkeep (or any other keeper) is the *primary* caller, run
this keeper as a **backstop**: set `sentinel_delay_fraction = 0.25`. Each pass then
exits quietly while less than 25% of the round has elapsed, giving the primary layer
first shot; if reward calls are *still* pending after the gate, the keeper acts.
Round progress is computed from the RoundsManager's own views
(`blockNum() - currentRoundStartBlock()) / roundLength()`) — i.e. in the block frame
the contract actually sees (Arbitrum contracts see the L1 block estimate, **not** the
L2 height that `eth_blockNumber` returns).

Two independent layers with jittered schedules make a missed round essentially
impossible, and the idempotent contract makes overlap free (a second caller's sweep
skips already-rewarded orchestrators for ~25k gas each).

## Design notes

**Subscriber discovery is O(subscribers), not O(pool).** The keeper incrementally
scans BondingManager `RewardCallerSet` logs (topic0
`0x15932b87747cac36d3c505e86a946c6d3a79d9d7bdb79d81584d32bbe54516c2`) from the
LIP-118 block forward, maintains a last-write-wins `transcoder -> rewardCaller` map in
the state file, and treats every transcoder currently pointing at our contract as a
subscriber. The first run scans months of history once (a few minutes on public
RPCs, chunked adaptively); every later run scans only new blocks.

**The eviction blind spot is closed by construction.** The contract's pool views
(and `rewardAll`'s sweep) walk the protocol's *next-round* pool, so a subscriber
evicted mid-round (out-competed, resigned, slashed) is invisible to them while
remaining reward-eligible until round end. This keeper never asks the pool who is
pending — it asks `filterPendingRewardCalls(<our subscriber list>)`, a pure predicate
over an explicit list with no pool enumeration. Evictees therefore appear in the
keeper's pending set automatically; whatever a *complete* `rewardAll` sweep leaves
behind is rescued with `rewardFor(remainder, zeros, zeros, 0)` in the same pass. No
`TranscoderDeactivated` event watching is needed (for cross-checking, that event's
topic0 is `0xfee3e693fc72d0a0a673805f3e606c551f4c677b9072444b90dd2d0406bc995c`,
verified against the Blockscout-verified LIP-118 target).

**Gas.** `rewardAll(15, 0)` with a hardcoded 25M gas limit, per the contract NatSpec.
If the contract ever reverts `InsufficientGas` (the tx couldn't afford even one
attempt), the keeper raises the limit once to 30M, then alerts. Estimation-based
limits are deliberately not used.

## Liveness (healthchecks)

Alerts can only be sent by a keeper that is *running*. A crashed box, an expired
venv, a broken cron entry — a **dead keeper cannot self-report**. Set
`healthcheck_ping_url` to a [healthchecks.io](https://healthchecks.io) check with a
grace period of ~2 hours: the keeper GETs the URL after every clean pass and
`<url>/fail` after failures, so *silence* pages you even when nothing else can.

## Failure modes — what each alert means

Every alert carries a `classification:` line. Operator actions:

| Classification | Meaning | Action |
|---|---|---|
| `LOW_BALANCE` | Active gas wallet below `warn_wei` (deduped daily) | Top up the wallet |
| `PRIMARY_WALLET_DRY` | Primary can't afford a tx; backup took over | Top up the primary now — you're on the spare |
| `INSUFFICIENT_FUNDS` | Neither wallet can afford a tx; nothing sent | Top up immediately; rewards at risk this round |
| `ALL_RPCS_DOWN` | Every configured RPC failed at transport level | Check network/providers; add endpoints to `rpc_urls` |
| `TX_REVERTED` | A send (or its pre-send simulation) reverted; message includes the decoded custom error (`SystemPaused`, `RoundNotInitializable(inner)`, `InsufficientGas`, ...) | Read the decoded reason; `SystemPaused`/`RoundNotInitializable` are protocol-side |
| `TX_STUCK` | No receipt despite fee-bumped rebroadcasts | Check Arbitrum status / gas market; the nonce is still pending |
| `PROTOCOL_DRIFT` | `RewardCallFailed` event observed — the contract pre-checks every expected failure, so a reward call reverting means the protocol changed under us | Investigate immediately; includes transcoder + decoded revert data |
| `PERSISTENT_FAILER` | Subscriber(s) still pending after a complete sweep *and* an eviction rescue | Investigate the listed transcoders; possibly protocol drift or a weird state edge |
| `TX_CAP_REACHED` | `max_txs_per_round` hit with work remaining | Raise the cap or investigate why txs aren't clearing the queue |
| `SCAN_FAILED` | Log scan failing even at minimum chunk size | Keeper still acts on known subscribers; fix/replace the RPC |
| `SYSTEM_PAUSED` | Livepeer protocol paused (alert-once daily, clean exit) | Nothing — wait for the protocol to unpause |
| `LATE_ROUND_PENDING` | (dry-run only) pending calls past 80% of the round | Someone should act — you're in dry-run |
| `UNEXPECTED_EXCEPTION` | Keeper bug or environment failure; traceback tail attached | File an issue with the traceback |
| `KEEPER_EXITED` | Process died outside every normal path (atexit hook) | Check host, logs, scheduler |

## Local end-to-end test (anvil fork)

`test_local.py` spins up an `anvil --fork-url` of Arbitrum One, deploys the real
contract, impersonates a live orchestrator to subscribe it, and runs the keeper
against the fork — including the primary-dry -> backup failover path. Requires
Foundry (`anvil`, `forge`, `cast`):

```bash
python test_local.py            # uses https://arb1.arbitrum.io/rpc for the fork
TEST_FORK_RPC=https://... python test_local.py
```
