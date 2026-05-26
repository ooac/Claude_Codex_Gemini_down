#!/usr/bin/env bash
set -euo pipefail

# 统一管理 Claude / Codex / Antigravity / Kimi：
# - check：只检查当前版本与最新版本
# - fix：修复损坏的安装和命令入口
# - update：升级到最新版本并修复入口

NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
NPM_CACHE="${NPM_CACHE:-$HOME/.cache/ai-toolchain-npm}"
NPM_GLOBAL_PREFIX="${NPM_GLOBAL_PREFIX:-$HOME/.npm-global}"
NPM_FETCH_RETRIES="${NPM_FETCH_RETRIES:-1}"
NPM_FETCH_RETRY_MINTIMEOUT="${NPM_FETCH_RETRY_MINTIMEOUT:-1000}"
NPM_FETCH_RETRY_MAXTIMEOUT="${NPM_FETCH_RETRY_MAXTIMEOUT:-4000}"
NPM_FETCH_TIMEOUT="${NPM_FETCH_TIMEOUT:-8000}"
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
    本地更新|可更新|迁移未完成|PATH未配置|无法检查|异常比较结果)
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
    本地更新|可更新|迁移未完成)
      printf '↻ %s' "$1"
      ;;
    PATH未配置|不可执行|未安装)
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
  local actual_width pad_count

  actual_width="$(display_width "$text")"
  if [ "$actual_width" -ge "$target_width" ]; then
    printf '%s' "$text"
    return 0
  fi

  pad_count=$((target_width - actual_width))
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
  scripts/ai-toolchain-manager.sh [snapshot|check|fix|update|all|selftest|check-raw|update-one|uninstall-gemini|fix-kimi-vscode]
  scripts/ai-toolchain-manager.sh update-one [claude|codex|antigravity|kimi]
  scripts/ai-toolchain-manager.sh all --compact
  scripts/ai-toolchain-manager.sh update-one codex --compact
  scripts/ai-toolchain-manager.sh uninstall-gemini
  scripts/ai-toolchain-manager.sh fix-kimi-vscode

说明：
  snapshot 输出当前四项工具的摘要和建议，适合启动前预览
  check   只检查当前版本、最新版本和可执行状态
  check-raw 机器可读检查输出，供 .command 解析菜单
  fix     修复损坏的入口或缺失的安装，不主动升级
  update  升级到最新版本，并修复入口
  update-one 仅更新单个工具
  uninstall-gemini 彻底卸载 Gemini CLI（含用户数据目录）
  fix-kimi-vscode 清空 VS Code Kimi 插件自定义路径，改用插件内置 CLI
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
  local output
  if ! output="$(
    npm \
      --fetch-retries="$NPM_FETCH_RETRIES" \
      --fetch-retry-mintimeout="$NPM_FETCH_RETRY_MINTIMEOUT" \
      --fetch-retry-maxtimeout="$NPM_FETCH_RETRY_MAXTIMEOUT" \
      --fetch-timeout="$NPM_FETCH_TIMEOUT" \
      view "${pkg}" version --registry "$NPM_REGISTRY" 2>/dev/null
  )"; then
    printf ''
    return 0
  fi
  printf '%s\n' "$output" | tail -n 1 | tr -d '[:space:]'
}

latest_tarball() {
  local pkg="$1"
  local output
  if ! output="$(
    npm \
      --fetch-retries="$NPM_FETCH_RETRIES" \
      --fetch-retry-mintimeout="$NPM_FETCH_RETRY_MINTIMEOUT" \
      --fetch-retry-maxtimeout="$NPM_FETCH_RETRY_MAXTIMEOUT" \
      --fetch-timeout="$NPM_FETCH_TIMEOUT" \
      view "$pkg" dist.tarball --registry "$NPM_REGISTRY" 2>/dev/null
  )"; then
    printf ''
    return 0
  fi
  printf '%s\n' "$output" | tail -n 1 | tr -d '[:space:]'
}

antigravity_platform_key() {
  local os arch
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    *)
      printf ''
      return 0
      ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)
      printf ''
      return 0
      ;;
  esac

  printf '%s_%s' "$os" "$arch"
}

latest_antigravity_version() {
  local platform manifest_url payload version
  platform="$(antigravity_platform_key)"
  if [ -z "$platform" ]; then
    printf ''
    return 0
  fi

  manifest_url="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/${platform}.json"
  payload="$(
    curl -fsSL --connect-timeout 5 --max-time 15 --retry 2 --retry-delay 1 "$manifest_url" 2>/dev/null || true
  )"

  if [ -z "$payload" ] && command -v wget >/dev/null 2>&1; then
    payload="$(wget -q -T 15 -O - "$manifest_url" 2>/dev/null || true)"
  fi

  if [ -z "$payload" ]; then
    printf ''
    return 0
  fi

  # 使用 awk 解析 JSON 字段，避免 BSD sed 的 BRE 兼容差异导致提取失败。
  version="$(printf '%s\n' "$payload" | awk -F'"' '/"version"[[:space:]]*:/ {print $4; exit}')"

  printf '%s' "$version"
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
  local output version path

  path="$(resolve_kimi_cmd)"
  if [ -n "$path" ] && [ -x "$path" ]; then
    if ! output="$("$path" --version 2>&1)"; then
      printf 'broken|%s|\n' "$path"
      return 0
    fi
    version="$(extract_version "$output")"
    if [ -z "$version" ]; then
      version="-"
    fi
    printf 'ok|%s|%s\n' "$path" "$version"
    return 0
  fi

  path="$(command -v kimi-cli 2>/dev/null || true)"
  if [ -n "$path" ]; then
    if ! output="$("$path" --version 2>&1)"; then
      printf 'broken|%s|\n' "$path"
      return 0
    fi
    version="$(extract_version "$output")"
    if [ -z "$version" ]; then
      version="-"
    fi
    printf 'ok|%s|%s\n' "$path" "$version"
    return 0
  fi

  printf 'missing||\n'
}

probe_antigravity() {
  local output version path
  path="$(command -v agy 2>/dev/null || true)"
  if [ -z "$path" ] && [ -x "$HOME/.local/bin/agy" ]; then
    path="$HOME/.local/bin/agy"
  fi
  if [ -z "$path" ]; then
    printf 'missing||\n'
    return 0
  fi
  if ! output="$("$path" --version 2>&1)"; then
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

latest_kimi_version() {
  local version
  version="$(
    curl -fsSL --connect-timeout 5 --max-time 12 --retry 2 --retry-delay 1 \
      "https://code.kimi.com/kimi-code/latest" 2>/dev/null | tr -d '[:space:]' || true
  )"
  if [ -z "$version" ] && command -v wget >/dev/null 2>&1; then
    version="$(
      wget -q -T 12 -O - "https://code.kimi.com/kimi-code/latest" 2>/dev/null | tr -d '[:space:]' || true
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
      if [ -z "$latest" ] || [ "$latest" = "-" ]; then
        printf '无法检查|请检查网络或 registry\n'
        return 0
      fi
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
  local path="${4:-}"
  local cmp migration_health migration_state old_sessions new_sessions old_history new_history reason path_state
  case "$state" in
    ok)
      if [ -n "$path" ] && ! has_kimi_migrate_command "$path"; then
        printf '可更新|检测到旧架构，建议执行 update 迁移到 kimi-code\n'
        return 0
      fi

      migration_health="$(kimi_migration_health)"
      IFS='|' read -r migration_state old_sessions new_sessions old_history new_history reason <<<"$migration_health"
      if [ "$migration_state" = "incomplete" ]; then
        printf '迁移未完成|执行 update 并完成会话迁移\n'
        return 0
      fi

      path_state="$(kimi_command_path_state)"
      case "$path_state" in
        missing|stale)
          printf 'PATH未配置|执行 fix 后可直接输入 kimi\n'
          return 0
          ;;
        *)
          ;;
      esac

      if [ -z "$latest" ] || [ "$latest" = "-" ]; then
        printf '无法检查|请检查网络或 kimi-code 版本源\n'
      elif [ -n "$current" ] && [ "$current" != "-" ]; then
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

status_and_tip_antigravity() {
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
        printf '已安装|可执行，尝试update\n'
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
  curl --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 -fsSL https://code.kimi.com/kimi-code/install.sh | bash >/dev/null 2>&1
}

count_kimi_session_states() {
  local home_dir="$1"
  if [ ! -d "$home_dir/sessions" ]; then
    printf '0'
    return 0
  fi
  find "$home_dir/sessions" -type f -name 'state.json' 2>/dev/null | wc -l | tr -d '[:space:]'
}

count_kimi_history_files() {
  local home_dir="$1"
  if [ ! -d "$home_dir/user-history" ]; then
    printf '0'
    return 0
  fi
  find "$home_dir/user-history" -type f 2>/dev/null | wc -l | tr -d '[:space:]'
}

read_kimi_migration_report() {
  local report_path="$1"
  local marker_path="${HOME}/.kimi/.migrated-to-kimi-code"
  python3 - "$report_path" "$marker_path" <<'PY'
import json
import os
import sys

path = sys.argv[1]
marker_path = sys.argv[2]


def load_json(json_path):
    if not os.path.isfile(json_path):
        return None
    try:
        with open(json_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


report = load_json(path)
marker = load_json(marker_path)
runs = []
if marker:
    runs.extend(marker.get("runs") or [])
if report:
    runs.append(report)

if not runs:
    print("0|false||0|0|0|0")
    raise SystemExit(0)

# 后续的 config-only 迁移会覆盖 migration-report.json；会话是否完整迁移
# 需要以历史 run 中最近一次 scope=all 的官方结果为准。
full_runs = [
    run for run in runs
    if (((run.get("summary") or {}).get("sessions") or {}).get("scope") or "") != "config-only"
]
data = full_runs[-1] if full_runs else runs[-1]

summary = data.get("summary") or {}
config = summary.get("config") or {}
sessions = summary.get("sessions") or {}
history = summary.get("userHistory") or {}

config_migrated = "true" if config.get("migrated") is True else "false"
scope = sessions.get("scope") or ""
sessions_expected = (sessions.get("sessionsMigrated") or 0) + (sessions.get("sessionsAlreadyMigrated") or 0)
sessions_failed = len(sessions.get("sessionsFailed") or [])
history_copied = history.get("copied") or 0
history_skipped = history.get("skippedExisting") or 0

print(f"1|{config_migrated}|{scope}|{sessions_expected}|{sessions_failed}|{history_copied}|{history_skipped}")
PY
}

kimi_migration_health() {
  local legacy_home="$HOME/.kimi"
  local new_home="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
  local report_path="${new_home}/migration-report.json"
  local old_sessions old_history new_sessions new_history
  local report_exists config_migrated scope sessions_expected sessions_failed history_copied history_skipped

  if [ ! -d "$legacy_home" ]; then
    printf 'complete|0|0|0|0|no_legacy_data\n'
    return 0
  fi

  old_sessions="$(count_kimi_session_states "$legacy_home")"
  old_history="$(count_kimi_history_files "$legacy_home")"
  new_sessions="$(count_kimi_session_states "$new_home")"
  new_history="$(count_kimi_history_files "$new_home")"

  IFS='|' read -r report_exists config_migrated scope sessions_expected sessions_failed history_copied history_skipped \
    <<<"$(read_kimi_migration_report "$report_path")"

  if [ "$report_exists" != "1" ]; then
    printf 'incomplete|%s|%s|%s|%s|missing_report\n' "$old_sessions" "$new_sessions" "$old_history" "$new_history"
    return 0
  fi

  if [ "$config_migrated" != "true" ]; then
    printf 'incomplete|%s|%s|%s|%s|config_not_migrated\n' "$old_sessions" "$new_sessions" "$old_history" "$new_history"
    return 0
  fi

  if [ "$old_history" -gt 0 ] && [ "$new_history" -lt "$old_history" ]; then
    printf 'incomplete|%s|%s|%s|%s|history_not_fully_migrated\n' "$old_sessions" "$new_sessions" "$old_history" "$new_history"
    return 0
  fi

  if [ "$old_sessions" -gt 0 ]; then
    if [ "$scope" = "config-only" ]; then
      printf 'incomplete|%s|%s|%s|%s|sessions_scope_config_only\n' "$old_sessions" "$new_sessions" "$old_history" "$new_history"
      return 0
    fi
    if [ "${sessions_failed:-0}" -gt 0 ]; then
      printf 'incomplete|%s|%s|%s|%s|sessions_failed\n' "$old_sessions" "$new_sessions" "$old_history" "$new_history"
      return 0
    fi
    if [ "$new_sessions" -lt "${sessions_expected:-0}" ]; then
      printf 'incomplete|%s|%s|%s|%s|session_count_not_fully_migrated\n' "$old_sessions" "$new_sessions" "$old_history" "$new_history"
      return 0
    fi
  fi

  printf 'complete|%s|%s|%s|%s|ok\n' "$old_sessions" "$new_sessions" "$old_history" "$new_history"
}

resolve_kimi_cmd() {
  local path
  path="${KIMI_CODE_HOME:-$HOME/.kimi-code}/bin/kimi"
  if [ -x "$path" ]; then
    printf '%s' "$path"
    return 0
  fi
  path="$(command -v kimi 2>/dev/null || true)"
  if [ -z "$path" ] && [ -x "$HOME/.local/bin/kimi" ]; then
    path="$HOME/.local/bin/kimi"
  fi
  printf '%s' "$path"
}

kimi_code_bin_dir() {
  printf '%s' "${KIMI_CODE_HOME:-$HOME/.kimi-code}/bin"
}

kimi_path_configured() {
  local file
  for file in \
    "$HOME/.config/fish/config.fish" \
    "$HOME/.zshrc" \
    "$HOME/.zprofile" \
    "$HOME/.bashrc" \
    "$HOME/.bash_profile"; do
    if [ -f "$file" ] && grep -Fq '.kimi-code/bin' "$file" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

kimi_command_path_state() {
  local bin_dir direct_cmd path_cmd
  bin_dir="$(kimi_code_bin_dir)"
  direct_cmd="${bin_dir}/kimi"

  if [ ! -x "$direct_cmd" ]; then
    printf 'not_needed'
    return 0
  fi

  path_cmd="$(command -v kimi 2>/dev/null || true)"
  if [ -z "$path_cmd" ]; then
    if kimi_path_configured; then
      printf 'ok'
      return 0
    fi
    printf 'missing'
    return 0
  fi

  if [ "$path_cmd" = "$direct_cmd" ]; then
    printf 'ok'
    return 0
  fi

  if [ "$(cd "$(dirname "$path_cmd")" 2>/dev/null && pwd -P)/$(basename "$path_cmd")" = "$(cd "$(dirname "$direct_cmd")" 2>/dev/null && pwd -P)/$(basename "$direct_cmd")" ]; then
    printf 'ok'
    return 0
  fi

  if "$path_cmd" --version >/dev/null 2>&1; then
    if kimi_path_configured; then
      printf 'ok'
      return 0
    fi
    printf 'ok'
  else
    printf 'stale'
  fi
}

append_once() {
  local file="$1"
  local marker="$2"
  local content="$3"

  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -Fq "$marker" "$file" 2>/dev/null; then
    return 0
  fi

  {
    printf '\n'
    printf '%s\n' "$marker"
    printf '%s\n' "$content"
  } >>"$file"
}

ensure_kimi_path_config() {
  local bin_dir fish_file zshrc zprofile bashrc bash_profile
  bin_dir="$(kimi_code_bin_dir)"

  if [ ! -x "${bin_dir}/kimi" ]; then
    return 0
  fi

  case ":$PATH:" in
    *":${bin_dir}:"*) ;;
    *) export PATH="${bin_dir}:$PATH" ;;
  esac

  fish_file="$HOME/.config/fish/config.fish"
  zshrc="$HOME/.zshrc"
  zprofile="$HOME/.zprofile"
  bashrc="$HOME/.bashrc"
  bash_profile="$HOME/.bash_profile"

  append_once "$fish_file" "# Kimi Code CLI PATH" "fish_add_path -g \"\$HOME/.kimi-code/bin\""
  append_once "$zshrc" "# Kimi Code CLI PATH" "export PATH=\"\$HOME/.kimi-code/bin:\$PATH\""
  append_once "$zprofile" "# Kimi Code CLI PATH" "export PATH=\"\$HOME/.kimi-code/bin:\$PATH\""
  append_once "$bashrc" "# Kimi Code CLI PATH" "export PATH=\"\$HOME/.kimi-code/bin:\$PATH\""
  append_once "$bash_profile" "# Kimi Code CLI PATH" "export PATH=\"\$HOME/.kimi-code/bin:\$PATH\""
}

has_kimi_migrate_command() {
  local kimi_cmd="$1"
  [ -n "$kimi_cmd" ] || return 1
  "$kimi_cmd" migrate --help >/dev/null 2>&1
}

run_kimi_migration_if_needed() {
  local kimi_cmd old_home new_home attempt
  local migration_health migration_state old_sessions new_sessions old_history new_history reason
  old_home="$HOME/.kimi"
  new_home="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
  kimi_cmd="$(resolve_kimi_cmd)"

  if [ ! -d "$old_home" ]; then
    return 0
  fi
  if [ -z "$kimi_cmd" ] || [ ! -x "$kimi_cmd" ]; then
    printf '未找到 kimi 命令，无法执行迁移。请确认安装成功后手动运行：kimi migrate\n' >&2
    return 1
  fi
  if ! has_kimi_migrate_command "$kimi_cmd"; then
    printf '当前 kimi 不支持 migrate（可能仍是旧架构）。请重试 update，或手动执行：%s migrate\n' "$kimi_cmd" >&2
    return 1
  fi

  log "检测到旧版数据目录：${old_home}"
  for attempt in 1 2; do
    log "执行 Kimi 迁移（第 ${attempt}/2 次）：${kimi_cmd} migrate"
    if ! "$kimi_cmd" migrate; then
      if [ "$attempt" -eq 1 ]; then
        log "$(color "$ANSI_YELLOW$ANSI_BOLD" "迁移执行未完成，将自动重试一次。" "$ANSI_RESET")"
        continue
      fi
      printf 'Kimi 迁移执行失败（已重试）。请重新运行：%s update-one kimi\n' "$0" >&2
      return 1
    fi

    migration_health="$(kimi_migration_health)"
    IFS='|' read -r migration_state old_sessions new_sessions old_history new_history reason <<<"$migration_health"
    if [ "$migration_state" = "complete" ]; then
      log "Kimi 迁移校验通过（旧会话 ${old_sessions} -> 新会话 ${new_sessions}，旧历史 ${old_history} -> 新历史 ${new_history}）。"
      log "Kimi 迁移完成（目标目录：${new_home}）。"
      return 0
    fi

    log "$(color "$ANSI_YELLOW$ANSI_BOLD" "迁移校验未通过（原因：${reason}，旧会话 ${old_sessions} -> 新会话 ${new_sessions}）。" "$ANSI_RESET")"
    if [ "$attempt" -eq 1 ]; then
      log "$(color "$ANSI_YELLOW$ANSI_BOLD" "将自动再执行一次迁移，请在交互中选择包含会话的迁移选项。" "$ANSI_RESET")"
    fi
  done

  printf 'Kimi 迁移仍未完成（严格校验失败）。请执行：%s update-one kimi，并在 migrate 中选择会话迁移。\n' "$0" >&2
  return 1
}

install_antigravity() {
  curl -fsSL https://antigravity.google/cli/install.sh | bash >/dev/null 2>&1
}

uninstall_gemini_cli() {
  local removed=0
  local skipped=0
  local -a failures=()
  local -a prefixes=()
  local -a unique_prefixes=()
  local -a sudo_prefixes=()
  local -a sudo_targets=()
  local -a remaining_bins=()
  local needs_sudo=0
  local npm_prefix prefix seen package_dir bin_file check_path entry

  log "$(color "$ANSI_BOLD$ANSI_CYAN" "执行模式：uninstall-gemini" "$ANSI_RESET")"
  log ""
  log "开始彻底卸载 Gemini CLI ..."

  prefixes+=("$NPM_GLOBAL_PREFIX")
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  if [ -n "$npm_prefix" ] && [ "$npm_prefix" != "undefined" ] && [ "$npm_prefix" != "null" ]; then
    prefixes+=("$npm_prefix")
  fi

  for prefix in "${prefixes[@]-}"; do
    [ -n "$prefix" ] || continue
    seen=0
    for entry in "${unique_prefixes[@]-}"; do
      if [ "$entry" = "$prefix" ]; then
        seen=1
        break
      fi
    done
    if [ "$seen" -eq 0 ]; then
      unique_prefixes+=("$prefix")
    fi
  done

  for prefix in "${unique_prefixes[@]-}"; do
    package_dir="$prefix/lib/node_modules/@google/gemini-cli"
    bin_file="$prefix/bin/gemini"
    if [ -e "$package_dir" ] || [ -L "$bin_file" ] || [ -e "$bin_file" ]; then
      if npm uninstall -g @google/gemini-cli --prefix "$prefix" >/dev/null 2>&1; then
        removed=$((removed + 1))
      else
        needs_sudo=1
        seen=0
        for entry in "${sudo_prefixes[@]-}"; do
          if [ "$entry" = "$prefix" ]; then
            seen=1
            break
          fi
        done
        if [ "$seen" -eq 0 ]; then
          sudo_prefixes+=("$prefix")
        fi
      fi

      for check_path in "$bin_file" "$package_dir"; do
        if [ -L "$check_path" ] || [ -e "$check_path" ]; then
          if rm -rf "$check_path" >/dev/null 2>&1; then
            removed=$((removed + 1))
          else
            needs_sudo=1
            seen=0
            for entry in "${sudo_targets[@]-}"; do
              if [ "$entry" = "$check_path" ]; then
                seen=1
                break
              fi
            done
            if [ "$seen" -eq 0 ]; then
              sudo_targets+=("$check_path")
            fi
          fi
        else
          skipped=$((skipped + 1))
        fi
      done
    else
      skipped=$((skipped + 1))
    fi
  done

  for check_path in \
    "$HOME/.local/bin/gemini" \
    "/opt/homebrew/bin/gemini" \
    "/usr/local/bin/gemini" \
    "$HOME/.gemini"; do
    if [ -L "$check_path" ] || [ -e "$check_path" ]; then
      if rm -rf "$check_path" >/dev/null 2>&1; then
        removed=$((removed + 1))
      else
        needs_sudo=1
        seen=0
        for entry in "${sudo_targets[@]-}"; do
          if [ "$entry" = "$check_path" ]; then
            seen=1
            break
          fi
        done
        if [ "$seen" -eq 0 ]; then
          sudo_targets+=("$check_path")
        fi
      fi
    else
      skipped=$((skipped + 1))
    fi
  done

  for check_path in \
    "$HOME/.vscode/extensions/google.geminicodeassist-"* \
    "$HOME/.vscode/extensions/google.gemini-cli-vscode-ide-companion-"*; do
    if [ -e "$check_path" ]; then
      if rm -rf "$check_path" >/dev/null 2>&1; then
        removed=$((removed + 1))
      else
        needs_sudo=1
        seen=0
        for entry in "${sudo_targets[@]-}"; do
          if [ "$entry" = "$check_path" ]; then
            seen=1
            break
          fi
        done
        if [ "$seen" -eq 0 ]; then
          sudo_targets+=("$check_path")
        fi
      fi
    else
      skipped=$((skipped + 1))
    fi
  done

  if [ "$needs_sudo" -eq 1 ]; then
    log ""
    log "$(color "$ANSI_YELLOW$ANSI_BOLD" "检测到部分残留需要管理员权限，正在请求密码继续删除..." "$ANSI_RESET")"
    if command -v sudo >/dev/null 2>&1 && [ -t 0 ]; then
      if sudo -v; then
        for prefix in "${sudo_prefixes[@]-}"; do
          if sudo npm uninstall -g @google/gemini-cli --prefix "$prefix" >/dev/null 2>&1; then
            removed=$((removed + 1))
          elif [ -e "$prefix/lib/node_modules/@google/gemini-cli" ] || [ -L "$prefix/bin/gemini" ] || [ -e "$prefix/bin/gemini" ]; then
            failures+=("sudo npm 卸载失败（prefix=${prefix}）")
          fi
        done

        for check_path in "${sudo_targets[@]-}"; do
          if [ -L "$check_path" ] || [ -e "$check_path" ]; then
            if sudo rm -rf "$check_path" >/dev/null 2>&1; then
              removed=$((removed + 1))
            elif [ -L "$check_path" ] || [ -e "$check_path" ]; then
              failures+=("sudo 删除失败：${check_path}")
            fi
          else
            skipped=$((skipped + 1))
          fi
        done
      else
        failures+=("sudo 认证失败，未能继续删除管理员权限残留")
        for prefix in "${sudo_prefixes[@]-}"; do
          if [ -e "$prefix/lib/node_modules/@google/gemini-cli" ] || [ -L "$prefix/bin/gemini" ] || [ -e "$prefix/bin/gemini" ]; then
            failures+=("需要 sudo 处理：prefix=${prefix}")
          fi
        done
        for check_path in "${sudo_targets[@]-}"; do
          if [ -L "$check_path" ] || [ -e "$check_path" ]; then
            failures+=("需要 sudo 删除：${check_path}")
          fi
        done
      fi
    else
      failures+=("当前会话无法请求 sudo（缺少 sudo 或非交互终端）")
      for prefix in "${sudo_prefixes[@]-}"; do
        if [ -e "$prefix/lib/node_modules/@google/gemini-cli" ] || [ -L "$prefix/bin/gemini" ] || [ -e "$prefix/bin/gemini" ]; then
          failures+=("需要 sudo 处理：prefix=${prefix}")
        fi
      done
      for check_path in "${sudo_targets[@]-}"; do
        if [ -L "$check_path" ] || [ -e "$check_path" ]; then
          failures+=("需要 sudo 删除：${check_path}")
        fi
      done
    fi
  fi

  if command -v which >/dev/null 2>&1; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      remaining_bins+=("$entry")
    done < <(which -a gemini 2>/dev/null | awk '!seen[$0]++')
  fi

  log ""
  log "卸载摘要："
  log "  已处理：${removed} 项"
  log "  已跳过：${skipped} 项（不存在或已清理）"
  if [ "${#failures[@]}" -gt 0 ]; then
    log "$(color "$ANSI_YELLOW$ANSI_BOLD" "  失败：${#failures[@]} 项" "$ANSI_RESET")"
    for entry in "${failures[@]-}"; do
      log "    - ${entry}"
    done
  else
    log "  失败：0 项"
  fi

  if [ "${#remaining_bins[@]}" -eq 0 ]; then
    log "$(color "$ANSI_GREEN$ANSI_BOLD" "Gemini CLI 复检：未发现 gemini 命令残留。" "$ANSI_RESET")"
  else
    log "$(color "$ANSI_YELLOW$ANSI_BOLD" "Gemini CLI 复检：仍发现以下路径，请手动处理：" "$ANSI_RESET")"
    for entry in "${remaining_bins[@]-}"; do
      log "  - ${entry}"
    done
  fi
}

kimi_vscode_extension_dir() {
  local dir
  dir="$(ls -dt "$HOME/.vscode/extensions"/moonshot-ai.kimi-code-* 2>/dev/null | head -n 1 || true)"
  printf '%s' "$dir"
}

kimi_vscode_builtin_cli_path() {
  printf '%s' "$HOME/Library/Application Support/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi"
}

ensure_kimi_vscode_builtin_cli() {
  local extension_dir manifest_path archive_path storage_dir builtin_cli manifest_info version platform output
  extension_dir="$(kimi_vscode_extension_dir)"
  if [ -z "$extension_dir" ] || [ ! -d "$extension_dir" ]; then
    printf '未找到 Kimi VS Code 插件目录：~/.vscode/extensions/moonshot-ai.kimi-code-*\n' >&2
    return 1
  fi

  manifest_path="$extension_dir/bin/kimi/manifest.json"
  archive_path="$extension_dir/bin/kimi/archive.tar.gz"
  storage_dir="$HOME/Library/Application Support/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi"
  builtin_cli="$storage_dir/kimi"

  if [ ! -f "$manifest_path" ]; then
    printf 'Kimi VS Code 插件缺少内置 CLI manifest：%s\n' "$manifest_path" >&2
    return 1
  fi
  if [ ! -f "$archive_path" ]; then
    printf 'Kimi VS Code 插件缺少内置 CLI 归档：%s\n' "$archive_path" >&2
    return 1
  fi

  manifest_info="$(python3 - "$manifest_path" <<'PY'
import json
import platform
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

machine = platform.machine().lower()
if sys.platform == "darwin":
    os_name = "darwin"
elif sys.platform.startswith("linux"):
    os_name = "linux"
elif sys.platform.startswith("win"):
    os_name = "win32"
else:
    os_name = sys.platform

arch = "arm64" if machine in {"arm64", "aarch64"} else "x64"
platform_key = f"{os_name}-{arch}"
print(f"{data.get('version', '')}|{platform_key}")
PY
)"
  version="${manifest_info%%|*}"
  platform="${manifest_info#*|}"

  if [ -x "$builtin_cli" ] && [ -f "$storage_dir/installed.json" ]; then
    if python3 - "$storage_dir/installed.json" "$version" "$platform" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

raise SystemExit(0 if data.get("version") == sys.argv[2] and data.get("platform") == sys.argv[3] else 1)
PY
    then
      if "$builtin_cli" info --json >/dev/null 2>&1; then
        printf '%s' "$builtin_cli"
        return 0
      fi
    fi
  fi

  rm -rf "$storage_dir"
  mkdir -p "$storage_dir"
  tar -xzf "$archive_path" -C "$storage_dir" --strip-components=1
  chmod 755 "$builtin_cli"
  python3 - "$storage_dir/installed.json" "$version" "$platform" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(
    json.dumps({"version": sys.argv[2], "platform": sys.argv[3], "type": "native"}, indent=2) + "\n",
    encoding="utf-8",
)
PY

  if ! output="$("$builtin_cli" info --json 2>&1)"; then
    printf 'Kimi VS Code 插件内置 CLI 校验失败：%s\n%s\n' "$builtin_cli" "$output" >&2
    return 1
  fi

  printf '%s' "$builtin_cli"
}

fix_kimi_vscode() {
  local settings_path builtin_cli output

  log "$(color "$ANSI_BOLD$ANSI_CYAN" "执行模式：fix-kimi-vscode" "$ANSI_RESET")"
  log ""

  settings_path="$HOME/Library/Application Support/Code/User/settings.json"
  python3 - "$settings_path" <<'PY'
import json
import pathlib
import sys

settings_path = pathlib.Path(sys.argv[1])
settings_path.parent.mkdir(parents=True, exist_ok=True)

if settings_path.exists() and settings_path.read_text(encoding="utf-8").strip():
    try:
        data = json.loads(settings_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"VS Code settings.json 不是标准 JSON，无法安全写入：{exc}")
else:
    data = {}

if not isinstance(data, dict):
    raise SystemExit("VS Code settings.json 根节点不是对象，无法安全写入。")

data["kimi.executablePath"] = ""
settings_path.write_text(
    json.dumps(data, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

  log "已清空 VS Code 设置：kimi.executablePath"
  log "Kimi VS Code 插件将使用内置 CLI。"

  builtin_cli="$(ensure_kimi_vscode_builtin_cli)"
  log "内置 CLI 路径：${builtin_cli}"

  output="$("$builtin_cli" info --json)"
  log "$(color "$ANSI_GREEN$ANSI_BOLD" "Kimi VS 插件内置 CLI 校验通过。" "$ANSI_RESET")"
  printf '%s\n' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("CLI 版本：%s，协议版本：%s" % (d.get("kimi_cli_version", "-"), d.get("wire_protocol_version", "-")))'
}

selftest() {
  local failed=0
  local out
  local tmp_home

  tmp_home="$(mktemp -d)"
  mkdir -p "$tmp_home/.kimi-code"

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

  out="$(status_and_tip "ok" "0.125.0" "")"
  if [ "${out%%|*}" = "无法检查" ]; then
    log "PASS status_and_tip 无法检查"
  else
    log "FAIL status_and_tip 无法检查 (got: $out)"
    failed=1
  fi

  out="$(HOME="$tmp_home" KIMI_CODE_HOME="$tmp_home/.kimi-code" status_and_tip_kimi "ok" "1.37.0" "1.38.0")"
  if [ "${out%%|*}" = "可更新" ]; then
    log "PASS status_and_tip_kimi 可更新"
  else
    log "FAIL status_and_tip_kimi 可更新 (got: $out)"
    failed=1
  fi

  out="$(HOME="$tmp_home" KIMI_CODE_HOME="$tmp_home/.kimi-code" status_and_tip_kimi "ok" "1.38.0" "1.38.0")"
  if [ "${out%%|*}" = "已是最新" ]; then
    log "PASS status_and_tip_kimi 已是最新"
  else
    log "FAIL status_and_tip_kimi 已是最新 (got: $out)"
    failed=1
  fi

  out="$(HOME="$tmp_home" KIMI_CODE_HOME="$tmp_home/.kimi-code" status_and_tip_kimi "ok" "1.38.0" "")"
  if [ "${out%%|*}" = "无法检查" ]; then
    log "PASS status_and_tip_kimi 无法检查"
  else
    log "FAIL status_and_tip_kimi 无法检查 (got: $out)"
    failed=1
  fi

  mkdir -p "$tmp_home/.kimi-code/bin"
  cat >"$tmp_home/.kimi-code/bin/kimi" <<'EOF'
#!/bin/sh
case "$1" in
  --version) printf '0.1.1\n' ;;
  migrate) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod 755 "$tmp_home/.kimi-code/bin/kimi"

  out="$(HOME="$tmp_home" KIMI_CODE_HOME="$tmp_home/.kimi-code" PATH="/usr/bin:/bin" status_and_tip_kimi "ok" "1.38.0" "1.38.0" "$tmp_home/.kimi-code/bin/kimi")"
  if [ "${out%%|*}" = "PATH未配置" ]; then
    log "PASS status_and_tip_kimi PATH未配置"
  else
    log "FAIL status_and_tip_kimi PATH未配置 (got: $out)"
    failed=1
  fi

  HOME="$tmp_home" KIMI_CODE_HOME="$tmp_home/.kimi-code" PATH="/usr/bin:/bin" ensure_kimi_path_config
  if grep -Fq '# Kimi Code CLI PATH' "$tmp_home/.config/fish/config.fish" \
    && grep -Fq '$HOME/.kimi-code/bin' "$tmp_home/.zshrc" \
    && grep -Fq '$HOME/.kimi-code/bin' "$tmp_home/.bashrc"; then
    log "PASS ensure_kimi_path_config 写入 shell 配置"
  else
    log "FAIL ensure_kimi_path_config 写入 shell 配置"
    failed=1
  fi

  out="$(raw_metrics "claude|Claude|2.1.128|-|无法检查|请检查网络或 registry|/tmp/claude")"
  if [ "$out" = "1|0|0|1" ]; then
    log "PASS raw_metrics 无法检查计为异常"
  else
    log "FAIL raw_metrics 无法检查计为异常 (got: $out)"
    failed=1
  fi

  if status_needs_update "迁移未完成"; then
    log "PASS status_needs_update 迁移未完成"
  else
    log "FAIL status_needs_update 迁移未完成"
    failed=1
  fi

  if status_needs_fix "PATH未配置"; then
    log "PASS status_needs_fix PATH未配置"
  else
    log "FAIL status_needs_fix PATH未配置"
    failed=1
  fi

  rm -rf "$tmp_home"

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
  local sibling_native_bin="$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code-darwin-arm64/claude"
  if [ -x "$native_bin" ]; then
    return 0
  fi
  if [ -x "$sibling_native_bin" ]; then
    return 0
  fi

  local tarball tmpdir
  tarball="$(latest_tarball "@anthropic-ai/claude-code-darwin-arm64@${version}")"
  if [ -z "$tarball" ]; then
    printf '错误：无法获取 Claude 原生包的 tarball 地址：%s\n' "$version" >&2
    return 1
  fi

  tmpdir="$(mktemp -d)"
  mkdir -p "$native_dir"
  if ! curl --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 -fsSL "$tarball" -o "$tmpdir/pkg.tgz"; then
    rm -rf "$tmpdir"
    return 1
  fi
  rm -rf "$native_dir"
  mkdir -p "$native_dir"
  if ! tar -xzf "$tmpdir/pkg.tgz" -C "$native_dir" --strip-components=1; then
    rm -rf "$tmpdir"
    return 1
  fi
  chmod 755 "$native_bin"
  rm -rf "$tmpdir"
}

install_claude() {
  local version="$1"
  local package_dir="$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code"
  local native_dir="$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code-darwin-arm64"
  local backup_dir backup_package backup_native exit_code
  [ -n "$version" ] || die "无法获取 Claude 最新版本，已跳过更新以保护现有安装。"

  mkdir -p "$CLAUDE_PREFIX"
  if [ ! -f "$CLAUDE_PREFIX/package.json" ]; then
    (cd "$CLAUDE_PREFIX" && npm init -y >/dev/null)
  fi

  backup_dir="$(mktemp -d)"
  backup_package="$backup_dir/claude-code"
  backup_native="$backup_dir/claude-code-darwin-arm64"
  if [ -e "$package_dir" ]; then
    cp -R "$package_dir" "$backup_package"
  fi
  if [ -e "$native_dir" ]; then
    cp -R "$native_dir" "$backup_native"
  fi

  if (cd "$CLAUDE_PREFIX" && npm install "@anthropic-ai/claude-code@${version}" --registry "$NPM_REGISTRY" --cache "$NPM_CACHE" >/dev/null) \
    && ensure_claude_native "$version" \
    && (cd "$package_dir" && node install.cjs >/dev/null); then
    rm -rf "$backup_dir"
    return 0
  fi

  exit_code=$?
  rm -rf "$package_dir" "$native_dir"
  if [ -e "$backup_package" ]; then
    mkdir -p "$(dirname "$package_dir")"
    cp -R "$backup_package" "$package_dir"
  fi
  if [ -e "$backup_native" ]; then
    mkdir -p "$(dirname "$native_dir")"
    cp -R "$backup_native" "$native_dir"
  fi
  rm -rf "$backup_dir"
  printf '错误：Claude 更新失败，已回滚到更新前的本地安装。\n' >&2
  return "$exit_code"
}

install_global_pkg() {
  local pkg="$1"
  local version="$2"
  [ -n "$version" ] || die "无法获取 ${pkg} 最新版本，已跳过更新以保护现有安装。"
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

  if [ -n "$effective_system_bin" ]; then
    mkdir -p "$effective_system_bin" 2>/dev/null || true
    if [ -w "$effective_system_bin" ]; then
      ensure_link "$effective_system_bin/claude" "$CLAUDE_APP_LINK"
      ensure_link "$effective_system_bin/codex" "$NPM_GLOBAL_PREFIX/bin/codex"
      if [ -x "$LOCAL_BIN_DIR/agy" ]; then
        ensure_link "$effective_system_bin/agy" "$LOCAL_BIN_DIR/agy"
      fi
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
      "$(pad_display "$display_name" 12)" \
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

  result="$(status_and_tip_kimi "$state" "$version" "$latest" "$path")"
  status="${result%%|*}"
  tip="${result#*|}"

  row="$(
    printf '%s %s %s %s %s %s' \
      "$(pad_display "Kimi" 12)" \
      "$(pad_display "${version:--}" 18)" \
      "$(pad_display "${latest:--}" 18)" \
      "$(pad_display "$(status_display_text "$status")" 12)" \
      "$(pad_display "$tip" 18)" \
      "${path:--}"
  )"
  row_color="$(line_color_for_status "$status")"
  log "$(color "$row_color" "$row" "$ANSI_RESET")"
}

check_one_antigravity() {
  local probe state path version latest result status tip row row_color

  probe="$(probe_antigravity)"
  state="${probe%%|*}"
  path="${probe#*|}"
  path="${path%%|*}"
  version="${probe##*|}"
  latest="$(latest_antigravity_version)"

  result="$(status_and_tip_antigravity "$state" "$version" "$latest")"
  status="${result%%|*}"
  tip="${result#*|}"

  row="$(
    printf '%s %s %s %s %s %s' \
      "$(pad_display "Antigravity" 12)" \
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

  result="$(status_and_tip_kimi "$state" "$version" "$latest" "$path")"
  status="${result%%|*}"
  tip="${result#*|}"

  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "kimi" "Kimi" "${version:--}" "${latest:--}" "$status" "$tip" "${path:--}"
}

raw_status_antigravity() {
  local probe state path version latest result status tip

  probe="$(probe_antigravity)"
  state="${probe%%|*}"
  path="${probe#*|}"
  path="${path%%|*}"
  version="${probe##*|}"
  latest="$(latest_antigravity_version)"

  result="$(status_and_tip_antigravity "$state" "$version" "$latest")"
  status="${result%%|*}"
  tip="${result#*|}"

  printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "antigravity" "Antigravity" "${version:--}" "${latest:--}" "$status" "$tip" "${path:--}"
}

check_raw() {
  raw_status_one "claude" "Claude" "claude" "@anthropic-ai/claude-code"
  raw_status_one "codex" "Codex" "codex" "@openai/codex"
  raw_status_antigravity
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

  result="$(status_and_tip_kimi "$state" "$version" "$latest" "$path")"
  status="${result%%|*}"
  tip="${result#*|}"

  render_snapshot_card "Kimi" "${version:--}" "${latest:--}" "$status" "$tip"
}

snapshot_one_antigravity() {
  local probe state path version latest status tip result

  probe="$(probe_antigravity)"
  state="${probe%%|*}"
  path="${probe#*|}"
  path="${path%%|*}"
  version="${probe##*|}"
  latest="$(latest_antigravity_version)"

  result="$(status_and_tip_antigravity "$state" "$version" "$latest")"
  status="${result%%|*}"
  tip="${result#*|}"

  render_snapshot_card "Antigravity" "${version:--}" "${latest:--}" "$status" "$tip"
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
      *)
        die "未知工具：$display_name"
        ;;
    esac
  fi
}

repair_or_update_kimi() {
  local mode="${1:-fix}"
  local current_state probe

  probe="$(probe_kimi)"
  current_state="${probe%%|*}"

  if [ "$mode" = "fix" ]; then
    if [ "$current_state" != "ok" ]; then
      install_kimi
    fi
    ensure_kimi_path_config
    return 0
  fi

  if [ "$mode" = "update" ] || [ "$current_state" != "ok" ]; then
    install_kimi
    ensure_kimi_path_config
    if ! run_kimi_migration_if_needed; then
      return 1
    fi
    return 0
  fi
}

repair_or_update_antigravity() {
  local mode="${1:-fix}"
  local probe state path version latest result status

  probe="$(probe_antigravity)"
  state="${probe%%|*}"
  path="${probe#*|}"
  path="${path%%|*}"
  version="${probe##*|}"
  latest="$(latest_antigravity_version)"
  result="$(status_and_tip_antigravity "$state" "$version" "$latest")"
  status="${result%%|*}"

  case "$mode" in
    fix)
      case "$status" in
        未安装|不可执行|异常比较结果|未知)
          install_antigravity
          ;;
        *)
          ;;
      esac
      ;;
    update)
      case "$status" in
        可更新)
          if [ -n "$path" ] && [ -x "$path" ]; then
            if ! "$path" update >/dev/null 2>&1; then
              install_antigravity
            fi
          else
            install_antigravity
          fi
          ;;
        未安装|不可执行|异常比较结果|未知)
          install_antigravity
          ;;
        已安装)
          if [ -n "$path" ] && [ -x "$path" ]; then
            "$path" update >/dev/null 2>&1 || true
          fi
          ;;
        *)
          ;;
      esac
      ;;
    *)
      die "未知模式：$mode"
      ;;
  esac
}

print_check_table() {
  log "执行检查结果："
  log "$(color "$ANSI_BOLD$ANSI_CYAN" "$(
    printf '%s %s %s %s %s %s' \
      "$(pad_display '工具' 12)" \
      "$(pad_display '当前版本' 18)" \
      "$(pad_display '最新版本' 18)" \
      "$(pad_display '状态' 12)" \
      "$(pad_display '建议' 18)" \
      "命令路径"
  )" "$ANSI_RESET")"
  log "$(color "$ANSI_DIM$ANSI_GRAY" "$(
    printf '%s %s %s %s %s %s' \
      "$(pad_display '------' 12)" \
      "$(pad_display '------' 18)" \
      "$(pad_display '------' 18)" \
      "$(pad_display '------' 12)" \
      "$(pad_display '------' 18)" \
      "------"
  )" "$ANSI_RESET")"
  check_one "Claude" "claude" "@anthropic-ai/claude-code" "$CLAUDE_PREFIX/node_modules/@anthropic-ai/claude-code"
  check_one "Codex" "codex" "@openai/codex" "$NPM_GLOBAL_PREFIX/lib/node_modules/@openai/codex"
  check_one_antigravity
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
    antigravity)
      repair_or_update_antigravity "update"
      ;;
    kimi)
      repair_or_update_kimi "update"
      ;;
    *)
      die "update-one 仅支持：claude|codex|antigravity|kimi"
      ;;
  esac
}

tool_display_name() {
  case "$1" in
    claude) printf 'Claude' ;;
    codex) printf 'Codex' ;;
    antigravity) printf 'Antigravity' ;;
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
      if (status == "可更新" || status == "迁移未完成") {
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
    可更新|迁移未完成)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

status_needs_fix() {
  case "${1:-}" in
    未安装|不可执行|PATH未配置|异常比较结果)
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
    log "[4/4] 复检完成：可更新 ${before_updatable} 项，异常 ${before_issue} 项。"
    if [ "$before_issue" -eq 0 ]; then
      log "$(color "$ANSI_GREEN$ANSI_BOLD" "结果：全部已是最新，已跳过升级动作。" "$ANSI_RESET")"
      return 0
    fi
    log "$(color "$ANSI_YELLOW$ANSI_BOLD" "结果：存在检查异常，请查看网络、registry 或工具状态。" "$ANSI_RESET")"
    return 1
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
      if [ "$key" = "kimi" ]; then
        if ! repair_or_update_kimi "update"; then
          log "$(color "$ANSI_RED$ANSI_BOLD" "[3/4] 更新 ${name} 失败" "$ANSI_RESET")"
          log "请执行 ./scripts/ai-toolchain-manager.sh update-one kimi 查看详细输出。"
          return 1
        fi
        ensure_links
      else
        run_detailed_with_fallback "[3/4] 更新 ${name}" update-one "$key"
      fi
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
    return 0
  else
    log "$(color "$ANSI_YELLOW$ANSI_BOLD" "结果：仍有待处理项（可更新 ${final_updatable}，异常 ${final_issue}）。" "$ANSI_RESET")"
    return 1
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
    可更新|迁移未完成|未安装|不可执行|异常比较结果)
      log "更新 ${tool_name} 中..."
      if [ "$tool_key" = "kimi" ]; then
        if ! repair_or_update_kimi "update"; then
          log "$(color "$ANSI_RED$ANSI_BOLD" "更新 ${tool_name} 失败" "$ANSI_RESET")"
          log "请执行 ./scripts/ai-toolchain-manager.sh update-one kimi 查看详细输出。"
          return 1
        fi
        ensure_links
      else
        run_detailed_with_fallback "更新 ${tool_name}" update-one "$tool_key"
      fi
      log "更新 ${tool_name} 完成。"
      ;;
    无法检查)
      log "${tool_name} 暂时无法检查最新版本，请确认网络或 registry 后再更新。"
      return 1
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
  local compact_status=0
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
    snapshot|check|fix|update|all|selftest|check-raw|update-one|uninstall-gemini|fix-kimi-vscode) ;;
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
      die "用法：scripts/ai-toolchain-manager.sh update-one [claude|codex|antigravity|kimi]"
    fi
    if [ "${#extra_args[@]}" -gt 1 ]; then
      die "update-one 参数过多：${extra_args[*]}"
    fi
    target_tool="$(printf '%s' "${extra_args[0]}" | tr '[:upper:]' '[:lower:]')"
    case "$target_tool" in
      claude|codex|antigravity|kimi) ;;
      *)
        die "update-one 仅支持：claude|codex|antigravity|kimi"
        ;;
    esac
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

  if [ "$mode" = "uninstall-gemini" ]; then
    uninstall_gemini_cli
    return 0
  fi

  if [ "$mode" = "fix-kimi-vscode" ]; then
    fix_kimi_vscode
    return $?
  fi

  if [ "$mode" = "all" ]; then
    if [ "$compact" -eq 1 ]; then
      run_all_compact || {
        compact_status=$?
        return "$compact_status"
      }
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
      run_update_one_compact "$target_tool" || {
        compact_status=$?
        return "$compact_status"
      }
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
    snapshot_one_antigravity
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
  repair_or_update_antigravity "$mode"
  repair_or_update_kimi "$mode"
  ensure_links

  log ""
  log "复检结果："
  print_check_table
}

main "$@"
