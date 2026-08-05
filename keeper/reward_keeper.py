#!/usr/bin/env python3
"""
reward_keeper.py — production keeper for the LivepeerRewardCaller (livepeer.bot).

Implements the full keeper recipe from the contract NatSpec / repo README:

  1. Resolve RoundsManager/BondingManager through the Controller at runtime
     (exactly like the contract does); bail out cleanly if the protocol is paused.
  2. Discover subscribers O(subscribers) via incremental eth_getLogs on the
     BondingManager RewardCallerSet event (never a pool walk).
  3. pending = filterPendingRewardCalls(subscribers) — this predicate-only view is
     immune to the pool-walk eviction blind spot BY CONSTRUCTION: we filter OUR
     subscriber list, not the pool, so a subscriber evicted mid-round stays visible
     here until rewarded or round end.
  4. Optional sentinel gate (defer to a primary automation layer early in the round).
  5. rewardAll(15, 0) with a HARDCODED 25M gas limit, looped on complete == false;
     stall detection (pending unchanged across two progressing txs); InsufficientGas
     -> raise the limit once to 30M, then alert.
  6. Eviction sweep: whatever filterPendingRewardCalls still returns after a complete
     pool sweep can only be evictees (or persistent failers) — rescue them with
     rewardFor(remainder, zeros, zeros, 0), then alert on anything that survives.
  7. Primary/backup gas wallet with balance thresholds, stuck-tx rebroadcast with
     fee bumps, multi-RPC failover, SMTP + Telegram + console alerting with
     dedup, healthchecks.io ping, crash-report atexit hook.

Exit codes: 0 = ok / no work; 1 = alert-worthy failure; 2 = configuration error.

Python 3.11+, web3.py v7+. Single file; ABIs embedded below (generated from
`forge inspect LivepeerRewardCaller abi --json`, trimmed).
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import random
import re
import smtplib
import ssl
import sys
import time
import traceback
import urllib.request
from email.mime.text import MIMEText
from pathlib import Path
from typing import Any, Callable, Optional

try:
    import tomllib  # 3.11+
except ImportError:  # pragma: no cover
    print("FATAL: Python 3.11+ required (tomllib missing)", file=sys.stderr)
    sys.exit(2)

try:
    import requests
    from eth_abi import decode as abi_decode
    from eth_account import Account
    from web3 import HTTPProvider, Web3
    from web3.exceptions import TimeExhausted, TransactionNotFound
    from web3.logs import DISCARD
except ImportError as e:  # pragma: no cover
    print(f"FATAL: missing dependency ({e}). Run: pip install -r requirements.txt", file=sys.stderr)
    sys.exit(2)

# web3 v7 names; keep soft fallbacks so a v6 install degrades gracefully.
try:
    from web3.exceptions import Web3RPCError
except ImportError:  # pragma: no cover
    class Web3RPCError(Exception):
        ...

try:
    from web3.exceptions import ContractLogicError
except ImportError:  # pragma: no cover
    class ContractLogicError(Exception):
        ...

# ---------------------------------------------------------------------------
# Verified constants (Arbitrum One / this repo — see keeper/README.md)
# ---------------------------------------------------------------------------

DEFAULT_CONTROLLER = "0xD8E8328501E9645d16Cf49539efC04f734606ee4"
LIP118_BLOCK = 489_354_275  # BondingManager LIP-118 target registered here (L2 block)

# keccak256("RewardCallerSet(address,address)") — emitted by the BondingManager proxy,
# both params indexed. Verified with `cast keccak`.
TOPIC_REWARD_CALLER_SET = "0x15932b87747cac36d3c505e86a946c6d3a79d9d7bdb79d81584d32bbe54516c2"

# keccak256("TranscoderDeactivated(address,uint256)") — verified against the Blockscout-
# verified LIP-118 target ABI (impl 0xbe197fcBfe74DE8F10460EA61644B006cC0f0Bd2):
# transcoder indexed, deactivationRound in data. Documented for operators; this keeper
# does NOT need it (see design note in README — filterPendingRewardCalls on OUR list
# already sees evictees).
TOPIC_TRANSCODER_DEACTIVATED = "0xfee3e693fc72d0a0a673805f3e606c551f4c677b9072444b90dd2d0406bc995c"

ZERO_ADDR = "0x0000000000000000000000000000000000000000"
EXPLORER_TX = "https://arbiscan.io/tx/"

# Custom error selectors of LivepeerRewardCaller (cast sig, verified):
ERR_SELECTORS = {
    "0x729e4c40": "SystemPaused()",
    "0x579c1ef7": "RoundNotInitializable(bytes)",
    "0xff633a38": "LengthMismatch()",
    "0xd92e233d": "ZeroAddress()",
    "0x1c26714c": "InsufficientGas()",
}
SEL_ERROR_STRING = "0x08c379a0"  # Error(string)
SEL_PANIC = "0x4e487b71"         # Panic(uint256)
SEL_INSUFFICIENT_GAS = "0x1c26714c"
SEL_ROUND_NOT_INIT = "0x579c1ef7"

# ---------------------------------------------------------------------------
# Embedded minimal ABIs (from `forge inspect LivepeerRewardCaller abi --json`, trimmed;
# full copy in keeper/abi/LivepeerRewardCaller.json)
# ---------------------------------------------------------------------------

REWARD_CALLER_ABI = json.loads("""
[
 {"type":"function","name":"rewardAll","stateMutability":"nonpayable",
  "inputs":[{"name":"_maxRewards","type":"uint256"},{"name":"_minGasPerCall","type":"uint256"}],
  "outputs":[{"name":"rewarded","type":"uint256"},{"name":"failed","type":"uint256"},{"name":"complete","type":"bool"}]},
 {"type":"function","name":"rewardFor","stateMutability":"nonpayable",
  "inputs":[{"name":"_transcoders","type":"address[]"},{"name":"_newPosPrevs","type":"address[]"},
            {"name":"_newPosNexts","type":"address[]"},{"name":"_minGasPerCall","type":"uint256"}],
  "outputs":[{"name":"rewarded","type":"uint256"},{"name":"failed","type":"uint256"},{"name":"processed","type":"uint256"}]},
 {"type":"function","name":"getPendingRewardCalls","stateMutability":"view",
  "inputs":[],"outputs":[{"name":"pending","type":"address[]"}]},
 {"type":"function","name":"filterPendingRewardCalls","stateMutability":"view",
  "inputs":[{"name":"_candidates","type":"address[]"}],"outputs":[{"name":"pending","type":"address[]"}]},
 {"type":"function","name":"getHints","stateMutability":"view",
  "inputs":[{"name":"_transcoders","type":"address[]"}],
  "outputs":[{"name":"newPosPrevs","type":"address[]"},{"name":"newPosNexts","type":"address[]"}]},
 {"type":"function","name":"version","stateMutability":"pure","inputs":[],"outputs":[{"name":"","type":"string"}]},
 {"type":"event","name":"RoundInitialized","anonymous":false,"inputs":[
   {"name":"round","type":"uint256","indexed":true},{"name":"caller","type":"address","indexed":true}]},
 {"type":"event","name":"RewardCallSucceeded","anonymous":false,"inputs":[
   {"name":"round","type":"uint256","indexed":true},{"name":"transcoder","type":"address","indexed":true},
   {"name":"caller","type":"address","indexed":true},{"name":"gasUsed","type":"uint256","indexed":false}]},
 {"type":"event","name":"RewardCallFailed","anonymous":false,"inputs":[
   {"name":"round","type":"uint256","indexed":true},{"name":"transcoder","type":"address","indexed":true},
   {"name":"caller","type":"address","indexed":true},{"name":"revertData","type":"bytes","indexed":false}]},
 {"type":"event","name":"BatchProcessed","anonymous":false,"inputs":[
   {"name":"round","type":"uint256","indexed":true},{"name":"caller","type":"address","indexed":true},
   {"name":"processed","type":"uint256","indexed":false},{"name":"rewarded","type":"uint256","indexed":false},
   {"name":"failed","type":"uint256","indexed":false},{"name":"complete","type":"bool","indexed":false}]}
]
""")

CONTROLLER_ABI = json.loads("""
[
 {"type":"function","name":"getContract","stateMutability":"view",
  "inputs":[{"name":"_id","type":"bytes32"}],"outputs":[{"name":"","type":"address"}]},
 {"type":"function","name":"paused","stateMutability":"view","inputs":[],"outputs":[{"name":"","type":"bool"}]}
]
""")

# All five getters verified present on the deployed RoundsManager
# 0xdd6f56DcC28D3F5f27084381fE8Df634985cc39f via live eth_call (2026-08-04).
# blockNum() returns block.number AS THE CONTRACT SEES IT (the L1 estimate on Arbitrum;
# the anvil-local height on a fork) — round progress must be computed in that frame,
# never from web3.eth.block_number (the L2 height).
ROUNDS_ABI = json.loads("""
[
 {"type":"function","name":"currentRound","stateMutability":"view","inputs":[],"outputs":[{"name":"","type":"uint256"}]},
 {"type":"function","name":"currentRoundInitialized","stateMutability":"view","inputs":[],"outputs":[{"name":"","type":"bool"}]},
 {"type":"function","name":"currentRoundStartBlock","stateMutability":"view","inputs":[],"outputs":[{"name":"","type":"uint256"}]},
 {"type":"function","name":"roundLength","stateMutability":"view","inputs":[],"outputs":[{"name":"","type":"uint256"}]},
 {"type":"function","name":"blockNum","stateMutability":"view","inputs":[],"outputs":[{"name":"","type":"uint256"}]}
]
""")

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

VERBOSE = False


def _ts() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def log(level: str, msg: str) -> None:
    print(f"{_ts()} [{level:5}] {msg}", flush=True)


def info(msg: str) -> None:
    log("INFO", msg)


def warn(msg: str) -> None:
    log("WARN", msg)


def debug(msg: str) -> None:
    if VERBOSE:
        log("DEBUG", msg)


def eth_str(wei: int) -> str:
    return f"{wei / 1e18:.6f} ETH"


# ---------------------------------------------------------------------------
# Errors / control flow
# ---------------------------------------------------------------------------

class ConfigError(Exception):
    ...


class AllRpcsDown(Exception):
    ...


class KeeperAbort(Exception):
    """Raised after an alert has already been sent; carries the exit code."""

    def __init__(self, code: int, why: str):
        super().__init__(why)
        self.code = code


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

class Cfg:
    def __init__(self, raw: dict, path: str):
        self.path = path
        # --- top level ------------------------------------------------------
        self.rpc_urls: list[str] = _env_list("KEEPER_RPC_URLS") or raw.get("rpc_urls") or []
        if not self.rpc_urls:
            raise ConfigError("rpc_urls must list at least one RPC endpoint")
        self.reward_caller: str = _addr(os.environ.get("KEEPER_REWARD_CALLER") or raw.get("reward_caller"),
                                        "reward_caller")
        self.controller: str = _addr(raw.get("controller") or DEFAULT_CONTROLLER, "controller")
        self.sentinel_delay_fraction: float = float(raw.get("sentinel_delay_fraction", 0.0))
        if not 0.0 <= self.sentinel_delay_fraction < 1.0:
            raise ConfigError("sentinel_delay_fraction must be in [0, 1)")
        self.max_txs_per_round: int = int(raw.get("max_txs_per_round", 10))
        self.state_file: str = os.environ.get("KEEPER_STATE_FILE") or raw.get("state_file") or "keeper_state.json"
        env_dry = os.environ.get("KEEPER_DRY_RUN", "").lower()
        self.dry_run: bool = env_dry in ("1", "true", "yes") if env_dry else bool(raw.get("dry_run", False))
        self.healthcheck_ping_url: str = raw.get("healthcheck_ping_url", "") or ""
        self.subscribers_static: list[str] = [_addr(a, "subscribers_static") for a in raw.get("subscribers_static", [])]
        self.initial_scan_from_block: int = int(raw.get("initial_scan_from_block", LIP118_BLOCK))
        # --- wallet ---------------------------------------------------------
        w = raw.get("wallet", {})
        self.wallet_raw = w
        self.warn_wei: int = int(w.get("warn_wei", 10_000_000_000_000_000))       # 0.01 ETH
        self.failover_wei: int = int(w.get("failover_wei", 2_000_000_000_000_000))  # 0.002 ETH
        # --- smtp / telegram ------------------------------------------------
        self.smtp: dict = raw.get("smtp", {}) or {}
        self.telegram: dict = raw.get("telegram", {}) or {}
        # --- daemon ---------------------------------------------------------
        d = raw.get("daemon", {})
        self.daemon_interval: int = int(d.get("interval_seconds", 1800))
        self.daemon_jitter: int = int(d.get("jitter_seconds", 300))
        # --- tx -------------------------------------------------------------
        t = raw.get("tx", {})
        self.gas_limit: int = int(t.get("gas_limit", 25_000_000))
        self.raised_gas_limit: int = int(t.get("raised_gas_limit", 30_000_000))
        self.max_rewards_per_tx: int = int(t.get("max_rewards_per_tx", 15))
        self.tx_wait_seconds: int = int(t.get("wait_seconds", 90))
        self.rebroadcast_retries: int = int(t.get("rebroadcast_retries", 3))
        self.fee_bump_percent: int = int(t.get("fee_bump_percent", 25))
        self.cost_margin: float = float(t.get("cost_margin", 1.5))
        # --- scan -----------------------------------------------------------
        s = raw.get("scan", {})
        self.scan_chunk: int = int(s.get("chunk", 2_000_000))
        self.scan_min_chunk: int = int(s.get("min_chunk", 50_000))


def _env_list(name: str) -> Optional[list[str]]:
    v = os.environ.get(name)
    return [x.strip() for x in v.split(",") if x.strip()] if v else None


def _addr(v: Any, what: str) -> str:
    if not v or not isinstance(v, str):
        raise ConfigError(f"{what}: address missing")
    try:
        return Web3.to_checksum_address(v)
    except Exception:
        raise ConfigError(f"{what}: invalid address {v!r}") from None


def load_config(path: str) -> Cfg:
    p = Path(path)
    if not p.is_file():
        raise ConfigError(f"config file not found: {path}")
    with open(p, "rb") as f:
        try:
            raw = tomllib.load(f)
        except tomllib.TOMLDecodeError as e:
            raise ConfigError(f"config parse error: {e}") from None
    return Cfg(raw, str(p))


# ---------------------------------------------------------------------------
# State (JSON file, atomic writes)
# ---------------------------------------------------------------------------

def load_state(path: str) -> dict:
    p = Path(path)
    if p.is_file():
        try:
            return json.loads(p.read_text())
        except Exception as e:
            warn(f"state file unreadable ({e}); starting fresh")
    return {"v": 1}


def save_state(path: str, state: dict) -> None:
    p = Path(path)
    if p.parent and str(p.parent) not in (".", ""):
        p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(state, indent=1, sort_keys=True))
    os.replace(tmp, p)


# ---------------------------------------------------------------------------
# RPC pool with rotation
# ---------------------------------------------------------------------------

# Transport-level failures rotate to the next provider. Contract reverts and RPC
# *semantic* errors (e.g. getLogs range too large) must NOT rotate — they propagate.
TRANSPORT_ERRORS = (requests.exceptions.RequestException, OSError, TimeoutError, ConnectionError)


class Chain:
    def __init__(self, urls: list[str]):
        self.urls = urls
        self.i = 0
        self._w3: dict[int, Web3] = {}

    def w3(self) -> Web3:
        if self.i not in self._w3:
            self._w3[self.i] = Web3(HTTPProvider(self.urls[self.i], request_kwargs={"timeout": 45}))
        return self._w3[self.i]

    @property
    def url(self) -> str:
        return self.urls[self.i]

    def call(self, fn: Callable[[Web3], Any]) -> Any:
        """Run fn against the active provider; rotate through all on transport failure."""
        last: Optional[Exception] = None
        for _ in range(len(self.urls)):
            try:
                return fn(self.w3())
            except TRANSPORT_ERRORS as e:
                warn(f"rpc transport failure on {self.url}: {type(e).__name__}: {e}")
                last = e
                self.i = (self.i + 1) % len(self.urls)
        raise AllRpcsDown(f"all {len(self.urls)} RPC endpoints failed; last: {last}")


# ---------------------------------------------------------------------------
# Revert decoding
# ---------------------------------------------------------------------------

def decode_revert(data: bytes | None) -> str:
    """Human-readable rendering of raw revert data, incl. our custom errors."""
    if not data:
        return "empty revert data (out-of-gas or bare revert)"
    sel = "0x" + data[:4].hex()
    body = data[4:]
    try:
        if sel == SEL_ERROR_STRING:
            return f'Error("{abi_decode(["string"], body)[0]}")'
        if sel == SEL_PANIC:
            return f"Panic(0x{abi_decode(['uint256'], body)[0]:02x})"
        if sel == SEL_ROUND_NOT_INIT:
            inner = abi_decode(["bytes"], body)[0]
            return f"RoundNotInitializable(inner: {decode_revert(bytes(inner))})"
        if sel in ERR_SELECTORS:
            return ERR_SELECTORS[sel]
    except Exception:
        pass
    return f"unknown revert {sel} (raw: 0x{data.hex()})"


_HEX_RE = re.compile(r"0x[0-9a-fA-F]{8,}")


def extract_revert_data(exc: Exception) -> Optional[bytes]:
    """Best-effort extraction of raw revert bytes from a web3 exception."""
    candidates: list[Any] = [getattr(exc, "data", None)]
    candidates.extend(getattr(exc, "args", []) or [])
    for obj in candidates:
        if isinstance(obj, (bytes, bytearray)) and len(obj) >= 4:
            return bytes(obj)
        if isinstance(obj, str) and obj.startswith("0x") and len(obj) >= 10:
            try:
                return bytes.fromhex(obj[2:])
            except ValueError:
                pass
        if isinstance(obj, dict):
            d = obj.get("data")
            if isinstance(d, str) and d.startswith("0x") and len(d) >= 10:
                try:
                    return bytes.fromhex(d[2:])
                except ValueError:
                    pass
    m = _HEX_RE.search(str(exc))
    if m:
        try:
            return bytes.fromhex(m.group(0)[2:])
        except ValueError:
            pass
    return None


def revert_selector(exc: Exception) -> str:
    data = extract_revert_data(exc)
    return "0x" + data[:4].hex() if data and len(data) >= 4 else ""


# ---------------------------------------------------------------------------
# Notifications (console always; SMTP + Telegram best-effort; deduped via state)
# ---------------------------------------------------------------------------

# Failure classification -> default dedup window (seconds). 0 = never dedup.
DEDUP_WINDOWS = {
    "LOW_BALANCE": 86_400,        # "deduped per day" per spec
    "ALL_RPCS_DOWN": 21_600,
    "SYSTEM_PAUSED": 86_400,      # alert-once while paused
    "SCAN_FAILED": 21_600,
    "PRIMARY_WALLET_DRY": 3_600,  # immediate, but not once per tx within a sweep
}


class Notifier:
    def __init__(self, cfg: Cfg, state: dict):
        self.cfg = cfg
        self.state = state
        self.sent_any = False

    def alert(self, severity: str, kind: str, title: str, lines: list[str],
              dedup_key: Optional[str] = None) -> None:
        """kind is the failure classification; every alert carries one."""
        key = dedup_key or kind
        window = DEDUP_WINDOWS.get(kind, 0)
        alerts = self.state.setdefault("alerts", {})
        now = int(time.time())
        if window and now - int(alerts.get(key, 0)) < window:
            info(f"alert deduped (kind={kind}, key={key}, window={window}s): {title}")
            return
        alerts[key] = now
        # prune entries older than 7 days
        for k in [k for k, ts in alerts.items() if now - int(ts) > 604_800]:
            del alerts[k]

        body = "\n".join([f"severity: {severity}", f"classification: {kind}", f"reason: {title}"] + lines)
        # console — the always-on fallback channel
        log("ALERT", f"[{severity}] {kind}: {title}")
        for ln in lines:
            log("ALERT", f"  {ln}")
        self.sent_any = True
        self._smtp(f"[livepeer-keeper] {severity} {kind}: {title}", body)
        self._telegram(f"[livepeer-keeper] {severity} {kind}\n{title}\n" + "\n".join(lines))

    # -- channels (must never raise) ----------------------------------------

    def _smtp(self, subject: str, body: str) -> None:
        c = self.cfg.smtp
        if not c.get("host") or not c.get("to"):
            return
        try:
            pw = os.environ.get(c.get("pass_env", ""), "") if c.get("pass_env") else ""
            frm = c.get("from") or c.get("user") or "keeper@localhost"
            to = c["to"]
            tos = [to] if isinstance(to, str) else list(to)
            msg = MIMEText(body)
            msg["Subject"], msg["From"], msg["To"] = subject, frm, ", ".join(tos)
            port = int(c.get("port", 587))
            tls = c.get("tls", True)
            if port == 465 or (isinstance(tls, str) and tls.lower() == "ssl"):
                srv = smtplib.SMTP_SSL(c["host"], port, timeout=20, context=ssl.create_default_context())
            else:
                srv = smtplib.SMTP(c["host"], port, timeout=20)
                if tls:
                    srv.starttls(context=ssl.create_default_context())
            if c.get("user") and pw:
                srv.login(c["user"], pw)
            srv.sendmail(frm, tos, msg.as_string())
            srv.quit()
            debug("smtp alert sent")
        except Exception as e:
            warn(f"smtp notification failed (non-fatal): {type(e).__name__}: {e}")

    def _telegram(self, text: str) -> None:
        c = self.cfg.telegram
        token = os.environ.get(c.get("bot_token_env", ""), "") if c.get("bot_token_env") else ""
        if not token or not c.get("chat_id"):
            return
        try:
            req = urllib.request.Request(
                f"https://api.telegram.org/bot{token}/sendMessage",
                data=json.dumps({"chat_id": str(c["chat_id"]), "text": text[:4000]}).encode(),
                headers={"Content-Type": "application/json"},
            )
            urllib.request.urlopen(req, timeout=15).read()
            debug("telegram alert sent")
        except Exception as e:
            warn(f"telegram notification failed (non-fatal): {type(e).__name__}: {e}")


def healthcheck_ping(cfg: Cfg, ok: bool) -> None:
    url = cfg.healthcheck_ping_url
    if not url:
        return
    target = url if ok else url.rstrip("/") + "/fail"
    try:
        urllib.request.urlopen(target, timeout=10).read()
        debug(f"healthcheck ping {'ok' if ok else 'FAIL'} -> {target}")
    except Exception as e:
        warn(f"healthcheck ping failed (non-fatal): {e}")


# ---------------------------------------------------------------------------
# Wallets
# ---------------------------------------------------------------------------

class Wallet:
    def __init__(self, name: str, acct: Any):
        self.name = name
        self.acct = acct

    @property
    def addr(self) -> str:
        return self.acct.address


def load_wallet(cfg: Cfg, which: str) -> Optional[Wallet]:
    """which in ('primary', 'backup'). Raw-key env beats keystore if both set."""
    w = cfg.wallet_raw
    key_env = w.get(f"{which}_key_env", "")
    if key_env and os.environ.get(key_env):
        try:
            return Wallet(which, Account.from_key(os.environ[key_env].strip()))
        except Exception as e:
            raise ConfigError(f"{which}_key_env ${key_env}: invalid private key ({e})") from None
    ks = w.get(f"{which}_keystore", "")
    if ks:
        pass_env = w.get(f"{which}_keystore_pass_env", "")
        pw = os.environ.get(pass_env, "") if pass_env else ""
        if not pw:
            raise ConfigError(f"{which}_keystore set but password env ${pass_env or '<unset>'} is empty")
        try:
            kj = json.loads(Path(ks).read_text())
            return Wallet(which, Account.from_key(Account.decrypt(kj, pw)))
        except ConfigError:
            raise
        except Exception as e:
            raise ConfigError(f"{which}_keystore {ks}: cannot decrypt ({e})") from None
    return None


# ---------------------------------------------------------------------------
# Run context
# ---------------------------------------------------------------------------

class Ctx:
    """Everything one --once invocation accumulates (also feeds alert bodies)."""

    def __init__(self) -> None:
        self.round: Optional[int] = None
        self.progress: float = 0.0
        self.chain_id: Optional[int] = None
        self.txs: list[str] = []              # tx hashes sent this run
        self.failures: dict[str, str] = {}    # transcoder -> decoded revert (RewardCallFailed)
        self.wallet: Optional[Wallet] = None
        self.balances: dict[str, int] = {}

    def alert_lines(self) -> list[str]:
        lines = []
        if self.round is not None:
            lines.append(f"round: {self.round} (progress {self.progress * 100:.0f}%)")
        for name, bal in self.balances.items():
            lines.append(f"wallet {name}: {eth_str(bal)}")
        for h in self.txs:
            lines.append(f"tx: {EXPLORER_TX}{h}")
        return lines


# ---------------------------------------------------------------------------
# Contract helpers (constructed per active provider)
# ---------------------------------------------------------------------------

def c_reward(w3: Web3, addr: str):
    return w3.eth.contract(address=addr, abi=REWARD_CALLER_ABI)


def c_controller(w3: Web3, addr: str):
    return w3.eth.contract(address=addr, abi=CONTROLLER_ABI)


def c_rounds(w3: Web3, addr: str):
    return w3.eth.contract(address=addr, abi=ROUNDS_ABI)


def resolve_managers(chain: Chain, cfg: Cfg) -> tuple[str, str, bool]:
    """(bonding_manager, rounds_manager, paused) via the Controller registry."""
    def op(w3: Web3):
        ctrl = c_controller(w3, cfg.controller)
        bm = ctrl.functions.getContract(Web3.keccak(text="BondingManager")).call()
        rm = ctrl.functions.getContract(Web3.keccak(text="RoundsManager")).call()
        paused = ctrl.functions.paused().call()
        return Web3.to_checksum_address(bm), Web3.to_checksum_address(rm), paused
    return chain.call(op)


def round_status(chain: Chain, rm_addr: str) -> tuple[int, bool, float]:
    """(currentRound, initialized, progress 0..1) — all in the CONTRACT's block frame.

    On Arbitrum, block.number inside contracts is the L1 block estimate while
    web3.eth.block_number is the L2 height; RoundsManager.blockNum() returns the
    former, so deriving progress purely from RoundsManager views is correct on
    mainnet AND on anvil forks (where block.number is anvil's own height)."""
    def op(w3: Web3):
        rm = c_rounds(w3, rm_addr)
        cur = rm.functions.currentRound().call()
        init = rm.functions.currentRoundInitialized().call()
        try:
            start = rm.functions.currentRoundStartBlock().call()
            bn = rm.functions.blockNum().call()
            rl = rm.functions.roundLength().call()
            prog = max(0.0, min(1.0, (bn - start) / rl)) if rl else 1.0
        except Exception as e:
            warn(f"round progress unavailable ({e}); assuming 100% so the sentinel gate never blocks")
            prog = 1.0
        return cur, init, prog
    return chain.call(op)


# ---------------------------------------------------------------------------
# Subscriber discovery (incremental RewardCallerSet log scan)
# ---------------------------------------------------------------------------

def discover_subscribers(chain: Chain, cfg: Cfg, state: dict, notifier: Notifier,
                         bm_addr: str) -> list[str]:
    target = cfg.reward_caller.lower()
    rc_map: dict[str, str] = state.setdefault("reward_caller_map", {})

    frm = state.get("last_scanned_block")
    frm = cfg.initial_scan_from_block if frm is None else int(frm) + 1
    latest = chain.call(lambda w3: w3.eth.block_number)
    chunk = cfg.scan_chunk
    scanned_ok = True

    while frm <= latest:
        to = min(frm + chunk - 1, latest)
        try:
            logs = chain.call(lambda w3, a=frm, b=to: w3.eth.get_logs({
                "address": bm_addr,
                "topics": [TOPIC_REWARD_CALLER_SET],
                "fromBlock": a,
                "toBlock": b,
            }))
        except AllRpcsDown:
            raise
        except Exception as e:
            # semantic provider error, most likely range/result limits -> shrink chunk
            if chunk > cfg.scan_min_chunk:
                chunk = max(cfg.scan_min_chunk, chunk // 2)
                debug(f"getLogs rejected ({type(e).__name__}); shrinking chunk to {chunk}")
                continue
            notifier.alert("WARNING", "SCAN_FAILED",
                           f"RewardCallerSet log scan failing at block {frm} even at min chunk",
                           [f"provider error: {e}",
                            "acting on the subscriber set known so far (state file + subscribers_static)"])
            scanned_ok = False
            break
        for lg in sorted(logs, key=lambda l: (l["blockNumber"], l["logIndex"])):
            transcoder = Web3.to_checksum_address(bytes(lg["topics"][1])[-20:]).lower()
            caller = Web3.to_checksum_address(bytes(lg["topics"][2])[-20:]).lower()
            rc_map[transcoder] = caller  # last write wins
            debug(f"RewardCallerSet: {transcoder} -> {caller} @ block {lg['blockNumber']}")
        state["last_scanned_block"] = to
        save_state(cfg.state_file, state)  # crash-safe incremental progress
        frm = to + 1
        chunk = min(chunk * 2, cfg.scan_chunk)  # recover after shrinks

    subs = [Web3.to_checksum_address(t) for t, c in rc_map.items() if c == target]
    for s in cfg.subscribers_static:
        if s not in subs:
            subs.append(s)
    scan_note = "" if scanned_ok else " (scan incomplete!)"
    info(f"subscribers: {len(subs)} known{scan_note}"
         + (f" -> {', '.join(subs)}" if subs and len(subs) <= 10 else ""))
    return subs


def filter_pending(chain: Chain, cfg: Cfg, subs: list[str]) -> list[str]:
    if not subs:
        return []
    def op(w3: Web3):
        return c_reward(w3, cfg.reward_caller).functions.filterPendingRewardCalls(subs).call()
    return [Web3.to_checksum_address(a) for a in chain.call(op)]


# ---------------------------------------------------------------------------
# Wallet selection / balance policy
# ---------------------------------------------------------------------------

def pick_wallet(chain: Chain, cfg: Cfg, ctx: Ctx, notifier: Notifier,
                primary: Optional[Wallet], backup: Optional[Wallet]) -> Wallet:
    """Estimated cost = gas_limit * gasPrice * margin. Primary below
    max(failover_wei, est) -> switch to backup + immediate alert. Active wallet
    below warn_wei -> daily-deduped warning."""
    if primary is None:
        raise ConfigError("no primary wallet configured (wallet.primary_key_env / primary_keystore)")
    gas_price = chain.call(lambda w3: w3.eth.gas_price)
    est = int(cfg.gas_limit * gas_price * cfg.cost_margin)
    threshold = max(cfg.failover_wei, est)

    p_bal = chain.call(lambda w3: w3.eth.get_balance(primary.addr))
    ctx.balances["primary " + primary.addr] = p_bal
    chosen = primary
    if p_bal < threshold:
        b_bal = chain.call(lambda w3: w3.eth.get_balance(backup.addr)) if backup else 0
        if backup:
            ctx.balances["backup " + backup.addr] = b_bal
        if backup and b_bal >= threshold:
            notifier.alert("CRITICAL", "PRIMARY_WALLET_DRY",
                           f"primary gas wallet dry (balance {eth_str(p_bal)}, "
                           f"need {eth_str(threshold)}), used backup",
                           ctx.alert_lines())
            chosen = backup
        else:
            notifier.alert("CRITICAL", "INSUFFICIENT_FUNDS",
                           f"no wallet can afford a tx (primary {eth_str(p_bal)}, "
                           f"backup {eth_str(b_bal) if backup else 'not configured'}, "
                           f"need {eth_str(threshold)})",
                           ctx.alert_lines())
            raise KeeperAbort(1, "insufficient wallet funds")

    a_bal = chain.call(lambda w3: w3.eth.get_balance(chosen.addr))
    if a_bal < cfg.warn_wei:
        notifier.alert("WARNING", "LOW_BALANCE",
                       f"active wallet ({chosen.name}) balance {eth_str(a_bal)} "
                       f"below warn threshold {eth_str(cfg.warn_wei)}",
                       ctx.alert_lines(), dedup_key=f"LOW_BALANCE:{chosen.addr}")
    ctx.wallet = chosen
    return chosen


# ---------------------------------------------------------------------------
# Transaction machinery
# ---------------------------------------------------------------------------

class TxResult:
    def __init__(self, receipt: Any, tx_hash: str):
        self.receipt = receipt
        self.tx_hash = tx_hash


def _raw_tx(signed: Any) -> bytes:
    return getattr(signed, "raw_transaction", None) or signed.rawTransaction  # v7 / v6


def send_and_wait(chain: Chain, cfg: Cfg, ctx: Ctx, notifier: Notifier, wallet: Wallet,
                  fn_builder: Callable[[Web3], Any], gas_limit: int) -> TxResult:
    """Sign+send with 'pending' nonce; on no receipt within tx_wait_seconds,
    rebroadcast the SAME nonce with +fee_bump_percent fees, bounded retries."""
    def build_and_send(w3: Web3, gas_price: int, nonce: Optional[int]) -> tuple[str, int, dict]:
        n = w3.eth.get_transaction_count(wallet.addr, "pending") if nonce is None else nonce
        tx = fn_builder(w3).build_transaction({
            "from": wallet.addr,
            "nonce": n,
            "gas": gas_limit,
            "gasPrice": gas_price,
            "chainId": ctx.chain_id,
        })
        signed = wallet.acct.sign_transaction(tx)
        h = w3.eth.send_raw_transaction(_raw_tx(signed)).hex()
        return (h if h.startswith("0x") else "0x" + h), n, tx

    # eth_gasPrice tracks the CURRENT block's base fee with no headroom; Arbitrum's dynamic
    # pricing can tick the base fee up between quote and inclusion, and the node then rejects
    # the tx outright ("max fee per gas less than block base fee"). Quote +25%: on Arbitrum a
    # legacy tx is only ever charged the actual base fee, so the headroom costs nothing.
    gas_price = int(chain.call(lambda w3: w3.eth.gas_price) * 5 // 4) + 1
    tx_hash, nonce, _ = chain.call(lambda w3: build_and_send(w3, gas_price, None))
    ctx.txs.append(tx_hash)
    info(f"sent tx {tx_hash} (nonce {nonce}, gas {gas_limit}, gasPrice {gas_price}, wallet {wallet.name})")
    hashes = [tx_hash]

    for attempt in range(cfg.rebroadcast_retries + 1):
        deadline = time.time() + cfg.tx_wait_seconds
        while time.time() < deadline:
            for h in hashes:
                try:
                    rcpt = chain.call(lambda w3, hh=h: w3.eth.get_transaction_receipt(hh))
                    return TxResult(rcpt, h)
                except TransactionNotFound:
                    pass
            time.sleep(3)
        if attempt >= cfg.rebroadcast_retries:
            break
        gas_price = int(gas_price * (100 + cfg.fee_bump_percent) / 100) + 1
        warn(f"tx unmined after {cfg.tx_wait_seconds}s; rebroadcasting nonce {nonce} "
             f"with gasPrice {gas_price} (attempt {attempt + 1}/{cfg.rebroadcast_retries})")
        try:
            h2, _, _ = chain.call(lambda w3: build_and_send(w3, gas_price, nonce))
            if h2 not in hashes:
                hashes.append(h2)
                ctx.txs.append(h2)
        except (ValueError, Web3RPCError) as e:
            s = str(e).lower()
            if "nonce too low" in s:  # original mined between polls
                debug("nonce too low on rebroadcast; polling originals for a receipt")
                continue
            if "already known" in s or "already imported" in s or "underpriced" in s:
                debug(f"rebroadcast not accepted ({s[:80]}); continuing to wait")
                continue
            raise

    notifier.alert("CRITICAL", "TX_STUCK",
                   f"tx unmined after {cfg.rebroadcast_retries} fee-bumped rebroadcasts (nonce {nonce})",
                   ctx.alert_lines() + [f"hashes tried: {', '.join(hashes)}"])
    raise KeeperAbort(1, "tx stuck")


def simulate(chain: Chain, cfg: Cfg, fn_builder: Callable[[Web3], Any],
             gas_limit: int, from_addr: str):
    """eth_call the exact tx first: reverts are caught for free, pre-send."""
    def op(w3: Web3):
        return fn_builder(w3).call({"from": from_addr, "gas": gas_limit})
    return chain.call(op)


def classify_and_alert_revert(notifier: Notifier, ctx: Ctx, exc: Exception, where: str) -> str:
    """Returns the selector so callers can special-case InsufficientGas."""
    data = extract_revert_data(exc)
    decoded = decode_revert(data) if data else f"(no revert data extracted: {exc})"
    sel = "0x" + data[:4].hex() if data and len(data) >= 4 else ""
    if sel != SEL_INSUFFICIENT_GAS:
        notifier.alert("CRITICAL", "TX_REVERTED",
                       f"{where} reverted: {decoded}", ctx.alert_lines())
    return sel


def parse_batch_events(chain: Chain, cfg: Cfg, ctx: Ctx, receipt: Any) -> Optional[dict]:
    """Decode BatchProcessed + RewardCallSucceeded/Failed from a receipt."""
    def op(w3: Web3):
        rc = c_reward(w3, cfg.reward_caller)
        batches = rc.events.BatchProcessed().process_receipt(receipt, errors=DISCARD)
        oks = rc.events.RewardCallSucceeded().process_receipt(receipt, errors=DISCARD)
        fails = rc.events.RewardCallFailed().process_receipt(receipt, errors=DISCARD)
        inits = rc.events.RoundInitialized().process_receipt(receipt, errors=DISCARD)
        return batches, oks, fails, inits
    batches, oks, fails, inits = chain.call(op)

    for ev in inits:
        info(f"round {ev['args']['round']} initialized by this tx")
    for ev in oks:
        info(f"RewardCallSucceeded: transcoder {ev['args']['transcoder']} "
             f"(gasUsed {ev['args']['gasUsed']})")
    for ev in fails:
        t = Web3.to_checksum_address(ev["args"]["transcoder"])
        decoded = decode_revert(bytes(ev["args"]["revertData"]))
        ctx.failures[t] = decoded
        warn(f"RewardCallFailed: transcoder {t} revert: {decoded}")
    if not batches:
        return None
    a = batches[-1]["args"]
    return {"processed": a["processed"], "rewarded": a["rewarded"],
            "failed": a["failed"], "complete": a["complete"]}


# ---------------------------------------------------------------------------
# The act phase: rewardAll loop + eviction-sweep rescue
# ---------------------------------------------------------------------------

def round_tx_count(state: dict, rnd: int) -> int:
    return int(state.setdefault("round_txs", {}).get(str(rnd), 0))


def bump_round_tx(state: dict, cfg: Cfg, rnd: int) -> None:
    rt = state.setdefault("round_txs", {})
    rt[str(rnd)] = int(rt.get(str(rnd), 0)) + 1
    # keep only the current round's counter
    for k in [k for k in rt if k != str(rnd)]:
        del rt[k]
    save_state(cfg.state_file, state)


def check_tx_cap(state: dict, cfg: Cfg, ctx: Ctx, notifier: Notifier) -> None:
    if round_tx_count(state, ctx.round) >= cfg.max_txs_per_round:
        notifier.alert("CRITICAL", "TX_CAP_REACHED",
                       f"max_txs_per_round ({cfg.max_txs_per_round}) reached with work remaining",
                       ctx.alert_lines())
        raise KeeperAbort(1, "tx cap reached")


def send_reward_tx(chain: Chain, cfg: Cfg, ctx: Ctx, notifier: Notifier, state: dict,
                   primary: Optional[Wallet], backup: Optional[Wallet],
                   fn_builder: Callable[[Web3], Any], what: str,
                   gas_state: dict) -> Optional[dict]:
    """Simulate -> send -> receipt -> events, with the InsufficientGas raise-once
    rule shared between rewardAll and the rescue rewardFor. Returns batch dict."""
    while True:
        if cfg.dry_run:
            # dry runs simulate only: skip the tx cap and the balance/failover policy
            wallet = primary or Wallet("simulated", Account.from_key("0x" + "11" * 32))
        else:
            check_tx_cap(state, cfg, ctx, notifier)
            wallet = pick_wallet(chain, cfg, ctx, notifier, primary, backup)
        gas_limit = gas_state["limit"]
        try:
            sim = simulate(chain, cfg, fn_builder, gas_limit, wallet.addr)
            debug(f"{what} simulation ok: {sim}")
        except AllRpcsDown:
            raise
        except (KeeperAbort, ConfigError):
            raise
        except Exception as e:
            sel = classify_and_alert_revert(notifier, ctx, e, f"{what} (pre-send simulation)")
            if sel == SEL_INSUFFICIENT_GAS and not gas_state["raised"]:
                gas_state["limit"] = cfg.raised_gas_limit
                gas_state["raised"] = True
                warn(f"InsufficientGas in simulation; raising gas limit once to {cfg.raised_gas_limit}")
                continue
            if sel == SEL_INSUFFICIENT_GAS:
                notifier.alert("CRITICAL", "TX_REVERTED",
                               f"{what} still InsufficientGas after raising the gas limit to "
                               f"{gas_state['limit']} — investigate pool size / protocol change",
                               ctx.alert_lines())
            raise KeeperAbort(1, "simulation revert")

        if cfg.dry_run:
            info(f"DRY RUN: would send {what} with gas limit {gas_limit} from {wallet.name} "
                 f"({wallet.addr}); simulated result: {sim}")
            return None

        bump_round_tx(state, cfg, ctx.round)
        res = send_and_wait(chain, cfg, ctx, notifier, wallet, fn_builder, gas_limit)
        rcpt = res.receipt
        if rcpt["status"] == 1:
            batch = parse_batch_events(chain, cfg, ctx, rcpt)
            gas_used = rcpt.get("gasUsed", 0)
            info(f"{what} mined ok: {res.tx_hash} gasUsed={gas_used} batch={batch}")
            return batch

        # status 0: replay via eth_call at the mined block to decode the reason
        warn(f"{what} tx {res.tx_hash} REVERTED on-chain; replaying to decode")
        try:
            simulate(chain, cfg, fn_builder, gas_limit, wallet.addr)
            notifier.alert("CRITICAL", "TX_REVERTED",
                           f"{what} reverted on-chain but replay succeeds (transient state race?)",
                           ctx.alert_lines())
            raise KeeperAbort(1, "tx reverted, replay clean")
        except (KeeperAbort, AllRpcsDown):
            raise
        except Exception as e:
            sel = classify_and_alert_revert(notifier, ctx, e, what)
            if sel == SEL_INSUFFICIENT_GAS and not gas_state["raised"]:
                gas_state["limit"] = cfg.raised_gas_limit
                gas_state["raised"] = True
                warn(f"InsufficientGas on-chain; raising gas limit once to {cfg.raised_gas_limit}")
                continue
            if sel == SEL_INSUFFICIENT_GAS:
                notifier.alert("CRITICAL", "TX_REVERTED",
                               f"{what} still InsufficientGas at gas limit {gas_state['limit']}",
                               ctx.alert_lines())
            raise KeeperAbort(1, "tx reverted")


def act(chain: Chain, cfg: Cfg, ctx: Ctx, notifier: Notifier, state: dict,
        subs: list[str], pending0: list[str],
        primary: Optional[Wallet], backup: Optional[Wallet]) -> int:
    """rewardAll loop + eviction rescue. Returns exit code."""
    gas_state = {"limit": cfg.gas_limit, "raised": False}

    def reward_all_builder(w3: Web3):
        return c_reward(w3, cfg.reward_caller).functions.rewardAll(cfg.max_rewards_per_tx, 0)

    last_pending: Optional[list[str]] = None
    pending = pending0
    stalled = False

    while True:
        batch = send_reward_tx(chain, cfg, ctx, notifier, state, primary, backup,
                               reward_all_builder, "rewardAll", gas_state)
        if batch is None:  # dry run
            info("DRY RUN: stopping after simulated rewardAll")
            if ctx.progress > 0.8 and pending:
                notifier.alert("WARNING", "LATE_ROUND_PENDING",
                               f"dry-run mode: {len(pending)} reward call(s) still pending past "
                               f"80% of round {ctx.round}",
                               ctx.alert_lines() + [f"pending: {', '.join(pending)}"])
            return 0

        pending = filter_pending(chain, cfg, subs)
        info(f"pending after tx: {len(pending)}" + (f" -> {', '.join(pending)}" if pending else ""))

        if batch["complete"]:
            # Pool sweep finished. Anything still pending is invisible to the pool
            # walk (mid-round evictee) or a persistent failer -> rescue phase.
            break
        if batch["processed"] > 0 and last_pending is not None and pending == last_pending:
            # pending unchanged across two consecutive progressing txs
            warn("pending unchanged across two progressing txs; stopping rewardAll loop")
            stalled = True
            break
        last_pending = pending
        if not pending:
            break

    # ---- eviction sweep / rescue -----------------------------------------
    remainder = filter_pending(chain, cfg, subs)
    if remainder:
        info(f"rescue phase: {len(remainder)} subscriber(s) still pending after "
             f"{'stalled ' if stalled else 'complete '}sweep (likely mid-round evictees "
             f"or persistent failers): {', '.join(remainder)}")
        zeros = [ZERO_ADDR] * len(remainder)

        def reward_for_builder(w3: Web3):
            return c_reward(w3, cfg.reward_caller).functions.rewardFor(remainder, zeros, zeros, 0)

        send_reward_tx(chain, cfg, ctx, notifier, state, primary, backup,
                       reward_for_builder, "rewardFor(rescue)", gas_state)
        remainder = filter_pending(chain, cfg, subs)

    # ---- final verdict ----------------------------------------------------
    code = 0
    if ctx.failures:
        detail = [f"  {t}: {r}" for t, r in ctx.failures.items()]
        notifier.alert("CRITICAL", "PROTOCOL_DRIFT",
                       f"{len(ctx.failures)} RewardCallFailed event(s) observed — the contract's "
                       "pre-checks filter every expected failure, so this means protocol drift; "
                       "investigate",
                       ctx.alert_lines() + detail)
        code = 1
    if remainder:
        detail = [f"  {t}: {ctx.failures.get(t, 'no revert observed (never attempted?)')}"
                  for t in remainder]
        notifier.alert("CRITICAL", "PERSISTENT_FAILER",
                       f"{len(remainder)} subscriber(s) still pending after sweep + rescue in "
                       f"round {ctx.round}",
                       ctx.alert_lines() + detail)
        code = 1
    if code == 0:
        info(f"round {ctx.round}: all subscriber reward calls settled "
             f"({len(pending0)} were pending at start; txs sent this run: {len(ctx.txs)})")
    return code


# ---------------------------------------------------------------------------
# One keeper invocation
# ---------------------------------------------------------------------------

def run_once(cfg: Cfg) -> int:
    state = load_state(cfg.state_file)
    notifier = Notifier(cfg, state)
    ctx = Ctx()
    _EXIT["notifier"] = notifier
    _EXIT["ctx"] = ctx
    _EXIT["clean"] = False  # armed only while a pass is in flight
    chain = Chain(cfg.rpc_urls)

    try:
        code = _run_once_inner(chain, cfg, state, notifier, ctx)
        save_state(cfg.state_file, state)
        healthcheck_ping(cfg, ok=(code == 0))
        return code
    except KeeperAbort as e:
        info(f"aborting: {e} (alert already sent)")
        save_state(cfg.state_file, state)
        healthcheck_ping(cfg, ok=False)
        return e.code
    except AllRpcsDown as e:
        notifier.alert("CRITICAL", "ALL_RPCS_DOWN", str(e), ctx.alert_lines())
        save_state(cfg.state_file, state)
        healthcheck_ping(cfg, ok=False)
        return 1
    except ConfigError:
        raise
    except Exception:
        tb = traceback.format_exc().strip().splitlines()
        tail = tb[-14:]
        notifier.alert("CRITICAL", "UNEXPECTED_EXCEPTION",
                       f"keeper crashed: {tb[-1] if tb else 'unknown'}",
                       ctx.alert_lines() + ["traceback tail:"] + [f"  {l}" for l in tail])
        save_state(cfg.state_file, state)
        healthcheck_ping(cfg, ok=False)
        return 1


def _run_once_inner(chain: Chain, cfg: Cfg, state: dict, notifier: Notifier, ctx: Ctx) -> int:
    info(f"reward_keeper starting (config {cfg.path}, dry_run={cfg.dry_run}, "
         f"sentinel={cfg.sentinel_delay_fraction})")

    # sanity: contract must exist at the configured address
    code_at = chain.call(lambda w3: w3.eth.get_code(cfg.reward_caller))
    if not code_at or len(code_at) == 0:
        raise ConfigError(f"no contract code at reward_caller {cfg.reward_caller} "
                          f"(placeholder address? wrong network?)")
    ctx.chain_id = chain.call(lambda w3: w3.eth.chain_id)
    ver = chain.call(lambda w3: c_reward(w3, cfg.reward_caller).functions.version().call())
    debug(f"chain id {ctx.chain_id}; contract version {ver}")

    # controller resolution + pause gate
    bm_addr, rm_addr, paused = resolve_managers(chain, cfg)
    debug(f"BondingManager {bm_addr}, RoundsManager {rm_addr}, paused={paused}")
    if paused:
        notifier.alert("WARNING", "SYSTEM_PAUSED",
                       "Livepeer protocol is paused; nothing can be rewarded (alert deduped daily)",
                       ctx.alert_lines())
        info("protocol paused; clean exit")
        return 0

    # round status
    rnd, initialized, progress = round_status(chain, rm_addr)
    ctx.round, ctx.progress = rnd, progress
    info(f"round {rnd}: initialized={initialized}, progress {progress * 100:.1f}%")

    # subscriber discovery (incremental log scan; O(subscribers))
    subs = discover_subscribers(chain, cfg, state, notifier, bm_addr)

    # pending — filterPendingRewardCalls over OUR list (evictee-proof by construction)
    pending = filter_pending(chain, cfg, subs)
    info(f"pending reward calls: {len(pending)}"
         + (f" -> {', '.join(pending)}" if pending else ""))

    if not pending:
        if initialized:
            info("nothing to do: round initialized, no pending subscriber reward calls")
            return 0
        info("nothing to do: no pending subscriber reward calls (round not initialized; "
             "initialization alone is not this keeper's job)")
        return 0

    # sentinel gate
    if cfg.sentinel_delay_fraction > 0 and progress < cfg.sentinel_delay_fraction:
        info(f"sentinel mode: round progress {progress * 100:.1f}% < "
             f"{cfg.sentinel_delay_fraction * 100:.0f}% gate; deferring to the primary "
             "automation layer (quiet exit)")
        return 0

    # act
    primary = load_wallet(cfg, "primary")
    backup = load_wallet(cfg, "backup")
    if not cfg.dry_run and primary is None:
        raise ConfigError("no primary wallet configured and dry_run is false")
    if cfg.dry_run and primary is None:
        primary = Wallet("simulated", Account.from_key("0x" + "11" * 32))
        info("DRY RUN without a configured wallet: simulating from a throwaway address")
        gas_state = {"limit": cfg.gas_limit, "raised": False}
        try:
            sim = simulate(chain, cfg,
                           lambda w3: c_reward(w3, cfg.reward_caller).functions
                           .rewardAll(cfg.max_rewards_per_tx, 0),
                           gas_state["limit"], primary.addr)
            info(f"DRY RUN: rewardAll(15, 0) simulation -> rewarded={sim[0]} failed={sim[1]} "
                 f"complete={sim[2]}")
        except Exception as e:
            info(f"DRY RUN: simulation reverted: {decode_revert(extract_revert_data(e))}")
        return 0

    return act(chain, cfg, ctx, notifier, state, subs, pending, primary, backup)


# ---------------------------------------------------------------------------
# atexit crash reporter
# ---------------------------------------------------------------------------

# clean=True by default so argparse/--help exits stay silent; run_once arms it.
_EXIT: dict[str, Any] = {"clean": True, "notifier": None, "ctx": None, "reason": ""}


def _atexit_hook() -> None:
    if _EXIT["clean"]:
        return
    n: Optional[Notifier] = _EXIT.get("notifier")
    ctx: Optional[Ctx] = _EXIT.get("ctx")
    reason = _EXIT.get("reason") or "process exited without reaching a clean shutdown path"
    lines = ctx.alert_lines() if ctx else []
    if n is not None:
        try:
            n.alert("CRITICAL", "KEEPER_EXITED", f"keeper exited unexpectedly: {reason}", lines)
        except Exception:
            print(f"{_ts()} [ALERT] KEEPER_EXITED: {reason}", flush=True)
    else:
        print(f"{_ts()} [ALERT] KEEPER_EXITED: {reason}", flush=True)


atexit.register(_atexit_hook)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    global VERBOSE
    ap = argparse.ArgumentParser(
        prog="reward_keeper",
        description="Keeper for the LivepeerRewardCaller shared reward service (livepeer.bot)")
    ap.add_argument("--config", default="config.toml", help="path to TOML config (default: config.toml)")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--once", action="store_true", help="single pass (default)")
    mode.add_argument("--daemon", action="store_true",
                      help="run forever: one pass every daemon.interval_seconds + jitter")
    ap.add_argument("--verbose", action="store_true", help="debug logging")
    args = ap.parse_args()
    VERBOSE = args.verbose

    try:
        cfg = load_config(args.config)
    except ConfigError as e:
        print(f"CONFIG ERROR: {e}", file=sys.stderr)
        _EXIT["clean"] = True  # config errors are self-explanatory; no crash alert
        sys.exit(2)

    if args.daemon:
        info(f"daemon mode: interval {cfg.daemon_interval}s + jitter 0..{cfg.daemon_jitter}s")
        try:
            while True:
                try:
                    code = run_once(cfg)
                    _EXIT["clean"] = True  # pass ended through a handled path
                    info(f"pass finished with code {code}")
                except ConfigError as e:
                    print(f"CONFIG ERROR: {e}", file=sys.stderr)
                    _EXIT["clean"] = True
                    sys.exit(2)
                nap = cfg.daemon_interval + random.randint(0, max(cfg.daemon_jitter, 0))
                info(f"sleeping {nap}s")
                time.sleep(nap)
        except KeyboardInterrupt:
            info("daemon interrupted; bye")
            _EXIT["clean"] = True
            sys.exit(0)
    else:
        try:
            code = run_once(cfg)
        except ConfigError as e:
            print(f"CONFIG ERROR: {e}", file=sys.stderr)
            _EXIT["clean"] = True
            sys.exit(2)
        _EXIT["clean"] = True
        sys.exit(code)


if __name__ == "__main__":
    main()
