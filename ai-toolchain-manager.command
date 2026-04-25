#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/ai-toolchain-manager.sh"
cd "$ROOT_DIR"

normalize_mode() {
  case "${1:-}" in
    "一键搞定"|"auto"|"all") printf 'all' ;;
    "检查"|"check"|"c") printf 'check' ;;
    "修复"|"fix"|"f") printf 'fix' ;;
    "更新"|"update"|"u") printf 'update' ;;
    "快照"|"snapshot"|"s") printf 'snapshot' ;;
    "自测"|"selftest"|"t") printf 'selftest' ;;
    "") printf '' ;;
    *) printf '%s' "$1" ;;
  esac
}

run_mode() {
  local mode="$1"
  shift || true
  if "$SCRIPT_PATH" "$mode" "$@"; then
    printf '\n执行完成。\n'
    return 0
  fi
  local exit_code=$?
  printf '\n执行失败（exit=%s）。\n' "$exit_code"
  return "$exit_code"
}

render_snapshot() {
  "$SCRIPT_PATH" snapshot
  printf '\n'
}

render_update_hint() {
  local raw key name current latest status tip path item
  local update_items=""

  raw="$("$SCRIPT_PATH" check-raw 2>/dev/null || true)"
  while IFS='|' read -r key name current latest status tip path; do
    [ -n "$key" ] || continue
    if [ "$status" = "可更新" ]; then
      case "$key" in
        claude) item="1 ${name} ${current} -> ${latest}" ;;
        codex) item="2 ${name} ${current} -> ${latest}" ;;
        gemini) item="3 ${name} ${current} -> ${latest}" ;;
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
  done <<<"$raw"

  if [ -n "$update_items" ]; then
    printf '当前可更新项：%s\n' "$update_items"
  else
    printf '当前可更新项：无（均为最新或需先修复）\n'
  fi
}

run_interactive_menu() {
  local input
  while true; do
    render_update_hint
    printf '操作说明：\n'
    printf '  [回车] 一键升级全部（check -> fix -> update -> check）\n'
    printf '  [1] 仅升级 Claude\n'
    printf '  [2] 仅升级 Codex\n'
    printf '  [3] 仅升级 Gemini\n'
    printf '  [4] 仅升级 Kimi\n'
    printf '  [c] 仅检查   [f] 修复异常   [q] 退出\n'
    printf '请输入：'
    if ! read -r input; then
      input="q"
    fi
    case "$input" in
      "")
        run_mode all
        break
        ;;
      "1")
        run_mode update-one claude || true
        printf '\n'
        render_snapshot
        ;;
      "2")
        run_mode update-one codex || true
        printf '\n'
        render_snapshot
        ;;
      "3")
        run_mode update-one gemini || true
        printf '\n'
        render_snapshot
        ;;
      "4")
        run_mode update-one kimi || true
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
      "q"|"Q"|"quit"|"取消")
        printf '已取消。\n'
        break
        ;;
      *)
        printf '无效输入，请输入回车/1/2/3/4/c/f/q。\n\n'
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
