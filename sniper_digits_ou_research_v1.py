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
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterable

ENGINE_VERSION = "1.0.0"
PROTOCOL_VERSION = "digits-ou-paper-v1"
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


def contract_wins(contract_type: str, barrier: int, digit: int) -> bool:
    if contract_type == "DIGITOVER":
        return digit > barrier
    if contract_type == "DIGITUNDER":
        return digit < barrier
    raise ValueError(f"unsupported contract: {contract_type}")


def proposal_economics(proposal: dict[str, Any]) -> tuple[float, float, float]:
    ask, payout = float(proposal["ask_price"]), float(proposal["payout"])
    if ask <= 0 or payout <= 0:
        raise ValueError("proposal ask_price and payout must be positive")
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
                    currency=self.args.currency, random_seed=self.args.seed, mode=self.args.mode)
        (self.root / "metadata.json").write_text(json.dumps(data, indent=2), encoding="utf-8")

    def mark_gap(self, reason: str) -> None:
        self.clean_ticks = 0; self.pending.clear(); self.event(f"GAP DETECTED: {reason}")

    def ingest_tick(self, tick: dict[str, Any], gap=False) -> list[tuple[Hypothesis, dict[str, Any]]]:
        self.seq += 1
        pip = int(tick.get("pip_size", self.args.pip_size))
        digit = last_digit(tick["quote"], pip)
        if gap: self.mark_gap("tick sequence/connection discontinuity")
        self.ticks.append(dict(run_id=self.run_id, symbol=self.args.symbol, epoch=int(tick["epoch"]),
                               local_received_ts=utcnow(), quote=str(tick["quote"]), pip_size=pip,
                               last_digit=digit, tick_seq=self.seq, connection_id=self.connection_id, gap_flag=gap))
        self.digits.append(digit); self.clean_ticks += 1
        self._settle(int(tick["epoch"]), digit)
        if self.clean_ticks == 100: self.event("LOOKBACK REBUILD")
        if self.clean_ticks >= 100: return self._evaluate(int(tick["epoch"]), digit)
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


async def run_live(engine: ResearchEngine) -> None:
    import websockets
    deadline=time.monotonic()+engine.args.minutes*60
    while not engine.stop and time.monotonic() < deadline:
        try:
            engine.connection_id=uuid.uuid4().hex[:8]; engine.event(f"RECONNECT connection_id={engine.connection_id}")
            async with websockets.connect(f"wss://ws.derivws.com/websockets/v3?app_id={engine.args.app_id}") as ws:
                proposal_requests: dict[int, tuple[Hypothesis, dict[str, Any], int, float]] = {}
                request_id=0
                async def request_proposals(requests, epoch):
                    nonlocal request_id
                    for h,state in requests:
                        request_id += 1
                        proposal_requests[request_id]=(h,state,epoch,time.monotonic())
                        await ws.send(json.dumps({"proposal":1,"amount":engine.args.stake,"basis":"stake",
                            "contract_type":h.contract_type,"currency":engine.args.currency,"duration":1,
                            "duration_unit":"t","barrier":str(h.barrier),"symbol":engine.args.symbol,"req_id":request_id}))
                await ws.send(json.dumps({"ticks_history": engine.args.symbol, "count": engine.args.history,
                                          "end": "latest", "style": "ticks", "subscribe": 1}))
                async for raw in ws:
                    msg=json.loads(raw)
                    if "error" in msg: raise RuntimeError(msg["error"]["message"])
                    if "history" in msg:
                        pips=int(msg.get("pip_size", engine.args.pip_size))
                        for epoch, quote in zip(msg["history"]["times"], msg["history"]["prices"]):
                            # Seed history is persisted and builds state, but does not solicit retroactive proposals.
                            engine.ingest_tick({"epoch":epoch,"quote":quote,"pip_size":pips})
                    elif "tick" in msg:
                        tick=msg["tick"]; await request_proposals(engine.ingest_tick(tick),int(tick["epoch"]))
                    elif "proposal" in msg and msg.get("req_id") in proposal_requests:
                        h,state,epoch,sent=proposal_requests.pop(msg["req_id"])
                        proposal=dict(msg["proposal"]); proposal["latency_ms"]=(time.monotonic()-sent)*1000
                        engine.accept_proposal(h,state,proposal,epoch)
                    if engine.stop or time.monotonic() >= deadline: break
        except Exception as exc:
            engine.mark_gap(str(exc)); await asyncio.sleep(2)


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
