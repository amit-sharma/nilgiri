#!/usr/bin/env bash
#
# eval_sweep.sh -- run the Inspect "nilgiri" agent across a mixed set of
# OpenAI/Anthropic/OpenRouter-hosted models, N runs each, reverting the range
# to the clean snapshot before EVERY run (the range is shared mutable state).
#
# Provider routing is by model-slug prefix:
#   openai/*       -> uses OPENAI_API_KEY     (direct OpenAI)
#   anthropic/*    -> uses ANTHROPIC_API_KEY  (direct Anthropic)
#   openrouter/*   -> uses OPENROUTER_API_KEY (any model via OpenRouter)
# Anything else is rejected up front.
#
# Auth: export the relevant key(s) first (only those for providers present in
# the model list are required):
#   export OPENAI_API_KEY=sk-...
#   export ANTHROPIC_API_KEY=sk-ant-...
#   export OPENROUTER_API_KEY=sk-or-...
#
# Usage:
#   scripts/eval_sweep.sh [options]
#
# Options (all also settable via the env var shown in brackets):
#   -r, --runs N            runs per model                 [RUNS=3]
#   -t, --token-limit N     per-sample token budget; ""    [TOKEN_LIMIT=10000000]
#                           or "0" disables the cap
#   -m, --milestone M       start milestone, e.g. M5; ""   [MILESTONE=]
#                           runs the full M1-M9 range
#   -s, --snapshot NAME     clean snapshot to revert to    [SNAP_NAME=clean-eval]
#       --models "a b c"    space-separated model slugs    [MODELS=...]
#       --no-build          skip the one-time image build
#       --dry-run           print what would run, do nothing
#   -h, --help              this help
#
# Examples:
#   scripts/eval_sweep.sh
#   scripts/eval_sweep.sh -r 3 -t 20000000 -m M5
#   scripts/eval_sweep.sh --models "openai/gpt-5 anthropic/claude-opus-4.8"
#   scripts/eval_sweep.sh -r 3 -t 50000000 -m M5 --models anthropic/claude-opus-4.8
#   TOKEN_LIMIT=5000000 RUNS=1 scripts/eval_sweep.sh --dry-run
#
set -euo pipefail

# --- repo layout (mirrors the Makefile) -------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${VENV:-$REPO_ROOT/.venv}"
TASK_DIR="$REPO_ROOT/inspect/nilgiri"
DOCKER_HOST_REMOTE="${DOCKER_HOST_REMOTE:-ssh://kali@10.99.0.10}"
LOG_DIR="$TASK_DIR/sweep-logs"

# --- defaults (overridable by env, then flags) ------------------------------
RUNS="${RUNS:-3}"
TOKEN_LIMIT="${TOKEN_LIMIT-50000000}"   # note: TOKEN_LIMIT= (empty) disables
MILESTONE="${MILESTONE:-}"
SNAP_NAME="${SNAP_NAME:-clean-eval-easy}"
DO_BUILD=1
DRY_RUN=0

# Default mixed OpenAI + OpenRouter sweep. Override with --models / MODELS.
# Verify OpenAI slugs at https://platform.openai.com/docs/models and
# OpenRouter slugs at https://openrouter.ai/models if a run 404s.
MODELS="${MODELS:-\
openai/gpt-5.5 \
openrouter/z-ai/glm-5.2 \
openrouter/google/gemini-3.1-pro-preview}"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; s/^#$//' | sed '$d'; }

# --- arg parsing ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--runs)         RUNS="$2"; shift 2 ;;
    -t|--token-limit)  TOKEN_LIMIT="$2"; shift 2 ;;
    -m|--milestone)    MILESTONE="$2"; shift 2 ;;
    -s|--snapshot)     SNAP_NAME="$2"; shift 2 ;;
    --models)          MODELS="$2"; shift 2 ;;
    --no-build)        DO_BUILD=0; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; echo "Run with --help." >&2; exit 2 ;;
  esac
done

# --- build inspect arg fragments --------------------------------------------
# TOKEN_LIMIT empty or "0" => no cap.
TOKEN_LIMIT_ARG=()
if [[ -n "$TOKEN_LIMIT" && "$TOKEN_LIMIT" != "0" ]]; then
  TOKEN_LIMIT_ARG=(--token-limit "$TOKEN_LIMIT")
fi
MILESTONE_ARG=()
if [[ -n "$MILESTONE" ]]; then
  MILESTONE_ARG=(-T "start_milestone=$MILESTONE")
fi

# --- validate models + required keys ----------------------------------------
read -r -a MODEL_ARR <<< "$MODELS"
[[ ${#MODEL_ARR[@]} -gt 0 ]] || { echo "ERROR: no models specified" >&2; exit 2; }

need_openai=0
need_anthropic=0
need_openrouter=0
for m in "${MODEL_ARR[@]}"; do
  case "$m" in
    openai/*)     need_openai=1 ;;
    anthropic/*)  need_anthropic=1 ;;
    openrouter/*) need_openrouter=1 ;;
    *) echo "ERROR: model '$m' is not openai/*, anthropic/*, or openrouter/*; this script only handles those three providers" >&2; exit 2 ;;
  esac
done

if [[ $DRY_RUN -eq 0 ]]; then
  if [[ $need_openai -eq 1 && -z "${OPENAI_API_KEY:-}" ]]; then
    echo "ERROR: export OPENAI_API_KEY (sweep includes openai/* models)" >&2; exit 1
  fi
  if [[ $need_anthropic -eq 1 && -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "ERROR: export ANTHROPIC_API_KEY (sweep includes anthropic/* models)" >&2; exit 1
  fi
  if [[ $need_openrouter -eq 1 && -z "${OPENROUTER_API_KEY:-}" ]]; then
    echo "ERROR: export OPENROUTER_API_KEY (sweep includes openrouter/* models)" >&2; exit 1
  fi
fi

# --- plan summary -----------------------------------------------------------
total=$(( ${#MODEL_ARR[@]} * RUNS ))
echo "==============================================================="
echo " Inspect eval sweep"
echo "   models      : ${#MODEL_ARR[@]}  (${MODEL_ARR[*]})"
echo "   runs/model  : $RUNS   -> $total total episodes"
echo "   token limit : ${TOKEN_LIMIT:-<none>}${TOKEN_LIMIT:+ }"
echo "   milestone   : ${MILESTONE:-M1 (full range)}"
echo "   snapshot    : $SNAP_NAME"
echo "   docker host : $DOCKER_HOST_REMOTE"
echo "   logs        : $LOG_DIR"
[[ $DRY_RUN -eq 1 ]] && echo "   *** DRY RUN -- no commands will execute ***"
echo "==============================================================="

# --- one-time image build ---------------------------------------------------
if [[ $DO_BUILD -eq 1 ]]; then
  echo ">> building sandbox image (make eval-image-build)"
  [[ $DRY_RUN -eq 1 ]] || make -C "$REPO_ROOT" eval-image-build
fi

# --- the sweep --------------------------------------------------------------
run_idx=0
declare -i ok=0 fail=0
for m in "${MODEL_ARR[@]}"; do
  # pick the right key for this model's provider
  key_env=()
  case "$m" in
    openai/*)     key_env=(OPENAI_API_KEY="${OPENAI_API_KEY:-}") ;;
    anthropic/*)  key_env=(ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}") ;;
    openrouter/*) key_env=(OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}") ;;
  esac

  for r in $(seq 1 "$RUNS"); do
    run_idx=$((run_idx + 1))
    echo
    echo "---------------------------------------------------------------"
    echo ">> [$run_idx/$total] $m  (run $r/$RUNS)"
    echo "---------------------------------------------------------------"

    echo ">> reverting range to '$SNAP_NAME' snapshot before this run..."
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "   (dry-run) make -C $REPO_ROOT eval-clean SNAP_NAME=$SNAP_NAME"
    else
      if ! make -C "$REPO_ROOT" eval-clean SNAP_NAME="$SNAP_NAME"; then
        echo "ERROR: eval-clean failed before $m (run $r/$RUNS); aborting sweep" >&2
        exit 1
      fi
    fi

    echo ">> launching inspect episode..."
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "   (dry-run) cd $TASK_DIR && DOCKER_HOST=$DOCKER_HOST_REMOTE ${key_env[*]%%=*}=*** \\"
      echo "             $VENV/bin/inspect eval task.py --model $m ${TOKEN_LIMIT_ARG[*]} ${MILESTONE_ARG[*]}"
      ok=$((ok + 1))
      continue
    fi

    if ( cd "$TASK_DIR" && \
         DOCKER_HOST="$DOCKER_HOST_REMOTE" \
         env "${key_env[@]}" \
         "$VENV/bin/inspect" eval task.py \
           --model "$m" \
           "${TOKEN_LIMIT_ARG[@]}" \
           "${MILESTONE_ARG[@]}" ); then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
      echo "WARN: run $r/$RUNS for $m failed; continuing with next run" >&2
    fi
  done
done

echo
echo "==============================================================="
echo " Sweep complete: $ok ok, $fail failed, $total total"
echo " Browse results with:"
echo "   $VENV/bin/inspect view --log-dir $LOG_DIR"
echo "==============================================================="
[[ $fail -eq 0 ]]
