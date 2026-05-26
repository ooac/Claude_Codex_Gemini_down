# Kimi CLI 与 VS Code 插件现状

> 更新时间：2026-05-26

本文记录本仓库对 Kimi 的管理边界、升级逻辑、数据迁移逻辑，以及 Kimi VS Code 插件与新版 Kimi Code CLI 的兼容边界。

## 1. Kimi CLI 当前情况

本仓库管理的是新版 Kimi Code CLI，入口优先使用：

```bash
~/.kimi-code/bin/kimi
```

当前新版 CLI 的典型启动方式是：

```bash
kimi
```

如果终端提示 `Unknown command: kimi`，但 `~/.kimi-code/bin/kimi` 存在，说明是 PATH 未配置。脚本会在 `fix` 中把下面路径写入常见 shell 配置：

```bash
~/.kimi-code/bin
```

覆盖范围：

- `~/.config/fish/config.fish`
- `~/.zshrc`
- `~/.zprofile`
- `~/.bashrc`
- `~/.bash_profile`

## 2. Kimi 更新逻辑

Kimi 的安装与更新来源固定为官方新版 Kimi Code：

```bash
curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash
```

最新版本检测来源：

```text
https://code.kimi.com/kimi-code/latest
```

脚本中的关键入口：

```bash
./scripts/ai-toolchain-manager.sh update-one kimi
./scripts/ai-toolchain-manager.sh update-one kimi --compact
./scripts/ai-toolchain-manager.sh all --compact
```

行为规则：

- 已是最新时直接跳过，不重复更新。
- 未安装或不可执行时执行官方安装脚本。
- 检测到旧架构时执行新版安装并进入迁移校验。
- 更新 Kimi 后会同步修复 PATH，保证新终端可直接输入 `kimi`。
- Kimi 登录态不会自动迁移；如启动后提示 OAuth 过期，需要在 Kimi 界面输入 `/login`。

## 3. Kimi 数据迁移逻辑

旧版数据目录：

```text
~/.kimi
```

新版数据目录：

```text
~/.kimi-code
```

脚本只在这些场景触发迁移：

- `update`
- `update-one kimi`
- `all --compact` 且 Kimi 需要更新或迁移

迁移命令：

```bash
kimi migrate
```

迁移校验会读取：

- `~/.kimi-code/migration-report.json`
- `~/.kimi/.migrated-to-kimi-code`

校验规则：

- 配置必须迁移成功。
- 如果旧目录存在会话，迁移记录不能只是 `config-only`。
- 以官方最近一次非 `config-only` 的迁移记录为准。
- 新目录中的会话数量必须达到官方记录中的实际可迁移会话数量。
- 如果校验失败，脚本会自动重试一次；仍失败则命令失败并提示手动重跑。

注意：官方迁移会跳过空会话或无效会话，因此脚本不会再按旧目录全部 `state.json` 数量做死板比较。

## 4. Kimi VS Code 插件当前情况与处理策略

Kimi VS Code 插件支持 `kimi.executablePath` 设置。这个值如果不为空，插件会把它当成自定义 CLI。

之前 VS Code 设置里存在：

```json
"kimi.executablePath": "kimi"
```

插件会把这个值当成自定义 CLI，并调用旧插件协议：

```bash
kimi info --json
```

但新版 Kimi Code CLI 当前不支持该命令。实测新版 CLI 会返回：

```text
error: unknown option '--json'
```

新版 CLI 的命令形态是面向终端 TUI 和新架构的，例如：

```bash
kimi
kimi migrate
kimi export
```

它不是当前 VS Code 插件所期待的旧 `kimi-cli` 协议入口。

因此当前处理策略是：

- 终端使用新版 `~/.kimi-code/bin/kimi`。
- VS Code 插件先使用插件内置 CLI，保证插件面板能正常连接。
- 等官方插件适配新版 Kimi Code CLI 后，再考虑切回新版 CLI。

## 5. 为什么 VS Code 插件无法直接接新版 CLI

这不是 PATH 问题，也不是 `kimi.executablePath` 没写对。

核心原因是协议不兼容：

- VS Code 插件先用 `info --json` 做 CLI 信息探测。
- 新版 Kimi Code CLI 没有 `info` 子命令，也不支持 `--json` 全局参数。
- 插件后续还依赖旧 wire protocol。
- 因此即使把 `kimi.executablePath` 写成 `~/.kimi-code/bin/kimi` 的绝对路径，也无法让当前插件版本直接使用新版 CLI。
- 插件内置 CLI 是当前插件协议的匹配版本，支持 `info --json`。
- 为了让 VS Code 插件可用，必须让 `kimi.executablePath` 为空，让插件回到内置 CLI。

## 6. 本仓库提供的 VS 插件修复能力

脚本提供：

```bash
./scripts/ai-toolchain-manager.sh fix-kimi-vscode
```

菜单入口：

```text
[k] 修复 Kimi VS插件
```

该命令会：

- 清空 VS Code 用户设置里的自定义 CLI 路径：

```json
"kimi.executablePath": ""
```

- 让插件使用自己的内置 CLI。
- 如果 VS Code globalStorage 里的内置 CLI 缓存缺失或版本不匹配，脚本会从插件目录中的 `bin/kimi/archive.tar.gz` 重新解压。
- 再执行内置 CLI 校验：

```bash
~/Library/Application Support/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi info --json
```

校验通过后，VS Code 里需要重新加载窗口或重启 VS Code，让插件重新读取设置。

## 7. 当前可用方案

可用：

- 终端直接使用新版 Kimi Code CLI：

```bash
kimi
```

- 通过本仓库脚本更新、迁移和修复 PATH：

```bash
./scripts/ai-toolchain-manager.sh update-one kimi
./scripts/ai-toolchain-manager.sh fix
```

- 通过本仓库脚本修复 VS Code 插件，让它使用插件内置 CLI：

```bash
./scripts/ai-toolchain-manager.sh fix-kimi-vscode
```

暂不可用：

- 当前 Kimi VS Code 插件直接使用新版 `~/.kimi-code/bin/kimi` 作为后端。

等待条件：

- Kimi 官方发布适配新版 Kimi Code CLI 的 VS Code 插件。
- 或官方新版 CLI 恢复/提供兼容插件的 `info --json` 与 wire protocol。
