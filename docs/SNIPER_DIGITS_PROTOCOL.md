# SNIPER-DIGITS protocol v1

## Architecture and scientific protocol

The collector is passive and single-symbol. `discovery` records tick-time states but never fires; it exports candidate evidence for an external, offline selection process. `oos` refuses to start without a JSON file of explicitly frozen hypotheses. Changing any rule, threshold, lookback, contract, barrier, delay, or minimum margin requires a new hypothesis ID and a new OOS run. The analyser is read-only and never writes rules.

The live transport uses only public tick history/tick subscriptions and proposal requests. There is no account credential or execution path. A proposal supplies the actual ask and payout; break-even is `ask_price / payout`, edge is `estimated_p - break_even`, and PAPER EV is `estimated_p * payout - ask_price`.

Settlement is by exact tick sequence: for a one-tick contract the next received clean tick is the settlement tick. A gap cancels unresolved shots and resets the clean lookback. Delayed tracks are labelled counterfactual; only delay zero on `SNIPER` is the primary prospective observation. Matched controls preserve contract, barrier, state economics, and temporal neighbourhood.

## Files

Each run is under `data/digits_over_under/<symbol>/sniper_digits_v1/run_<run_id>/`:

* `metadata.json`: versions, run/session identity, timestamps, complete CLI, Git/Python/websockets versions, lookbacks, hypotheses/frozen rules, families, stake/currency, seed and mode.
* `ticks.parquet.jsonl` (incremental authority) and, when PyArrow is installed, `ticks.parquet`: `run_id,symbol,epoch,local_received_ts,quote,pip_size,last_digit,tick_seq,connection_id,gap_flag`.
* `opportunities.parquet[.jsonl]`: `epoch,run_id,state,candidate,proposal,break_even,estimated_p,edge,decision,reason,mode`. State contains lag digits, digit frequencies at 10/20/50/100, streaks, group counts, entropy, chi-square, extrema, time-since each digit and stable `state_id`.
* `proposals.parquet[.jsonl]`: `run_id,epoch,contract_type,barrier,duration,duration_unit,stake,ask_price,payout,break_even,proposal_id,proposal_epoch,proposal_latency_ms`.
* `paper_results.csv`: one completed row with shot/run/signal IDs, contract/state/hypothesis/proposal, economics and probability, exact entry/settlement ticks and digits, W/L/P&L, track/control pairing, lookback/delay/hour.
* `paper_summary.csv`: family/track, N, W/L, WR/Wilson interval, mean BE/edge, P&L/ROI and maximum W/L streak.
* `events.log`: gaps, reconnects and lookback rebuilds.

JSONL journals are flushed on every row. CSV results are flushed and `fsync`'d per settlement. Ctrl+C closes streams, compacts Parquet when available, summarizes, and finalizes metadata.

## Leakage risks

No state may include the settlement tick, future proposal response, or retroactively reconstructed window. History seeds state only; it is not an outcome for a shot. Wall-clock matching must never replace tick sequence settlement. Discovery and OOS datasets must remain distinct. Counterfactual delays and controls must not be pooled with primary shots. Symbol datasets must not be pooled before symbol-aware analysis. Proposal failures and gaps are explicit missingness, not silently dropped trials. Repeated searches require the reported Bonferroni correction.

## Commands

Install optional runtime/test dependencies: `python -m pip install websockets pyarrow pytest`.

Offline tests: `python -m pytest -q`.

Discovery smoke test (Ctrl+C after data arrives): `python sniper_digits_ou_research_v1.py --symbol 1HZ10V --minutes 1 --history 5000 --session-label smoke`.

OOS: `python sniper_digits_ou_research_v1.py --symbol 1HZ10V --minutes 120 --history 5000 --mode oos --hypotheses frozen_hypotheses.json --session-label oos-v1`.

Analysis: `python analyze_sniper_digits_ou_v1.py --results "data/digits_over_under/*/sniper_digits_v1/run_*/paper_results.csv" --opportunities "data/digits_over_under/*/sniper_digits_v1/run_*/opportunities.parquet" --hypothesis-count 8`.

Windows PowerShell long run: `py sniper_digits_ou_research_v1.py --symbol 1HZ10V --minutes 480 --stake 1 --currency USD --history 5000 --out-dir data/digits_over_under --session-label win-long`.

Termux long run: `termux-wake-lock && python sniper_digits_ou_research_v1.py --symbol 1HZ10V --minutes 480 --stake 1 --currency USD --history 5000 --out-dir ~/storage/shared/sniper-data --session-label termux-long; termux-wake-unlock`.
