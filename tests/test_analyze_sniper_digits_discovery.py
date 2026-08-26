import argparse, json
from pathlib import Path
from analyze_sniper_digits_discovery_v1 import (REPORT_SECTIONS, add_replication, adjust_pvalues, baseline,
    baseline_rows, contract_win, deduplicate, evaluate_candidates, frozen, load_runs, match_outcome,
    run_analysis, temporal_split, thresholds, wilson)

def tick(seq,digit,conn="a",gap=False,epoch=None):
    return {"tick_seq":seq,"epoch":seq if epoch is None else epoch,"last_digit":digit,"connection_id":conn,"gap_flag":gap}
def op(seq,state=None): return {"epoch":seq,"state":state or {"tick_seq":seq,"count_0_1_2":30,"entropy":3.2}}
def matched(ticks,seq=1,h=1):
    by={t["tick_seq"]:t for t in ticks};return match_outcome(op(seq),by,set(),h)

def test_t1_outcome(): assert matched([tick(1,1),tick(2,7)])==(7,None)
def test_contract_semantics(): assert contract_win("DIGITOVER",2,3) and contract_win("DIGITUNDER",7,6)
def test_gap_dropped(): assert matched([tick(1,1),tick(2,7,gap=True)])[1]=="DROP_GAP"
def test_reconnect_dropped(): assert matched([tick(1,1),tick(2,7,"b")])[1]=="DROP_RECONNECT"
def test_history_rebuild_not_settlement():
    ticks=[tick(1,1,epoch=9),tick(2,7,epoch=8)];by={t["tick_seq"]:t for t in ticks}
    assert match_outcome({"epoch":9,"state":{"tick_seq":1}},by,set(),1)[1]=="DROP_HISTORY_REBUILD"
def test_temporal_split_no_shuffle():
    a,b=temporal_split([{"epoch":i,"tick_seq":i} for i in reversed(range(10))],.6);assert [r["epoch"] for r in a]==list(range(6)) and len(b)==4
def test_baselines():
    assert baseline("DIGITOVER",0)==.9 and baseline("DIGITOVER",3)==.6
    assert baseline("DIGITUNDER",6)==.6 and baseline("DIGITUNDER",9)==.9
def test_wilson():
    lo,hi=wilson(80,100);assert .70<lo<.73 and .86<hi<.89
def test_multiple_testing():
    bon,fdr=adjust_pvalues([.01,.02,.5]);assert bon==[.03,.06,1] and fdr[0]<=fdr[1]<=fdr[2]
def test_threshold_search_controlled():
    found=thresholds("streak_low_digits",list(range(1,101)));assert (">=",2) in found and len(found)<20

def rows(effect_confirm=True,symbol="A"):
    out=[]
    for i in range(300):
        active=i%2==0; train=i<180; win=active and (train or effect_confirm)
        out.append({"symbol":symbol,"run_id":"r","epoch":i,"tick_seq":i,"horizon":1,
                    "settlement_digit":9 if win else 0,"state":{"count_0_1_2":40 if active else 10}})
    return out
def test_train_only_rule_rejected():
    candidates,_=evaluate_candidates(rows(False),.6,50,40,100)
    target=[r for r in candidates if r["contract_type"]=="DIGITOVER" and r["operator_1"]==">="]
    assert target and all(r["classification"]=="REJECT" for r in target)
def test_confirmed_rule_survives():
    candidates,_=evaluate_candidates(rows(True),.6,50,40,100);assert any(r["classification"]!="REJECT" for r in candidates)
def candidate(symbol):return {"symbol":symbol,"contract_type":"DIGITOVER","barrier":2,"feature_1":"entropy","operator_1":"<=","classification":"PROMISING","score":1}
def test_replication_two_symbols():
    data=[candidate("A"),candidate("B")];add_replication(data);assert {r["replication_category"] for r in data}=={"REPLICATED_2_SYMBOLS"}
def test_replication_three_symbols():
    data=[candidate(x) for x in "ABC"];add_replication(data);assert all(r["symbols_replicated"]==3 for r in data)
def test_rule_deduplication():
    a=candidate("A");b={**a,"score":2};assert deduplicate([a,b])==[b]
def test_frozen_candidate_valid():
    r={**candidate("A"),"candidate_id":"x","threshold_1":3,"N_train":100,"WR_train":.8,"N_confirm":80,"WR_confirm":.79,"symbols_replicated":2}
    result=frozen([r],[])[0];assert result["frozen"] is True and result["engine_compatible"] is False and result["rule"]["conditions"]

def make_run(root,mode="discovery",empty=False):
    run=root/"A"/"sniper_digits_v1"/"run_r";run.mkdir(parents=True)
    (run/"metadata.json").write_text(json.dumps({"run_id":"r","symbol":"A","mode":mode,"engine_version":"1","protocol_version":"p","pip_digits":2}))
    ticks=[tick(i,i%10) for i in range(1,8)];ops=[] if empty else [op(i) for i in range(1,7)]
    (run/"ticks.parquet.jsonl").write_text("\n".join(json.dumps(x) for x in ticks));(run/"opportunities.parquet.jsonl").write_text("\n".join(json.dumps(x) for x in ops));return run
def test_input_files_unchanged(tmp_path):
    run=make_run(tmp_path);before={p:p.read_bytes() for p in run.iterdir()};load_runs(tmp_path,[],[1]);assert all(p.read_bytes()==v for p,v in before.items())
def test_non_discovery_ignored(tmp_path):
    make_run(tmp_path,"oos");loaded=load_runs(tmp_path,[],[1]);assert loaded.outcomes==[] and loaded.integrity[0]["reason"]=="NOT_DISCOVERY"
def test_empty_run_ignored(tmp_path):
    make_run(tmp_path,empty=True);loaded=load_runs(tmp_path,[],[1]);assert not loaded.outcomes and loaded.integrity[0]["reason"]=="NO_OPPORTUNITIES"
def test_report_and_outputs(tmp_path):
    make_run(tmp_path);args=argparse.Namespace(data_root=str(tmp_path),symbols=[],out_dir=str(tmp_path/"analysis"),min_train=1,min_confirm=1,train_fraction=.6,horizons=[1],max_rules=20,seed=1)
    out=run_analysis(args);text=(out/"discovery_report.txt").read_text();assert all(section in text for section in REPORT_SECTIONS)
    assert {"all_candidates.csv","shortlist.csv","frozen_hypotheses_candidates.json","run_integrity.csv","dropped_outcomes.csv","symbol_summary.csv"}<={p.name for p in out.iterdir()}
