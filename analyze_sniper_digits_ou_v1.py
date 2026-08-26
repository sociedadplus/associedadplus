#!/usr/bin/env python3
"""Offline, read-only analyser for SNIPER-DIGITS result datasets."""
from __future__ import annotations
import argparse, csv, glob, math
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from sniper_digits_ou_research_v1 import max_streak, wilson

def load(patterns):
    rows=[]
    for pattern in patterns:
        for name in glob.glob(pattern):
            with open(name, encoding="utf-8") as f: rows.extend(csv.DictReader(f))
    return rows

def metric(rows):
    n=len(rows); w=sum(int(r["win"]) for r in rows); pl=sum(float(r["paper_pl"]) for r in rows)
    invested=sum(float(r["ask_price"]) for r in rows); be=sum(float(r["break_even"]) for r in rows)/n if n else 0
    lo,hi=wilson(w,n)
    return f"N={n} WIN={w} LOSS={n-w} WR={w/n if n else 0:.4f} Wilson95=[{lo:.4f},{hi:.4f}] mean_BE={be:.4f} WR-BE={(w/n-be) if n else 0:.4f} P/L={pl:.4f} ROI={pl/invested if invested else 0:.4f}"

def grouped(lines, rows, title, keys):
    lines += ["", title]
    groups=defaultdict(list)
    for r in rows: groups[tuple(r.get(k,"") for k in keys)].append(r)
    for key, group in sorted(groups.items()): lines.append(f"{key}: {metric(group)}")

def streak_distribution(rows):
    dist=Counter(); current=0
    for r in rows:
        if int(r["loss"]): current+=1
        elif current: dist[current]+=1; current=0
    if current: dist[current]+=1
    return dict(sorted(dist.items()))

def report(rows, hypothesis_count=0):
    lines=["SNIPER-DIGITS OOS REPORT", metric(rows)]
    for title, keys in (("BY CONTRACT",["contract_type"]),("BY BARRIER",["barrier"]),
                        ("BY HYPOTHESIS",["hypothesis_id"]),("BY STATE",["state_id"]),
                        ("BY HOUR UTC",["hour_utc"]),("BY LOOKBACK",["lookback"]),
                        ("BY SYMBOL",["symbol"]),("SNIPER VS CONTROL",["track","control_type"])):
        grouped(lines,rows,title,keys)
    lines += ["", "CALIBRATION"]
    buckets=defaultdict(list)
    for r in rows: buckets[math.floor(float(r["estimated_p"])*50)/50].append(r)
    for b,rs in sorted(buckets.items()): lines.append(f"estimated {b:.2f}-{b+.02:.2f}: observed={sum(int(r['win']) for r in rs)/len(rs):.4f} n={len(rs)}")
    ordered=sorted(rows,key=lambda r:(r.get("run_id",""),int(r.get("settlement_tick",0))))
    losses=[int(r.get("settlement_tick",0)) for r in ordered if int(r["loss"])]
    after_win=sum(int(ordered[i]["loss"]) and int(ordered[i-1]["win"]) for i in range(1,len(ordered)))
    after_loss=sum(int(ordered[i]["loss"]) and int(ordered[i-1]["loss"]) for i in range(1,len(ordered)))
    lines += ["", "LOSS ANALYSIS", f"max consecutive losses={max_streak(ordered,'loss')}",
              f"loss streak distribution={streak_distribution(ordered)}",
              f"ticks between losses={[b-a for a,b in zip(losses,losses[1:])]}",
              f"loss after win={after_win} loss after loss={after_loss}",
              "Episode position and antecedent state are available by state_id in the rows above."]
    alpha=.05; corrected=alpha/hypothesis_count if hypothesis_count else alpha
    lines += ["", "MULTIPLE TESTS", f"hypotheses searched={hypothesis_count}", f"Bonferroni alpha={corrected:.8f}",
              "OOS results are never used by this analyser to mutate or select rules."]
    return "\n".join(lines)+"\n"

def main(argv=None):
    p=argparse.ArgumentParser(); p.add_argument("--results", nargs="+", required=True)
    p.add_argument("--opportunities", nargs="*", default=[]); p.add_argument("--hypothesis-count",type=int,default=0)
    p.add_argument("--out-dir",default="."); args=p.parse_args(argv)
    rows=load(args.results); stamp=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out=Path(args.out_dir)/f"sniper_digits_report_{stamp}.txt"; out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(report(rows,args.hypothesis_count),encoding="utf-8"); print(out)
if __name__ == "__main__": main()
