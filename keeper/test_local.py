#!/usr/bin/env python3
"""
test_local.py — end-to-end keeper test against an anvil fork of Arbitrum One.

What it does (no real funds, no real secrets — only anvil's well-known dev keys):

  1. starts `anvil --fork-url <RPC>` (Foundry required),
  2. deploys the real LivepeerRewardCaller from this repo (`forge create`),
  3. impersonates the top live orchestrator and points its LIP-118
     `setRewardCaller` at the fresh deployment,
  4. RUN 1: reward_keeper.py --once with an UNFUNDED primary wallet and a funded
     backup -> must discover the subscriber via RewardCallerSet logs, fail over to
     the backup (PRIMARY_WALLET_DRY alert), send rewardAll, and land the reward
     (on a fork the current round is always fresh/uninitialized, so the reward
     path is exercised; an already-rewarded clean skip is also accepted and
     reported),
  5. RUN 2: same config again -> incremental state, "nothing to do" path.

Usage:
  python test_local.py                    # forks https://arb1.arbitrum.io/rpc
  TEST_FORK_RPC=https://... python test_local.py
  FOUNDRY_BIN=/path/to/bin python test_local.py   # if foundry is not in ~/.foundry/bin

Run it with the same interpreter/venv that has the keeper's requirements installed.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
KEEPER = HERE / "reward_keeper.py"

CONTROLLER = "0xD8E8328501E9645d16Cf49539efC04f734606ee4"
BONDING_MANAGER = "0x35Bcf3c30594191d53231E4FF333E8A770453e40"
RPC = "http://127.0.0.1:8545"

# anvil's well-known dev keys (public knowledge, worthless outside local chains)
ANVIL_KEY0 = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ANVIL_KEY1 = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
# deterministic key with (virtually certainly) zero balance on the fork
UNFUNDED_KEY = "0x" + "01" * 32

EXE = ".exe" if os.name == "nt" else ""


def foundry(tool: str) -> str:
    bindir = os.environ.get("FOUNDRY_BIN") or str(Path.home() / ".foundry" / "bin")
    p = Path(bindir) / f"{tool}{EXE}"
    if p.is_file():
        return str(p)
    w = shutil.which(tool)
    if w:
        return w
    sys.exit(f"FATAL: {tool} not found (looked in {bindir} and PATH); install Foundry "
             f"or set FOUNDRY_BIN")


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    print(f"  $ {' '.join(str(c) for c in cmd)}", flush=True)
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def rpc_call(method: str, params: list) -> dict:
    req = urllib.request.Request(
        RPC, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                              "params": params}).encode(),
        headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=15).read())


def wait_for_anvil(timeout: int = 120) -> int:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = rpc_call("eth_blockNumber", [])
            if "result" in r:
                return int(r["result"], 16)
        except Exception:
            pass
        time.sleep(2)
    raise RuntimeError("anvil did not come up in time")


CHECKS: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    CHECKS.append((name, ok, detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""), flush=True)


def main() -> None:
    fork_rpc = os.environ.get("TEST_FORK_RPC", "https://arb1.arbitrum.io/rpc")
    anvil, forge, cast = foundry("anvil"), foundry("forge"), foundry("cast")
    tmp = Path(tempfile.mkdtemp(prefix="keeper_test_"))
    print(f"== workdir {tmp}")
    anvil_log = open(tmp / "anvil.log", "w")

    print(f"== starting anvil fork of {fork_rpc}")
    proc = subprocess.Popen([anvil, "--fork-url", fork_rpc, "--port", "8545"],
                            stdout=anvil_log, stderr=subprocess.STDOUT)
    try:
        fork_block = wait_for_anvil()
        print(f"== anvil up at block {fork_block}")

        # ---- deploy the real contract ---------------------------------------
        r = run([forge, "create", "src/LivepeerRewardCaller.sol:LivepeerRewardCaller",
                 "--rpc-url", RPC, "--private-key", ANVIL_KEY0, "--broadcast",
                 "--constructor-args", CONTROLLER, "--json"], cwd=str(REPO))
        deployed = ""
        for line in r.stdout.splitlines():
            line = line.strip()
            if line.startswith("{"):
                try:
                    deployed = json.loads(line).get("deployedTo", "") or deployed
                except json.JSONDecodeError:
                    pass
            elif line.startswith("Deployed to:"):
                deployed = line.split(":", 1)[1].strip()
        check("forge create deployed LivepeerRewardCaller", r.returncode == 0 and bool(deployed),
              deployed or (r.stdout + r.stderr)[-400:])
        if not deployed:
            raise RuntimeError("deployment failed")

        # ---- subscribe a real orchestrator via impersonation ----------------
        r = run([cast, "call", BONDING_MANAGER, "getFirstTranscoderInPool()(address)",
                 "--rpc-url", RPC])
        orch = r.stdout.strip()
        check("found live orchestrator (pool head)", r.returncode == 0 and orch.startswith("0x"), orch)

        for cmd in ([cast, "rpc", "anvil_setBalance", orch, "0xDE0B6B3A7640000", "--rpc-url", RPC],
                    [cast, "rpc", "anvil_impersonateAccount", orch, "--rpc-url", RPC]):
            r = run(cmd)
            if r.returncode != 0:
                raise RuntimeError(f"anvil rpc failed: {r.stdout}{r.stderr}")
        r = run([cast, "send", BONDING_MANAGER, "setRewardCaller(address)", deployed,
                 "--from", orch, "--unlocked", "--rpc-url", RPC, "--json"])
        check("orchestrator subscribed (setRewardCaller)", r.returncode == 0,
              "" if r.returncode == 0 else (r.stdout + r.stderr)[-400:])
        r = run([cast, "call", BONDING_MANAGER, "transcoderToRewardCaller(address)(address)",
                 orch, "--rpc-url", RPC])
        check("on-chain transcoderToRewardCaller == deployment",
              r.stdout.strip().lower() == deployed.lower(), r.stdout.strip())

        # ---- keeper config: unfunded primary, funded backup -----------------
        cfg = tmp / "config.toml"
        cfg.write_text(f'''
rpc_urls = ["{RPC}"]
reward_caller = "{deployed}"
controller = "{CONTROLLER}"
sentinel_delay_fraction = 0.0
max_txs_per_round = 10
state_file = "{(tmp / 'state.json').as_posix()}"
dry_run = false
initial_scan_from_block = {fork_block}

[wallet]
primary_key_env = "TEST_PRIMARY_KEY"
backup_key_env = "TEST_BACKUP_KEY"
warn_wei = 10000000000000000
failover_wei = 2000000000000000

[tx]
wait_seconds = 30
''')
        env = dict(os.environ, TEST_PRIMARY_KEY=UNFUNDED_KEY, TEST_BACKUP_KEY=ANVIL_KEY1)

        # ---- RUN 1: discovery + failover + reward ---------------------------
        print("== RUN 1: keeper --once (unfunded primary -> backup failover -> rewardAll)")
        r1 = run([sys.executable, str(KEEPER), "--config", str(cfg), "--once", "--verbose"],
                 env=env, timeout=600)
        print(r1.stdout)
        if r1.stderr.strip():
            print("-- stderr --\n" + r1.stderr)
        out = r1.stdout
        check("run 1 exit code 0", r1.returncode == 0, f"code {r1.returncode}")
        check("run 1 discovered the subscriber via RewardCallerSet logs",
              "subscribers: 1" in out and orch.lower()[2:10] in out.lower())
        rewarded = "RewardCallSucceeded" in out and "settled" in out
        skipped = "nothing to do" in out
        check("run 1 reward landed (or clean already-rewarded skip)", rewarded or skipped,
              "reward path" if rewarded else ("skip path (orchestrator already rewarded pre-fork)"
                                             if skipped else "neither"))
        if rewarded:
            check("run 1 failed over to backup wallet (PRIMARY_WALLET_DRY alert logged)",
                  "PRIMARY_WALLET_DRY" in out and "used backup" in out)
            check("run 1 no RewardCallFailed / drift", "PROTOCOL_DRIFT" not in out)

        # ---- RUN 2: idempotent no-work pass ---------------------------------
        print("== RUN 2: keeper --once again (expect: no pending, clean exit)")
        r2 = run([sys.executable, str(KEEPER), "--config", str(cfg), "--once", "--verbose"],
                 env=env, timeout=300)
        print(r2.stdout)
        check("run 2 exit code 0", r2.returncode == 0, f"code {r2.returncode}")
        check("run 2 took the no-work path", "nothing to do" in r2.stdout
              or "pending reward calls: 0" in r2.stdout)
        check("run 2 reused incremental scan state",
              (tmp / "state.json").is_file() and "last_scanned_block"
              in (tmp / "state.json").read_text())

    finally:
        proc.kill()
        anvil_log.close()

    failed = [c for c in CHECKS if not c[1]]
    print(f"\n== {len(CHECKS) - len(failed)}/{len(CHECKS)} checks passed")
    if failed:
        for name, _, detail in failed:
            print(f"   FAILED: {name} {detail}")
        sys.exit(1)
    print("== ALL GREEN")


if __name__ == "__main__":
    main()
