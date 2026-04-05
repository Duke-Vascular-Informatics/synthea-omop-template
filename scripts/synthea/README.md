# scripts/synthea/

Utilities for Synthea synthetic data generation and module visualization.

## Files

| File | Description | Called by |
|------|-------------|-----------|
| `run_synthea_pad_ssi.ps1` | Invokes the Synthea jar with the PAD/SSI module enabled. Configures population size, age range, state, and output directory. Requires Java and the Synthea jar to be present. | `workflow/04_generate_synthea_csv.ps1` |
| `generate_synthea_mermaid.R` | Parses `synthea/modules/pad_ssi.json` and generates a Mermaid state-diagram rendering of the module logic, saved as `synthea/modules/pad_ssi.diagram.html`. | `workflow/03_generate_synthea_module_artifacts.R` |

## Synthea configuration

Key parameters in `run_synthea_pad_ssi.ps1` that may need adjustment per environment:

| Parameter | Description |
|-----------|-------------|
| `-SyntheaHome` | Path to the Synthea jar directory |
| `-Population` | Number of synthetic patients to generate |
| `-AgeRange` | Minimum and maximum age for generated patients |
| `-State` | US state for simulated demographics |

Output CSVs are written to the Synthea default output directory and picked up by Step 05.
