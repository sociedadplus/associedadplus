"""Opt-in, read-only integration smoke test for the current Deriv Options API.

Run with: RUN_DERIV_LIVE_TEST=1 python -m pytest -q -s tests/test_live_options_api.py
"""
import argparse, asyncio, json, os
import pytest
from sniper_digits_ou_research_v1 import (Hypothesis, PUBLIC_OPTIONS_WS, active_symbols_payload,
    available_contract_types, contracts_for_payload, find_active_symbol, history_payload,
    proposal_payload, raise_for_api_errors, ticks_payload)

pytestmark=pytest.mark.skipif(os.getenv("RUN_DERIV_LIVE_TEST")!="1",reason="manual public LIVE test")

async def request(ws,payload):
    await ws.send(json.dumps(payload))
    while True:
        msg=json.loads(await asyncio.wait_for(ws.recv(),20))
        if msg.get("req_id")==payload["req_id"]:
            raise_for_api_errors(msg); return msg

async def smoke():
    import websockets
    async with websockets.connect(PUBLIC_OPTIONS_WS) as ws:
        active=await request(ws,active_symbols_payload(1))
        assert find_active_symbol(active,"1HZ10V")
        contracts=await request(ws,contracts_for_payload("1HZ10V",2))
        assert {"DIGITOVER","DIGITUNDER"} <= available_contract_types(contracts)
        history=await request(ws,history_payload("1HZ10V",20,3))
        assert history["history"]["prices"]
        await ws.send(json.dumps(ticks_payload("1HZ10V",4)))
        while True:
            tick=json.loads(await asyncio.wait_for(ws.recv(),20))
            raise_for_api_errors(tick)
            if "tick" in tick: break
        args=argparse.Namespace(stake=1,currency="USD",symbol="1HZ10V")
        proposal=await request(ws,proposal_payload(args,Hypothesis("live","DIGITOVER",1),5))
        assert float(proposal["proposal"]["ask_price"])>0 and float(proposal["proposal"]["payout"])>0

def test_public_options_api_read_only_smoke(): asyncio.run(smoke())
