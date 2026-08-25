import argparse, csv, json
from pathlib import Path
import pytest
from sniper_digits_ou_research_v1 import (Hypothesis, ResearchEngine, contract_wins, last_digit,
                                           proposal_economics, state_snapshot)
from analyze_sniper_digits_ou_v1 import report

def args(tmp_path, mode="discovery", hypotheses=None):
    return argparse.Namespace(symbol="1HZ10V",minutes=0,stake=1,currency="USD",history=5000,seed=7,
        out_dir=str(tmp_path),session_label="test",mode=mode,hypotheses=hypotheses,pip_size=2,app_id="1089")

@pytest.mark.parametrize("quote,pips,want",[("123.40",2,0),(123.4,2,0),("1.2340",4,0),("10",3,0),("1.209",3,9)])
def test_last_digit_preserves_display_precision(quote,pips,want): assert last_digit(quote,pips)==want

def test_contract_settlement_and_economics():
    assert contract_wins("DIGITOVER",3,4) and not contract_wins("DIGITOVER",3,3)
    assert contract_wins("DIGITUNDER",6,5) and not contract_wins("DIGITUNDER",6,6)
    assert proposal_economics({"ask_price":1,"payout":1.25})==(1,1.25,.8)

def test_gap_clears_pending_and_requires_rebuild(tmp_path):
    e=ResearchEngine(args(tmp_path)); e.pending=[{"settle_seq":2}]; e.clean_ticks=100
    e.mark_gap("test"); assert e.pending==[] and e.clean_ticks==0; e.close()

def test_discovery_never_fires_and_persists(tmp_path):
    e=ResearchEngine(args(tmp_path))
    for i in range(105): e.ingest_tick({"epoch":i,"quote":f"1.{i%10:02d}","pip_size":2})
    journal=e.opportunities.journal; e.close(); rows=[json.loads(x) for x in journal.read_text().splitlines()]
    assert rows and {r["decision"] for r in rows}=={"NO_FIRE"}

def test_oos_requires_frozen_rules(tmp_path):
    path=tmp_path/"h.json"; path.write_text(json.dumps([{"hypothesis_id":"h","contract_type":"DIGITOVER","barrier":1,"frozen":False}]))
    with pytest.raises(ValueError): ResearchEngine(args(tmp_path,"oos",str(path)))

def test_exact_next_tick_settlement_control_and_pl(tmp_path):
    path=tmp_path/"h.json"; path.write_text(json.dumps([{"hypothesis_id":"h","contract_type":"DIGITOVER","barrier":1,"min_edge":0}]))
    e=ResearchEngine(args(tmp_path,"oos",str(path)))
    for i in range(100): e.ingest_tick({"epoch":i,"quote":"1.29","pip_size":2})
    h=e.hypotheses[0]; state=state_snapshot(list(e.digits),e.seq)
    e.accept_proposal(h,state,{"id":"p1","ask_price":1,"payout":1.2},100)
    assert len(e.pending)==2 and {p["track"] for p in e.pending}=={"SNIPER","CONTROL"}
    e.ingest_tick({"epoch":101,"quote":"1.22","pip_size":2}); e.close()
    rows=list(csv.DictReader(e.results_path.open())); sniper=next(r for r in rows if r["track"]=="SNIPER")
    assert sniper["settlement_tick"]=="101" and sniper["win"]=="1" and float(sniper["paper_pl"])==pytest.approx(.2)

def test_analyser_sections():
    row={"win":"0","loss":"1","paper_pl":"-1","ask_price":"1","break_even":".8","estimated_p":".82",
         "contract_type":"DIGITOVER","barrier":"1","hypothesis_id":"h","state_id":"s","hour_utc":"1",
         "lookback":"100","symbol":"X","track":"SNIPER","control_type":"","run_id":"r","settlement_tick":"2"}
    text=report([row],1); assert "LOSS ANALYSIS" in text and "Bonferroni" in text and "CALIBRATION" in text
