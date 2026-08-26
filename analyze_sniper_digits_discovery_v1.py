#!/usr/bin/env python3
"""Read-only exploratory analyser for SNIPER-DIGITS discovery datasets."""
from __future__ import annotations
import argparse, csv, hashlib, json, math, statistics
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

CONTRACTS = [("DIGITOVER", b, (9-b)/10) for b in range(4)] + [("DIGITUNDER", b, b/10) for b in range(6,10)]
DROP_REASONS = ("DROP_GAP","DROP_RECONNECT","DROP_MISSING_NEXT_TICK","DROP_HISTORY_REBUILD","DROP_DUPLICATE","DROP_INVALID_STATE")
REPORT_SECTIONS = ("DATA INTEGRITY","BASELINE RESULTS","TRAIN/CONFIRM","MULTIPLE TESTING","TOP CANDIDATES",
                   "CROSS-SYMBOL REPLICATION","TEMPORAL STABILITY","LOSS-STREAK ANALYSIS","SHORTLIST",
                   "OOS RECOMMENDATIONS","LIMITATIONS")
CANDIDATE_FIELDS = ["candidate_id","symbol","contract_type","barrier","feature_1","operator_1","threshold_1",
 "feature_2","operator_2","threshold_2","strict_symbols_replicated","strict_replication_category",
 "family_symbols_replicated","family_replication_category","N_train","WR_train",
 "edge_train","N_confirm","WR_confirm","edge_confirm","Wilson_confirm_low","conservative_edge_confirm",
 "p_raw","p_bonferroni","p_fdr","temporal_stability","max_loss_streak","max_win_streak","loss_streak_distribution",
 "score","classification","block_stats"]

def read_jsonl(path: Path) -> list[dict[str,Any]]:
    if not path.exists(): return []
    rows=[]
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            try: rows.append(json.loads(line))
            except json.JSONDecodeError: continue
    return rows

def read_table(run: Path, stem: str) -> list[dict[str,Any]]:
    journal=run/f"{stem}.parquet.jsonl"
    if journal.exists(): return read_jsonl(journal)
    parquet=run/f"{stem}.parquet"
    if parquet.exists():
        try:
            import pyarrow.parquet as pq
            return pq.read_table(parquet).to_pylist()
        except ImportError: return []
    return []

def wilson(wins:int,n:int,z:float=1.96)->tuple[float,float]:
    if not n:return 0.,0.
    p=wins/n; d=1+z*z/n; c=(p+z*z/(2*n))/d; m=z*math.sqrt((p*(1-p)+z*z/(4*n))/n)/d
    return c-m,c+m

def contract_win(kind:str,barrier:int,digit:int)->bool:
    return digit>barrier if kind=="DIGITOVER" else digit<barrier

def baseline(kind:str,barrier:int)->float:
    return (9-barrier)/10 if kind=="DIGITOVER" else barrier/10

def binomial_p(wins:int,n:int,p0:float)->float:
    if not n:return 1.
    variance=n*p0*(1-p0)
    if not variance:return 1.
    z=(wins-n*p0)/math.sqrt(variance)
    return .5*math.erfc(z/math.sqrt(2))

def adjust_pvalues(values:list[float])->tuple[list[float],list[float]]:
    m=len(values)
    bon=[min(1.,p*m) for p in values]
    order=sorted(range(m),key=values.__getitem__); fdr=[1.]*m; running=1.
    for rank,i in reversed(list(enumerate(order,1))):
        running=min(running,values[i]*m/rank); fdr[i]=min(1.,running)
    return bon,fdr

def temporal_split(rows:list[dict[str,Any]],fraction:float)->tuple[list[dict[str,Any]],list[dict[str,Any]]]:
    ordered=sorted(rows,key=lambda r:(r.get("epoch",0),r.get("tick_seq",0)))
    cut=int(len(ordered)*fraction)
    return ordered[:cut],ordered[cut:]

def streaks(results:list[bool])->tuple[int,int,dict[int,int]]:
    max_l=max_w=lc=wc=0; dist=Counter()
    for won in results:
        if won:
            if lc:dist[lc]+=1
            lc=0;wc+=1;max_w=max(max_w,wc)
        else: wc=0;lc+=1;max_l=max(max_l,lc)
    if lc:dist[lc]+=1
    return max_l,max_w,dict(sorted(dist.items()))

def segmented_streaks(rows:list[dict[str,Any]],kind:str,barrier_:int)->tuple[int,int,dict[int,int]]:
    """Compute streaks independently inside each clean run/connection segment."""
    grouped=defaultdict(list)
    for row in rows:grouped[(row["run_id"],row.get("connection_id",""),row.get("segment_id",row["run_id"]))].append(row)
    max_l=max_w=0;distribution=Counter()
    for group in grouped.values():
        ordered=sorted(group,key=lambda r:(r["epoch"],r["tick_seq"]))
        ml,mw,dist=streaks([contract_win(kind,barrier_,r["settlement_digit"]) for r in ordered])
        max_l=max(max_l,ml);max_w=max(max_w,mw);distribution.update(dist)
    return max_l,max_w,dict(sorted(distribution.items()))

def match_outcome(op:dict[str,Any], ticks_by_seq:dict[int,dict[str,Any]], duplicate_epochs:set, horizon:int=1):
    state=op.get("state")
    if not isinstance(state,dict) or "tick_seq" not in state:return None,"DROP_INVALID_STATE"
    seq=int(state["tick_seq"]); current=ticks_by_seq.get(seq)
    if current is None:return None,"DROP_MISSING_NEXT_TICK"
    if int(current.get("epoch",-1))!=int(op.get("epoch",-2)):return None,"DROP_INVALID_STATE"
    if (current.get("connection_id"),int(current["epoch"])) in duplicate_epochs:return None,"DROP_DUPLICATE"
    chain=[]
    for offset in range(1,horizon+1):
        tick=ticks_by_seq.get(seq+offset)
        if tick is None:return None,"DROP_MISSING_NEXT_TICK"
        chain.append(tick)
    if any(bool(t.get("gap_flag")) for t in [current,*chain]):return None,"DROP_GAP"
    if any(t.get("connection_id")!=current.get("connection_id") for t in chain):return None,"DROP_RECONNECT"
    epochs=[int(t["epoch"]) for t in [current,*chain]]
    if any(b<=a for a,b in zip(epochs,epochs[1:])):
        return None,"DROP_HISTORY_REBUILD"
    if any((t.get("connection_id"),int(t["epoch"])) in duplicate_epochs for t in chain):return None,"DROP_DUPLICATE"
    return int(chain[-1]["last_digit"]),None

@dataclass
class Loaded:
    outcomes:list[dict[str,Any]]; integrity:list[dict[str,Any]]; drops:Counter; drop_records:list[dict[str,Any]]; ticks:int; opportunities:int

def load_runs(root:Path,symbols:list[str],horizons:list[int],run_ids:list[str]|None=None,session_labels:list[str]|None=None)->Loaded:
    outcomes=[]; integrity=[]; drops=Counter(); drop_records=[]; total_ticks=total_ops=0
    for run in sorted(root.glob("*/sniper_digits_v1/run_*")):
        if symbols and run.parts[-3] not in symbols:continue
        status="USED"; reason=""
        try: meta=json.loads((run/"metadata.json").read_text(encoding="utf-8"))
        except Exception: meta={};status="DROPPED";reason="INVALID_METADATA"
        ticks=read_table(run,"ticks") if status=="USED" else []; ops=read_table(run,"opportunities") if status=="USED" else []
        required=("run_id","symbol","mode","engine_version","protocol_version","pip_digits")
        if status=="USED" and run_ids and meta.get("run_id") not in run_ids:status="DROPPED";reason="FILTERED_RUN_ID"
        elif status=="USED" and session_labels and meta.get("session_label") not in session_labels:status="DROPPED";reason="FILTERED_SESSION_LABEL"
        elif status=="USED" and any(meta.get(k) is None for k in required):status="DROPPED";reason="INCOMPATIBLE_METADATA"
        elif status=="USED" and meta.get("symbol")!=run.parts[-3]:status="DROPPED";reason="SYMBOL_PATH_MISMATCH"
        elif status=="USED" and meta.get("mode")!="discovery":status="DROPPED";reason="NOT_DISCOVERY"
        elif status=="USED" and not ticks:status="DROPPED";reason="NO_TICKS"
        elif status=="USED" and not ops:status="DROPPED";reason="NO_OPPORTUNITIES"
        fields=("run_id","symbol","mode","engine_version","protocol_version","git_hash","start_time","end_time","session_label","pip_digits")
        row={k:meta.get(k) for k in fields};row.update(path=str(run),status=status,reason=reason,ticks=len(ticks),opportunities=len(ops));integrity.append(row)
        if status!="USED":continue
        total_ticks+=len(ticks);total_ops+=len(ops)
        seq_counts=Counter(int(t["tick_seq"]) for t in ticks)
        by_seq={int(t["tick_seq"]):t for t in ticks}
        segment_by_seq={};segment=0;previous=None
        for t in sorted(ticks,key=lambda x:int(x["tick_seq"])):
            discontinuous=(previous is None or int(t["tick_seq"])!=int(previous["tick_seq"])+1 or
                t.get("connection_id")!=previous.get("connection_id") or bool(t.get("gap_flag")) or
                int(t["epoch"])<=int(previous["epoch"]))
            if discontinuous:segment+=1
            segment_by_seq[int(t["tick_seq"])]=f'{meta.get("run_id")}:{t.get("connection_id")}:{segment}'
            previous=t
        epoch_counts=Counter((t.get("connection_id"),int(t["epoch"])) for t in ticks)
        duplicates={key for key,n in epoch_counts.items() if n>1}
        duplicate_seqs={seq for seq,n in seq_counts.items() if n>1}
        for op in ops:
            for horizon in horizons:
                op_seq=op.get("state",{}).get("tick_seq")
                if op_seq is not None and int(op_seq) in duplicate_seqs:
                    drop="DROP_DUPLICATE";digit=None
                else:
                    digit,drop=match_outcome(op,by_seq,duplicates,horizon)
                if drop:
                    drops[drop]+=1;drop_records.append({"run_id":meta["run_id"],"symbol":meta["symbol"],
                        "epoch":op.get("epoch"),"tick_seq":op.get("state",{}).get("tick_seq"),"horizon":horizon,"reason":drop});continue
                state=op["state"]
                outcomes.append(dict(run_id=meta["run_id"],symbol=meta["symbol"],epoch=int(op["epoch"]),
                    tick_seq=int(state["tick_seq"]),horizon=horizon,settlement_digit=digit,state=state,
                    connection_id=by_seq[int(state["tick_seq"])].get("connection_id"),
                    segment_id=segment_by_seq[int(state["tick_seq"])]))
    return Loaded(outcomes,integrity,drops,drop_records,total_ticks,total_ops)

def numeric_features(rows:list[dict[str,Any]])->list[str]:
    excluded={"tick_seq","state_id"}; found=set()
    for r in rows[:1000]:
        for k,v in r["state"].items():
            if k not in excluded and not k.startswith("digit_") and isinstance(v,(int,float)) and not isinstance(v,bool):found.add(k)
    return sorted(found)

def thresholds(feature:str,values:list[float])->list[tuple[str,float]]:
    values=sorted(values); result=set()
    if not values:return []
    for q in (.05,.1,.2,.3,.7,.8,.9,.95):
        value=values[min(len(values)-1,int((len(values)-1)*q))];result.add((">=" if q>=.5 else "<=",value))
    if feature.startswith("streak_"):
        result.update((">=",x) for x in (2,3,4,5,6))
    if feature.startswith("ticks_since_"):
        result.update((">=",x) for x in (10,20,30,50,75,100))
    return sorted(result,key=lambda x:(x[0],x[1]))

def applies(row:dict[str,Any],feature:str,operator:str,threshold:float)->bool:
    value=row["state"].get(feature)
    if not isinstance(value,(int,float)):return False
    return value>=threshold if operator==">=" else value<=threshold

def rule_applies(row:dict[str,Any],conditions:list[tuple[str,str,float]])->bool:
    return all(applies(row,*condition) for condition in conditions)

def block_statistics(rows:list[dict[str,Any]],kind:str,barrier_:int)->tuple[list[dict[str,Any]],float]:
    blocks=[]; signs=[]; base=baseline(kind,barrier_)
    by_run=defaultdict(list)
    for row in rows:by_run[row["run_id"]].append(row)
    for run_id,run_rows in sorted(by_run.items()):
      ordered=sorted(run_rows,key=lambda r:(r["epoch"],r["tick_seq"]))
      for i in range(4):
        part=ordered[i*len(ordered)//4:(i+1)*len(ordered)//4]; w=sum(contract_win(kind,barrier_,r["settlement_digit"]) for r in part)
        wr=w/len(part) if part else 0;blocks.append({"run_id":run_id,"block":i+1,"n":len(part),"wr":wr,"baseline":base,"edge":wr-base})
        if part:signs.append(wr>base)
    return blocks,sum(signs)/len(signs) if signs else 0

def evaluate_candidates(rows:list[dict[str,Any]],train_fraction=.6,min_train=100,min_confirm=75,max_rules=5000,max_pairs=200):
    results=[]; tested=0
    by_symbol=defaultdict(list)
    for r in rows:
        if r["horizon"]==1:by_symbol[r["symbol"]].append(r)
    for symbol,symbol_rows in by_symbol.items():
        symbol_tested=0
        train,confirm=temporal_split(symbol_rows,train_fraction)
        for feature in numeric_features(symbol_rows):
            vals=[float(r["state"][feature]) for r in train if isinstance(r["state"].get(feature),(int,float))]
            for operator,threshold in thresholds(feature,vals):
                for kind,b,base in CONTRACTS:
                    if symbol_tested>=max_rules:break
                    tested+=1;symbol_tested+=1
                    tr=[r for r in train if applies(r,feature,operator,threshold)];co=[r for r in confirm if applies(r,feature,operator,threshold)]
                    wt=sum(contract_win(kind,b,r["settlement_digit"]) for r in tr);wc=sum(contract_win(kind,b,r["settlement_digit"]) for r in co)
                    wrt=wt/len(tr) if tr else 0;wrc=wc/len(co) if co else 0;lo,_=wilson(wc,len(co)); blocks,stability=block_statistics(co,kind,b)
                    ml,mw,dist=segmented_streaks(co,kind,b)
                    valid=len(tr)>=min_train and len(co)>=min_confirm and wrt>base and wrc>base
                    classification="REJECT" if not valid else ("STRONG_DISCOVERY_CANDIDATE" if lo>=base and stability>=.75 else "PROMISING")
                    cid=hashlib.sha256(f"{symbol}|{kind}|{b}|{feature}|{operator}|{threshold}".encode()).hexdigest()[:16]
                    results.append(dict(candidate_id=cid,symbol=symbol,contract_type=kind,barrier=b,feature_1=feature,
                        operator_1=operator,threshold_1=threshold,feature_2="",operator_2="",threshold_2="",
                        strict_symbols_replicated=1,strict_replication_category="SINGLE_SYMBOL",
                        family_symbols_replicated=1,family_replication_category="SINGLE_SYMBOL",N_train=len(tr),WR_train=wrt,
                        edge_train=wrt-base,N_confirm=len(co),WR_confirm=wrc,edge_confirm=wrc-base,
                        Wilson_confirm_low=lo,conservative_edge_confirm=lo-base,p_raw=binomial_p(wc,len(co),base),
                        p_bonferroni=1.,p_fdr=1.,temporal_stability=stability,max_loss_streak=ml,max_win_streak=mw,
                        loss_streak_distribution=json.dumps(dist),score=0.,classification=classification,block_stats=json.dumps(blocks)))
                if symbol_tested>=max_rules:break
            if symbol_tested>=max_rules:break
        # Only strong TRAIN simple rules seed the bounded pair search. CONFIRM is untouched until evaluation.
        simple=[r for r in results if r["symbol"]==symbol and not r["feature_2"] and r["N_train"]>=min_train and r["edge_train"]>0]
        simple_groups=defaultdict(list)
        for rule in simple:simple_groups[(rule["contract_type"],rule["barrier"])].append(rule)
        simple=[]
        for group in simple_groups.values():simple.extend(sorted(group,key=lambda r:r["edge_train"]*math.sqrt(r["N_train"]),reverse=True)[:12])
        pair_counts=Counter();pair_budget=max(1,max_pairs//max(1,len(simple_groups)));seen=set()
        for i,left in enumerate(simple):
          for right in simple[i+1:]:
            contract_key=(left["contract_type"],left["barrier"])
            if contract_key!=(right["contract_type"],right["barrier"]):continue
            if pair_counts[contract_key]>=pair_budget:continue
            if feature_family(left["feature_1"])==feature_family(right["feature_1"]):continue
            ordered_conditions=sorted([(left["feature_1"],left["operator_1"],left["threshold_1"]),(right["feature_1"],right["operator_1"],right["threshold_1"])])
            first,second=ordered_conditions
            key=(left["contract_type"],left["barrier"],*first,*second)
            if key in seen:continue
            seen.add(key);pair_counts[contract_key]+=1;tested+=1
            conditions=ordered_conditions
            tr=[r for r in train if rule_applies(r,conditions)];co=[r for r in confirm if rule_applies(r,conditions)]
            kind=left["contract_type"];b=left["barrier"];base=baseline(kind,b)
            wt=sum(contract_win(kind,b,r["settlement_digit"]) for r in tr);wc=sum(contract_win(kind,b,r["settlement_digit"]) for r in co)
            wrt=wt/len(tr) if tr else 0;wrc=wc/len(co) if co else 0;lo,_=wilson(wc,len(co));blocks,stability=block_statistics(co,kind,b);ml,mw,dist=segmented_streaks(co,kind,b)
            valid=len(tr)>=min_train and len(co)>=min_confirm and wrt>base and wrc>base
            classification="REJECT" if not valid else ("STRONG_DISCOVERY_CANDIDATE" if lo>=base and stability>=.75 else "PROMISING")
            cid=hashlib.sha256(f"{symbol}|{key}".encode()).hexdigest()[:16]
            results.append(dict(candidate_id=cid,symbol=symbol,contract_type=kind,barrier=b,feature_1=first[0],operator_1=first[1],threshold_1=first[2],
              feature_2=second[0],operator_2=second[1],threshold_2=second[2],strict_symbols_replicated=1,strict_replication_category="SINGLE_SYMBOL",
              family_symbols_replicated=1,family_replication_category="SINGLE_SYMBOL",N_train=len(tr),WR_train=wrt,edge_train=wrt-base,N_confirm=len(co),WR_confirm=wrc,edge_confirm=wrc-base,
              Wilson_confirm_low=lo,conservative_edge_confirm=lo-base,p_raw=binomial_p(wc,len(co),base),p_bonferroni=1.,p_fdr=1.,temporal_stability=stability,
              max_loss_streak=ml,max_win_streak=mw,loss_streak_distribution=json.dumps(dist),score=0.,classification=classification,block_stats=json.dumps(blocks)))
    bon,fdr=adjust_pvalues([r["p_raw"] for r in results])
    for r,pb,pf in zip(results,bon,fdr):r["p_bonferroni"]=pb;r["p_fdr"]=pf
    add_replication(results)
    for r in results:
        rep=max(r["strict_symbols_replicated"],r["family_symbols_replicated"]); r["score"]=r["conservative_edge_confirm"]*math.log1p(r["N_confirm"])*r["temporal_stability"]*(1+.25*(rep-1))
    return sorted(results,key=lambda r:r["score"],reverse=True),tested

def feature_family(feature):
    if feature in {"count_0_1","count_0_1_2","freq_0","freq_1","freq_2"}:return "LOW_DIGIT_CONCENTRATION"
    if feature in {"count_7_8_9","freq_7","freq_8","freq_9"}:return "HIGH_DIGIT_CONCENTRATION"
    if feature in {"entropy","chi_square_uniformity","max_digit_frequency","min_digit_frequency"}:return "DISTRIBUTION_CONCENTRATION"
    if feature.startswith("ticks_since_digit_"):return "DIGIT_ABSENCE"
    return feature
def concept(row):
    second=(feature_family(row["feature_2"]),row["operator_2"]) if row.get("feature_2") else ("","")
    return row["contract_type"],row["barrier"],feature_family(row["feature_1"]),row["operator_1"],*second
def thresholds_close(a,b):
    scale=max(abs(float(a)),abs(float(b)),1.);return abs(float(a)-float(b))/scale<=.10
def strict_match(a,b):
    return (a["contract_type"],a["barrier"],a["feature_1"],a["operator_1"],a.get("feature_2",""),a.get("operator_2","")) == (b["contract_type"],b["barrier"],b["feature_1"],b["operator_1"],b.get("feature_2",""),b.get("operator_2","")) and thresholds_close(a["threshold_1"],b["threshold_1"]) and (not a.get("feature_2") or thresholds_close(a["threshold_2"],b["threshold_2"]))
def add_replication(rows):
    accepted=[r for r in rows if r["classification"]!="REJECT"]
    family_groups=defaultdict(set)
    for r in accepted:family_groups[concept(r)].add(r["symbol"])
    for r in rows:
        strict_symbols={other["symbol"] for other in accepted if strict_match(r,other)} or {r["symbol"]}
        family_symbols=family_groups.get(concept(r),{r["symbol"]})
        sn=len(strict_symbols);fn=len(family_symbols)
        r["strict_symbols_replicated"]=sn;r["strict_replication_category"]={1:"SINGLE_SYMBOL",2:"STRICT_REPLICATION_2_SYMBOLS"}.get(sn,"STRICT_REPLICATION_3_SYMBOLS")
        r["family_symbols_replicated"]=fn;r["family_replication_category"]={1:"SINGLE_SYMBOL",2:"FAMILY_REPLICATION_2_SYMBOLS"}.get(fn,"FAMILY_REPLICATION_3_SYMBOLS")

def deduplicate(rows):
    best={}
    for r in rows:
        key=(r["symbol"],*concept(r));
        if key not in best or r["score"]>best[key]["score"]:best[key]=r
    return sorted(best.values(),key=lambda r:r["score"],reverse=True)

def write_csv(path:Path,rows:list[dict[str,Any]],fields=None):
    fields=fields or sorted({k for r in rows for k in r})
    with path.open("w",newline="",encoding="utf-8") as f:
        w=csv.DictWriter(f,fieldnames=fields,extrasaction="ignore");w.writeheader();w.writerows(rows)

def frozen(shortlist,integrity):
    origins=[{k:r.get(k) for k in ("run_id","symbol","engine_version","protocol_version","git_hash")} for r in integrity if r["status"]=="USED"]
    return [{"hypothesis_id":f'discovery_{r["candidate_id"]}',"symbol":r["symbol"],"contract_type":r["contract_type"],
      "barrier":r["barrier"],"lookback":100,"rule":{"conditions":[{"feature":r["feature_1"],"operator":r["operator_1"],"threshold":r["threshold_1"]}]+([{"feature":r["feature_2"],"operator":r["operator_2"],"threshold":r["threshold_2"]}] if r.get("feature_2") else [])},
      "delay":0,"min_edge":0.02,"frozen":True,"candidate_rank":i+1,"train_stats":{"n":r["N_train"],"wr":r["WR_train"]},
      "confirm_stats":{"n":r["N_confirm"],"wr":r["WR_confirm"]},"strict_symbols_replicated":r["strict_symbols_replicated"],"family_symbols_replicated":r["family_symbols_replicated"],
      "discovery_origins":origins,"engine_compatible":False} for i,r in enumerate(shortlist)]

def baseline_rows(outcomes):
    rows=[]
    for symbol in sorted({r["symbol"] for r in outcomes}):
      data=[r for r in outcomes if r["symbol"]==symbol and r["horizon"]==1]
      for kind,b,base in CONTRACTS:
        w=sum(contract_win(kind,b,r["settlement_digit"]) for r in data);lo,hi=wilson(w,len(data));wr=w/len(data) if data else 0
        rows.append(dict(symbol=symbol,contract_type=kind,barrier=b,N=len(data),wins=w,losses=len(data)-w,WR=wr,
                         wilson95_low=lo,wilson95_high=hi,baseline=base,edge=wr-base,lift_relative=(wr-base)/base))
    return rows

def report_text(loaded,candidates,shortlist,tested,summaries):
    used=[r for r in loaded.integrity if r["status"]=="USED"]; symbols=sorted({r["symbol"] for r in used}); valid=sum(r["horizon"]==1 for r in loaded.outcomes)
    replicated2=sum(r["strict_symbols_replicated"]==2 for r in shortlist);replicated3=sum(r["strict_symbols_replicated"]>=3 for r in shortlist)
    lines=["SNIPER-DIGITS DISCOVERY REPORT","EXECUTIVE SUMMARY",
      f"runs_found={len(loaded.integrity)} runs_valid={len(used)} symbols={','.join(symbols)} ticks={loaded.ticks} opportunities={loaded.opportunities}",
      f"valid_primary_outcomes={valid} drops_gap={loaded.drops['DROP_GAP']} drops_reconnect={loaded.drops['DROP_RECONNECT']}",
      f"hypotheses_tested={tested} shortlist={len(shortlist)} replicated_2={replicated2} replicated_3={replicated3}"]
    for section in REPORT_SECTIONS:
      lines += ["",section]
      if section=="DATA INTEGRITY":lines += [json.dumps(r,sort_keys=True) for r in loaded.integrity]+[f"drops={dict(loaded.drops)}"]
      elif section=="BASELINE RESULTS":lines += [json.dumps(r,sort_keys=True) for r in summaries]
      elif section=="MULTIPLE TESTING":lines += [f"tests={tested}; p_raw, Bonferroni and Benjamini-Hochberg FDR are reported per candidate."]
      elif section in ("TOP CANDIDATES","TRAIN/CONFIRM"):lines += [json.dumps(r,sort_keys=True) for r in candidates[:10]]
      elif section=="SHORTLIST":lines += [json.dumps(r,sort_keys=True) for r in shortlist]
      elif section=="OOS RECOMMENDATIONS":lines += ["Human review is required. The current engine cannot consume generic rule.conditions; add a frozen rule evaluator before OOS."]
      elif section=="LIMITATIONS":lines += ["Discovery is exploratory, has no proposal economics, and is neither profitable nor OOS-validated. Normal-approximation p-values are screening statistics."]
      if section=="TOP CANDIDATES":lines += ["score = conservative_edge_confirm * ln(1 + N_confirm) * temporal_stability * (1 + 0.25 * (max strict/family symbols - 1)). STRICT and FAMILY replication are reported separately."]
    return "\n".join(lines)+"\n"

def run_analysis(args):
    loaded=load_runs(Path(args.data_root),args.symbols,args.horizons,getattr(args,"run_ids",None),getattr(args,"session_labels",None)); candidates,tested=evaluate_candidates(loaded.outcomes,args.train_fraction,args.min_train,args.min_confirm,args.max_rules,getattr(args,"max_pairs",200))
    candidates=deduplicate(candidates); shortlist=[r for r in candidates if r["classification"]!="REJECT"]
    stamp=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ");out=Path(args.out_dir).parent/f"{Path(args.out_dir).name}_{stamp}";out.mkdir(parents=True)
    summaries=baseline_rows(loaded.outcomes);write_csv(out/"all_candidates.csv",candidates,CANDIDATE_FIELDS);write_csv(out/"shortlist.csv",shortlist,CANDIDATE_FIELDS)
    write_csv(out/"run_integrity.csv",loaded.integrity);write_csv(out/"dropped_outcomes.csv",loaded.drop_records,
        ["run_id","symbol","epoch","tick_seq","horizon","reason"])
    write_csv(out/"symbol_summary.csv",summaries);write_csv(out/"feature_threshold_results.csv",candidates,CANDIDATE_FIELDS)
    (out/"frozen_hypotheses_candidates.json").write_text(json.dumps(frozen(shortlist,loaded.integrity),indent=2),encoding="utf-8")
    (out/"discovery_report.txt").write_text(report_text(loaded,candidates,shortlist,tested,summaries),encoding="utf-8");return out

def parse_args(argv=None):
    p=argparse.ArgumentParser();p.add_argument("--data-root",default="data/digits_over_under");p.add_argument("--symbols",nargs="*",default=[])
    p.add_argument("--run-ids",nargs="*",default=[]);p.add_argument("--session-labels",nargs="*",default=[])
    p.add_argument("--out-dir",default="analysis_digits_discovery");p.add_argument("--min-train",type=int,default=100);p.add_argument("--min-confirm",type=int,default=75)
    p.add_argument("--train-fraction",type=float,default=.6);p.add_argument("--horizons",nargs="+",type=int,default=[1]);p.add_argument("--max-rules",type=int,default=5000);p.add_argument("--max-pairs",type=int,default=200);p.add_argument("--seed",type=int,default=1)
    args=p.parse_args(argv); 
    if not 0<args.train_fraction<1 or any(h not in (1,2,3) for h in args.horizons):p.error("invalid split or horizon")
    return args
def main(argv=None):print(run_analysis(parse_args(argv)))
if __name__=="__main__":main()
