#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CLI_BUILD_SCRIPT="$ROOT/build_cli.sh"
WORKSPACE_ROOT="$(cd "$ROOT/../.." && pwd)"
IME_DATA_ROOT="${FASTCHIME_IME_DATA_ROOT:-$WORKSPACE_ROOT/data/IME}"
CLI_BIN="$WORKSPACE_ROOT/bin/cli/UnifyIMECLI"
RETRAIN_SCRIPT="$ROOT/scripts/retrain_ranker.py"
INSTALL_SCRIPT="$ROOT/scripts/install_ranker_model.py"

DEFAULT_DATA_DIR="$IME_DATA_ROOT/x20"
DEFAULT_OUTPUT_DIR="$WORKSPACE_ROOT/bin/train/mlp_x20"
LOG_DIR="$WORKSPACE_ROOT/bin/train/test_train_logs"
ROUNDS=5

TRAIN_JSONL="${TRAIN_JSONL:-$DEFAULT_DATA_DIR/train.jsonl}"
VALID_JSONL="${VALID_JSONL:-$DEFAULT_DATA_DIR/valid.jsonl}"
TEST_JSONL="${TEST_JSONL:-$DEFAULT_DATA_DIR/test.jsonl}"
OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
BACKEND="${BACKEND:-mlp}"
EPOCHS="${EPOCHS:-24}"
BATCH_SIZE="${BATCH_SIZE:-128}"
LEARNING_RATE="${LEARNING_RATE:-0.001}"
NEIGHBOR_NOISE_WEIGHT="${NEIGHBOR_NOISE_WEIGHT:-0.35}"
BUILTIN_POSITIVE_BOOST="${BUILTIN_POSITIVE_BOOST:-1.5}"
BUILTIN_NEGATIVE_BOOST="${BUILTIN_NEGATIVE_BOOST:-1.05}"

mkdir -p "$LOG_DIR"

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

latest_model_path() {
  if [[ -f "$OUTPUT_DIR/CandidateRanker.mlpackage" ]]; then
    echo "$OUTPUT_DIR/CandidateRanker.mlpackage"
    return 0
  fi
  if [[ -f "$OUTPUT_DIR/CandidateRanker.mlmodel" ]]; then
    echo "$OUTPUT_DIR/CandidateRanker.mlmodel"
    return 0
  fi
  return 1
}

echo "[$(timestamp)] Building CLI binary..."
"$CLI_BUILD_SCRIPT"

for file in "$TRAIN_JSONL" "$VALID_JSONL" "$TEST_JSONL"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing dataset file: $file" >&2
    exit 2
  fi
done

echo "[$(timestamp)] Dataset:"
echo "  train=$TRAIN_JSONL"
echo "  valid=$VALID_JSONL"
echo "  test=$TEST_JSONL"
echo "[$(timestamp)] Output dir: $OUTPUT_DIR"
echo "[$(timestamp)] Rounds: $ROUNDS"

for round in $(seq 1 "$ROUNDS"); do
  ROUND_LOG="$LOG_DIR/round_${round}.log"
  SELFTEST_LOG="$LOG_DIR/round_${round}_selftest.log"
  RETRAIN_LOG="$LOG_DIR/round_${round}_retrain.log"

  {
    echo "========== ROUND $round/$ROUNDS =========="
    echo "started_at=$(timestamp)"

    if MODEL_PATH="$(latest_model_path)"; then
      echo "[install] source=$MODEL_PATH"
      python3 "$INSTALL_SCRIPT" "$MODEL_PATH"
    else
      echo "[install] no existing model found in $OUTPUT_DIR, skipping pre-install"
    fi

    echo "[selftest] running full summary"
    set +e
    "$CLI_BIN" selftest full --rounds 1 --summary-only | tee "$SELFTEST_LOG"
    SELFTEST_STATUS=$?
    set -e
    echo "[selftest] exit_status=$SELFTEST_STATUS"

    echo "[train] continue-from=$OUTPUT_DIR"
    python3 "$RETRAIN_SCRIPT" \
      --train "$TRAIN_JSONL" \
      --valid "$VALID_JSONL" \
      --test "$TEST_JSONL" \
      --output "$OUTPUT_DIR" \
      --backend "$BACKEND" \
      --epochs "$EPOCHS" \
      --batch-size "$BATCH_SIZE" \
      --learning-rate "$LEARNING_RATE" \
      --neighbor-noise-weight "$NEIGHBOR_NOISE_WEIGHT" \
      --builtin-positive-boost "$BUILTIN_POSITIVE_BOOST" \
      --builtin-negative-boost "$BUILTIN_NEGATIVE_BOOST" \
      --continue-from "$OUTPUT_DIR" \
      --install | tee "$RETRAIN_LOG"

    echo "ended_at=$(timestamp)"
  } | tee "$ROUND_LOG"
done

echo "[$(timestamp)] All rounds complete. Logs in $LOG_DIR"
