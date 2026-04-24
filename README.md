# AI 工具链管理

这个目录提供一个 Mac 双击入口，用来检查、修复和更新以下工具：

- Claude
- Codex
- Gemini

## 使用方式

双击 `[ai-toolchain-manager.command](/Users/xianyu_air/Desktop/GitHub/000/ai-toolchain-manager.command)`，然后用按钮选择模式：

- `check`：只检查当前版本和最新版本
- `fix`：修复异常的安装或入口
- `update`：更新到最新版并自动修复入口
- `snapshot`：只看三项工具的摘要
- `all`：一键全量处理（`check -> fix -> update -> check`）

`update` 是批量更新，一次会处理 Claude、Codex、Gemini 三项。
`all` 是一键搞定模式，直接把常见问题全流程跑完。

启动时会先显示当前三项工具的摘要，执行后会继续在终端里显示结果。当前版本不再生成 HTML 报告，也不再额外写日志文件。

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
```

如果只想双击运行：

```bash
chmod +x ai-toolchain-manager.command
./ai-toolchain-manager.command
```

## 脚本说明

- `[scripts/ai-toolchain-manager.sh](/Users/xianyu_air/Desktop/GitHub/000/scripts/ai-toolchain-manager.sh)` 是实际执行脚本
- `.command` 只负责双击启动和模式选择
