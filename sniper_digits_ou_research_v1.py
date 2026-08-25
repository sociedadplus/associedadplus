#!/usr/bin/env python3
"""SNIPER-DIGITS: passive DIGITOVER/DIGITUNDER research collector.

The module deliberately contains no account authentication or order execution.
Its network vocabulary is restricted to ticks, ticks_history and proposal.
"""
from __future__ import annotations

import argparse
import asyncio
import csv
import hashlib
import json
import math
import os
import platform
import random
import signal
import statistics
import subprocess
import sys
import time
import uuid
from collections import Counter, deque
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterable

ENGINE_VERSION = "1.0.0"
PROTOCOL_VERSION = "digits-ou-paper-v1"
PUBLIC_OPTIONS_WS = "wss://api.derivws.com/trading/v1/options/ws/public"
CONTRACTS = [("DIGITOVER", b) for b in range(4)] + [("DIGITUNDER", b) for b in range(6, 10)]
LOOKBACKS = (10, 20, 50, 100)
RESULT_FIELDS = ["shot_id", "run_id", "symbol", "signal_epoch", "signal_tick_seq", "contract_type",
                 "barrier", "state_id", "hypothesis_id", "proposal_id", "ask_price", "payout",
                 "break_even", "estimated_p", "edge", "expected_value", "entry_tick", "settlement_tick",
                 "entry_digit", "settlement_digit", "win", "loss", "paper_pl", "track", "control_type",
                 "paired_shot_id", "lookback", "delay", "hour_utc"]


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def last_digit(quote: int | float | str | Decimal, pip_size: int) -> int:
    """Extract the displayed last digit without losing trailing zeroes."""
    if pip_size < 0:
        raise ValueError("pip_size must be non-negative")
    scaled = Decimal(str(quote)).quantize(Decimal(1).scaleb(-pip_size)) * (10 ** pip_size)
    return int(scaled) % 10


def pip_digits(value: int | float | str | Decimal) -> int:
    """Normalise either decimal pip size (0.001) or a digit count (3)."""
    pip = Decimal(str(value))
    if pip < 0:
        raise ValueError("pip_size must be non-negative")
    if pip == pip.to_integral_value():
        return int(pip)
    normalized = pip.normalize()
    if normalized.as_tuple().digits != (1,) or normalized.as_tuple().exponent >= 0:
        raise ValueError(f"pip_size is not a power of ten: {value}")
    return -normalized.as_tuple().exponent


class APIResponseError(RuntimeError):
    def __init__(self, code: str, message: str):
        self.code, self.message = code, message
        super().__init__(f"{code}: {message}" if code else message)


def response_errors(message: dict[str, Any]) -> list[dict[str, str]]:
    """Return a uniform list for both legacy ``error`` and current ``errors``."""
    raw = message.get("errors", message.get("error", []))
    if not raw:
        return []
    if isinstance(raw, dict):
        raw = [raw]
    if not isinstance(raw, list):
        raw = [{"message": str(raw)}]
    return [{"code": str(item.get("code", "")), "message": str(item.get("message", item))}
            if isinstance(item, dict) else {"code": "", "message": str(item)} for item in raw]


def raise_for_api_errors(message: dict[str, Any]) -> None:
    errors = response_errors(message)
    if errors:
        combined = "; ".join(f'{e["code"]}: {e["message"]}'.strip(": ") for e in errors)
        raise APIResponseError(",".join(e["code"] for e in errors if e["code"]), combined)


def active_symbols_payload(req_id: int) -> dict[str, Any]:
    return {"active_symbols": "brief", "req_id": req_id}


def contracts_for_payload(symbol: str, req_id: int) -> dict[str, Any]:
    return {"contracts_for": symbol, "req_id": req_id}


def history_payload(symbol: str, count: int, req_id: int) -> dict[str, Any]:
    return {"ticks_history": symbol, "count": count, "end": "latest", "style": "ticks", "req_id": req_id}


def ticks_payload(symbol: str, req_id: int) -> dict[str, Any]:
    return {"ticks": symbol, "subscribe": 1, "req_id": req_id}


def proposal_payload(args: argparse.Namespace, hypothesis: "Hypothesis", req_id: int) -> dict[str, Any]:
    return {"proposal": 1, "amount": args.stake, "basis": "stake", "contract_type": hypothesis.contract_type,
            "currency": args.currency, "duration": 1, "duration_unit": "t", "barrier": str(hypothesis.barrier),
            "underlying_symbol": args.symbol, "req_id": req_id}


def contract_wins(contract_type: str, barrier: int, digit: int) -> bool:
    if contract_type == "DIGITOVER":
        return digit > barrier
    if contract_type == "DIGITUNDER":
        return digit < barrier
    raise ValueError(f"unsupported contract: {contract_type}")


def proposal_economics(proposal: dict[str, Any]) -> tuple[float, float, float]:
    try:
        ask, payout = float(Decimal(str(proposal["ask_price"]))), float(Decimal(str(proposal["payout"])))
    except (KeyError, ValueError, ArithmeticError) as exc:
        raise ValueError("proposal lacks valid ask_price/payout economics") from exc
    if not math.isfinite(ask) or not math.isfinite(payout) or ask <= 0 or payout <= ask:
        raise ValueError("proposal requires finite positive payout greater than ask_price")
    return ask, payout, ask / payout


def streak(values: list[int], predicate=lambda a, b: a == b) -> int:
    if not values:
        return 0
    n = 1
    for i in range(len(values) - 1, 0, -1):
        if not predicate(values[i], values[i - 1]):
            break
        n += 1
    return n


def state_snapshot(digits: list[int], tick_seq: int) -> dict[str, Any]:
    counts = Counter(digits[-100:])
    out: dict[str, Any] = {"last_digit": digits[-1], "tick_seq": tick_seq}
    for i, d in enumerate(reversed(digits[-10:]), 1):
        out[f"digit_{i}"] = d
    for d in range(10):
        out[f"freq_{d}"] = counts[d] / min(100, len(digits))
        try:
            out[f"ticks_since_digit_{d}"] = list(reversed(digits)).index(d)
        except ValueError:
            out[f"ticks_since_digit_{d}"] = None
    for n in LOOKBACKS:
        window = digits[-n:]
        out[f"freq_last_{n}"] = json.dumps([window.count(d) / len(window) for d in range(10)])
    probs = [v / min(100, len(digits)) for v in counts.values()]
    expected = min(100, len(digits)) / 10
    out.update(streak_same_digit=streak(digits),
               streak_low_digits=streak(digits, lambda a, b: a <= 4 and b <= 4) if digits[-1] <= 4 else 0,
               streak_high_digits=streak(digits, lambda a, b: a >= 5 and b >= 5) if digits[-1] >= 5 else 0,
               count_0_1=sum(d in (0, 1) for d in digits[-100:]),
               count_0_1_2=sum(d in (0, 1, 2) for d in digits[-100:]),
               count_7_8_9=sum(d in (7, 8, 9) for d in digits[-100:]),
               entropy=-sum(p * math.log2(p) for p in probs if p),
               chi_square_uniformity=sum((counts[d] - expected) ** 2 / expected for d in range(10)),
               max_digit_frequency=max(counts.values()) / min(100, len(digits)),
               min_digit_frequency=min(counts[d] for d in range(10)) / min(100, len(digits)))
    canonical = json.dumps(out, sort_keys=True, separators=(",", ":"))
    out["state_id"] = hashlib.sha256(canonical.encode()).hexdigest()[:16]
    return out


@dataclass(frozen=True)
class Hypothesis:
    hypothesis_id: str
    contract_type: str
    barrier: int
    lookback: int = 100
    delay: int = 0
    min_edge: float = 0.02
    max_entropy: float = 3.4
    frozen: bool = True

    def estimate(self, digits: list[int]) -> float:
        window = digits[-self.lookback:]
        return sum(contract_wins(self.contract_type, self.barrier, d) for d in window) / len(window)

    def matches(self, state: dict[str, Any]) -> bool:
        return float(state["entropy"]) <= self.max_entropy


class JsonlTable:
    """Crash-safe append table, optionally compacted to Parquet at shutdown."""
    def __init__(self, parquet_path: Path):
        self.path = parquet_path
        self.journal = parquet_path.with_suffix(parquet_path.suffix + ".jsonl")
        self.handle = self.journal.open("a", encoding="utf-8", buffering=1)

    def append(self, row: dict[str, Any]) -> None:
        self.handle.write(json.dumps(row, ensure_ascii=False, default=str) + "\n")
        self.handle.flush()

    def close(self) -> None:
        self.handle.flush(); os.fsync(self.handle.fileno()); self.handle.close()
        try:
            import pyarrow as pa
            import pyarrow.parquet as pq
            rows = [json.loads(line) for line in self.journal.read_text(encoding="utf-8").splitlines() if line]
            if rows:
                tmp = self.path.with_suffix(".tmp.parquet")
                pq.write_table(pa.Table.from_pylist(rows), tmp)
                tmp.replace(self.path)
        except ImportError:
            pass  # the journal remains the authoritative incremental dataset


class ResearchEngine:
    def __init__(self, args: argparse.Namespace):
        self.args, self.run_id = args, uuid.uuid4().hex[:12]
        self.root = Path(args.out_dir) / args.symbol / "sniper_digits_v1" / f"run_{self.run_id}"
        self.root.mkdir(parents=True)
        self.ticks = JsonlTable(self.root / "ticks.parquet")
        self.opportunities = JsonlTable(self.root / "opportunities.parquet")
        self.proposals = JsonlTable(self.root / "proposals.parquet")
        self.results_path, self.summary_path = self.root / "paper_results.csv", self.root / "paper_summary.csv"
        self.events = (self.root / "events.log").open("a", encoding="utf-8", buffering=1)
        self.digits: deque[int] = deque(maxlen=max(args.history, 100))
        self.seq = 0; self.connection_id = ""; self.clean_ticks = 0; self.pending: list[dict[str, Any]] = []
        self.stop = False; self.rng = random.Random(args.seed)
        self.pip_digits = pip_digits(args.pip_size)
        self.hypotheses = self._hypotheses()
        self._write_metadata(None)

    def _hypotheses(self) -> list[Hypothesis]:
        if self.args.mode == "discovery":
            return []
        if not self.args.hypotheses:
            raise ValueError("OOS requires --hypotheses with frozen rules")
        raw = json.loads(Path(self.args.hypotheses).read_text(encoding="utf-8"))
        hypotheses = [Hypothesis(**item) for item in raw]
        if not all(h.frozen for h in hypotheses):
            raise ValueError("every OOS hypothesis must be frozen")
        return hypotheses

    def event(self, text: str) -> None:
        line = f"{utcnow()} {text}"; print(line); self.events.write(line + "\n")

    def _write_metadata(self, end: str | None) -> None:
        try: git_hash = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        except Exception: git_hash = None
        try:
            import websockets
            websocket_version = websockets.__version__
        except ImportError: websocket_version = None
        data = dict(engine_version=ENGINE_VERSION, protocol_version=PROTOCOL_VERSION, run_id=self.run_id,
                    session_label=self.args.session_label, symbol=self.args.symbol, start_time=getattr(self, "start", utcnow()),
                    end_time=end, cli=sys.argv, git_hash=git_hash, python_version=platform.python_version(),
                    websockets_version=websocket_version, lookbacks=LOOKBACKS,
                    hypotheses=[asdict(h) for h in getattr(self, "hypotheses", [])],
                    frozen_rules=self.args.mode == "oos", contract_families=CONTRACTS, stake=self.args.stake,
                    currency=self.args.currency, random_seed=self.args.seed, mode=self.args.mode,
                    pip_digits=getattr(self, "pip_digits", None), public_endpoint=PUBLIC_OPTIONS_WS)
        (self.root / "metadata.json").write_text(json.dumps(data, indent=2), encoding="utf-8")

    def mark_gap(self, reason: str) -> None:
        self.clean_ticks = 0; self.pending.clear(); self.event(f"GAP DETECTED: {reason}")

    def ingest_tick(self, tick: dict[str, Any], gap=False, eligible=True) -> list[tuple[Hypothesis, dict[str, Any]]]:
        self.seq += 1
        received_pip = tick.get("pip_size")
        if received_pip is not None and pip_digits(received_pip) != self.pip_digits:
            raise APIResponseError("PIP_SIZE_MISMATCH",
                                   f"tick pip_size={received_pip} differs from preflight digits={self.pip_digits}")
        pip = self.pip_digits
        digit = last_digit(tick["quote"], pip)
        if gap: self.mark_gap("tick sequence/connection discontinuity")
        self.ticks.append(dict(run_id=self.run_id, symbol=self.args.symbol, epoch=int(tick["epoch"]),
                               local_received_ts=utcnow(), quote=str(tick["quote"]), pip_size=pip,
                               last_digit=digit, tick_seq=self.seq, connection_id=self.connection_id, gap_flag=gap))
        self.digits.append(digit); self.clean_ticks += 1
        if eligible:
            self._settle(int(tick["epoch"]), digit)
        if self.clean_ticks == 100: self.event("LOOKBACK REBUILD")
        if eligible and self.clean_ticks >= 100: return self._evaluate(int(tick["epoch"]), digit)
        return []

    def _evaluate(self, epoch: int, digit: int) -> list[tuple[Hypothesis, dict[str, Any]]]:
        state = state_snapshot(list(self.digits), self.seq)
        if self.args.mode == "discovery":
            self.opportunities.append(dict(epoch=epoch, run_id=self.run_id, state=state, candidate=None,
                                           proposal=None, break_even=None, estimated_p=None, edge=None,
                                           decision="NO_FIRE", reason="DISCOVERY_COLLECT_ONLY", mode="discovery"))
            return []
        requests=[]
        for h in self.hypotheses:
            p = h.estimate(list(self.digits))
            # Proposal arrives asynchronously in live operation; this record explains evaluation intent.
            decision = "REQUEST_PROPOSAL" if h.matches(state) else "NO_FIRE"
            self.opportunities.append(dict(epoch=epoch, run_id=self.run_id, state=state, candidate=asdict(h),
                                           proposal=None, break_even=None, estimated_p=p, edge=None,
                                           decision=decision, reason="STATE_MATCH" if h.matches(state) else "RULE_NOT_MET", mode="oos"))
            if h.matches(state): requests.append((h, state))
        return requests

    def accept_proposal(self, h: Hypothesis, state: dict[str, Any], proposal: dict[str, Any], epoch: int) -> None:
        ask, payout, be = proposal_economics(proposal); p = h.estimate(list(self.digits)); edge = p - be
        row = dict(run_id=self.run_id, epoch=epoch, contract_type=h.contract_type, barrier=h.barrier,
                   duration=1, duration_unit="t", stake=self.args.stake, ask_price=ask, payout=payout,
                   break_even=be, proposal_id=proposal["id"], proposal_epoch=proposal.get("date_start", epoch),
                   proposal_latency_ms=proposal.get("latency_ms"))
        self.proposals.append(row)
        fire = edge >= h.min_edge and h.matches(state) and self.clean_ticks >= h.lookback
        self.opportunities.append(dict(epoch=epoch, run_id=self.run_id, state=state, candidate=asdict(h), proposal=row,
                                       break_even=be, estimated_p=p, edge=edge, decision="FIRE" if fire else "NO_FIRE",
                                       reason="EDGE_OK" if fire else "EDGE_TOO_LOW", mode="oos"))
        if fire: self._paper_shot(h, state, row, p, edge)

    def _paper_shot(self, h: Hypothesis, state: dict[str, Any], proposal: dict[str, Any], p: float, edge: float) -> None:
        shot_id = uuid.uuid4().hex; print(f"[PAPER SHOT #{shot_id[:8]}]")
        base = dict(shot_id=shot_id, run_id=self.run_id, symbol=self.args.symbol, signal_epoch=proposal["epoch"],
                    signal_tick_seq=self.seq, contract_type=h.contract_type, barrier=h.barrier,
                    state_id=state["state_id"], hypothesis_id=h.hypothesis_id, proposal_id=proposal["proposal_id"],
                    ask_price=proposal["ask_price"], payout=proposal["payout"], break_even=proposal["break_even"],
                    estimated_p=p, edge=edge, expected_value=p * proposal["payout"] - proposal["ask_price"],
                    entry_tick=self.seq, entry_digit=self.digits[-1], lookback=h.lookback, delay=h.delay,
                    hour_utc=datetime.fromtimestamp(proposal["epoch"], timezone.utc).hour)
        self.pending.append({**base, "settle_seq": self.seq + 1 + h.delay, "track": "SNIPER", "control_type": "", "paired_shot_id": ""})
        control = {**base, "shot_id": uuid.uuid4().hex, "settle_seq": self.seq + 1 + self.rng.choice((0, 1, 2)),
                   "track": "CONTROL", "control_type": "CONTROL_MATCHED", "paired_shot_id": shot_id}
        self.pending.append(control)

    def _settle(self, epoch: int, digit: int) -> None:
        due = [p for p in self.pending if p["settle_seq"] == self.seq]
        self.pending = [p for p in self.pending if p["settle_seq"] > self.seq]
        for row in due:
            win = contract_wins(row["contract_type"], int(row["barrier"]), digit)
            row.update(settlement_tick=self.seq, settlement_digit=digit, win=int(win), loss=int(not win),
                       paper_pl=(row["payout"] - row["ask_price"]) if win else -row["ask_price"])
            row.pop("settle_seq"); self._append_result(row)

    def _append_result(self, row: dict[str, Any]) -> None:
        exists = self.results_path.exists()
        with self.results_path.open("a", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=RESULT_FIELDS); 
            if not exists: w.writeheader()
            w.writerow({k: row.get(k) for k in RESULT_FIELDS}); f.flush(); os.fsync(f.fileno())

    def summarize(self) -> None:
        if not self.results_path.exists(): return
        rows = list(csv.DictReader(self.results_path.open(encoding="utf-8")))
        groups: dict[tuple[str, str], list[dict[str, str]]] = {}
        for r in rows: groups.setdefault((f'{r["contract_type"]}_{r["barrier"]}', r["track"]), []).append(r)
        fields = ["family", "track", "n", "wins", "losses", "win_rate", "wilson95_low", "wilson95_high",
                  "mean_BE", "mean_edge", "paper_pl", "ROI", "max_loss_streak", "max_win_streak"]
        with self.summary_path.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=fields); w.writeheader()
            for (family, track), rs in groups.items():
                n=len(rs); wins=sum(int(r["win"]) for r in rs); lo,hi=wilson(wins,n); pl=sum(float(r["paper_pl"]) for r in rs)
                w.writerow(dict(family=family, track=track, n=n, wins=wins, losses=n-wins, win_rate=wins/n,
                                wilson95_low=lo, wilson95_high=hi, mean_BE=statistics.fmean(float(r["break_even"]) for r in rs),
                                mean_edge=statistics.fmean(float(r["edge"]) for r in rs), paper_pl=pl,
                                ROI=pl/sum(float(r["ask_price"]) for r in rs), max_loss_streak=max_streak(rs,"loss"),
                                max_win_streak=max_streak(rs,"win")))

    def close(self) -> None:
        for table in (self.ticks, self.opportunities, self.proposals): table.close()
        self.summarize(); self.events.close(); self._write_metadata(utcnow())


def wilson(wins: int, n: int, z: float = 1.96) -> tuple[float, float]:
    if not n: return 0.0, 0.0
    p=wins/n; d=1+z*z/n; c=(p+z*z/(2*n))/d; m=z*math.sqrt((p*(1-p)+z*z/(4*n))/n)/d
    return c-m,c+m


def max_streak(rows: Iterable[dict[str, Any]], key: str) -> int:
    best=cur=0
    for row in rows:
        cur=cur+1 if int(row[key]) else 0; best=max(best,cur)
    return best


def find_active_symbol(message: dict[str, Any], symbol: str) -> dict[str, Any] | None:
    entries = message.get("active_symbols", [])
    return next((item for item in entries
                 if item.get("symbol", item.get("underlying_symbol")) == symbol), None)


def available_contract_types(message: dict[str, Any]) -> set[str]:
    body = message.get("contracts_for", {})
    entries = body.get("available", body if isinstance(body, list) else [])
    return {str(item.get("contract_type", item.get("contract", ""))) for item in entries}


async def receive_request(ws, payload: dict[str, Any]) -> dict[str, Any]:
    """Send a preflight request and wait for its correlated response."""
    await ws.send(json.dumps(payload))
    while True:
        message = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
        if message.get("req_id") == payload["req_id"]:
            raise_for_api_errors(message)
            return message


async def live_preflight(ws, engine: ResearchEngine) -> None:
    active = await receive_request(ws, active_symbols_payload(1))
    selected = find_active_symbol(active, engine.args.symbol)
    if selected is None:
        raise APIResponseError("INVALID_SYMBOL", f"{engine.args.symbol} is not present in active_symbols")
    if selected.get("is_trading_suspended") in (1, True):
        raise APIResponseError("INACTIVE_SYMBOL", f"{engine.args.symbol} is trading-suspended")
    if "pip_size" not in selected:
        raise APIResponseError("MISSING_PIP_SIZE", f"active_symbols omitted pip_size for {engine.args.symbol}")
    engine.pip_digits = pip_digits(selected["pip_size"])
    contracts = await receive_request(ws, contracts_for_payload(engine.args.symbol, 2))
    available = available_contract_types(contracts)
    missing = {"DIGITOVER", "DIGITUNDER"} - available
    if missing:
        raise APIResponseError("MISSING_CONTRACTS", f"{engine.args.symbol} does not offer {sorted(missing)}")
    engine._write_metadata(None)
    engine.event(f"PREFLIGHT OK symbol={engine.args.symbol} pip_digits={engine.pip_digits} contracts=DIGITOVER,DIGITUNDER")


async def run_live(engine: ResearchEngine) -> None:
    import websockets
    deadline=time.monotonic()+engine.args.minutes*60
    while not engine.stop and time.monotonic() < deadline:
        try:
            engine.connection_id=uuid.uuid4().hex[:8]; engine.event(f"RECONNECT connection_id={engine.connection_id}")
            async with websockets.connect(PUBLIC_OPTIONS_WS) as ws:
                await live_preflight(ws, engine)
                proposal_requests: dict[int, tuple[Hypothesis, dict[str, Any], int, float]] = {}
                request_id=100
                async def request_proposals(requests, epoch):
                    nonlocal request_id
                    for h,state in requests:
                        request_id += 1
                        proposal_requests[request_id]=(h,state,epoch,time.monotonic())
                        await ws.send(json.dumps(proposal_payload(engine.args, h, request_id)))
                request_id += 1
                history_id = request_id
                await ws.send(json.dumps(history_payload(engine.args.symbol, engine.args.history, history_id)))
                subscribed = False
                async for raw in ws:
                    msg=json.loads(raw)
                    errors=response_errors(msg)
                    if errors:
                        detail="; ".join(f'{e["code"]}: {e["message"]}'.strip(": ") for e in errors)
                        engine.event(f"API ERROR req_id={msg.get('req_id')} {detail}")
                        if msg.get("req_id") in proposal_requests:
                            h,state,epoch,_=proposal_requests.pop(msg["req_id"])
                            engine.opportunities.append(dict(epoch=epoch,run_id=engine.run_id,state=state,
                                candidate=asdict(h),proposal=None,break_even=None,estimated_p=h.estimate(list(engine.digits)),
                                edge=None,decision="NO_PROPOSAL",reason=detail,mode="oos"))
                            continue
                        raise_for_api_errors(msg)
                    if "history" in msg:
                        if msg.get("pip_size") is not None and pip_digits(msg["pip_size"]) != engine.pip_digits:
                            raise APIResponseError("PIP_SIZE_MISMATCH",
                                f"history pip_size={msg['pip_size']} differs from preflight digits={engine.pip_digits}")
                        for epoch, quote in zip(msg["history"]["times"], msg["history"]["prices"]):
                            # Seed history is persisted and builds state, but does not solicit retroactive proposals.
                            engine.ingest_tick({"epoch":epoch,"quote":quote}, eligible=False)
                        if not subscribed:
                            request_id += 1
                            await ws.send(json.dumps(ticks_payload(engine.args.symbol, request_id)))
                            subscribed = True
                    elif "tick" in msg:
                        tick=msg["tick"]; await request_proposals(engine.ingest_tick(tick),int(tick["epoch"]))
                    elif "proposal" in msg and msg.get("req_id") in proposal_requests:
                        h,state,epoch,sent=proposal_requests.pop(msg["req_id"])
                        proposal=dict(msg["proposal"]); proposal["latency_ms"]=(time.monotonic()-sent)*1000
                        try:
                            engine.accept_proposal(h,state,proposal,epoch)
                        except ValueError as exc:
                            engine.event(f"API ERROR req_id={msg.get('req_id')} INVALID_PROPOSAL_ECONOMICS: {exc}")
                            engine.opportunities.append(dict(epoch=epoch,run_id=engine.run_id,state=state,
                                candidate=asdict(h),proposal=proposal,break_even=None,
                                estimated_p=h.estimate(list(engine.digits)),edge=None,decision="NO_PROPOSAL",
                                reason=f"INVALID_PROPOSAL_ECONOMICS: {exc}",mode="oos"))
                    if engine.stop or time.monotonic() >= deadline: break
        except APIResponseError as exc:
            engine.event(f"API ERROR code={exc.code} message={exc.message}")
            raise  # API/schema errors are never mislabeled as market-data gaps.
        except Exception as exc:
            engine.mark_gap(f"transport failure: {type(exc).__name__}: {exc}"); await asyncio.sleep(2)


def parse_args(argv=None):
    p=argparse.ArgumentParser(description="PAPER ONLY Deriv digits research collector")
    p.add_argument("--symbol", required=True); p.add_argument("--minutes", type=float, default=120)
    p.add_argument("--stake", type=float, default=1); p.add_argument("--currency", default="USD")
    p.add_argument("--history", type=int, default=5000); p.add_argument("--seed", type=int, default=1)
    p.add_argument("--out-dir", default="data/digits_over_under"); p.add_argument("--session-label", default="")
    p.add_argument("--mode", choices=("discovery","oos"), default="discovery")
    p.add_argument("--hypotheses", help="JSON file; mandatory and immutable in OOS")
    p.add_argument("--pip-size", type=int, default=2); p.add_argument("--app-id", default="1089")
    return p.parse_args(argv)


def main(argv=None):
    args=parse_args(argv); print("SEGURANÇA: PAPER ONLY. NÃO EXISTE BUY/SELL.")
    engine=ResearchEngine(args)
    def stop(*_): engine.stop=True
    signal.signal(signal.SIGINT, stop); signal.signal(signal.SIGTERM, stop)
    try: asyncio.run(run_live(engine))
    finally: engine.close()

if __name__ == "__main__": main()
