# ============================================================
# COMPARATIVE ANALYSES — second-pass RAG over answers.csv
# Inputs : rag_outputs/answers.csv  (rows = original prompts; cols = PDFs)
# Outputs: rag_outputs/S3_comparative_analyses.csv (long format)
# Model  : local LLM via ollamar (same host/model as prior run)
# Scope  : four scenario prompts (P1-P4) x five analytical layers x six IPCC PDFs
# ============================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(purrr)
  library(stringr)
  library(glue)
  library(tibble)
  library(ollamar)
})

# --------------------------- Configuration ---------------------------
# The first-pass script writes rag_outputs/answers.csv. The fallback filenames
# below make the script usable when the SI package is executed from a flat folder.
input_candidates <- c(
  file.path("rag_outputs", "S2_answers.csv"),
  file.path("rag_outputs", "answers.csv"),
  "S2_answers.csv",
  "S3_answers.csv"
)
input_csv <- input_candidates[file.exists(input_candidates)][1]
if (is.na(input_csv)) {
  stop("No first-pass answers file found. Expected rag_outputs/answers.csv or S2_answers.csv.")
}

output_dir <- if (dir.exists("rag_outputs")) "rag_outputs" else "."
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
out_csv <- file.path(output_dir, "S3_comparative_analyses.csv")

req_url       <- Sys.getenv("OLLAMA_HOST", "http://localhost:11434")
model         <- "xara:latest"
min_words     <- 250L
max_ctx_chars <- 12000L

# The manuscript reports four scenario prompts, labelled P1-P4. If answers.csv
# contains additional exploratory first-pass prompts, they are not part of S3.
target_prompt_ids <- 1:4

# --------------------------- Five analytical prompts ---------------------------
# These five layered analytical prompts correspond to the manuscript's Analysis 1-5.
analysis_prompts <- c(
  # Analysis 1: internal validity
  "Evaluate the internal validity of the argumentation by identifying the explicit causal claims, the supporting evidence, and the logical warrants in the excerpt. Where the chain of reasoning is incomplete, propose the minimal additional evidence required, remaining within IPCC terminology.",
  # Analysis 2: uncertainty quantification
  "Quantify and qualify uncertainty as presented or implied in the excerpt. Classify statements by confidence or likelihood categories consistent with IPCC usage, and explain how these classifications affect the strength of the conclusions.",
  # Analysis 3: causal mechanisms narrative
  "Extract the principal mechanisms described in the excerpt and synthesize them into a concise causal narrative over time up to 2050. Indicate any feedback loops, path dependencies, or thresholds mentioned or implied.",
  # Analysis 4: external consistency
  "Assess the external consistency by comparing the claims in the excerpt to canonical IPCC AR6 constructs such as the Shared Socioeconomic Pathways (SSPs) and illustrative mitigation pathways. Indicate where the excerpt's perspective aligns or diverges from these constructs, and discuss why that matters for inference.",
  # Analysis 5: research agenda proposition
  "Formulate a compact research agenda derived from the gaps and limitations of the excerpt. Propose two to three empirical strategies that would most improve the decision-relevance of the findings within the next five years."
)

# --------------------------- Utilities ---------------------------
trim_to <- function(x, n) {
  if (is.na(x) || !nzchar(x)) return("")
  if (nchar(x) <= n) return(x)
  substr(x, 1L, n)
}

word_count <- function(x) {
  if (is.na(x) || !nzchar(x)) return(0L)
  length(strsplit(x, "\\s+")[[1]])
}

compose_analysis_prompt <- function(original_prompt, cell_text, analysis_prompt, min_words) {
  glue(
    "Your task is to produce a rigorous, academic analysis based solely on the EVIDENCE provided below, which is an answer previously generated from an IPCC/GIEC synthesis document. Do not introduce external claims. Write in a precise academic register, avoid bullet points, and make limitations explicit.

ORIGINAL PROMPT (for context):
{original_prompt}

EVIDENCE (BEGIN)
{cell_text}
EVIDENCE (END)

ANALYTICAL INSTRUCTION:
{analysis_prompt}

Requirements: at least {min_words} words; coherent paragraphs; use IPCC-consistent terminology for confidence/likelihood where relevant; declare uncertainty where the evidence is insufficient."
  )
}

expand_if_needed <- function(ans, original_prompt, cell_text, analysis_prompt, min_words) {
  if (word_count(ans) >= min_words) return(ans)
  followup <- glue(
    "Earlier answer was under {min_words} words or insufficiently detailed. Using the SAME EVIDENCE again, expand and refine the analysis without adding external information.

ORIGINAL PROMPT:
{original_prompt}

EVIDENCE (BEGIN)
{cell_text}
EVIDENCE (END)

ANALYTICAL INSTRUCTION (restate and expand):
{analysis_prompt}"
  )
  out <- tryCatch(
    generate(host = req_url, model = model, prompt = followup, stream = FALSE, output = "text"),
    error = function(e) ""
  )
  if (!nzchar(out)) ans else out
}

# --------------------------- Load answers.csv ---------------------------
answers <- readr::read_csv(input_csv, show_col_types = FALSE)

required_cols <- c("prompt_id", "prompt")
missing_cols <- setdiff(required_cols, names(answers))
if (length(missing_cols) > 0L) {
  stop(glue("Missing required column(s) in {input_csv}: {paste(missing_cols, collapse = ', ')}"))
}

answers <- answers %>%
  mutate(prompt_id = as.integer(.data$prompt_id)) %>%
  filter(.data$prompt_id %in% target_prompt_ids) %>%
  arrange(.data$prompt_id)

missing_prompt_ids <- setdiff(target_prompt_ids, answers$prompt_id)
if (length(missing_prompt_ids) > 0L) {
  stop(glue("Missing manuscript scenario prompt id(s): {paste(missing_prompt_ids, collapse = ', ')}"))
}
if (nrow(answers) != length(target_prompt_ids)) {
  stop(glue("Expected four manuscript scenario prompt rows after filtering; found {nrow(answers)}."))
}

# Identify document columns. All non-id/text columns are treated as per-PDF answers.
doc_cols <- setdiff(names(answers), required_cols)
if (length(doc_cols) < 1L) stop("No document columns found in answers.csv")

expected_rows <- nrow(answers) * length(analysis_prompts) * length(doc_cols)
message(glue("Selected {nrow(answers)} scenario prompts x {length(analysis_prompts)} analytical prompts x {length(doc_cols)} documents = {expected_rows} expected rows."))

# --------------------------- Run analyses ---------------------------
# Long-format output: one row per (original_prompt_id, analysis_id, document).
comparative <- map_dfr(
  seq_len(nrow(answers)),
  function(i) {
    orig_id <- answers$prompt_id[[i]]
    orig_pr <- answers$prompt[[i]]

    cells <- answers[i, doc_cols] %>%
      mutate(across(everything(), ~ trim_to(.x, max_ctx_chars)))

    map_dfr(seq_along(analysis_prompts), function(aid) {
      ap <- analysis_prompts[[aid]]

      map_dfr(doc_cols, function(dc) {
        cell_txt <- cells[[dc]]

        if (is.na(cell_txt) || !nzchar(cell_txt)) {
          tibble(
            prompt_id = orig_id,
            original_prompt = orig_pr,
            analysis_id = aid,
            analysis_prompt = ap,
            document = dc,
            analysis_text = "(No evidence available in this cell.)"
          )
        } else {
          prompt_text <- compose_analysis_prompt(orig_pr, cell_txt, ap, min_words)

          raw <- tryCatch(
            generate(host = req_url, model = model, prompt = prompt_text, stream = FALSE, output = "text"),
            error = function(e) {
              warning(sprintf("Generation error at row %d, analysis %d, doc %s: %s", i, aid, dc, e$message))
              ""
            }
          )

          if (word_count(raw) < min_words) {
            raw <- expand_if_needed(raw, orig_pr, cell_txt, ap, min_words)
          }

          tibble(
            prompt_id = orig_id,
            original_prompt = orig_pr,
            analysis_id = aid,
            analysis_prompt = ap,
            document = dc,
            analysis_text = if (nzchar(raw)) raw else "(Generation failed.)"
          )
        }
      })
    })
  }
)

if (nrow(comparative) != expected_rows) {
  stop(glue("Unexpected row count: expected {expected_rows}, generated {nrow(comparative)}."))
}

# --------------------------- Write CSV ---------------------------
readr::write_csv(comparative, out_csv)
message(glue("Wrote: {out_csv}"))
message(glue("Rows: {nrow(comparative)} = {length(target_prompt_ids)} prompts x {length(analysis_prompts)} analyses x {length(doc_cols)} documents"))
