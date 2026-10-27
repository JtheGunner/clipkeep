# 📏 Evaluation harness

Measures how well Clipkeep finds things and groups sessions, so tuning is driven by numbers.

```bash
./scripts/eval.sh                  # synthetic corpus, compared with baseline.json
./scripts/eval.sh --report out.md  # also write the report to a file
```

The exit code is `1` when a metric falls below the baseline (`2` for bad options or unreadable files; a failed build of `swift run` also exits `1`). The same check runs in the test
suite (`EvaluationTests`), so a regression fails CI.

---

## 📊 Metrics

| Metric | Meaning |
|---|---|
| Recall@1 / @5 / @10 | Share of gold queries whose target is among the first 1, 5 or 10 results |
| MRR | Mean of `1 / rank` of the target (0 if it is not in the first 50) |
| Time to result | Time from submitting a query to having the result list (median and p95) |
| Sessions, pairwise F1 | Agreement of computed sessions with labelled ones, over all pairs of events |
| Sessions, exactly reproduced | Share of labelled sessions found with exactly the same events |

Session metrics need labelled sessions and are shown as `–` for data without them.

## 🗂️ Data

| File | Content |
|---|---|
| `synthetic-corpus.json` | About 330 fictional copies in 42 labelled sessions (development, operations, cooking, travel, invoices, writing) |
| `synthetic-gold.json` | 56 queries: single words, word pairs, remembered prefixes, upper-case phrases |
| `baseline.json` | Reference values and tolerance |
| `generate_synthetic.py` | Deterministic generator of the two data files |

All committed data is fictional: no real texts, addresses, secrets or personal data. A test
checks the corpus with the secret detector.

A gold query names the target by a substring of its text:

```json
{ "queries": [ { "query": "ingress timeout", "targetContains": "(s12e3)" } ] }
```

## 🏠 Evaluating your own data

Real notes never belong in the repository. Keep the gold set next to your text file in
`eval/local/` (ignored by git) and run:

```bash
./scripts/eval.sh --text ~/notes.txt --gold eval/local/gold.json
```

The file is imported into a throwaway database (secrets are dropped), then every gold query is
run. Targets are found by `targetContains`. There is no baseline for your own data unless you
name one with `--baseline`.

> [!IMPORTANT]
> The gold set and the evaluation must cut the file into entries the same way. By default
> (`--split automatic`) a file with separator lines such as `---` is cut at those lines, and an
> entry that contains a secret is dropped as a whole, taking every target inside it along. If
> the gold set was built from blank-line blocks, evaluate with `--split blank-lines`:
>
> ```bash
> ./scripts/eval.sh --text ~/notes.txt --gold eval/local/gold.json --split blank-lines
> ```
>
> Modes: `automatic`, `separators`, `blank-lines`, `every-line`. Choose gold targets that are not
> secrets, because those entries never reach the database.

## 🎯 Baseline

| Metric | Baseline |
|---|---|
| Recall@1 | 57.1 % |
| Recall@5 | 73.2 % |
| Recall@10 | 94.6 % |
| MRR | 0.643 |
| Sessions, pairwise F1 | 100 % |
| Sessions, exactly reproduced | 100 % |

A quality metric may fall by at most `tolerance` (0.02, absolute). Latency only has a ceiling
(`maximumLatencyMs`, 250 ms for p95) because speed depends on the machine.

The synthetic sessions are cleanly separated by long pauses, so session grouping is an easy
case; it guards against breaking the segmentation rather than measuring its limit.

After an intended change of ranking or segmentation, check the report, then update the numbers:

```bash
./scripts/eval.sh --write-baseline
```

Commit `baseline.json` together with the change and update the table above.
