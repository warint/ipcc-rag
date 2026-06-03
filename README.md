# AI-assisted comparative historical consistency analysis of IPCC reports

This repository accompanies the manuscript **“AI-assisted comparative historical consistency analysis of IPCC reports with Retrieval-Augmented Generation using layered analytical prompts.”** It contains the reproducibility materials, first-pass model outputs, second-pass comparative outputs, and redacted R scripts used to examine how six IPCC synthesis reports respond to a common set of scenario-based prompts.

The repository is a research compendium rather than an R package. Its purpose is to make the prompt banks, output files, and code structure inspectable and rerunnable, subject to the reproducibility qualifications stated below.

## Repository contents

| File or directory | Description |
| --- | --- |
| `S1_Supporting_Information_reproducibility_prompt_parameter_audit.docx` | Supporting information file containing the reproducibility checklist, prompt banks, parameter audit, output inventory, and known missing execution metadata. |
| `S2_answers.csv` | First-pass outputs. Rows are the four manuscript scenario prompts, P1–P4. Columns are the six IPCC synthesis-report PDF filenames. |
| `S3_comparative_analyses.csv` | Second-pass comparative outputs in long format. The expected structure is 4 first-pass prompts × 5 analytical prompts × 6 IPCC reports = 120 rows. |
| `S4_model_5_code_v1_redacted.R` | Redacted R script for the first-pass sparse RAG pipeline. The script uses the four manuscript-aligned scenario prompts. |
| `S5_model_5_code_step_2_redacted.R` | Redacted R script for the second-pass comparative analysis. The script uses five manuscript-aligned analytical prompts and checks the expected 120-row output. |
| `S4_Redacted_R_scripts.zip` | Archive containing the two redacted R scripts. |
| `input_data/` | Local directory expected by the scripts for the six IPCC PDF files. This directory may need to be created locally if the PDFs are not stored in the GitHub repository. |
| `rag_outputs/` | Output directory created by the scripts during reruns. |

Important: earlier development runs used additional exploratory prompts. The manuscript-aligned repository uses **four** first-pass scenario prompts and **five** second-pass analytical prompts. Do not mix the current files with older exploratory files such as `S3_answers.csv`, `S3_comparative_analyses_original_600rows.csv`, or scripts that define ten first-pass prompts.

## Study design

The study compares six IPCC synthesis reports corresponding to the first through sixth assessment cycles. Each report is queried with the same four scenario prompts so that cross-report differences can be interpreted as differences in the retrieved report evidence and in the model’s response to that evidence under a common prompting structure.

The four first-pass scenario prompts are:

| ID | Prompt |
| --- | --- |
| P1 | Identify plausible inflection points up to 2050 where mitigation or adaptation pathways structurally diverge; specify quantitative signposts consistent with IPCC evidence. |
| P2 | Surface emerging technologies and system constraints that could alter emissions or resilience trajectories; describe boundary conditions for scale-up. |
| P3 | Characterize socio-economic compound risks, such as heat, drought, and conflict, and governance stress tests; outline second-order effects. |
| P4 | Assess carbon dioxide removal feasibility at scale; identify limiting factors and lock-in risks under alternative policy regimes. |

The five second-pass analytical prompts are:

| ID | Analytical layer |
| --- | --- |
| A1 | Internal validity: identify causal claims, supporting evidence, logical warrants, and minimal additional evidence where reasoning is incomplete. |
| A2 | Uncertainty: classify statements by confidence or likelihood categories consistent with IPCC usage and explain their inferential consequences. |
| A3 | Causal mechanisms: synthesize the principal mechanisms into a causal narrative up to 2050, including feedbacks, path dependencies, and thresholds. |
| A4 | External consistency: compare claims to canonical AR6 constructs such as Shared Socioeconomic Pathways and illustrative mitigation pathways. |
| A5 | Research agenda: propose two to three empirical strategies that would improve decision relevance within five years. |

## Pipeline summary

The first-pass script reads PDF files from `input_data/`, extracts text with `pdftools`, normalizes whitespace, and divides each report into overlapping text chunks. The script uses sparse tf–idf retrieval through `quanteda`, ranks chunks by cosine similarity between each prompt and each document chunk, selects up to eight relevant chunks under a 12,000-character context limit, and submits the resulting context block to a local Ollama-compatible endpoint through `ollamar`.

The core first-pass parameters are:

| Parameter | Value |
| --- | ---: |
| `chunk_chars` | 1800 |
| `chunk_overlap` | 200 |
| `top_k_chunks` | 8 |
| `max_ctx_chars` | 12000 |
| `min_words` | 250 |
| Retrieval method | Sparse tf–idf with cosine similarity |
| Model tag | `xara:latest` |
| Default endpoint | `http://localhost:11434` |

The second-pass script reads the first-pass answers, filters to prompt IDs 1–4, applies the five analytical prompts to each document-specific answer cell, and writes `S3_comparative_analyses.csv`.

## Input PDFs

The scripts expect six PDF files in `input_data/`. The archived output columns preserve the following filenames:

```text
2nd-assessment-en-1.1995.pdf
ar4_syr_full_report.2007.pdf
ipcc_90_92_assessments_far_full_report.pdf
IPCC_AR6_SYR_FullVolume. 2023.pdf
SYR_AR5_FINAL_full. 2014.pdf
SYR_TAR_full_report.2001.pdf
```

If the PDFs are not included in the repository, create `input_data/` and place the six PDFs there before rerunning the scripts. The scripts use `basename()` for output column names, so changes in PDF filenames will change the output column names even when the document contents are unchanged.

## Software requirements

The scripts were written for R and use the following R packages:

```r
install.packages(c(
  "pdftools", "quanteda", "dplyr", "purrr", "readr",
  "stringi", "stringr", "glue", "tibble"
))
```

The scripts also require `ollamar`. Install it from the same source used in your local R environment if it is not available through your standard package repository.

A later audit capture recorded the following environment. These values document the later reproducibility environment and should not be treated as a complete historical execution log for the original generation run.

| Component | Recorded value |
| --- | --- |
| R | 4.6.0 |
| Operating system | Ubuntu 24.04.4 LTS |
| CPU | AMD EPYC 7443P, 32 online CPUs |
| Memory | Approximately 70 GiB total memory |
| `pdftools` | 3.9.0 |
| `quanteda` | 4.4 |
| `dplyr` | 1.2.1 |
| `purrr` | 1.2.2 |
| `readr` | 2.2.0 |
| `stringi` | 1.8.7 |
| `glue` | 1.8.1 |
| `tibble` | 3.3.1 |
| `ollamar` | 0.9.0 |



## Reproducibility limitations

The deposited scripts and outputs make the analytical structure inspectable, but they do not provide a fully exact historical rerun record. The scripts are redacted to avoid distributing a private local-area-network endpoint. Repository users should set `OLLAMA_HOST` in their own environment rather than editing private server addresses into the scripts. The model is queried locally through the configured endpoint; no external API call is required by the scripts unless the local endpoint is itself configured to proxy requests elsewhere.


