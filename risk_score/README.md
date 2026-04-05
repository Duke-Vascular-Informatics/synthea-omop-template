# risk_score/

Configuration files that define the PAD/SSI integer risk score model.
These are the primary inputs to `R/risk_score_pipeline.R`.

## Files

| File | Description |
|------|-------------|
| `components.csv` | One row per risk score component. Defines the component name, OMOP domain, lookback window (days relative to index date), minimum event count to qualify, and integer point value. |
| `component_concepts.csv` | OMOP concept IDs for each component. Supports `include_descendants = true` for ancestor rollup via `concept_ancestor`. Optional `concept_role` and `value_concept_ids` columns for measurement and observation sub-typing. |
| `risk_lookup.csv` | Maps each integer total score to a calibrated predicted SSI probability. Used by the pipeline to produce probability-scale outputs alongside the raw integer score. |

## Score components

| component_id | Description | Points |
|---|---|---|
| `female` | Female sex | 1 |
| `overweight` | BMI 25–30 | 1 |
| `obese` | BMI > 30 | 2 |
| `urgnt` | Urgent/emergent procedure | 2 |
| `abi_35` | Ankle-brachial index < 0.35 | 2 |
| `prrevasc_any` | Prior open revascularization | 1 |
| `prolong_abx` | Prolonged pre-op antibiotic exposure (> 2 days) | 1 |
| `open_revasc` | Open (non-endovascular) procedure type | 1 |
| `mFI_high` | Modified Frailty Index ≥ 2 of 5 conditions | 2 |
| `op_time_240` | Operative time > 240 minutes | 2 |

## Modifying the score

- To add a component: add a row to `components.csv` and one or more concept rows to `component_concepts.csv`.
- To update concept mappings: edit `component_concepts.csv` — changes take effect on the next pipeline run.
- Concept IDs should be verified against the live OMOP vocabulary (`omop_vocab.concept`) before use.
