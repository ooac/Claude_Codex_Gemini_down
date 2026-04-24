#!/usr/bin/env bash
set -euo pipefail

# 统一管理 Claude / Codex / Gemini：
# - check：只检查当前版本与最新版本
# - fix：修复损坏的安装和命令入口
# - update：升级到最新版本并修复入口

NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
NPM_CACHE="${NPM_CACHE:-$HOME/.cache/ai-toolchain-npm}"
NPM_GLOBAL_PREFIX="${NPM_GLOBAL_PREFIX:-$HOME/.npm-global}"
CLAUDE_PREFIX="${CLAUDE_PREFIX:-$HOME/.claude/local-user}"
LOCAL_BIN_DIR="${LOCAL_BIN_DIR:-$HOME/.local/bin}"
SYSTEM_BIN_DIR="${SYSTEM_BIN_DIR:-/opt/homebrew/bin}"

CLAUDE_APP_LINK="$HOME/.claude/local/claude"
USE_COLOR=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  USE_COLOR=1
fi

ANSI_RESET=$'\033[0m'
ANSI_BOLD=$'\033[1m'
ANSI_DIM=$'\033[2m'
ANSI_RED=$'\033[31m'
ANSI_GREEN=$'\033[32m'
ANSI_YELLOW=$'\033[33m'
ANSI_CYAN=$'\033[36m'
ANSI_GRAY=$'\033[90m'

color() {
  if [ "$USE_COLOR" -eq 1 ]; then
    printf '%s%s%s' "$1" "$2" "$3"
  else
    printf '%s' "$2"
  fi
}

line_color_for_status() {
  case "$1" in
    已是最新|无需处理)
      printf '%s' "$ANSI_GREEN"
      ;;
    本地更新|可更新)
      printf '%s' "$ANSI_YELLOW"
      ;;
    不可执行|未安装)
      printf '%s' "$ANSI_RED"
      ;;
    *)
      printf '%s' "$ANSI_CYAN"
      ;;
  esac
}

status_display_text() {
  case "$1" in
    已是最新|无需处理)
      printf '✓ %s' "$1"
      ;;
    本地更新|可更新)
      printf '↻ %s' "$1"
      ;;
    不可执行|未安装)
      printf '⚠ %s' "$1"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

repeat_char() {
  local char="$1"
  local count="$2"
  local out
  printf -v out '%*s' "$count" ''
  out="${out// /$char}"
  printf '%s' "$out"
}

display_width() {
  python3 - "$1" <<'PY'
import sys
import unicodedata

text = sys.argv[1]
width = 0
for ch in text:
    if unicodedata.combining(ch):
        continue
    if unicodedata.east_asian_width(ch) in ("F", "W"):
        width += 2
    else:
        width += 1
print(width)
PY
}

pad_display() {
  local text="$1"
  local target_width="$2"
  local align="${3:-left}"
  local actual_width pad_count pad_char

  actual_width="$(display_width "$text")"
  if [ "$actual_width" -ge "$target_width" ]; then
    printf '%s' "$text"
    return 0
  fi

  pad_count=$((target_width - actual_width))
  pad_char=' '
  if [ "$align" = "right" ]; then
    printf '%*s%s' "$pad_count" '' "$text"
  else
    printf '%s%*s' "$text" "$pad_count" ''
  fi
}

card_row() {
  local label="$1"
  local value="$2"
  local label_color="${3:-$ANSI_GRAY}"
  local value_color="${4:-$ANSI_CYAN$ANSI_BOLD}"
  local border_color="${5:-$ANSI_CYAN}"
  local label_width=6
  local inner_width=30
  local value_width=$((inner_width - label_width - 1))
  local label_text value_text

  label_text="$(pad_display "$label" "$label_width")"
  value_text="$(pad_display "$value" "$value_width")"

  printf '%s%s %s%s' \
    "$(color "$border_color" "│" "$ANSI_RESET")" \
    "$(color "$label_color" "$label_text" "$ANSI_RESET")" \
    "$(color "$value_color" "$value_text" "$ANSI_RESET")" \
    "$(color "$border_color" "│" "$ANSI_RESET")"
}

usage() {
  cat <<'EOF'
用法：
  scripts/ai-toolchain-manager.sh [snapshot|check|fix|update|all]

说明：
  snapshot 输出当前三项工具的摘要和建议，适合启动前预览
  check   只检查当前版本、最新版本和可执行状态
  fix     修复损坏的入口或缺失的安装，不主动升级
  update  升级到最新版本，并修复入口
  all     一键执行：check -> fix -> update -> check

可选环境变量：
  NPM_REGISTRY=https://registry.npmjs.org
  NPM_CACHE=~/.cache/ai-toolchain-npm
  NPM_GLOBAL_PREFIX=~/.npm-global
  CLAUDE_PREFIX=~/.claude/local-user
EOF
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

extract_version() {
  printf '%s\n' "$1" | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n 1 || true
}

semver_cmp() {
  local a b
  IFS='.' read -r -a a <<<"${1:-0.0.0}"
  IFS='.' read -r -a b <<<"${2:-0.0.0}"
  local i
  for i in 0 1 2; do
    local ai="${a[i]:-0}"
    local bi="${b[i]:-0}"
    if ((10#$ai > 10#$bi)); then
      printf '1\n'
      return 0
    fi
    if ((10#$ai < 10#$bi)); then
      printf '-1\n'
      return 0
    fi
  done
  printf '0\n'
}

latest_version() {
  local pkg="$1"
  npm view "${pkg}" version --registry "$NPM_REGISTRY" 2>/dev/null | tail -n 1 | tr -d '[:space:]'
}

installed_pkg_version() {
  local path="$1"
  node -p "require('${path}/package.json').version" 2>/dev/null || true
}

ensure_link() {
  local link_path="$1"
  local target_path="$2"
  mkdir -p "$(dirname "$link_path")"
  ln -sfn "$target_path" "$link_path"
}

probe_tool() {
  local cmd="$1"
  local output version path
  path="$(command -v "$cmd" 2>/dev/null || true)"
  if [ -z "$path" ]; then
    printf 'missing||\n'
    return 0
  fi
  if ! output="$("$cmd" --version 2>&1)"; then
    printf 'broken|%s|\n' "$path"
    return 0
  fi
  version="$(extract_version "$output")"
  if [ -z "$version" ]; then
    printf 'broken|%s|\n' "$path"
    return 0
  fi
  printf 'ok|%s|%s\n' "$path" "$version"
}

status_and_tip() {
  local state="$1"
  local current="$2"
  local latest="$3"
  local cmp
  case "$state" in
    ok)
      cmp="$(semver_cmp "$current" "$latest")"
      case "$cmp" in
        0) printf '已是最新|无需处理\n' ;;
        1) printf '本地更新|可保留当前版本\n' ;;
        -1) printf '可更新|建议执行 update\n' ;;
        *) printf '未知|先执行 check\n' ;;
      esac
      ;;
    broken)
      printf '不可执行|建议先执行 fix\n'
      ;;
    missing)
      printf '未安装|建议先执行 fix\n'
      ;;
    *)
      printf '未知|建议先执行 check\n'
      ;;
  esac
}

ensure_claude_native() {
  local version="$1"
  local native_dir="$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code/node_modules/@anthropic-ai/claude-code-darwin-arm64"
  local native_bin="$native_dir/claude"
  if [ -x "$native_bin" ]; then
    return 0
  fi

  local tarball tmpdir
  tarball="$(npm view "@anthropic-ai/claude-code-darwin-arm64@${version}" dist.tarball --registry "$NPM_REGISTRY" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
  [ -n "$tarball" ] || die "无法获取 Claude 原生包的 tarball 地址：${version}"

  tmpdir="$(mktemp -d)"
  mkdir -p "$native_dir"
  curl -fsSL "$tarball" -o "$tmpdir/pkg.tgz"
  rm -rf "$native_dir"
  mkdir -p "$native_dir"
  tar -xzf "$tmpdir/pkg.tgz" -C "$native_dir" --strip-components=1
  chmod 755 "$native_bin"
  rm -rf "$tmpdir"
}

install_claude() {
  local version="$1"
  mkdir -p "$CLAUDE_PREFIX"
  if [ ! -f "$CLAUDE_PREFIX/package.json" ]; then
    (cd "$CLAUDE_PREFIX" && npm init -y >/dev/null)
  fi

  rm -rf "$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code"
  (cd "$CLAUDE_PREFIX" && npm install "@anthropic-ai/claude-code@${version}" --registry "$NPM_REGISTRY" --cache "$NPM_CACHE" >/dev/null)
  ensure_claude_native "$version"
  (cd "$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code" && node install.cjs >/dev/null)
}

install_global_pkg() {
  local pkg="$1"
  local version="$2"
  npm install -g "${pkg}@${version}" --prefix "$NPM_GLOBAL_PREFIX" --registry "$NPM_REGISTRY" --cache "$NPM_CACHE" >/dev/null
}

write_claude_wrapper() {
  mkdir -p "$(dirname "$CLAUDE_APP_LINK")"
  rm -f "$CLAUDE_APP_LINK"
  cat > "$CLAUDE_APP_LINK" <<EOF
#!/bin/sh
NODE_BIN="/opt/homebrew/bin/node"
if [ ! -x "\$NODE_BIN" ]; then
  NODE_BIN="\$(command -v node || true)"
fi
if [ -z "\$NODE_BIN" ] || [ ! -x "\$NODE_BIN" ]; then
  echo "错误：找不到可用的 node" >&2
  exit 1
fi
exec "\$NODE_BIN" "$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code/cli-wrapper.cjs" "\$@"
EOF
  chmod 755 "$CLAUDE_APP_LINK"
}

ensure_links() {
  mkdir -p "$LOCAL_BIN_DIR" "$SYSTEM_BIN_DIR" "$(dirname "$CLAUDE_APP_LINK")"

  write_claude_wrapper
  ensure_link "$LOCAL_BIN_DIR/claude" "$CLAUDE_APP_LINK"
  ensure_link "$SYSTEM_BIN_DIR/claude" "$CLAUDE_APP_LINK"

  ensure_link "$LOCAL_BIN_DIR/codex" "$NPM_GLOBAL_PREFIX/bin/codex"
  ensure_link "$SYSTEM_BIN_DIR/codex" "$NPM_GLOBAL_PREFIX/bin/codex"

  ensure_link "$LOCAL_BIN_DIR/gemini" "$NPM_GLOBAL_PREFIX/bin/gemini"
  ensure_link "$SYSTEM_BIN_DIR/gemini" "$NPM_GLOBAL_PREFIX/bin/gemini"
}

check_one() {
  local display_name="$1"
  local cmd_name="$2"
  local pkg="$3"
  local install_path="$4"
  local current latest probe state path version cmp result status tip

  probe="$(probe_tool "$cmd_name")"
  state="${probe%%|*}"
  path="${probe#*|}"
  path="${path%%|*}"
  version="${probe##*|}"
  latest="$(latest_version "$pkg")"

  result="$(status_and_tip "$state" "$version" "$latest")"
  status="${result%%|*}"
  tip="${result#*|}"

  local row row_color
  row="$(
    printf '%s %s %s %s %s %s' \
      "$(pad_display "$display_name" 8)" \
      "$(pad_display "${version:--}" 18)" \
      "$(pad_display "${latest:--}" 18)" \
      "$(pad_display "$(status_display_text "$status")" 12)" \
      "$(pad_display "$tip" 18)" \
      "${path:--}"
  )"
  row_color="$(line_color_for_status "$status")"
  log "$(color "$row_color" "$row" "$ANSI_RESET")"
}

snapshot_one() {
  local display_name="$1"
  local cmd_name="$2"
  local pkg="$3"
  local probe state path version latest status tip result

  probe="$(probe_tool "$cmd_name")"
  state="${probe%%|*}"
  path="${probe#*|}"
  path="${path%%|*}"
  version="${probe##*|}"
  latest="$(latest_version "$pkg")"

  result="$(status_and_tip "$state" "$version" "$latest")"
  status="${result%%|*}"
  tip="${result#*|}"

  render_snapshot_card "$display_name" "${version:--}" "${latest:--}" "$status" "$tip"
}

render_snapshot_card() {
  local name="$1"
  local current="$2"
  local latest="$3"
  local status="$4"
  local tip="$5"
  local title current_line latest_line status_line tip_line border status_text box_color inner_width status_value_color

  inner_width=30
  box_color="$ANSI_CYAN"
  status_text="$(status_display_text "$status")"
  status_value_color="$(line_color_for_status "$status")"
  title="╭─ $(pad_display "$name" $((inner_width - 4))) ─╮"
  current_line="$(card_row '当前：' "$current" "$ANSI_GRAY" "$ANSI_CYAN$ANSI_BOLD" "$box_color")"
  latest_line="$(card_row '最新：' "$latest" "$ANSI_GRAY" "$ANSI_CYAN$ANSI_BOLD" "$box_color")"
  status_line="$(card_row '状态：' "$status_text" "$ANSI_GRAY" "$status_value_color$ANSI_BOLD" "$box_color")"
  tip_line="$(card_row '建议：' "$tip" "$ANSI_GRAY$ANSI_DIM" "$ANSI_GRAY$ANSI_DIM" "$box_color")"
  border="╰$(repeat_char '─' "$inner_width")╯"

  log "$(color "$box_color$ANSI_BOLD" "$title" "$ANSI_RESET")"
  log "$(color "$box_color" "$current_line" "$ANSI_RESET")"
  log "$(color "$box_color" "$latest_line" "$ANSI_RESET")"
  log "$(color "$box_color$ANSI_BOLD" "$status_line" "$ANSI_RESET")"
  log "$(color "$box_color" "$tip_line" "$ANSI_RESET")"
  log "$(color "$box_color" "$border" "$ANSI_RESET")"
}

repair_or_update_one() {
  local display_name="$1"
  local cmd_name="$2"
  local pkg="$3"
  local install_path="$4"
  local mode="${5:-fix}"
  local current_state current_path current_version latest installed_version target_version cmp

  current_state="$(probe_tool "$cmd_name")"
  current_state="${current_state%%|*}"
  latest="$(latest_version "$pkg")"
  installed_version="$(installed_pkg_version "$install_path")"

  if [ "$mode" = "update" ]; then
    target_version="$latest"
  else
    target_version="${installed_version:-$latest}"
  fi

  if [ "$mode" = "update" ] || [ "$current_state" != "ok" ] || [ -z "$installed_version" ]; then
    case "$display_name" in
      Claude)
        install_claude "$target_version"
        ;;
      Codex)
        install_global_pkg "$pkg" "$target_version"
        ;;
      Gemini)
        install_global_pkg "$pkg" "$target_version"
        ;;
      *)
        die "未知工具：$display_name"
        ;;
    esac
  fi
}

main() {
  local mode="${1:-check}"
  case "$mode" in
    snapshot|check|fix|update|all) ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac

  require_cmd npm
  require_cmd curl
  require_cmd tar
  require_cmd node
  require_cmd python3

  mkdir -p "$NPM_CACHE" "$NPM_GLOBAL_PREFIX" "$CLAUDE_PREFIX"

  if [ "$mode" = "all" ]; then
    log "$(color "$ANSI_BOLD$ANSI_CYAN" "一键全量处理：check -> fix -> update -> check" "$ANSI_RESET")"
    log ""
    log "$(color "$ANSI_BOLD" "[1/4] 执行检查" "$ANSI_RESET")"
    "$0" check
    log ""
    log "$(color "$ANSI_BOLD" "[2/4] 执行修复" "$ANSI_RESET")"
    "$0" fix
    log ""
    log "$(color "$ANSI_BOLD" "[3/4] 执行更新" "$ANSI_RESET")"
    "$0" update
    log ""
    log "$(color "$ANSI_BOLD" "[4/4] 最终复检" "$ANSI_RESET")"
    "$0" check
    log ""
    log "$(color "$ANSI_GREEN$ANSI_BOLD" "一键全量处理完成" "$ANSI_RESET")"
    return 0
  fi

  if [ "$mode" = "snapshot" ]; then
    log "$(color "$ANSI_BOLD$ANSI_CYAN" "AI 工具链摘要" "$ANSI_RESET")"
    log "$(color "$ANSI_DIM$ANSI_GRAY" "────────────────────────────────" "$ANSI_RESET")"
    snapshot_one "Claude" "claude" "@anthropic-ai/claude-code"
    snapshot_one "Codex" "codex" "@openai/codex"
    snapshot_one "Gemini" "gemini" "@google/gemini-cli"
    return 0
  fi

  log "$(color "$ANSI_BOLD$ANSI_CYAN" "执行模式：${mode}" "$ANSI_RESET")"
  log ""
  log "执行检查结果："
  log "$(color "$ANSI_BOLD$ANSI_CYAN" "$(
    printf '%s %s %s %s %s %s' \
      "$(pad_display '工具' 8)" \
      "$(pad_display '当前版本' 18)" \
      "$(pad_display '最新版本' 18)" \
      "$(pad_display '状态' 12)" \
      "$(pad_display '建议' 18)" \
      "命令路径"
  )" "$ANSI_RESET")"
  log "$(color "$ANSI_DIM$ANSI_GRAY" "$(
    printf '%s %s %s %s %s %s' \
      "$(pad_display '------' 8)" \
      "$(pad_display '------' 18)" \
      "$(pad_display '------' 18)" \
      "$(pad_display '------' 12)" \
      "$(pad_display '------' 18)" \
      "------"
  )" "$ANSI_RESET")"
  check_one "Claude" "claude" "@anthropic-ai/claude-code" "$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code"
  check_one "Codex" "codex" "@openai/codex" "$NPM_GLOBAL_PREFIX/lib/node_modules/@openai/codex"
  check_one "Gemini" "gemini" "@google/gemini-cli" "$NPM_GLOBAL_PREFIX/lib/node_modules/@google/gemini-cli"

  if [ "$mode" = "check" ]; then
    return 0
  fi

  log ""
  log "开始执行修复/更新..."

  repair_or_update_one "Claude" "claude" "@anthropic-ai/claude-code" "$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code" "$mode"
  repair_or_update_one "Codex" "codex" "@openai/codex" "$NPM_GLOBAL_PREFIX/lib/node_modules/@openai/codex" "$mode"
  repair_or_update_one "Gemini" "gemini" "@google/gemini-cli" "$NPM_GLOBAL_PREFIX/lib/node_modules/@google/gemini-cli" "$mode"
  ensure_links

  log ""
  log "复检结果："
  log "$(color "$ANSI_BOLD$ANSI_CYAN" "$(
    printf '%s %s %s %s %s %s' \
      "$(pad_display '工具' 8)" \
      "$(pad_display '当前版本' 18)" \
      "$(pad_display '最新版本' 18)" \
      "$(pad_display '状态' 12)" \
      "$(pad_display '建议' 18)" \
      "命令路径"
  )" "$ANSI_RESET")"
  log "$(color "$ANSI_DIM$ANSI_GRAY" "$(
    printf '%s %s %s %s %s %s' \
      "$(pad_display '------' 8)" \
      "$(pad_display '------' 18)" \
      "$(pad_display '------' 18)" \
      "$(pad_display '------' 12)" \
      "$(pad_display '------' 18)" \
      "------"
  )" "$ANSI_RESET")"
  check_one "Claude" "claude" "@anthropic-ai/claude-code" "$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code"
  check_one "Codex" "codex" "@openai/codex" "$NPM_GLOBAL_PREFIX/lib/node_modules/@openai/codex"
  check_one "Gemini" "gemini" "@google/gemini-cli" "$NPM_GLOBAL_PREFIX/lib/node_modules/@google/gemini-cli"
}

main "$@"
