# ============================================================
# RAG ANALYZER (single-model, simple host/IP) — IPCC 6 PDFs
# Rows = four manuscript prompts (P1-P4); Columns = PDF filenames; Output = CSV
# Dependencies: pdftools, quanteda, dplyr, purrr, readr, stringi, glue, tibble, ollamar
# ============================================================

suppressPackageStartupMessages({
  library(pdftools)
  library(quanteda)
  library(dplyr)
  library(purrr)
  library(readr)
  library(stringi)
  library(glue)
  library(tibble)
  library(ollamar)
})

# --------------------------- Configuration ---------------------------
input_dir     <- "input_data"
output_dir    <- "rag_outputs"
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

# Use a local Ollama-compatible endpoint. Set OLLAMA_HOST before rerun if needed.
req_url   <- Sys.getenv("OLLAMA_HOST", "http://localhost:11434")
model     <- "xara:latest"
min_words <- 250L

# Chunking and retrieval
chunk_chars   <- 1800L
chunk_overlap <- 200L
max_ctx_chars <- 12000L
top_k_chunks  <- 8L

# Scenario prompts retained in the manuscript (P1-P4).
# The manuscript reports four scenario prompts, labelled P1-P4.
# Additional exploratory prompts from earlier development runs are intentionally excluded.
prompts <- c(
  "Identify plausible inflection points up to 2050 where mitigation or adaptation pathways structurally diverge; specify quantitative signposts consistent with IPCC evidence.",
  "Surface emerging technologies and system constraints that could alter emissions or resilience trajectories; describe boundary conditions for scale-up.",
  "Characterize socio-economic compound risks (e.g., heat, drought, conflict) and governance stress tests; outline second-order effects.",
  "Assess carbon dioxide removal feasibility at scale; identify limiting factors and lock-in risks under alternative policy regimes."
)
expected_prompt_count <- 4L
stopifnot(length(prompts) == expected_prompt_count)

# --------------------------- Utilities ---------------------------
read_pdf_text <- function(pdf_path) {
  pages <- pdftools::pdf_text(pdf_path)
  paste(pages, collapse = "\n\n")
}

chunk_text <- function(x, chunk_chars = 1800L, overlap = 200L) {
  x <- stri_replace_all_regex(x, "\\s+", " ")
  n <- nchar(x)
  if (n == 0L) return(character(0))
  step <- max(1L, chunk_chars - overlap)
  starts <- seq(1L, max(1L, n - chunk_chars + 1L), by = step)
  ends   <- pmin(starts + chunk_chars - 1L, n)
  mapply(function(s, e) substr(x, s, e), starts, ends, USE.NAMES = FALSE)
}

word_count <- function(x) {
  if (is.na(x) || !nzchar(x)) return(0L)
  length(strsplit(x, "\\s+")[[1]])
}

# Manual cosine similarity fallback (no extra packages beyond quanteda)
cosine_sim_query <- function(dfm_mat, query_name = "query") {
  X <- as.matrix(dfm_mat)
  if (!query_name %in% rownames(X)) stop("query row not found in dfm")
  q <- X[query_name, , drop = FALSE]
  nrms <- sqrt(rowSums(X * X)); nrms[nrms == 0] <- 1
  Xn <- X / nrms
  qn <- q / sqrt(sum(q * q))
  as.numeric(Xn %*% t(qn))
}

rank_chunks <- function(chunks, query, top_k = 8L) {
  texts    <- c(query, chunks)
  docnames <- c("query", paste0("chunk_", seq_along(chunks)))
  corp <- quanteda::corpus(texts, docnames = docnames)
  toks <- quanteda::tokens(corp, remove_punct = TRUE, remove_numbers = TRUE)
  dfm_ <- quanteda::dfm(toks)
  dfm_tfidf <- quanteda::dfm_tfidf(dfm_, scheme_tf = "prop", scheme_df = "inverse")
  sc <- cosine_sim_query(dfm_tfidf, query_name = "query")
  sc[is.na(sc)] <- 0
  scores <- sc[-1]
  ord <- order(scores, decreasing = TRUE)
  list(order = ord, scores = scores[ord])
}

select_context <- function(chunks, ord, max_chars = 12000L, top_k = 8L) {
  sel <- character(0); total <- 0L
  for (idx in ord[seq_len(min(length(ord), top_k))]) {
    ctext <- chunks[[idx]]; clen <- nchar(ctext)
    if (total + clen > max_chars) break
    sel <- c(sel, ctext); total <- total + clen
  }
  paste(sel, collapse = "\n\n---\n\n")
}

compose_prompt <- function(doc_name, context, user_prompt, min_words) {
  glue(
    "Your task is to answer the analytical prompt using ONLY the evidence contained within the provided IPCC/GIEC document context.
Write in a precise, academic style. Anchor statements in the context and avoid speculation beyond it.
If quantitative signposts are requested, extract magnitudes, time frames, or ranges that appear in the context.

Document: {doc_name}

=== CONTEXT (BEGIN) ===
{context}
=== CONTEXT (END) ===

PROMPT:
{user_prompt}

Requirements: at least {min_words} words; coherent structure; no bullet points; avoid hallucinations; if evidence is insufficient, state the limitation explicitly."
  )
}

expand_if_needed <- function(ans, host, model, doc_name, context, user_prompt, min_words) {
  if (word_count(ans) >= min_words) return(ans)
  follow_up <- glue(
    "Earlier answer was under {min_words} words or insufficiently detailed.
Using the SAME CONTEXT again, expand and refine the answer, ensuring at least {min_words}+ words and drawing on the most relevant quantitative details.

Document: {doc_name}

=== CONTEXT (BEGIN) ===
{context}
=== CONTEXT (END) ===

PROMPT (restate and expand):
{user_prompt}"
  )
  out <- tryCatch(
    generate(host = host, model = model, prompt = follow_up, stream = FALSE, output = "text"),
    error = function(e) ""
  )
  if (!nzchar(out)) return(ans)
  out
}

# --------------------------- Load PDFs and chunk ---------------------------
pdf_files <- list.files(input_dir, pattern = "\\.pdf$", full.names = TRUE)
stopifnot(length(pdf_files) >= 1L)

pdf_store <- tibble(
  pdf_path = pdf_files,
  pdf_name = basename(pdf_files)
) %>%
  mutate(
    text   = map_chr(pdf_path, read_pdf_text),
    chunks = map(text, ~ chunk_text(.x, chunk_chars = chunk_chars, overlap = chunk_overlap))
  )

# --------------------------- Run prompts × PDFs ---------------------------
results <- map_dfr(
  seq_along(prompts),
  function(i) {
    ptxt <- prompts[[i]]
    message(glue("Prompt {i}/{length(prompts)}"))
    
    # Rank and select context per PDF
    ctx_per_pdf <- map(pdf_store$chunks, function(chs) {
      if (length(chs) == 0L) return("")
      rk  <- rank_chunks(chs, ptxt, top_k = top_k_chunks)
      ctx <- select_context(chs, rk$order, max_chars = max_ctx_chars, top_k = top_k_chunks)
      ctx
    })
    
    # Generate per PDF using ollamar through the configured local endpoint
    answers <- character(length(pdf_store$pdf_name))
    for (j in seq_along(pdf_store$pdf_name)) {
      doc_name <- pdf_store$pdf_name[[j]]
      ctx      <- ctx_per_pdf[[j]]
      prompt   <- compose_prompt(doc_name, ctx, ptxt, min_words)
      
      raw <- tryCatch(
        generate(host = req_url, model = model, prompt = prompt, stream = FALSE, output = "text"),
        error = function(e) {
          warning(sprintf("Generation error for '%s' (prompt %d): %s", doc_name, i, e$message))
          ""
        }
      )
      
      if (word_count(raw) < min_words) {
        raw <- expand_if_needed(raw, req_url, model, doc_name, ctx, ptxt, min_words)
      }
      answers[[j]] <- raw
    }
    
    tibble(prompt_id = i, prompt = ptxt) %>%
      bind_cols(as_tibble_row(setNames(as.list(answers), pdf_store$pdf_name)))
  }
)

# --------------------------- Write CSV ---------------------------
results <- results %>% relocate(prompt, .after = prompt_id)
if (nrow(results) != expected_prompt_count) {
  stop(glue("Expected {expected_prompt_count} first-pass prompt rows, got {nrow(results)}."))
}

# Keep answers.csv for pipeline continuity and S2_answers.csv for SI-package naming.
out_csv <- file.path(output_dir, "answers.csv")
out_si_csv <- file.path(output_dir, "S2_answers.csv")
write_csv(results, out_csv)
write_csv(results, out_si_csv)
message(glue("Wrote: {out_csv}"))
message(glue("Wrote: {out_si_csv}"))
message(glue("Rows: {nrow(results)} = four manuscript scenario prompts (P1-P4)"))
