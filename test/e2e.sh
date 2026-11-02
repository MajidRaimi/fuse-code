#!/usr/bin/env bash
set -uo pipefail

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MOCK_KEY="test-fuse-key"
readonly WRONG_KEY="wrong-key"
readonly MOCK_READY_SECONDS=30
readonly COMMAND_DEADLINE_SECONDS=900
readonly SESSION_DEADLINE_SECONDS=240
readonly LOG_TAIL_LINES=40
readonly REQUESTED_MOCK_LOG="${E2E_MOCK_LOG:-}"
readonly DEFAULT_MAIN_MODEL="moonshotai/Kimi-K3[1m]"
readonly DEFAULT_SONNET_MODEL="zai-org/GLM-5.3-Flash[1m]"
readonly DEFAULT_SMALL_MODEL="Qwen/Qwen3.8-Flash-Next"
readonly PINNED_MAIN_MODEL="deepseek-ai/DeepSeek-V4.1-Flash"
readonly REJECTED_MODEL="tarjama/llmx-1.0"
readonly EXPECTED_OPTION_MODELS='["moonshotai/Kimi-K3[1m]","zai-org/GLM-5.3-Flash[1m]","deepseek-ai/DeepSeek-V4.1-Flash","Qwen/Qwen3.8-Flash-Next","acme/new-chat-9"]'

WORK_DIR=""
MOCK_PID=""
MOCK_URL=""
FAILURE_DETAIL=""
FAILURES=0
PASSES=0

cleanup() {
  if [[ -n "$MOCK_PID" ]]; then
    kill "$MOCK_PID" 2>/dev/null
    wait "$MOCK_PID" 2>/dev/null
  fi
  if [[ -n "$WORK_DIR" ]]; then
    [[ -n "$REQUESTED_MOCK_LOG" && -f "$WORK_DIR/mock.log" ]] && cp "$WORK_DIR/mock.log" "$REQUESTED_MOCK_LOG"
    rm -rf "$WORK_DIR"
  fi
  return 0
}

abort() {
  printf 'e2e: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || abort "$1 is required on PATH"
}

unset_matching_variables() {
  local name
  for name in $(compgen -e); do
    case "$name" in
      FUSE_* | ANTHROPIC_* | CLAUDE* | XDG_*_HOME) unset "$name" ;;
    esac
  done
}

isolate_environment() {
  local claude_bin
  claude_bin="$(command -v claude)"
  WORK_DIR="$(mktemp -d)"
  WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
  mkdir -p "$WORK_DIR/home" "$WORK_DIR/tools" "$WORK_DIR/project" "$WORK_DIR/logs"
  ln -s "$claude_bin" "$WORK_DIR/tools/claude"
  unset_matching_variables
  export HOME="$WORK_DIR/home"
  export SHELL=/bin/bash
  export PATH="$WORK_DIR/tools:$PATH"
  export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"
  export no_proxy="$NO_PROXY"
}

start_mock() {
  local attempt
  MOCK_FUSE_PORT=0 MOCK_FUSE_KEY="$MOCK_KEY" MOCK_FUSE_LOG=1 \
    bun "$REPO_DIR/test/mock-fuse.ts" </dev/null >"$WORK_DIR/mock.out" 2>"$WORK_DIR/mock.log" &
  MOCK_PID=$!
  for ((attempt = 0; attempt < MOCK_READY_SECONDS * 10; attempt++)); do
    MOCK_URL="$(sed -n 's|^mock-fuse listening on \(http://127\.0\.0\.1:[0-9][0-9]*\)$|\1|p' "$WORK_DIR/mock.out")"
    [[ -n "$MOCK_URL" ]] && return 0
    kill -0 "$MOCK_PID" 2>/dev/null || break
    sleep 0.1
  done
  cat "$WORK_DIR/mock.out" "$WORK_DIR/mock.log" >&2
  abort "the mock FUSE server did not start"
}

run_with_deadline() {
  perl -e 'alarm shift; exec @ARGV or exit 127' "$@"
}

run_logged() {
  local name="$1" deadline="$2"
  shift 2
  run_with_deadline "$deadline" "$@" </dev/null >"$WORK_DIR/logs/$name.log" 2>&1
}

run_installer() {
  local name="$1"
  shift
  (cd "$REPO_DIR" && run_logged "$name" "$COMMAND_DEADLINE_SECONDS" env "$@" ./install.sh)
}

run_fuse() {
  local name="$1"
  shift
  (cd "$WORK_DIR/project" && run_logged "$name" "$COMMAND_DEADLINE_SECONDS" env "$@")
}

log_tail() {
  tail -n "$LOG_TAIL_LINES" "$WORK_DIR/logs/$1.log" 2>/dev/null
}

fail_with() {
  FAILURE_DETAIL="$1"
  return 1
}

fail_with_log() {
  fail_with "$(printf '%s\nlog %s:\n%s' "$1" "$2" "$(log_tail "$2")")"
}

assert() {
  local name="$1"
  shift
  FAILURE_DETAIL=""
  if "$@"; then
    PASSES=$((PASSES + 1))
    printf 'ok - %s\n' "$name"
  else
    FAILURES=$((FAILURES + 1))
    printf 'not ok - %s\n' "$name"
    [[ -n "$FAILURE_DETAIL" ]] && printf '%s\n' "$FAILURE_DETAIL" | sed 's/^/    | /'
  fi
  return 0
}

env_file() {
  printf '%s\n' "$HOME/.config/fuse/env"
}

fuse_settings() {
  printf '%s\n' "$HOME/.claude/fuse/settings.json"
}

user_settings() {
  printf '%s\n' "$HOME/.claude/settings.json"
}

launcher() {
  printf '%s\n' "$HOME/.local/bin/fuse"
}

saved_env_value() {
  (
    set +u
    . "$(env_file)" >/dev/null 2>&1
    printf '%s' "${!1:-}"
  )
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

expect_env_value() {
  local name="$1" expected="$2" actual
  actual="$(saved_env_value "$name")"
  [[ "$actual" == "$expected" ]] || fail_with "$name is '$actual', expected '$expected'"
}

expect_settings() {
  local filter="$1"
  jq -e "$filter" "$(fuse_settings)" >/dev/null 2>&1 \
    || fail_with "$(printf 'fuse settings do not satisfy %s:\n%s' "$filter" "$(cat "$(fuse_settings)" 2>&1)")"
}

expect_log_contains() {
  grep -qF -- "$2" "$WORK_DIR/logs/$1.log" || fail_with_log "output does not contain '$2'" "$1"
}

check_first_install() {
  run_installer first-install "FUSE_API_KEY=$MOCK_KEY" "FUSE_BASE_URL=$MOCK_URL" \
    || fail_with_log "install.sh exited with status $?" first-install || return 1
  expect_log_contains first-install "Skipping $REJECTED_MODEL"
}

check_env_file() {
  local mode
  [[ -f "$(env_file)" ]] || fail_with "$(env_file) does not exist" || return 1
  mode="$(file_mode "$(env_file)")"
  [[ "$mode" == "600" ]] || fail_with "$(env_file) has mode $mode, expected 600" || return 1
  grep -qF -- "$MOCK_KEY" "$(env_file)" || fail_with "$(env_file) does not contain the API key" || return 1
  expect_env_value FUSE_API_KEY "$MOCK_KEY"
}

check_models_configured() {
  local option_models
  expect_settings '.theme == "custom:fuse"' || return 1
  expect_settings '.disableClaudeAiConnectors == true' || return 1
  option_models="$(jq -c '[.modelPicker.options[].model]' "$(fuse_settings)" 2>&1)"
  [[ "$option_models" == "$EXPECTED_OPTION_MODELS" ]] \
    || fail_with "option models are $option_models, expected $EXPECTED_OPTION_MODELS" || return 1
  expect_env_value FUSE_DEFAULT_MODEL "$DEFAULT_MAIN_MODEL" || return 1
  expect_env_value FUSE_SONNET_MODEL "$DEFAULT_SONNET_MODEL" || return 1
  expect_env_value FUSE_SMALL_MODEL "$DEFAULT_SMALL_MODEL"
}

check_themes_installed() {
  local theme
  for theme in fuse.json fuse-light.json; do
    [[ -f "$HOME/.claude/themes/$theme" ]] || fail_with "$HOME/.claude/themes/$theme does not exist" || return 1
  done
}

check_session_answers() {
  local status=0 transcript
  (cd "$WORK_DIR/project" && run_with_deadline "$SESSION_DEADLINE_SECONDS" "$(launcher)" -p "Reply with the single word ok") \
    </dev/null >"$WORK_DIR/logs/session.out" 2>"$WORK_DIR/logs/session.log" || status=$?
  transcript="$(printf 'stdout:\n%s\nstderr:\n%s' "$(cat "$WORK_DIR/logs/session.out")" "$(log_tail session)")"
  [[ "$status" -eq 0 ]] || fail_with "$(printf 'fuse -p exited with status %s\n%s' "$status" "$transcript")" || return 1
  grep -qx 'ok' "$WORK_DIR/logs/session.out" || fail_with "$(printf 'fuse -p did not print ok\n%s' "$transcript")"
}

write_user_settings() {
  mkdir -p "$(dirname "$(user_settings)")"
  printf '%s\n' "$1" >"$(user_settings)"
}

run_fuse_version() {
  run_fuse "$1" "$(launcher)" --version || fail_with_log "fuse --version exited with status $?" "$1"
}

check_guard_removes_leftovers() {
  local settings_after
  write_user_settings "{\"model\":\"$DEFAULT_MAIN_MODEL\",\"theme\":\"custom:fuse\",\"permissions\":{\"allow\":[\"Bash(ls)\"]}}"
  run_fuse_version guard-leftovers || return 1
  settings_after="$(cat "$(user_settings)" 2>&1)"
  jq -e '(has("model") | not) and (has("theme") | not) and .permissions == {"allow":["Bash(ls)"]}' \
    <<<"$settings_after" >/dev/null 2>&1 || fail_with "user settings after fuse --version: $settings_after"
}

check_guard_keeps_user_choices() {
  local original='{"model":"opus","theme":"dark"}' settings_after
  write_user_settings "$original"
  run_fuse_version guard-own-values || return 1
  settings_after="$(cat "$(user_settings)" 2>&1)"
  jq -e --argjson expected "$original" '. == $expected' <<<"$settings_after" >/dev/null 2>&1 \
    || fail_with "user settings changed to: $settings_after"
}

refresh() {
  local name="$1"
  shift
  run_fuse "$name" "$@" "$(launcher)" --refresh-models
}

check_light_theme_refresh() {
  refresh refresh-light FUSE_THEME=light || fail_with_log "fuse --refresh-models exited with status $?" refresh-light || return 1
  expect_settings '.theme == "custom:fuse-light"' || return 1
  expect_env_value FUSE_THEME light
}

check_wrong_key_rejected() {
  if refresh refresh-wrong-key "FUSE_API_KEY=$WRONG_KEY"; then
    fail_with_log "fuse --refresh-models succeeded with a wrong key" refresh-wrong-key
    return 1
  fi
  expect_log_contains refresh-wrong-key "rejected" || return 1
  expect_env_value FUSE_API_KEY "$MOCK_KEY"
}

check_pinned_main_model() {
  refresh refresh-pinned "FUSE_DEFAULT_MODEL=$PINNED_MAIN_MODEL" \
    || fail_with_log "fuse --refresh-models exited with status $?" refresh-pinned || return 1
  expect_env_value FUSE_DEFAULT_MODEL "$PINNED_MAIN_MODEL"
}

check_reset_models() {
  run_fuse reset-models "$(launcher)" --reset-models \
    || fail_with_log "fuse --reset-models exited with status $?" reset-models || return 1
  expect_env_value FUSE_DEFAULT_MODEL "$DEFAULT_MAIN_MODEL"
}

check_reinstall_reuses_key() {
  run_installer reinstall || fail_with_log "install.sh exited with status $?" reinstall
}

run_assertions() {
  assert "install.sh succeeds and skips $REJECTED_MODEL" check_first_install
  assert "env file exists with mode 600 and holds the key" check_env_file
  assert "fuse settings and env file hold the verified models" check_models_configured
  assert "dark and light themes are installed" check_themes_installed
  assert "fuse -p answers ok through the mock" check_session_answers
  assert "guard removes fuse model and theme left in user settings" check_guard_removes_leftovers
  assert "guard keeps the user's own model and theme" check_guard_keeps_user_choices
  assert "FUSE_THEME=light refresh switches to the light theme" check_light_theme_refresh
  assert "refresh with a wrong key is rejected and keeps the saved key" check_wrong_key_rejected
  assert "FUSE_DEFAULT_MODEL pins the main model on refresh" check_pinned_main_model
  assert "fuse --reset-models restores the default main model" check_reset_models
  assert "install.sh again without FUSE_API_KEY reuses the saved key" check_reinstall_reuses_key
}

main() {
  require_command claude
  require_command bun
  require_command jq
  require_command perl
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  isolate_environment
  start_mock
  printf 'e2e: mock FUSE at %s, claude %s\n' "$MOCK_URL" "$(claude --version 2>/dev/null)"
  run_assertions
  printf 'e2e: %s passed, %s failed\n' "$PASSES" "$FAILURES"
  [[ "$FAILURES" -eq 0 ]]
}

main "$@"
