# AI 工具链管理

这个目录提供一个 Mac 双击入口，用来检查、修复和更新以下工具：

- Claude
- Codex
- Antigravity
- Kimi

## 使用方式

双击 `ai-toolchain-manager.command` 后会先显示摘要，然后进入终端菜单：

- 直接回车：一键全量处理（`check -> fix -> update -> check`，简略进度输出）
- 输入 `1/2/3/4`：单项升级（Claude/Codex/Antigravity/Kimi，简略进度输出）
- 输入 `c`：只检查
- 输入 `f`：修复异常
- 输入 `g`：彻底卸载 Gemini CLI
- 输入 `k`：修复 Kimi VS Code 插件的 CLI 路径
- 输入 `q`：退出

`update` 是批量更新，一次会处理 Claude、Codex、Antigravity、Kimi 四项。
`all` 是一键搞定模式，直接把常见问题全流程跑完。
`all --compact` 与 `update-one --compact` 只显示阶段进度和简要结论；已是最新项会自动跳过，不再重复执行更新。`check/fix/update` 默认保持详细输出，便于排障。
`ai-toolchain-manager.command` 使用动态目录定位，不依赖固定用户路径。

Kimi 的安装/更新来源：`curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash`
Kimi 的最新版本检测来源：`https://code.kimi.com/kimi-code/latest`
Kimi CLI、数据迁移与 VS Code 插件兼容性说明见：[docs/kimi.md](docs/kimi.md)
Kimi 的命令入口检测会额外确认 `kimi` 是否能直接从终端启动：
- 若新版入口存在于 `~/.kimi-code/bin/kimi`，但 `command -v kimi` 找不到，会显示 `PATH未配置`
- 执行 `fix` 会把 `~/.kimi-code/bin` 写入 fish、zsh、bash 常见配置文件，之后新终端可直接输入 `kimi`
- Kimi 登录态不会迁移；启动后如提示 OAuth 过期，请在 Kimi 界面输入 `/login`
`fix-kimi-vscode` 会清空 VS Code 的 `kimi.executablePath`，让 Kimi VS Code 插件使用插件内置 CLI，并校验 `info --json` 可用；新版 `~/.kimi-code/bin/kimi` 继续用于终端。
Kimi 升级成功的定义是“安装成功 + 数据迁移校验通过”：
- 仅在 `update` / `update-one kimi` / `all --compact` 涉及 Kimi 更新时触发迁移
- 迁移后强校验 `migration-report.json` 与 `~/.kimi/.migrated-to-kimi-code` 中最近一次会话迁移记录，按官方实际可迁移会话数校验
- 若检测到 `Config only`、取消迁移或数据未完整迁移，会自动重试 1 次；仍失败则本次更新返回失败
- `check/check-raw/snapshot` 会显示 `迁移未完成` 状态，提醒继续执行 Kimi 更新闭环
Antigravity 的安装来源：`curl -fsSL https://antigravity.google/cli/install.sh | bash`
Antigravity 的版本检测命令：`agy --version`

启动时会先显示当前四项工具的摘要，执行后会继续在终端里显示结果。当前版本不再生成 HTML 报告，也不再额外写日志文件。

`g`（或命令 `uninstall-gemini`）会清理：
- Gemini CLI npm 全局包（`@google/gemini-cli`，覆盖 `NPM_GLOBAL_PREFIX` 与 `npm config get prefix`）
- 常见 Gemini 命令入口（`~/.local/bin/gemini`、`/opt/homebrew/bin/gemini`、`/usr/local/bin/gemini`）
- 用户目录 `~/.gemini`
- VS Code Gemini 相关扩展目录（`google.geminicodeassist-*`、`google.gemini-cli-vscode-ide-companion-*`）
- 如遇权限不足，会提示输入 sudo 密码继续删除残留

## 复制到其他电脑

前置依赖（目标电脑）：

- `bash`
- `node` / `npm`
- `python3`
- `curl`
- `tar`

复制后执行：

```bash
cd /你的目录/000
chmod +x ai-toolchain-manager.command scripts/ai-toolchain-manager.sh
./scripts/ai-toolchain-manager.sh check
./scripts/ai-toolchain-manager.sh fix
./scripts/ai-toolchain-manager.sh update
./scripts/ai-toolchain-manager.sh all
./scripts/ai-toolchain-manager.sh all --compact
./scripts/ai-toolchain-manager.sh selftest
./scripts/ai-toolchain-manager.sh check-raw
./scripts/ai-toolchain-manager.sh update-one codex
./scripts/ai-toolchain-manager.sh update-one codex --compact
./scripts/ai-toolchain-manager.sh update-one antigravity
./scripts/ai-toolchain-manager.sh update-one antigravity --compact
./scripts/ai-toolchain-manager.sh uninstall-gemini
./scripts/ai-toolchain-manager.sh fix-kimi-vscode
```

如果只想双击运行：

```bash
chmod +x ai-toolchain-manager.command
xattr -d com.apple.quarantine ai-toolchain-manager.command 2>/dev/null || true
./ai-toolchain-manager.command
```

## 脚本说明

- `scripts/ai-toolchain-manager.sh` 是实际执行脚本
- `.command` 只负责双击启动和模式选择
