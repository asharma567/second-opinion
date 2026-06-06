#!/usr/bin/env bash
# reason.sh — adversarial refinement loop for second-opinion
#
# Implements the :reason pattern from /autoresearch:reason but with cross-provider
# cold-start judges instead of all-Claude subagents. Same harness, different judge
# composition. See DAT-554.
#
# Flow (per round):
#   1. Author-A produces candidate
#   2. Critic attacks candidate-A (forced weaknesses)
#   3. Author-B sees task + A + critique, produces challenger
#   4. Synthesizer produces AB from task + A + B (skipped in debate mode)
#   5. Judge panel evaluates {A, B, AB} under randomized labels (X, Y, Z)
#   6. Convergence check: incumbent wins N consecutive rounds → stop
#
# Each agent invocation is a fresh subprocess against its adapter — no history.
# Sequential execution throughout (droplet 2GB RAM constraint).
#
# Bash 3.2 compatible (macOS default); no mapfile, no associative arrays.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTERS="$SKILL_DIR/scripts/adapters"
RUNS_ROOT="$SKILL_DIR/reason-runs"

if [[ -r "$HOME/.openclaw-tgpkb/secrets/llm_keys.sh" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.openclaw-tgpkb/secrets/llm_keys.sh"
fi

# ---------- defaults ----------
mode="convergent"   # convergent | creative | debate
domain="software"
judges_n=3
convergence_n=3
max_iterations=0    # 0 = unbounded (rely on convergence)
no_synthesis=0
temperature=""
chain=""
task=""

usage() {
  cat <<'EOF'
Usage: reason.sh [options] <task description>

Options:
  --mode <m>           convergent (default) | creative | debate
  --domain <d>         software (default) | product | business | security | research | content
  --judges N           judge panel size (3 default; 5 or 7 for thorough)
  --convergence N      consecutive wins to declare convergence (default 3)
  --iterations N       bound max rounds (default 0 = until convergence)
  --no-synthesis       skip Phase 5 (equivalent to --mode debate)
  --temperature low|high   adapter hint (best-effort)
  --chain <targets>    write handoff.json suggesting next command (comma-separated)
  -h, --help           this help

Example:
  reason.sh --judges 3 --convergence 3 \
            "Should we use event sourcing for our order management system?"
EOF
}

# ---------- argument parsing ----------
prompt_parts=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --domain) domain="$2"; shift 2 ;;
    --judges) judges_n="$2"; shift 2 ;;
    --convergence) convergence_n="$2"; shift 2 ;;
    --iterations) max_iterations="$2"; shift 2 ;;
    --no-synthesis) no_synthesis=1; shift ;;
    --temperature) temperature="$2"; shift 2 ;;
    --chain) chain="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do prompt_parts+=("$1"); shift; done ;;
    *) prompt_parts+=("$1"); shift ;;
  esac
done

task="${prompt_parts[*]:-}"
if [[ -z "$task" ]]; then
  echo "error: task description required" >&2
  usage >&2
  exit 2
fi

if [[ "$mode" == "debate" ]]; then no_synthesis=1; fi

# ---------- discover available providers ----------
providers=()
command -v codex >/dev/null 2>&1 && providers+=(codex)
[[ -n "${XAI_API_KEY:-}" ]]        && providers+=(grok)
[[ -n "${GEMINI_API_KEY:-}" ]]     && providers+=(gemini)
[[ -n "${OPENROUTER_API_KEY:-}" ]] && providers+=(openrouter)

if [[ ${#providers[@]} -lt 2 ]]; then
  echo "error: reason loop needs ≥2 providers (have: ${providers[*]:-none})" >&2
  echo "  configure at least two of: codex CLI, XAI_API_KEY, GEMINI_API_KEY, OPENROUTER_API_KEY" >&2
  exit 4
fi

# ---------- role → provider mapping ----------
# Pick provider for each role, preferring distinct providers where possible.
# Fall back to repeats only when fewer than 4 providers are available.
pick_role() {
  local role="$1"
  local preferred=""
  case "$role" in
    author_a)    preferred="codex gemini grok openrouter" ;;
    critic)      preferred="grok openrouter codex gemini" ;;
    author_b)    preferred="gemini codex grok openrouter" ;;
    synthesizer) preferred="codex gemini openrouter grok" ;;
  esac
  local p q
  for p in $preferred; do
    for q in "${providers[@]}"; do
      if [[ "$p" == "$q" ]]; then
        echo "$p"
        return
      fi
    done
  done
}

# Judges: pick N distinct providers (or repeat the smallest pool if N > pool size)
select_judges() {
  local n="$1"
  local i=0
  while [[ $i -lt $n ]]; do
    echo "${providers[$((i % ${#providers[@]}))]}"
    i=$((i + 1))
  done
}

# ---------- setup run dir ----------
slug="$(echo "$task" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
[[ -z "$slug" ]] && slug="run"
run_id="$(date +%y%m%d-%H%M)-$slug"
run_dir="$RUNS_ROOT/$run_id"
mkdir -p "$run_dir"

role_author_a="$(pick_role author_a)"
role_critic="$(pick_role critic)"
role_author_b="$(pick_role author_b)"
role_synthesizer="$(pick_role synthesizer)"

echo "[reason] run dir: $run_dir" >&2
echo "[reason] providers available: ${providers[*]}" >&2
echo "[reason] roles: A=$role_author_a, critic=$role_critic, B=$role_author_b, synth=$role_synthesizer" >&2
echo "[reason] mode=$mode domain=$domain judges=$judges_n convergence=$convergence_n max_iter=$max_iterations" >&2

# Manifest
providers_json="$(printf '%s\n' "${providers[@]}" | jq -Rs 'split("\n") | map(select(. != ""))')"
cat > "$run_dir/manifest.json" <<EOF
{
  "task": $(printf '%s' "$task" | jq -Rs .),
  "mode": "$mode",
  "domain": "$domain",
  "judges_n": $judges_n,
  "convergence_n": $convergence_n,
  "max_iterations": $max_iterations,
  "no_synthesis": $no_synthesis,
  "temperature": $(printf '%s' "${temperature:-}" | jq -Rs .),
  "providers_available": $providers_json,
  "role_author_a": "$role_author_a",
  "role_critic": "$role_critic",
  "role_author_b": "$role_author_b",
  "role_synthesizer": "$role_synthesizer",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# TSV header
printf "round\twinner\tvotes_A\tvotes_B\tvotes_AB\twords_A\twords_B\twords_AB\tincumbent_after\tconsec_wins\n" > "$run_dir/reason-results.tsv"

# ---------- helpers ----------
strip_envelope() {
  awk '
    /^=== provider: / { in_body=1; next }
    /^=== end ===$/ { in_body=0; next }
    in_body { print }
  '
}

call_adapter() {
  # call_adapter <provider> <prompt_file> <output_file>
  local provider="$1" pfile="$2" ofile="$3"
  local prompt_content
  prompt_content="$(cat "$pfile")"
  if [[ ! -x "$ADAPTERS/${provider}.sh" ]]; then
    echo "error: adapter $provider not found" >&2
    return 4
  fi
  set +e
  "$ADAPTERS/${provider}.sh" "$prompt_content" > "${ofile}.raw" 2>"${ofile}.err"
  local rc=$?
  set -e
  strip_envelope < "${ofile}.raw" > "$ofile"
  return $rc
}

word_count() {
  if [[ -f "$1" ]]; then
    wc -w < "$1" | tr -d ' '
  else
    echo 0
  fi
}

shuffle3() {
  printf 'A\nB\nAB\n' | awk 'BEGIN{srand()} {print rand()"\t"$0}' | sort -k1,1n | cut -f2-
}

shuffle2() {
  printf 'A\nB\n' | awk 'BEGIN{srand()} {print rand()"\t"$0}' | sort -k1,1n | cut -f2-
}

# Domain criteria for judge prompts
domain_criteria() {
  case "$1" in
    software) echo "Correctness, feasibility, edge case coverage, maintainability tradeoffs" ;;
    product) echo "User value clarity, feasibility, prioritization rationale, metrics" ;;
    business) echo "ROI reasoning, risk awareness, stakeholder consideration, actionability" ;;
    security) echo "Threat coverage, defense-in-depth, real attack scenario validity" ;;
    research) echo "Hypothesis clarity, falsifiability, methodology soundness, novelty" ;;
    content) echo "Clarity, audience fit, argument strength, factual accuracy" ;;
    *) echo "Substance, reasoning quality, completeness, practical applicability" ;;
  esac
}

# ---------- prompt templates ----------
write_author_a_prompt() {
  local round="$1" out="$2"
  if [[ "$round" -eq 1 ]]; then
    cat > "$out" <<EOF
Task: $task
Domain: $domain

Produce a high-quality response to this task. Be thorough, concrete, and well-reasoned. Do NOT hold back — this is your best attempt.

CONSTRAINTS:
- No hedging language ("perhaps", "maybe", "it depends") unless genuinely uncertain
- Every claim must be supported by reasoning or evidence
- If this is a design/architecture task: specify components, interfaces, and tradeoffs explicitly
- If this is an argument/decision task: state your position clearly, then defend it
- Length: appropriate for depth of task — not artificially long or short
EOF
  else
    local incumbent_file="$3"
    cat > "$out" <<EOF
Task: $task
Domain: $domain

Current best candidate (do not reproduce verbatim — build on it):

---
$(cat "$incumbent_file")
---

Your role: Improve this candidate. Identify its weaknesses and produce a version that addresses them. You may restructure, extend, prune, or reframe. Do NOT simply paraphrase. Produce a genuinely better version.
EOF
  fi
}

write_critic_prompt() {
  local candidate_a_file="$1" out="$2"
  cat > "$out" <<EOF
You are an adversarial critic. Your job is to ATTACK the following candidate ruthlessly.

Candidate:
---
$(cat "$candidate_a_file")
---

RULES:
1. Find MINIMUM 3 distinct weaknesses (more is better)
2. Each weakness must be SPECIFIC — quote or reference the exact claim, section, or reasoning you're attacking
3. Weaknesses must be SUBSTANTIVE — not stylistic nitpicks unless the style undermines comprehension
4. Do NOT offer fixes — only attack. The Author-B role will respond to your critique
5. Rate each weakness by impact: FATAL (invalidates the argument), MAJOR (significant gap), MINOR (improvable)
6. End with a one-line "Verdict" sentence summarizing the weakest point overall

Output format:
WEAKNESS-1 [FATAL|MAJOR|MINOR]: {specific claim or section} — {critique}
WEAKNESS-2 [FATAL|MAJOR|MINOR]: ...
...
VERDICT: {one-line summary of the most critical weakness}
EOF
}

write_author_b_prompt() {
  local candidate_a_file="$1" critique_file="$2" out="$3"
  cat > "$out" <<EOF
Task: $task
Domain: $domain

Here is a previous attempt at this task:
---
CANDIDATE A:
$(cat "$candidate_a_file")
---

Here is an adversarial critique of Candidate A:
---
CRITIQUE:
$(cat "$critique_file")
---

Your role: Produce a BETTER candidate (Candidate B) that addresses the critique's weaknesses while preserving what Candidate A did well.

CONSTRAINTS:
- Address at least the FATAL and MAJOR weaknesses from the critique
- Do NOT simply patch A — rethink structure and reasoning where the critique reveals deeper issues
- Do NOT reference the critique explicitly ("as the critique noted...") — integrate the improvements naturally
- Do NOT reproduce A verbatim — your candidate must be substantively different
- Every claim must be supported by reasoning or evidence
- Avoid over-correcting: if a MINOR weakness was stylistic, don't restructure the entire response for it
EOF
}

write_synthesizer_prompt() {
  local candidate_a_file="$1" candidate_b_file="$2" out="$3"
  cat > "$out" <<EOF
Task: $task
Domain: $domain

You have two candidate responses to this task:
---
CANDIDATE A:
$(cat "$candidate_a_file")
---
CANDIDATE B:
$(cat "$candidate_b_file")
---

Your role: Produce CANDIDATE AB — a synthesis that is superior to both A and B.

CONSTRAINTS:
1. Identify what A does better than B (specific strengths)
2. Identify what B does better than A (specific strengths)
3. Combine the strongest elements — do NOT average them into mediocrity
4. Resolve any direct contradictions by reasoning through which position is better supported
5. The result must be COHERENT — not a patchwork. It should read as a single unified response
6. Do NOT invent new claims that neither A nor B supports — synthesize only from what exists
7. Do NOT hedge contradictions — pick a position and defend it

Begin with a 2-3 sentence internal monologue (in [brackets]) explaining what you're taking from each, then produce the full synthesized candidate.
EOF
}

write_judge_prompt() {
  # write_judge_prompt label_x_file label_y_file label_z_file out debate_mode
  local label_x_file="$1" label_y_file="$2" label_z_file="$3" out="$4" debate_mode="$5"
  local criteria
  criteria="$(domain_criteria "$domain")"
  if [[ "$debate_mode" == "1" ]]; then
    cat > "$out" <<EOF
You are an expert evaluator in $domain.

Task: $task

Below are 2 candidate responses. Labels are arbitrary — do NOT assume ordering implies quality.

---
CANDIDATE X:
$(cat "$label_x_file")

---
CANDIDATE Y:
$(cat "$label_y_file")
---

EVALUATION RULES:
1. You MUST pick a winner. "Tie" is not acceptable — force-rank if close
2. Evaluate on: accuracy/correctness, completeness, reasoning quality, practical applicability
3. Domain-specific criteria: $criteria
4. Your reasoning must cite SPECIFIC text from the candidates (quote or reference)
5. DO NOT pick based on length — longer is not better
6. DO NOT pick based on style — substance wins

Output format:
WINNER: X | Y
RUNNER-UP: X | Y
REASONING: {2-4 sentences citing specific evidence}
WINNING_STRENGTH: {the single strongest element of the winner}
RUNNER_UP_GAP: {the specific gap that prevented runner-up from winning}
EOF
  else
    cat > "$out" <<EOF
You are an expert evaluator in $domain.

Task: $task

Below are 3 candidate responses. Labels are arbitrary — do NOT assume ordering implies quality.

---
CANDIDATE X:
$(cat "$label_x_file")

---
CANDIDATE Y:
$(cat "$label_y_file")

---
CANDIDATE Z:
$(cat "$label_z_file")
---

EVALUATION RULES:
1. You MUST pick a winner. "Tie" is not acceptable — force-rank if close
2. Evaluate on: accuracy/correctness, completeness, reasoning quality, practical applicability
3. Domain-specific criteria: $criteria
4. Your reasoning must cite SPECIFIC text from the candidates (quote or reference)
5. DO NOT pick based on length — longer is not better
6. DO NOT pick based on style — substance wins

Output format:
WINNER: X | Y | Z
RUNNER-UP: X | Y | Z
REASONING: {2-4 sentences citing specific evidence}
WINNING_STRENGTH: {the single strongest element of the winner}
RUNNER_UP_GAP: {the specific gap that prevented runner-up from winning}
EOF
  fi
}

# ---------- judge parsing ----------
extract_judge_vote() {
  local f="$1"
  grep -iE '^WINNER:[[:space:]]*[XYZ]' "$f" 2>/dev/null \
    | head -1 \
    | sed -E 's/^WINNER:[[:space:]]*([XYZ]).*/\1/I' \
    | tr 'a-z' 'A-Z' || true
}

extract_judge_runner_up() {
  local f="$1"
  grep -iE '^RUNNER-UP:[[:space:]]*[XYZ]' "$f" 2>/dev/null \
    | head -1 \
    | sed -E 's/^RUNNER-UP:[[:space:]]*([XYZ]).*/\1/I' \
    | tr 'a-z' 'A-Z' || true
}

# Label-map lookup without associative arrays.
# get_candidate_for_label X -> echoes "A" or "B" or "AB"
get_candidate_for_label() {
  case "$1" in
    X) echo "$label_x_cand" ;;
    Y) echo "$label_y_cand" ;;
    Z) echo "$label_z_cand" ;;
  esac
}

# get_file_for_candidate A -> echoes path to candidate file in current round
get_file_for_candidate() {
  case "$1" in
    A)  echo "$round_dir/candidate-A.txt" ;;
    B)  echo "$round_dir/candidate-B.txt" ;;
    AB) echo "$round_dir/candidate-AB.txt" ;;
  esac
}

# ---------- main loop ----------
incumbent=""
incumbent_file=""
round=0
consecutive_wins=0
last_winners=()
converged_reason=""

# Initialize lineage
: > "$run_dir/reason-lineage.jsonl"

# Selected judges (computed once)
judge_providers=()
while IFS= read -r jp; do
  judge_providers+=("$jp")
done < <(select_judges "$judges_n")

while : ; do
  round=$((round + 1))
  round_dir="$run_dir/round-$round"
  mkdir -p "$round_dir"
  echo "" >&2
  echo "=========================" >&2
  echo "[reason] Round $round" >&2
  echo "=========================" >&2

  # Phase 2: Generate-A
  echo "[round $round] Phase 2: Generate-A ($role_author_a)" >&2
  if [[ -z "$incumbent_file" ]]; then
    write_author_a_prompt "$round" "$round_dir/prompt-A.txt"
  else
    write_author_a_prompt "$round" "$round_dir/prompt-A.txt" "$incumbent_file"
  fi
  if ! call_adapter "$role_author_a" "$round_dir/prompt-A.txt" "$round_dir/candidate-A.txt"; then
    echo "[reason] author_a failed — see $round_dir/candidate-A.txt.err" >&2
    cat "$round_dir/candidate-A.txt.err" >&2
    exit 5
  fi
  echo "  → $(word_count "$round_dir/candidate-A.txt") words" >&2

  # Phase 3: Critic
  echo "[round $round] Phase 3: Critic ($role_critic)" >&2
  write_critic_prompt "$round_dir/candidate-A.txt" "$round_dir/prompt-critic.txt"
  if ! call_adapter "$role_critic" "$round_dir/prompt-critic.txt" "$round_dir/critique.txt"; then
    echo "[reason] critic failed — see $round_dir/critique.txt.err" >&2
    cat "$round_dir/critique.txt.err" >&2
    exit 5
  fi
  critic_weaknesses=$(grep -cE '^WEAKNESS-' "$round_dir/critique.txt" 2>/dev/null || echo 0)
  critic_weaknesses=${critic_weaknesses:-0}
  echo "  → $critic_weaknesses weaknesses raised" >&2

  # Phase 4: Generate-B
  echo "[round $round] Phase 4: Generate-B ($role_author_b)" >&2
  write_author_b_prompt "$round_dir/candidate-A.txt" "$round_dir/critique.txt" "$round_dir/prompt-B.txt"
  if ! call_adapter "$role_author_b" "$round_dir/prompt-B.txt" "$round_dir/candidate-B.txt"; then
    echo "[reason] author_b failed — see $round_dir/candidate-B.txt.err" >&2
    cat "$round_dir/candidate-B.txt.err" >&2
    exit 5
  fi
  echo "  → $(word_count "$round_dir/candidate-B.txt") words" >&2

  # Phase 5: Synthesize (skip in debate mode)
  ab_exists=0
  if [[ "$no_synthesis" == "0" ]]; then
    echo "[round $round] Phase 5: Synthesize-AB ($role_synthesizer)" >&2
    write_synthesizer_prompt "$round_dir/candidate-A.txt" "$round_dir/candidate-B.txt" "$round_dir/prompt-AB.txt"
    if call_adapter "$role_synthesizer" "$round_dir/prompt-AB.txt" "$round_dir/candidate-AB.txt"; then
      if [[ -s "$round_dir/candidate-AB.txt" ]]; then
        ab_exists=1
        echo "  → $(word_count "$round_dir/candidate-AB.txt") words" >&2
      else
        echo "  [warn] synthesizer returned empty body, falling back to debate for this round" >&2
      fi
    else
      echo "  [warn] synthesizer failed, falling back to debate for this round" >&2
      [[ -f "$round_dir/candidate-AB.txt.err" ]] && cat "$round_dir/candidate-AB.txt.err" >&2
    fi
  fi

  # Phase 6: Judge panel
  echo "[round $round] Phase 6: Judge panel (N=$judges_n)" >&2

  # Randomize label map this round
  perm_a=""; perm_b=""; perm_c=""
  if [[ "$ab_exists" == "1" ]]; then
    i=0
    while IFS= read -r line; do
      case $i in
        0) perm_a="$line" ;;
        1) perm_b="$line" ;;
        2) perm_c="$line" ;;
      esac
      i=$((i + 1))
    done < <(shuffle3)
    label_x_cand="$perm_a"
    label_y_cand="$perm_b"
    label_z_cand="$perm_c"
    debate_flag=0
  else
    i=0
    while IFS= read -r line; do
      case $i in
        0) perm_a="$line" ;;
        1) perm_b="$line" ;;
      esac
      i=$((i + 1))
    done < <(shuffle2)
    label_x_cand="$perm_a"
    label_y_cand="$perm_b"
    label_z_cand=""
    debate_flag=1
  fi

  # Save label map for transcripts
  if [[ "$ab_exists" == "1" ]]; then
    echo "X=$label_x_cand Y=$label_y_cand Z=$label_z_cand" > "$round_dir/label-map.txt"
  else
    echo "X=$label_x_cand Y=$label_y_cand" > "$round_dir/label-map.txt"
  fi

  # Copy to labeled files (judges see these, not A/B/AB)
  cp "$(get_file_for_candidate "$label_x_cand")" "$round_dir/labeled-X.txt"
  cp "$(get_file_for_candidate "$label_y_cand")" "$round_dir/labeled-Y.txt"
  if [[ "$ab_exists" == "1" ]]; then
    cp "$(get_file_for_candidate "$label_z_cand")" "$round_dir/labeled-Z.txt"
    write_judge_prompt "$round_dir/labeled-X.txt" "$round_dir/labeled-Y.txt" "$round_dir/labeled-Z.txt" "$round_dir/prompt-judge.txt" 0
  else
    : > "$round_dir/labeled-Z.txt"
    write_judge_prompt "$round_dir/labeled-X.txt" "$round_dir/labeled-Y.txt" "" "$round_dir/prompt-judge.txt" 1
  fi

  # Dispatch judges sequentially
  vote_count_A=0; vote_count_B=0; vote_count_AB=0
  judge_idx=0
  for jp in "${judge_providers[@]}"; do
    judge_idx=$((judge_idx + 1))
    judge_out="$round_dir/judge-${judge_idx}-${jp}.txt"
    echo "  [judge $judge_idx/${#judge_providers[@]}: $jp] ..." >&2
    if call_adapter "$jp" "$round_dir/prompt-judge.txt" "$judge_out"; then
      vote_label="$(extract_judge_vote "$judge_out")"
      if [[ -n "$vote_label" ]]; then
        winner_cand="$(get_candidate_for_label "$vote_label")"
        case "$winner_cand" in
          A)  vote_count_A=$((vote_count_A + 1)) ;;
          B)  vote_count_B=$((vote_count_B + 1)) ;;
          AB) vote_count_AB=$((vote_count_AB + 1)) ;;
        esac
        echo "    → voted $vote_label = $winner_cand" >&2
      else
        echo "    [warn] judge $judge_idx ($jp) abstained or malformed output" >&2
      fi
    else
      echo "    [warn] judge $judge_idx ($jp) FAILED" >&2
    fi
  done

  # Tally
  round_winner=""
  best_votes=-1
  for c in A B AB; do
    [[ "$c" == "AB" && "$ab_exists" == "0" ]] && continue
    case "$c" in
      A)  v=$vote_count_A ;;
      B)  v=$vote_count_B ;;
      AB) v=$vote_count_AB ;;
    esac
    if [[ "$v" -gt "$best_votes" ]]; then
      best_votes=$v
      round_winner=$c
    fi
  done

  # Detect tie among top
  same_top=0
  for c in A B AB; do
    [[ "$c" == "AB" && "$ab_exists" == "0" ]] && continue
    case "$c" in
      A)  v=$vote_count_A ;;
      B)  v=$vote_count_B ;;
      AB) v=$vote_count_AB ;;
    esac
    [[ "$v" -eq "$best_votes" ]] && same_top=$((same_top + 1))
  done

  if [[ "$same_top" -gt 1 ]]; then
    echo "  [tiebreak] runner-up votes" >&2
    runner_A=0; runner_B=0; runner_AB=0
    judge_idx=0
    for jp in "${judge_providers[@]}"; do
      judge_idx=$((judge_idx + 1))
      judge_out="$round_dir/judge-${judge_idx}-${jp}.txt"
      [[ -f "$judge_out" ]] || continue
      ru_label="$(extract_judge_runner_up "$judge_out")"
      if [[ -n "$ru_label" ]]; then
        ru_cand="$(get_candidate_for_label "$ru_label")"
        case "$ru_cand" in
          A)  runner_A=$((runner_A + 1)) ;;
          B)  runner_B=$((runner_B + 1)) ;;
          AB) runner_AB=$((runner_AB + 1)) ;;
        esac
      fi
    done
    best_ru=-1
    for c in A B AB; do
      [[ "$c" == "AB" && "$ab_exists" == "0" ]] && continue
      case "$c" in
        A)  v=$vote_count_A; r=$runner_A ;;
        B)  v=$vote_count_B; r=$runner_B ;;
        AB) v=$vote_count_AB; r=$runner_AB ;;
      esac
      [[ "$v" -ne "$best_votes" ]] && continue
      if [[ "$r" -gt "$best_ru" ]]; then
        best_ru=$r
        round_winner=$c
      fi
    done
    # Status quo bias if still tied
    if [[ -n "$incumbent" ]]; then
      still_tied=0
      for c in A B AB; do
        [[ "$c" == "AB" && "$ab_exists" == "0" ]] && continue
        case "$c" in
          A)  v=$vote_count_A; r=$runner_A ;;
          B)  v=$vote_count_B; r=$runner_B ;;
          AB) v=$vote_count_AB; r=$runner_AB ;;
        esac
        [[ "$v" -ne "$best_votes" ]] && continue
        [[ "$r" -eq "$best_ru" ]] && still_tied=$((still_tied + 1))
      done
      if [[ "$still_tied" -gt 1 ]]; then
        echo "  [tiebreak] status quo — incumbent ($incumbent) wins" >&2
        round_winner="$incumbent"
      fi
    fi
  fi

  echo "  → round $round winner: $round_winner (votes A=$vote_count_A B=$vote_count_B AB=$vote_count_AB)" >&2

  # Update incumbent + convergence
  if [[ -z "$incumbent" ]]; then
    incumbent="$round_winner"
    cp "$(get_file_for_candidate "$round_winner")" "$run_dir/current-incumbent.txt"
    incumbent_file="$run_dir/current-incumbent.txt"
    consecutive_wins=1
  elif [[ "$round_winner" == "$incumbent" ]]; then
    consecutive_wins=$((consecutive_wins + 1))
    # Promote the new round's winning text (could be improved version of incumbent type)
    cp "$(get_file_for_candidate "$round_winner")" "$run_dir/current-incumbent.txt"
  else
    incumbent="$round_winner"
    consecutive_wins=1
    cp "$(get_file_for_candidate "$round_winner")" "$run_dir/current-incumbent.txt"
  fi
  last_winners+=("$round_winner")

  # Lineage line
  words_a="$(word_count "$round_dir/candidate-A.txt")"
  words_b="$(word_count "$round_dir/candidate-B.txt")"
  words_ab=0
  [[ "$ab_exists" == "1" ]] && words_ab="$(word_count "$round_dir/candidate-AB.txt")"
  jq -n \
    --argjson round "$round" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson words_a "$words_a" \
    --argjson words_b "$words_b" \
    --argjson words_ab "$words_ab" \
    --arg label_x "$label_x_cand" \
    --arg label_y "$label_y_cand" \
    --arg label_z "$label_z_cand" \
    --argjson votes_a "$vote_count_A" \
    --argjson votes_b "$vote_count_B" \
    --argjson votes_ab "$vote_count_AB" \
    --arg round_winner "$round_winner" \
    --arg incumbent "$incumbent" \
    --argjson consec "$consecutive_wins" \
    --argjson critic_weaknesses "$critic_weaknesses" \
    '{
      round: $round, timestamp: $ts,
      candidate_A_words: $words_a, candidate_B_words: $words_b, candidate_AB_words: $words_ab,
      label_map: {X: $label_x, Y: $label_y, Z: $label_z},
      vote_tally: {A: $votes_a, B: $votes_b, AB: $votes_ab},
      round_winner: $round_winner, incumbent_after: $incumbent,
      consecutive_wins: $consec, critic_weaknesses: $critic_weaknesses
    }' >> "$run_dir/reason-lineage.jsonl"

  # TSV row
  printf "%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d\n" \
    "$round" "$round_winner" "$vote_count_A" "$vote_count_B" "$vote_count_AB" \
    "$words_a" "$words_b" "$words_ab" "$incumbent" "$consecutive_wins" \
    >> "$run_dir/reason-results.tsv"

  # Phase 7: Convergence check
  if [[ "$mode" == "convergent" && "$consecutive_wins" -ge "$convergence_n" ]]; then
    converged_reason="converged ($consecutive_wins consecutive wins by $incumbent)"
    break
  fi
  if [[ "$max_iterations" -gt 0 && "$round" -ge "$max_iterations" ]]; then
    converged_reason="bounded stop (max_iterations=$max_iterations reached)"
    break
  fi
  # Oscillation guard
  if [[ ${#last_winners[@]} -ge 5 ]]; then
    distinct=$(printf '%s\n' "${last_winners[@]: -5}" | sort -u | wc -l | tr -d ' ')
    if [[ "$distinct" -ge 3 && "$consecutive_wins" -lt 2 ]]; then
      converged_reason="oscillation detected — last 5 winners had $distinct distinct candidates"
      break
    fi
  fi
done

echo "" >&2
echo "[reason] STOP — $converged_reason" >&2

# ---------- final outputs ----------
final_incumbent="$incumbent"
final_round="$round"
final_text_file="$run_dir/current-incumbent.txt"

# overview.md
cat > "$run_dir/overview.md" <<EOF
# Reason run — $run_id

**Task**: $task
**Domain**: $domain
**Mode**: $mode
**Outcome**: $converged_reason
**Final winner**: $final_incumbent (round $final_round, $consecutive_wins consecutive wins)
**Rounds run**: $final_round
**Judge panel**: $judges_n (${judge_providers[*]:-})
**Convergence threshold**: $convergence_n consecutive wins

## Final winning candidate

\`\`\`
$(cat "$final_text_file")
\`\`\`

## Provider role assignments

| Role | Provider |
|---|---|
| Author-A | $role_author_a |
| Critic | $role_critic |
| Author-B | $role_author_b |
| Synthesizer | $role_synthesizer |
| Judges | ${judge_providers[*]:-} |

See \`reason-results.tsv\`, \`lineage.md\`, \`judge-transcripts.md\` for details.
EOF

# lineage.md
{
  echo "# Lineage — $run_id"
  echo ""
  echo "Round-by-round trace."
  echo ""
  echo "| Round | Winner | Votes (A/B/AB) | Words A/B/AB | Incumbent after | Consec wins |"
  echo "|---|---|---|---|---|---|"
  awk -F'\t' 'NR > 1 {
    printf "| %s | %s | %s/%s/%s | %s/%s/%s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
  }' "$run_dir/reason-results.tsv"
} > "$run_dir/lineage.md"

# candidates.md (final round only)
{
  echo "# Final-round candidates"
  echo ""
  for c in A B AB; do
    fp="$run_dir/round-$final_round/candidate-$c.txt"
    [[ -f "$fp" ]] || continue
    [[ ! -s "$fp" ]] && continue
    echo "## Candidate $c"
    echo ""
    echo '```'
    cat "$fp"
    echo '```'
    echo ""
  done
} > "$run_dir/candidates.md"

# judge-transcripts.md
{
  echo "# Judge transcripts"
  echo ""
  r=1
  while [[ "$r" -le "$final_round" ]]; do
    echo "## Round $r"
    echo ""
    if [[ -f "$run_dir/round-$r/label-map.txt" ]]; then
      echo '**Label map (revealed post-evaluation):**'
      echo '```'
      cat "$run_dir/round-$r/label-map.txt"
      echo '```'
      echo ""
    fi
    for jf in "$run_dir/round-$r"/judge-*.txt; do
      [[ -f "$jf" ]] || continue
      jname="$(basename "$jf" .txt)"
      echo "### $jname"
      echo ""
      echo '```'
      cat "$jf"
      echo '```'
      echo ""
    done
    r=$((r + 1))
  done
} > "$run_dir/judge-transcripts.md"

# handoff.json
converged_flag=false
case "$converged_reason" in
  converged*) converged_flag=true ;;
esac
final_text_content="$(cat "$final_text_file")"
chain_list="null"
if [[ -n "$chain" ]]; then
  chain_list="$(printf '%s' "$chain" | jq -Rs 'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$";""))')"
fi
jq -n \
  --arg version "1.0" \
  --arg tool "second-opinion:reason" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg task "$task" \
  --arg domain "$domain" \
  --arg mode "$mode" \
  --argjson rounds "$final_round" \
  --argjson converged "$converged_flag" \
  --argjson consec_wins "$consecutive_wins" \
  --arg final_winner "$final_incumbent" \
  --arg converged_text "$final_text_content" \
  --argjson final_words "$(word_count "$final_text_file")" \
  --arg lineage_path "$run_dir/reason-lineage.jsonl" \
  --argjson chain_list "$chain_list" \
  '{
    version: $version,
    tool: $tool,
    generated_at: $generated_at,
    task: $task,
    domain: $domain,
    mode: $mode,
    summary: {
      rounds_run: $rounds,
      converged: $converged,
      consecutive_wins: $consec_wins,
      final_winner: $final_winner
    },
    converged_candidate: {
      text: $converged_text,
      word_count: $final_words,
      won_in_round: $rounds
    },
    lineage_path: $lineage_path,
    chain_requested: $chain_list
  }' > "$run_dir/handoff.json"

# stdout summary
echo "=== provider: second-opinion:reason ==="
echo ""
echo "Task: $task"
echo "Outcome: $converged_reason"
echo "Final winner: $final_incumbent (round $final_round)"
echo "Rounds: $final_round | Judges: $judges_n (${judge_providers[*]:-})"
echo ""
echo "--- final candidate ---"
cat "$final_text_file"
echo ""
echo "--- run dir ---"
echo "$run_dir"
echo "=== end ==="
