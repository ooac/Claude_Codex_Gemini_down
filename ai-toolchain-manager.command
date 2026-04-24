#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/scripts/ai-toolchain-manager.sh" snapshot
printf '\n'

MODE="${1:-}"
if [ -z "$MODE" ]; then
  if [ -t 0 ]; then
    MODE="$(
      osascript <<'APPLESCRIPT' 2>/dev/null || true
set choice to button returned of (display dialog "请选择要执行的模式：" buttons {"取消", "检查", "修复", "更新", "一键搞定"} default button "一键搞定" with title "AI 工具链管理" with icon note)
return choice
APPLESCRIPT
    )"
  else
    MODE="all"
  fi
fi

if [ -z "$MODE" ] || [ "$MODE" = "false" ] || [ "$MODE" = "取消" ]; then
  printf '已取消。\n'
  exit 0
fi

case "$MODE" in
  "一键搞定") MODE="all" ;;
  "检查") MODE="check" ;;
  "修复") MODE="fix" ;;
  "更新") MODE="update" ;;
  "auto") MODE="all" ;;
esac

if [ ! -x "$ROOT_DIR/scripts/ai-toolchain-manager.sh" ]; then
  chmod +x "$ROOT_DIR/scripts/ai-toolchain-manager.sh"
fi

if "$ROOT_DIR/scripts/ai-toolchain-manager.sh" "$MODE"; then
  EXIT_CODE=0
else
  EXIT_CODE=$?
fi

if [ "$EXIT_CODE" -eq 0 ]; then
  printf '\n执行完成。\n'
else
  printf '\n执行失败。\n'
fi

if [ -t 0 ]; then
  printf '按回车关闭窗口...\n'
  read -r _ || true
fi
