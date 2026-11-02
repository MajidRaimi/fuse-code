#!/usr/bin/env bash
set -euo pipefail

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly FIXTURE="$REPO_DIR/test/fixtures/models.json"
readonly PWSH="${PWSH:-pwsh}"
readonly JQ_ERROR_PREFIX="jq: error (at <unknown>): "

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/data/fuse-code" "$WORK_DIR/config" "$WORK_DIR/home"
cp "$REPO_DIR/models.tsv" "$REPO_DIR/slots.tsv" "$WORK_DIR/data/fuse-code/"
jq '{data: [.data[] | select(.id | test("embed"))]}' "$FIXTURE" >"$WORK_DIR/embed-only.json"

export HOME="$WORK_DIR/home" XDG_DATA_HOME="$WORK_DIR/data" XDG_CONFIG_HOME="$WORK_DIR/config"
unset CLAUDE_CONFIG_DIR FUSE_BIN_DIR FUSE_API_KEY FUSE_BASE_URL FUSE_THEME FUSE_DEFAULT_MODEL FUSE_SONNET_MODEL FUSE_SMALL_MODEL
source "$REPO_DIR/install.sh"

bash_plan() {
  local models_path="$1" output
  shift
  if output="$(plan_models "$(cat "$models_path")" "$@" 2>&1)"; then
    printf '%s\n' "$output"
  else
    printf 'error: %s\n' "${output#"$JQ_ERROR_PREFIX"}"
  fi
}

powershell_plan() {
  local models_path="$1"
  "$PWSH" -NoLogo -NoProfile -File "$REPO_DIR/test/print-plan.ps1" \
    -ModelsPath "$models_path" -Main "$2" -Sonnet "$3" -Small "$4" -Theme "$5" -VerifiedJson "$6"
}

failures=0
compare() {
  local name="$1"
  shift
  if diff -u <(bash_plan "$@") <(powershell_plan "$@") >"$WORK_DIR/diff"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name"
    sed 's/^/    | /' "$WORK_DIR/diff"
    failures=$((failures + 1))
  fi
}

compare 'defaults before probing' "$FIXTURE" '' '' '' dark null
compare 'only verified models after probing' "$FIXTURE" '' '' '' dark '["zai-org/GLM-5.3-Flash","Qwen/Qwen3.8-Flash-Next","acme/new-chat-9"]'
compare 'pinned slots with the light theme' "$FIXTURE" 'deepseek-ai/DeepSeek-V4.1-Flash' 'acme/new-chat-9' 'moonshotai/Kimi-K3[1m]' light null
compare 'a preset picked as the main model' "$FIXTURE" '@preset/team-coder' '' '' dark '["@preset/team-coder","Qwen/Qwen3.8-Flash-Next"]'
compare 'a pinned model that failed the check' "$FIXTURE" 'tarjama/llmx-1.0' '' '' dark '["moonshotai/Kimi-K3","tarjama/llmx-9"]'
compare 'nothing passed the check' "$FIXTURE" '' '' '' dark '[]'
compare 'no supported chat model' "$WORK_DIR/embed-only.json" '' '' '' dark null

printf 'parity: %d failed\n' "$failures"
[[ "$failures" -eq 0 ]]
