#!/usr/bin/env bash
set -euo pipefail

readonly SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_BASE_URL="https://api.fuse.humainaic.com"
readonly CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
readonly SHARE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fuse-code"
readonly ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/fuse/env"
readonly SAVED_BIN_DIR="$( { [[ -r "$ENV_FILE" ]] && ( . "$ENV_FILE" >/dev/null 2>&1; printf '%s' "${FUSE_BIN_DIR:-}" ); } || true )"
readonly BIN_DIR="${FUSE_BIN_DIR:-${SAVED_BIN_DIR:-$HOME/.local/bin}}"
readonly FUSE_SETTINGS="$CLAUDE_DIR/fuse/settings.json"
readonly THEMES_DIR="$CLAUDE_DIR/themes"
readonly LAUNCHER="$BIN_DIR/fuse"
readonly PROBE_LAUNCHER="$SHARE_DIR/bin/fuse"
readonly PROBE_SECONDS=150
readonly PROBE_PARALLEL=3
readonly MAIN_PREFERENCE="moonshotai/Kimi-K3 zai-org/GLM-5.3-Flash deepseek-ai/DeepSeek-V4.1-Flash zai-org/GLM-5.2 MiniMaxAI/MiniMax-M3"
readonly SONNET_PREFERENCE="zai-org/GLM-5.3-Flash moonshotai/Kimi-K3 deepseek-ai/DeepSeek-V4.1-Flash zai-org/GLM-5.2 MiniMaxAI/MiniMax-M3"
readonly SMALL_PREFERENCE="Qwen/Qwen3.8-Flash-Next Qwen/Qwen3.6-35B-A3B deepseek-ai/DeepSeek-V4.1-Flash MiniMaxAI/MiniMax-M3 zai-org/GLM-5.3-Flash"

readonly REQUESTED_KEY="${FUSE_API_KEY:-}"
readonly REQUESTED_BASE_URL="${FUSE_BASE_URL:-}"
readonly REQUESTED_THEME="${FUSE_THEME:-}"
readonly REQUESTED_MAIN="${FUSE_DEFAULT_MODEL:-}"
readonly REQUESTED_SONNET="${FUSE_SONNET_MODEL:-}"
readonly REQUESTED_SMALL="${FUSE_SMALL_MODEL:-}"

if [[ -t 1 ]]; then
  readonly GREEN=$'\033[38;2;1;208;153m' RED=$'\033[31m' DIM=$'\033[2m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
  readonly GREEN="" RED="" DIM="" BOLD="" RESET=""
fi

say() { printf '%s==>%s %s\n' "$GREEN" "$RESET" "$*"; }
note() { printf '    %s%s%s\n' "$DIM" "$*" "$RESET"; }
die() { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

has_tty() { { : </dev/tty; } 2>/dev/null; }

ask_yes() {
  local answer
  has_tty || return 1
  printf '%s [Y/n] ' "$1" >/dev/tty
  read -r answer </dev/tty || return 1
  [[ -z "$answer" || "$answer" == [Yy]* ]]
}

usage() {
  cat <<EOF
Usage: ./install.sh [option]

  (no option)          Install or repair fuse, reusing a saved key if there is one
  --refresh-models     Re-read the models your key can use and rebuild the /model list
  --reset-models       Same as --refresh-models, but pick the default models again
  --self-update        Pull the latest fuse-code from git and reinstall
  --uninstall          Remove fuse, its settings, themes and saved key

Environment overrides: FUSE_API_KEY, FUSE_BASE_URL, FUSE_THEME (dark or light),
FUSE_DEFAULT_MODEL, FUSE_SONNET_MODEL, FUSE_SMALL_MODEL.
EOF
}

saved_value() {
  [[ -r "$ENV_FILE" ]] || return 0
  ( set +u; . "$ENV_FILE" >/dev/null 2>&1; printf '%s' "${!1:-}" )
}

ensure_jq() {
  command -v jq >/dev/null && return 0
  if command -v brew >/dev/null; then
    say "Installing jq with Homebrew"
    brew install jq >/dev/null
  elif command -v apt-get >/dev/null && command -v sudo >/dev/null; then
    say "Installing jq with apt"
    sudo apt-get install -y jq >/dev/null
  fi
  command -v jq >/dev/null || die "jq is required. Install it (brew install jq, or apt install jq) and run this again."
}

claude_path() {
  command -v claude 2>/dev/null && return 0
  [[ -x "$HOME/.local/bin/claude" ]] && printf '%s\n' "$HOME/.local/bin/claude" && return 0
  return 1
}

ensure_claude() {
  claude_path >/dev/null && return 0
  ask_yes "Claude Code is not installed. Install it now with the official installer?" \
    || die "Install Claude Code first (https://claude.ai/install.sh) and run this again."
  curl -fsSL https://claude.ai/install.sh | bash
  claude_path >/dev/null || die "Claude Code still was not found after installing it."
}

resolve_api_key() {
  local key="$REQUESTED_KEY"
  [[ -n "$key" ]] || key="$(saved_value FUSE_API_KEY)"
  if [[ -z "$key" ]]; then
    has_tty || die "No FUSE API key. Run it as: FUSE_API_KEY=your-key ./install.sh"
    printf 'Paste your FUSE API key (input is hidden): ' >/dev/tty
    read -rs key </dev/tty
    printf '\n' >/dev/tty
  fi
  key="${key//[[:space:]]/}"
  [[ -n "$key" ]] || die "The FUSE API key is empty."
  printf '%s' "$key"
}

fetch_models() {
  local base_url="$1" key="$2" body status
  body="$(mktemp)"
  status="$(curl -sS -m 30 -o "$body" -w '%{http_code}' -K - "$base_url/v1/models" \
    <<<"header = \"Authorization: Bearer $key\"")" || { rm -f "$body"; die "Could not reach $base_url"; }
  case "$status" in
    200) cat "$body"; rm -f "$body" ;;
    401 | 403) rm -f "$body"; die "FUSE rejected that API key (HTTP $status)." ;;
    *) rm -f "$body"; die "FUSE answered HTTP $status when listing models." ;;
  esac
}

plan_models() {
  jq -n \
    --argjson models "$1" \
    --rawfile catalog "$SHARE_DIR/models.tsv" \
    --arg main "$2" --arg sonnet "$3" --arg small "$4" --arg theme "$5" \
    --argjson verified "$6" \
    --arg main_preference "$MAIN_PREFERENCE" \
    --arg sonnet_preference "$SONNET_PREFERENCE" \
    --arg small_preference "$SMALL_PREFERENCE" '
    def base: sub("\\[1m\\]$"; "");
    ($models.data | map({key: .id, value: .}) | from_entries) as $byId
    | ($catalog | split("\n") | map(select(length > 0) | split("\t") | {id: .[0], label: .[1], summary: .[2]})) as $known
    | def context_of($id): ($byId[$id].max_model_len // $byId[$byId[$id].preset.model // ""].max_model_len // 0);
      def context_label($id): context_of($id) as $n
        | if $n >= 1000000 then "1M" elif $n > 0 then "\($n / 1000 | floor)k" else "unknown" end;
      def usable($id): $byId[$id] != null and ($verified == null or ($verified | any(. == $id)));
      def reference($id): $id + (if context_of($id) >= 1000000 then "[1m]" else "" end);
      def chat_model($id): ($byId[$id].owned_by == "vllm")
        and (context_of($id) >= 200000)
        and ($id | test("embed|rerank|vision|translat|transcri|stt|tts|image|i2v|t2v"; "i") | not);
      def pick($current; $preference):
        ($current | base) as $wanted
        | if $wanted != "" and usable($wanted) then $wanted
          else first(($preference | split(" ")[]), $known[].id | select(usable(.))) // null end;
    pick($main; $main_preference) as $main_id
    | if $main_id == null then error(if $verified == null then "none of the supported chat models are enabled for this key" else "no model passed the Claude Code check" end) else . end
    | (pick($sonnet; $sonnet_preference) // $main_id) as $sonnet_id
    | (pick($small; $small_preference) // $main_id) as $small_id
    | ($known | map(.id)) as $known_ids
    | [
        ($known[] | select(usable(.id)) | {model: reference(.id), label, description: "Fuse, \(context_label(.id)) context, \(.summary)"}),
        ($models.data[].id as $id | select(($known_ids | any(. == $id) | not) and chat_model($id) and usable($id))
          | {model: reference($id), label: ($id | split("/") | last), description: "Fuse, \(context_label($id)) context, new on Fuse"})
      ] as $listed
    | ($listed | map(.model | base)) as $listed_ids
    | ($listed + [
        [$main_id, $sonnet_id, $small_id] | unique | .[] as $id | select($listed_ids | any(. == $id) | not)
        | if ($id | startswith("@preset/"))
          then {model: reference($id), label: ($byId[$id].preset.name // $id), description: "Fuse preset for \($byId[$id].preset.model // "a custom model")"}
          else {model: reference($id), label: ($id | split("/") | last), description: "Fuse, \(context_label($id)) context, your pick"} end
      ]) as $options
    | {
        main: reference($main_id),
        sonnet: reference($sonnet_id),
        small: reference($small_id),
        settings: {
          modelPicker: {replaceBuiltInOptions: true, options: $options},
          theme: (if $theme == "light" then "custom:fuse-light" else "custom:fuse" end),
          disableClaudeAiConnectors: true
        }
      }'
}

write_private_file() {
  local target="$1" tmp
  mkdir -p "$(dirname "$target")"
  tmp="$(mktemp "$target.XXXXXX")"
  cat >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$target"
}

write_env() {
  {
    printf 'FUSE_API_KEY=%q\n' "$2"
    printf 'FUSE_BASE_URL=%q\n' "$3"
    printf 'FUSE_THEME=%q\n' "$4"
    printf 'FUSE_DEFAULT_MODEL=%q\n' "$5"
    printf 'FUSE_SONNET_MODEL=%q\n' "$6"
    printf 'FUSE_SMALL_MODEL=%q\n' "$7"
    printf 'FUSE_BIN_DIR=%q\n' "$BIN_DIR"
  } | write_private_file "$1"
}

copy_payload() {
  [[ "$SOURCE_DIR" == "$SHARE_DIR" ]] && return 0
  mkdir -p "$SHARE_DIR/bin" "$SHARE_DIR/themes"
  cp "$SOURCE_DIR/install.sh" "$SOURCE_DIR/models.tsv" "$SHARE_DIR/"
  cp "$SOURCE_DIR/bin/fuse" "$SHARE_DIR/bin/fuse"
  cp "$SOURCE_DIR/themes/"*.json "$SHARE_DIR/themes/"
  chmod +x "$SHARE_DIR/install.sh" "$SHARE_DIR/bin/fuse"
  [[ -d "$SOURCE_DIR/.git" ]] && printf '%s\n' "$SOURCE_DIR" >"$SHARE_DIR/source-dir"
  return 0
}

install_launcher() {
  mkdir -p "$BIN_DIR"
  if [[ -e "$LAUNCHER" ]] && ! grep -q 'fuse-code' "$LAUNCHER" 2>/dev/null; then
    local backup="$LAUNCHER.bak-$(date +%Y%m%d%H%M%S)"
    mv "$LAUNCHER" "$backup"
    note "Your previous fuse command was saved as $backup"
  fi
  cp "$SHARE_DIR/bin/fuse" "$LAUNCHER"
  chmod +x "$LAUNCHER"
}

install_themes() {
  mkdir -p "$THEMES_DIR"
  cp "$SHARE_DIR/themes/fuse.json" "$SHARE_DIR/themes/fuse-light.json" "$THEMES_DIR/"
}

shell_rc() {
  case "$(basename "${SHELL:-}")" in
    zsh) printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) [[ "$(uname)" == "Darwin" ]] && printf '%s\n' "$HOME/.bash_profile" || printf '%s\n' "$HOME/.bashrc" ;;
    *) return 1 ;;
  esac
}

ensure_path() {
  case ":$PATH:" in *":$BIN_DIR:"*) return 0 ;; esac
  local rc line="export PATH=\"$BIN_DIR:\$PATH\""
  if rc="$(shell_rc)"; then
    grep -qsF "$line" "$rc" || printf '\n%s\n' "$line" >>"$rc"
    note "Added $BIN_DIR to your PATH in $rc. Open a new terminal before running fuse."
  else
    note "Add $BIN_DIR to your PATH to run fuse from anywhere."
  fi
}

configure() {
  local mode="$1" key base_url theme main sonnet small models plan verified
  key="$(resolve_api_key)"
  base_url="${REQUESTED_BASE_URL:-$(saved_value FUSE_BASE_URL)}"
  base_url="${base_url:-$DEFAULT_BASE_URL}"
  base_url="${base_url%/}"
  theme="${REQUESTED_THEME:-$(saved_value FUSE_THEME)}"
  [[ "$theme" == "light" ]] || theme="dark"

  if [[ "$mode" == "reset" ]]; then
    main="$REQUESTED_MAIN" sonnet="$REQUESTED_SONNET" small="$REQUESTED_SMALL"
  else
    main="${REQUESTED_MAIN:-$(saved_value FUSE_DEFAULT_MODEL)}"
    sonnet="${REQUESTED_SONNET:-$(saved_value FUSE_SONNET_MODEL)}"
    small="${REQUESTED_SMALL:-$(saved_value FUSE_SMALL_MODEL)}"
  fi

  say "Checking your key against $base_url"
  models="$(fetch_models "$base_url" "$key")"
  plan="$(build_plan "$models" "$main" "$sonnet" "$small" "$theme" null)" || exit 1

  say "Testing each model inside Claude Code"
  verified="$(verify_models "$plan" "$key" "$base_url" "$theme")"
  plan="$(build_plan "$models" "$main" "$sonnet" "$small" "$theme" "$verified")" || exit 1
  save_plan "$plan" "$key" "$base_url" "$theme" "$ENV_FILE" "$FUSE_SETTINGS"
  main="$(jq -r .main <<<"$plan")"
  sonnet="$(jq -r .sonnet <<<"$plan")"
  small="$(jq -r .small <<<"$plan")"

  say "Models"
  note "main   $main"
  note "sonnet $sonnet"
  note "small  $small"
  note "/model $(jq -r '[.settings.modelPicker.options[].label] | join(", ")' <<<"$plan")"

}

build_plan() {
  local plan
  plan="$(plan_models "$@" 2>&1)" || die "${plan#jq: error (at <unknown>): }"
  printf '%s\n' "$plan"
}

save_plan() {
  local plan="$1"
  write_env "$5" "$2" "$3" "$4" "$(jq -r .main <<<"$plan")" "$(jq -r .sonnet <<<"$plan")" "$(jq -r .small <<<"$plan")"
  jq .settings <<<"$plan" | write_private_file "$6"
}

run_with_deadline() {
  if command -v perl >/dev/null; then
    perl -e '
      my $seconds = shift;
      my $pid = fork() // exit 125;
      if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127; }
      local $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 2; kill "KILL", -$pid; exit 124; };
      alarm $seconds;
      waitpid($pid, 0);
      exit($? >> 8);
    ' "$PROBE_SECONDS" "$@"
  else
    "$@"
  fi
}

probe_model() {
  local reference="$1" log="$2"
  (
    cd "$PROBE_DIR/work"
    export FUSE_ENV_FILE="$PROBE_DIR/env" FUSE_SETTINGS_FILE="$PROBE_DIR/settings.json"
    run_with_deadline "$PROBE_LAUNCHER" --model "$reference" --no-session-persistence \
      --strict-mcp-config --setting-sources project \
      -p "Reply with the single word ok" </dev/null >"$log" 2>&1
  ) && ! grep -q "API Error" "$log"
}

verify_models() {
  local plan="$1" reference references index=0 passed="[]" project_key
  PROBE_DIR="$(mktemp -d)"
  mkdir -p "$PROBE_DIR/work"
  save_plan "$plan" "$2" "$3" "$4" "$PROBE_DIR/env" "$PROBE_DIR/settings.json"
  references="$(jq -r '.settings.modelPicker.options[].model' <<<"$plan")"
  while IFS= read -r reference; do
    index=$((index + 1))
    ( probe_model "$reference" "$PROBE_DIR/$index.log" && : >"$PROBE_DIR/$index.ok" ) &
    if (( index % PROBE_PARALLEL == 0 )); then wait; fi
  done <<<"$references"
  wait
  index=0
  while IFS= read -r reference; do
    index=$((index + 1))
    if [[ -f "$PROBE_DIR/$index.ok" ]]; then
      passed="$(jq -c --arg id "${reference%\[1m\]}" '. + [$id]' <<<"$passed")"
    else
      note "Skipping $reference: $(grep -m1 -E 'API Error|rror' "$PROBE_DIR/$index.log" 2>/dev/null || printf 'no answer')" >&2
    fi
  done <<<"$references"
  project_key="$(cd "$PROBE_DIR/work" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
  rm -rf "$PROBE_DIR" "$CLAUDE_DIR/projects/$project_key"
  printf '%s\n' "$passed"
}

install() {
  ensure_jq
  ensure_claude
  copy_payload
  install_launcher
  install_themes
  configure keep
  "$LAUNCHER" --version >/dev/null 2>&1 || note "Warning: fuse --version failed. Run it to see why."
  ensure_path
  printf '\n%sDone.%s Run %sfuse%s to start Claude Code on FUSE.\n' "$GREEN$BOLD" "$RESET" "$BOLD" "$RESET"
  note "Refresh the model list any time with: fuse --refresh-models"
}

refresh_models() {
  ensure_jq
  [[ -r "$ENV_FILE" ]] || die "fuse is not installed yet. Run ./install.sh first."
  configure "$1"
  say "Model list updated. Restart any open fuse sessions to see it."
}

self_update() {
  local source=""
  [[ -r "$SHARE_DIR/source-dir" ]] && source="$(cat "$SHARE_DIR/source-dir")"
  [[ -n "$source" && -d "$source/.git" ]] || die "Could not find the fuse-code git clone. Clone it again and run ./install.sh."
  say "Pulling the latest fuse-code into $source"
  git -C "$source" pull --ff-only
  exec bash "$source/install.sh"
}

uninstall() {
  ask_yes "Remove fuse, its settings, themes and saved FUSE key?" || die "Cancelled."
  [[ -x "$PROBE_LAUNCHER" ]] && "$PROBE_LAUNCHER" --version >/dev/null 2>&1 || true
  if [[ -e "$LAUNCHER" ]] && grep -q 'fuse-code' "$LAUNCHER" 2>/dev/null; then
    rm -f "$LAUNCHER"
  fi
  rm -rf "$CLAUDE_DIR/fuse" "$SHARE_DIR"
  rm -f "$THEMES_DIR/fuse.json" "$THEMES_DIR/fuse-light.json" "$ENV_FILE"
  rmdir "$(dirname "$ENV_FILE")" 2>/dev/null || true
  say "fuse is uninstalled. Your regular Claude Code setup was not touched."
}

main() {
  case "${1:-}" in
    "") install ;;
    --refresh-models) refresh_models keep ;;
    --reset-models) refresh_models reset ;;
    --self-update) self_update ;;
    --uninstall) uninstall ;;
    -h | --help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
