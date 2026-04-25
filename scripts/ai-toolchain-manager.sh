#!/usr/bin/env bash
set -euo pipefail

# 统一管理 Claude / Codex / Gemini / Kimi：
# - check：只检查当前版本与最新版本
# - fix：修复损坏的安装和命令入口
# - update：升级到最新版本并修复入口

NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
NPM_CACHE="${NPM_CACHE:-$HOME/.cache/ai-toolchain-npm}"
NPM_GLOBAL_PREFIX="${NPM_GLOBAL_PREFIX:-$HOME/.npm-global}"
CLAUDE_PREFIX="${CLAUDE_PREFIX:-$HOME/.claude/local-user}"
LOCAL_BIN_DIR="${LOCAL_BIN_DIR:-$HOME/.local/bin}"
SYSTEM_BIN_DIR="${SYSTEM_BIN_DIR:-}"

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
    已是最新|已安装|无需处理)
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
    已是最新|已安装|无需处理)
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
  scripts/ai-toolchain-manager.sh [snapshot|check|fix|update|all|selftest|check-raw|update-one]
  scripts/ai-toolchain-manager.sh update-one [claude|codex|gemini|kimi]
  scripts/ai-toolchain-manager.sh all --compact
  scripts/ai-toolchain-manager.sh update-one codex --compact

说明：
  snapshot 输出当前四项工具的摘要和建议，适合启动前预览
  check   只检查当前版本、最新版本和可执行状态
  check-raw 机器可读检查输出，供 .command 解析菜单
  fix     修复损坏的入口或缺失的安装，不主动升级
  update  升级到最新版本，并修复入口
  update-one 仅更新单个工具
  all     一键执行：check -> fix -> update -> check
  selftest  仅执行逻辑回归测试，不安装不更新
  --compact 仅输出简略进度（建议用于 all / update-one）

可选环境变量：
  NPM_REGISTRY=https://registry.npmjs.org
  NPM_CACHE=~/.cache/ai-toolchain-npm
  NPM_GLOBAL_PREFIX=~/.npm-global
  CLAUDE_PREFIX=~/.claude/local-user
  SYSTEM_BIN_DIR=/opt/homebrew/bin  # 可选，强制写入系统 bin 目录
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
      printf '%s\n' '-1'
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
  if [ ! -e "$target_path" ]; then
    if [ -L "$link_path" ]; then
      rm -f "$link_path"
    fi
    return 0
  fi
  mkdir -p "$(dirname "$link_path")"
  ln -sfn "$target_path" "$link_path"
}

resolve_system_bin_dir() {
  if [ -n "$SYSTEM_BIN_DIR" ]; then
    printf '%s' "$SYSTEM_BIN_DIR"
    return 0
  fi

  local d
  for d in /opt/homebrew/bin /usr/local/bin; do
    if [ -d "$d" ] && [ -w "$d" ]; then
      printf '%s' "$d"
      return 0
    fi
  done

  printf ''
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

probe_kimi() {
  local cmd output version path
  for cmd in kimi kimi-cli; do
    path="$(command -v "$cmd" 2>/dev/null || true)"
    if [ -z "$path" ]; then
      continue
    fi
    if ! output="$("$cmd" --version 2>&1)"; then
      printf 'broken|%s|\n' "$path"
      return 0
    fi
    version="$(extract_version "$output")"
    if [ -z "$version" ]; then
      version="-"
    fi
    printf 'ok|%s|%s\n' "$path" "$version"
    return 0
  done
  printf 'missing||\n'
}

latest_kimi_version() {
  local version=""

  if command -v python3 >/dev/null 2>&1; then
    version="$(
      python3 - <<'PY' 2>/dev/null
import json
import urllib.request

try:
    with urllib.request.urlopen("https://pypi.org/pypi/kimi-cli/json", timeout=8) as resp:
        data = json.load(resp)
    print((data.get("info") or {}).get("version", ""))
except Exception:
    pass
PY
    )"
  fi

  if [ -z "$version" ]; then
    version="$(
      curl -fsSL https://pypi.org/pypi/kimi-cli/json 2>/dev/null \
        | tr -d '\n' \
        | sed -n 's/.*"version":"\([0-9][0-9.]*\)".*/\1/p' \
        | head -n 1
    )"
  fi

  printf '%s' "$version"
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
        *) printf '异常比较结果|建议执行 selftest\n' ;;
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

status_and_tip_kimi() {
  local state="$1"
  local current="${2:-}"
  local latest="${3:-}"
  local cmp
  case "$state" in
    ok)
      if [ -n "$current" ] && [ "$current" != "-" ] && [ -n "$latest" ] && [ "$latest" != "-" ]; then
        cmp="$(semver_cmp "$current" "$latest")"
        case "$cmp" in
          0) printf '已是最新|无需处理\n' ;;
          1) printf '本地更新|可保留当前版本\n' ;;
          -1) printf '可更新|建议执行 update\n' ;;
          *) printf '异常比较结果|建议执行 selftest\n' ;;
        esac
      else
        printf '已安装|可执行，update 会重装最新版\n'
      fi
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

install_kimi() {
  local mode="${1:-fix}"

  if [ "$mode" = "update" ] && command -v uv >/dev/null 2>&1; then
    if uv tool upgrade kimi-cli >/dev/null 2>&1; then
      return 0
    fi
  fi

  curl -fsSL https://code.kimi.com/install.sh | bash >/dev/null 2>&1
}

selftest() {
  local failed=0
  local out

  out="$(semver_cmp "0.124.0" "0.125.0")"
  if [ "$out" = "-1" ]; then
    log "PASS semver_cmp 0.124.0 < 0.125.0"
  else
    log "FAIL semver_cmp 0.124.0 < 0.125.0 (got: $out)"
    failed=1
  fi

  out="$(status_and_tip "ok" "0.124.0" "0.125.0")"
  if [ "${out%%|*}" = "可更新" ]; then
    log "PASS status_and_tip 可更新"
  else
    log "FAIL status_and_tip 可更新 (got: $out)"
    failed=1
  fi

  out="$(status_and_tip "ok" "0.125.0" "0.125.0")"
  if [ "${out%%|*}" = "已是最新" ]; then
    log "PASS status_and_tip 已是最新"
  else
    log "FAIL status_and_tip 已是最新 (got: $out)"
    failed=1
  fi

  out="$(status_and_tip_kimi "ok" "1.37.0" "1.38.0")"
  if [ "${out%%|*}" = "可更新" ]; then
    log "PASS status_and_tip_kimi 可更新"
  else
    log "FAIL status_and_tip_kimi 可更新 (got: $out)"
    failed=1
  fi

  out="$(status_and_tip_kimi "ok" "1.38.0" "1.38.0")"
  if [ "${out%%|*}" = "已是最新" ]; then
    log "PASS status_and_tip_kimi 已是最新"
  else
    log "FAIL status_and_tip_kimi 已是最新 (got: $out)"
    failed=1
  fi

  if [ "$failed" -eq 0 ]; then
    log "SELFTEST OK"
    return 0
  fi

  log "SELFTEST FAILED"
  return 1
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
  local wrapper_target="$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code/cli-wrapper.cjs"
  if [ ! -f "$wrapper_target" ]; then
    if [ -e "$CLAUDE_APP_LINK" ] || [ -L "$CLAUDE_APP_LINK" ]; then
      rm -f "$CLAUDE_APP_LINK"
    fi
    return 0
  fi
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
  local effective_system_bin
  effective_system_bin="$(resolve_system_bin_dir)"

  mkdir -p "$LOCAL_BIN_DIR" "$(dirname "$CLAUDE_APP_LINK")"

  write_claude_wrapper
  ensure_link "$LOCAL_BIN_DIR/claude" "$CLAUDE_APP_LINK"
  ensure_link "$LOCAL_BIN_DIR/codex" "$NPM_GLOBAL_PREFIX/bin/codex"
  ensure_link "$LOCAL_BIN_DIR/gemini" "$NPM_GLOBAL_PREFIX/bin/gemini"

  if [ -n "$effective_system_bin" ]; then
    mkdir -p "$effective_system_bin" 2>/dev/null || true
    if [ -w "$effective_system_bin" ]; then
      ensure_link "$effective_system_bin/claude" "$CLAUDE_APP_LINK"
      ensure_link "$effective_system_bin/codex" "$NPM_GLOBAL_PREFIX/bin/codex"
      ensure_link "$effective_system_bin/gemini" "$NPM_GLOBAL_PREFIX/bin/gemini"
    fi
  fi
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

check_one_kimi() {
  local probe state path version latest result status tip row row_color

  probe="$(probe_kimi)"
  state="${probe%%|*}"
  path="${probe#*|}"
  path="${path%%|*}"
  version="${probe##*|}"
  latest="$(latest_kimi_version)"

  result="$(status_and_tip_kimi "$state" "$version" "$latest")"
  status="${result%%|*}"
  tip="${result#*|}"

  row="$(
    printf '%s %s %s %s %s %s' \
      "$(pad_display "Kimi" 8)" \
      "$(pad_display "${version:--}" 18)" \
      "$(pad_display "${latest:--}" 18)" \
      "$(pad_display "$(status_display_text "$status")" 12)" \
      "$(pad_display "$tip" 18)" \
      "${path:--}"
  )"
  row_color="$(line_color_for_status "$status")"
  log "$(color "$row_color" "$row" "$ANSI_RESET")"
}

raw_status_one() {
  local key="$1"
  local display_name="$2"
  local cmd_name="$3"
  local pkg="$4"
  local probe state path version latest result status tip

  probe="$(probe_tool "$cmd_name")"
  state="${probe%%|*}"
  path="${probe#*|}"
  path="${path%%|*}"
  version="${probe##*|}"
  latest="$(latest_version "$pkg")"

  result="$(status_and_tip "$state" "$version" "$latest")"
  status="${result%%|*}"
  tip="${result#*|}"

  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$key" "$display_name" "${version:--}" "${latest:--}" "$status" "$tip" "${path:--}"
}

raw_status_kimi() {
  local probe state path version latest result status tip

  probe="$(probe_kimi)"
  state="${probe%%|*}"
  path="${probe#*|}"
  path="${path%%|*}"
  version="${probe##*|}"
  latest="$(latest_kimi_version)"

  result="$(status_and_tip_kimi "$state" "$version" "$latest")"
  status="${result%%|*}"
  tip="${result#*|}"

  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "kimi" "Kimi" "${version:--}" "${latest:--}" "$status" "$tip" "${path:--}"
}

check_raw() {
  raw_status_one "claude" "Claude" "claude" "@anthropic-ai/claude-code"
  raw_status_one "codex" "Codex" "codex" "@openai/codex"
  raw_status_one "gemini" "Gemini" "gemini" "@google/gemini-cli"
  raw_status_kimi
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

snapshot_one_kimi() {
  local probe state path version latest status tip result

  probe="$(probe_kimi)"
  state="${probe%%|*}"
  path="${probe#*|}"
  path="${path%%|*}"
  version="${probe##*|}"
  latest="$(latest_kimi_version)"

  result="$(status_and_tip_kimi "$state" "$version" "$latest")"
  status="${result%%|*}"
  tip="${result#*|}"

  render_snapshot_card "Kimi" "${version:--}" "${latest:--}" "$status" "$tip"
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

repair_or_update_kimi() {
  local mode="${1:-fix}"
  local current_state

  current_state="$(probe_kimi)"
  current_state="${current_state%%|*}"

  if [ "$mode" = "update" ] || [ "$current_state" != "ok" ]; then
    install_kimi "$mode"
  fi
}

print_check_table() {
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
  check_one_kimi
}

update_one_tool() {
  local tool_key="$1"
  case "$tool_key" in
    claude)
      repair_or_update_one "Claude" "claude" "@anthropic-ai/claude-code" "$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code" "update"
      ;;
    codex)
      repair_or_update_one "Codex" "codex" "@openai/codex" "$NPM_GLOBAL_PREFIX/lib/node_modules/@openai/codex" "update"
      ;;
    gemini)
      repair_or_update_one "Gemini" "gemini" "@google/gemini-cli" "$NPM_GLOBAL_PREFIX/lib/node_modules/@google/gemini-cli" "update"
      ;;
    kimi)
      repair_or_update_kimi "update"
      ;;
    *)
      die "update-one 仅支持：claude|codex|gemini|kimi"
      ;;
  esac
}

tool_display_name() {
  case "$1" in
    claude) printf 'Claude' ;;
    codex) printf 'Codex' ;;
    gemini) printf 'Gemini' ;;
    kimi) printf 'Kimi' ;;
    *) printf '%s' "$1" ;;
  esac
}

raw_metrics() {
  local raw="$1"
  awk -F'|' '
    NF >= 5 {
      total++
      status = $5
      if (status == "可更新") {
        updatable++
      } else if (status == "已是最新" || status == "本地更新" || status == "已安装" || status == "无需处理") {
        healthy++
      } else {
        issue++
      }
    }
    END {
      printf "%d|%d|%d|%d\n", total + 0, updatable + 0, healthy + 0, issue + 0
    }
  ' <<<"$raw"
}

raw_tool_record() {
  local raw="$1"
  local key="$2"
  awk -F'|' -v k="$key" '$1 == k { print; exit }' <<<"$raw"
}

status_needs_update() {
  case "${1:-}" in
    可更新)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

status_needs_fix() {
  case "${1:-}" in
    未安装|不可执行|异常比较结果)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

count_tool_keys() {
  local keys="${1:-}"
  local key count=0
  for key in $keys; do
    count=$((count + 1))
  done
  printf '%s' "$count"
}

tool_names_from_keys() {
  local keys="${1:-}"
  local key out="" name
  for key in $keys; do
    name="$(tool_display_name "$key")"
    out="${out}${out:+、}${name}"
  done
  printf '%s' "${out:-无}"
}

collect_tool_keys() {
  local raw="$1"
  local kind="$2"
  local key status out=""

  while IFS='|' read -r key _ _ _ status _ _; do
    [ -n "$key" ] || continue
    case "$kind" in
      update)
        if status_needs_update "$status"; then
          out="${out}${out:+ }${key}"
        fi
        ;;
      fix)
        if status_needs_fix "$status"; then
          out="${out}${out:+ }${key}"
        fi
        ;;
      *)
        ;;
    esac
  done <<<"$raw"

  printf '%s' "$out"
}

run_detailed_with_fallback() {
  local stage_title="$1"
  shift
  local tmp_file exit_code
  tmp_file="$(mktemp)"
  if "$0" "$@" >"$tmp_file" 2>&1; then
    rm -f "$tmp_file"
    return 0
  else
    exit_code=$?
  fi

  log "$(color "$ANSI_RED$ANSI_BOLD" "${stage_title}失败（exit=${exit_code}）" "$ANSI_RESET")"
  log "以下为该阶段详细输出："
  cat "$tmp_file"
  rm -f "$tmp_file"
  return "$exit_code"
}

run_all_compact() {
  local raw_before raw_after_fix raw_final
  local metrics before_updatable before_issue final_updatable final_issue
  local fix_keys update_keys fix_count update_count fixed_count updated_count key name
  local remaining_issue remaining_update

  log "$(color "$ANSI_BOLD$ANSI_CYAN" "一键全量处理：check -> fix -> update -> check（简略进度）" "$ANSI_RESET")"
  log ""

  log "[1/4] 检查中..."
  raw_before="$(check_raw)"
  metrics="$(raw_metrics "$raw_before")"
  IFS='|' read -r _ before_updatable _ before_issue <<<"$metrics"
  fix_keys="$(collect_tool_keys "$raw_before" fix)"
  update_keys="$(collect_tool_keys "$raw_before" update)"
  fix_count="$(count_tool_keys "$fix_keys")"
  update_count="$(count_tool_keys "$update_keys")"
  log "[1/4] 检查完成：可更新 ${before_updatable} 项，异常 ${before_issue} 项。"
  log ""

  if [ "$fix_count" -eq 0 ] && [ "$update_count" -eq 0 ]; then
    log "[2/4] 无需修复，已跳过。"
    log "[3/4] 无需更新，已跳过。"
    log "[4/4] 复检完成：可更新 0 项，异常 0 项。"
    log "$(color "$ANSI_GREEN$ANSI_BOLD" "结果：全部已是最新，已跳过升级动作。" "$ANSI_RESET")"
    return 0
  fi

  if [ "$fix_count" -gt 0 ]; then
    log "[2/4] 修复中：$(tool_names_from_keys "$fix_keys")..."
    run_detailed_with_fallback "[2/4] 修复阶段" fix
    raw_after_fix="$(check_raw)"
    remaining_issue="$(count_tool_keys "$(collect_tool_keys "$raw_after_fix" fix)")"
    fixed_count=$((fix_count - remaining_issue))
    if [ "$fixed_count" -lt 0 ]; then
      fixed_count=0
    fi
    log "[2/4] 修复完成：修复 ${fixed_count} 项，剩余异常 ${remaining_issue} 项。"
  else
    log "[2/4] 无需修复，已跳过。"
    raw_after_fix="$raw_before"
  fi
  log ""

  update_keys="$(collect_tool_keys "$raw_after_fix" update)"
  update_count="$(count_tool_keys "$update_keys")"
  if [ "$update_count" -gt 0 ]; then
    log "[3/4] 更新中：$(tool_names_from_keys "$update_keys")..."
    updated_count=0
    for key in $update_keys; do
      name="$(tool_display_name "$key")"
      run_detailed_with_fallback "[3/4] 更新 ${name}" update-one "$key"
      updated_count=$((updated_count + 1))
    done
    raw_final="$(check_raw)"
    remaining_update="$(count_tool_keys "$(collect_tool_keys "$raw_final" update)")"
    updated_count=$((updated_count - remaining_update))
    if [ "$updated_count" -lt 0 ]; then
      updated_count=0
    fi
    log "[3/4] 更新完成：已更新 ${updated_count} 项，仍可更新 ${remaining_update} 项。"
  else
    log "[3/4] 无需更新，已跳过。"
    raw_final="$(check_raw)"
  fi
  log ""

  log "[4/4] 复检中..."
  metrics="$(raw_metrics "$raw_final")"
  IFS='|' read -r _ final_updatable _ final_issue <<<"$metrics"
  log "[4/4] 复检完成：可更新 ${final_updatable} 项，异常 ${final_issue} 项。"
  if [ "$final_updatable" -eq 0 ] && [ "$final_issue" -eq 0 ]; then
    log "$(color "$ANSI_GREEN$ANSI_BOLD" "结果：全部已是最新，且无异常。" "$ANSI_RESET")"
  else
    log "$(color "$ANSI_YELLOW$ANSI_BOLD" "结果：仍有待处理项（可更新 ${final_updatable}，异常 ${final_issue}）。" "$ANSI_RESET")"
  fi
}

run_update_one_compact() {
  local tool_key="$1"
  local tool_name record status current latest
  local raw

  tool_name="$(tool_display_name "$tool_key")"
  log "$(color "$ANSI_BOLD$ANSI_CYAN" "单项更新（简略进度）" "$ANSI_RESET")"
  raw="$(check_raw)"
  record="$(raw_tool_record "$raw" "$tool_key")"
  if [ -z "$record" ]; then
    log "$(color "$ANSI_YELLOW$ANSI_BOLD" "复检：未获取到 ${tool_name} 状态，请执行 check 查看详情。" "$ANSI_RESET")"
    return 0
  fi

  IFS='|' read -r _ _ current latest status _ _ <<<"$record"
  case "$status" in
    可更新|未安装|不可执行|异常比较结果)
      log "更新 ${tool_name} 中..."
      run_detailed_with_fallback "更新 ${tool_name}" update-one "$tool_key"
      log "更新 ${tool_name} 完成。"
      ;;
    *)
      log "${tool_name} 当前为“${status}”，无需更新，已跳过。"
      return 0
      ;;
  esac

  raw="$(check_raw)"
  record="$(raw_tool_record "$raw" "$tool_key")"
  if [ -z "$record" ]; then
    log "$(color "$ANSI_YELLOW$ANSI_BOLD" "复检：未获取到 ${tool_name} 状态，请执行 check 查看详情。" "$ANSI_RESET")"
    return 0
  fi
  IFS='|' read -r _ _ current latest status _ _ <<<"$record"
  log "复检：${tool_name} ${status}（当前 ${current}，最新 ${latest}）。"
}

main() {
  local mode="${1:-check}"
  local target_tool=""
  local compact=0
  local arg
  local -a extra_args=()

  if [ "${TOOLCHAIN_COMPACT:-0}" = "1" ]; then
    compact=1
  fi

  for arg in "${@:2}"; do
    case "$arg" in
      --compact)
        compact=1
        ;;
      *)
        extra_args+=("$arg")
        ;;
    esac
  done

  case "$mode" in
    snapshot|check|fix|update|all|selftest|check-raw|update-one) ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac

  if [ "$mode" = "update-one" ]; then
    if [ "${#extra_args[@]}" -lt 1 ]; then
      die "用法：scripts/ai-toolchain-manager.sh update-one [claude|codex|gemini|kimi]"
    fi
    if [ "${#extra_args[@]}" -gt 1 ]; then
      die "update-one 参数过多：${extra_args[*]}"
    fi
    target_tool="$(printf '%s' "${extra_args[0]}" | tr '[:upper:]' '[:lower:]')"
  else
    if [ "${#extra_args[@]}" -gt 0 ]; then
      die "未知参数：${extra_args[*]}"
    fi
  fi

  require_cmd npm
  require_cmd curl
  require_cmd tar
  require_cmd node
  require_cmd python3

  mkdir -p "$NPM_CACHE" "$NPM_GLOBAL_PREFIX" "$CLAUDE_PREFIX"

  if [ "$mode" = "check-raw" ]; then
    check_raw
    return 0
  fi

  if [ "$mode" = "selftest" ]; then
    selftest
    return $?
  fi

  if [ "$mode" = "all" ]; then
    if [ "$compact" -eq 1 ]; then
      run_all_compact
      return 0
    fi

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

  if [ "$mode" = "update-one" ]; then
    if [ "$compact" -eq 1 ]; then
      run_update_one_compact "$target_tool"
      return 0
    fi

    log "$(color "$ANSI_BOLD$ANSI_CYAN" "执行模式：update-one (${target_tool})" "$ANSI_RESET")"
    log ""
    log "执行前检查："
    print_check_table
    log ""
    log "开始执行单项更新..."
    update_one_tool "$target_tool"
    ensure_links
    log ""
    log "复检结果："
    print_check_table
    return 0
  fi

  if [ "$mode" = "snapshot" ]; then
    log "$(color "$ANSI_BOLD$ANSI_CYAN" "AI 工具链摘要" "$ANSI_RESET")"
    log "$(color "$ANSI_DIM$ANSI_GRAY" "────────────────────────────────" "$ANSI_RESET")"
    snapshot_one "Claude" "claude" "@anthropic-ai/claude-code"
    snapshot_one "Codex" "codex" "@openai/codex"
    snapshot_one "Gemini" "gemini" "@google/gemini-cli"
    snapshot_one_kimi
    return 0
  fi

  log "$(color "$ANSI_BOLD$ANSI_CYAN" "执行模式：${mode}" "$ANSI_RESET")"
  log ""
  print_check_table

  if [ "$mode" = "check" ]; then
    return 0
  fi

  log ""
  log "开始执行修复/更新..."

  repair_or_update_one "Claude" "claude" "@anthropic-ai/claude-code" "$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code" "$mode"
  repair_or_update_one "Codex" "codex" "@openai/codex" "$NPM_GLOBAL_PREFIX/lib/node_modules/@openai/codex" "$mode"
  repair_or_update_one "Gemini" "gemini" "@google/gemini-cli" "$NPM_GLOBAL_PREFIX/lib/node_modules/@google/gemini-cli" "$mode"
  repair_or_update_kimi "$mode"
  ensure_links

  log ""
  log "复检结果："
  print_check_table
}

main "$@"
