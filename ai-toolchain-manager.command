#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/ai-toolchain-manager.sh"
RAW_STATUS=""
cd "$ROOT_DIR"

normalize_mode() {
  case "${1:-}" in
    "一键搞定"|"auto"|"all") printf 'all' ;;
    "检查"|"check"|"c") printf 'check' ;;
    "修复"|"fix"|"f") printf 'fix' ;;
    "卸载Gemini"|"uninstall-gemini"|"g") printf 'uninstall-gemini' ;;
    "卸载KimiCLI"|"uninstall-kimi-cli"|"m") printf 'uninstall-kimi-cli' ;;
    "修复KimiVS插件"|"fix-kimi-vscode"|"k") printf 'fix-kimi-vscode' ;;
    "更新"|"update"|"u") printf 'update' ;;
    "快照"|"snapshot"|"s") printf 'snapshot' ;;
    "自测"|"selftest"|"t") printf 'selftest' ;;
    "") printf '' ;;
    *) printf '%s' "$1" ;;
  esac
}

run_mode() {
  local mode="$1"
  local exit_code
  shift || true
  if "$SCRIPT_PATH" "$mode" "$@"; then
    printf '\n执行完成。\n'
    return 0
  else
    exit_code=$?
    printf '\n执行失败（exit=%s）。\n' "$exit_code"
    return "$exit_code"
  fi
}

render_snapshot() {
  "$SCRIPT_PATH" snapshot
  printf '\n'
}

render_update_hint() {
  local key name current latest status tip path item
  local update_items=""

  RAW_STATUS="$("$SCRIPT_PATH" check-raw 2>/dev/null || true)"
  while IFS='|' read -r key name current latest status tip path; do
    [ -n "$key" ] || continue
    if [ "$status" = "可更新" ] || [ "$status" = "迁移未完成" ]; then
      case "$key" in
        claude) item="1 ${name} ${current} -> ${latest}" ;;
        codex) item="2 ${name} ${current} -> ${latest}" ;;
        antigravity) item="3 ${name} ${current} -> ${latest}" ;;
        kimi) item="4 ${name} ${current} -> ${latest}" ;;
        *) item="" ;;
      esac
      if [ -n "$item" ]; then
        if [ -n "$update_items" ]; then
          update_items="${update_items}，${item}"
        else
          update_items="$item"
        fi
      fi
    fi
  done <<<"$RAW_STATUS"

  if [ -n "$update_items" ]; then
    printf '当前可更新项：%s\n' "$update_items"
  else
    printf '当前可更新项：无（均为最新或需先修复）\n'
  fi
}

status_from_current_raw() {
  local key="$1"
  awk -F'|' -v k="$key" '$1 == k { print $5; exit }' <<<"$RAW_STATUS"
}

should_run_single_update() {
  local key="$1"
  local name="$2"
  local status

  status="$(status_from_current_raw "$key")"
  case "$status" in
    可更新|迁移未完成|未安装|不可执行|异常比较结果)
      return 0
      ;;
    PATH未配置)
      printf '%s 需要先修复 PATH，请按 [f] 修复异常。\n' "$name"
      return 1
      ;;
    "")
      printf '%s 当前状态未知，已跳过更新。\n' "$name"
      return 1
      ;;
    无法检查)
      printf '%s 暂时无法检查最新版本，请确认网络或 registry 后再更新。\n' "$name"
      return 1
      ;;
    *)
      printf '%s 当前为“%s”，无需更新，已跳过。\n' "$name" "$status"
      return 1
      ;;
  esac
}

run_interactive_menu() {
  local input
  while true; do
    render_update_hint
    printf '操作说明：\n'
    printf '  [回车] 一键升级全部（check -> fix -> update -> check）\n'
    printf '  [1] 仅升级 Claude\n'
    printf '  [2] 仅升级 Codex\n'
    printf '  [3] 仅升级 Antigravity\n'
    printf '  [4] 仅升级 Kimi\n'
    printf '  [c] 仅检查   [f] 修复异常   [g] 卸载 Gemini   [m] 卸载 Kimi CLI   [k] 修复 Kimi VS插件   [q] 退出\n'
    printf '请输入：'
    if ! read -r input; then
      input="q"
    fi
    case "$input" in
      "")
        run_mode all --compact
        break
        ;;
      "1")
        if should_run_single_update "claude" "Claude"; then
          run_mode update-one claude --compact || true
        fi
        printf '\n'
        render_snapshot
        ;;
      "2")
        if should_run_single_update "codex" "Codex"; then
          run_mode update-one codex --compact || true
        fi
        printf '\n'
        render_snapshot
        ;;
      "3")
        if should_run_single_update "antigravity" "Antigravity"; then
          run_mode update-one antigravity --compact || true
        fi
        printf '\n'
        render_snapshot
        ;;
      "4")
        if should_run_single_update "kimi" "Kimi"; then
          run_mode update-one kimi --compact || true
        fi
        printf '\n'
        render_snapshot
        ;;
      "c"|"C")
        run_mode check || true
        printf '\n'
        render_snapshot
        ;;
      "f"|"F")
        run_mode fix || true
        printf '\n'
        render_snapshot
        ;;
      "g"|"G")
        run_mode uninstall-gemini || true
        printf '\n'
        ;;
      "m"|"M")
        run_mode uninstall-kimi-cli || true
        printf '\n'
        ;;
      "k"|"K")
        run_mode fix-kimi-vscode || true
        printf '\n'
        ;;
      "q"|"Q"|"quit"|"取消")
        printf '已取消。\n'
        break
        ;;
      *)
        printf '无效输入，请输入回车/1/2/3/4/c/f/g/m/k/q。\n\n'
        ;;
    esac
  done
}

if [ ! -x "$SCRIPT_PATH" ]; then
  chmod +x "$SCRIPT_PATH"
fi

MODE="$(normalize_mode "${1:-}")"

if [ -n "$MODE" ]; then
  run_mode "$MODE"
else
  render_snapshot
  if [ -t 0 ]; then
    run_interactive_menu
  else
    run_mode all
  fi
fi

if [ -t 0 ]; then
  printf '按回车关闭窗口...\n'
  read -r _ || true
fi
