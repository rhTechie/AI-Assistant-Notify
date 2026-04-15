# AI Assistant Notify

监测 AI 助手（Codex、Claude Code）的工作状态，在任务完成或被中断时通过飞书机器人发送通知。

## 功能特性

- **Codex 监测**: 监测 turn 完成和中断事件，提取项目信息和最近执行的命令
- **Claude Code 监测**: 监测会话进程状态，会话结束时发送通知
- **独立通知**: Codex 和 Claude Code 使用不同的飞书机器人，便于区分通知来源
- **灵活配置**: 可选择性启用特定的监测器

## 快速开始

### 1. 配置飞书机器人

为 Codex 和 Claude Code 分别创建飞书自定义机器人：

1. 在飞书中创建或打开一个群聊
2. 进入群设置 → 群机器人 → 添加机器人 → 自定义机器人
3. 设置机器人名称（如 `Codex提醒` 或 `Claude提醒`）
4. 安全设置选择"自定义关键词"，填写关键词（如 `Codex提醒` 或 `Claude提醒`）
5. 复制 webhook 地址

### 2. 配置环境变量

```bash
cp .env.example .env
```

编辑 `.env` 文件，填入你的 webhook 地址：

```bash
# Codex 飞书通知配置
CODEX_FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/your-codex-webhook"
CODEX_FEISHU_KEYWORD="Codex提醒"

# Claude Code 飞书通知配置
CLAUDE_FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/your-claude-webhook"
CLAUDE_FEISHU_KEYWORD="Claude提醒"

# 可选：选择启用的监测器
ENABLED_WATCHERS="codex,claude"
```

### 3. 测试通知

```bash
./scripts/watch.sh test-notify
```

### 4. 启动监测

```bash
# 启动所有监测器
./scripts/watch.sh start

# 或只启动特定监测器
./scripts/watch.sh start codex
./scripts/watch.sh start claude
```

### 5. 查看状态

```bash
./scripts/watch.sh status
```

### 6. 停止监测

```bash
# 停止所有监测器
./scripts/watch.sh stop

# 或停止特定监测器
./scripts/watch.sh stop codex
```

## 通知规则

### Codex
- Turn 正常完成时发送通知
- Turn 被中断时发送通知
- 通知包含项目名称、工作目录、最近执行的命令

### Claude Code
- 会话进程退出时发送通知
- 通知包含项目名称、工作目录、最后一次用户输入

## 配置说明

### 必需配置

- `CODEX_FEISHU_WEBHOOK`: Codex 通知的飞书 webhook 地址
- `CODEX_FEISHU_KEYWORD`: Codex 通知的关键词（需与飞书机器人设置一致）
- `CLAUDE_FEISHU_WEBHOOK`: Claude Code 通知的飞书 webhook 地址
- `CLAUDE_FEISHU_KEYWORD`: Claude Code 通知的关键词（需与飞书机器人设置一致）

**注意**：
- 如果只想监测 Codex，只配置 `CODEX_FEISHU_WEBHOOK` 即可
- 如果只想监测 Claude，只配置 `CLAUDE_FEISHU_WEBHOOK` 即可
- 工具会自动检测已配置的 webhook，只启动对应的监测器
- 可以多次调用 `start` 命令启动不同的监测器（例如：先 `start codex`，后 `start claude`）

## 排障

### 1. 检查监测器状态

```bash
./scripts/watch.sh status
```

### 2. 测试飞书通知

```bash
./scripts/watch.sh test-notify
```

### 3. 查看日志

- 运行日志: `/tmp/ai-assistant-notify/watch-runtime.log`
- 错误日志: `/tmp/ai-assistant-notify/watch-errors.log`

### 常见问题

**Q: 飞书通知发送失败？**

A: 检查以下几点：
- webhook 地址是否正确
- 关键词是否与飞书机器人设置一致
- 网络连接是否正常

**Q: 监测器启动失败？**

A: 检查：
- Codex: `~/.codex/log/codex-tui.log` 文件是否存在
- Claude: `~/.claude/sessions` 目录是否存在

**Q: 如何只监测一个 AI 助手？**

A: 只配置对应的 webhook 即可：
```bash
# 只监测 Codex
CODEX_FEISHU_WEBHOOK="https://..."
CODEX_FEISHU_KEYWORD="Codex提醒"

# 只监测 Claude
CLAUDE_FEISHU_WEBHOOK="https://..."
CLAUDE_FEISHU_KEYWORD="Claude提醒"
```

**Q: 可以先启动 Codex，后启动 Claude 吗？**

A: 可以！支持多次调用 start 命令：
```bash
./scripts/watch.sh start codex   # 先启动 Codex
./scripts/watch.sh start claude  # 后启动 Claude
```

## 架构说明

项目采用模块化设计，便于扩展：

```
scripts/
├── watch.sh                    # 主入口脚本
├── lib_env.sh                  # 环境变量加载
├── lib_notify.sh               # 飞书通知模块
├── watchers/
│   ├── codex_watcher.sh       # Codex 监测模块
│   └── claude_watcher.sh      # Claude Code 监测模块
└── utils/
    ├── process_utils.sh       # 进程管理工具
    └── log_utils.sh           # 日志工具
```

每个 watcher 模块实现统一接口：
- `{watcher}_watcher_init`: 初始化检查（检查依赖、配置等）
- `{watcher}_watcher_run`: 启动监测循环

### 监测原理

**Codex**: 通过 `tail -F` 实时监听 `~/.codex/log/codex-tui.log`，解析日志中的事件（turn 开始、完成、中断、工具调用）

**Claude Code**: 定期检查 `~/.claude/sessions/` 目录中的会话文件，监测进程状态和 `~/.claude/history.jsonl` 的变化

## 依赖

- `bash`: 运行脚本
- `curl`: 发送飞书通知
- `flock`: 进程锁，避免重复启动
- `tail`: 监听日志文件（Codex）
- `sed`/`grep`: 文本处理

## 注意事项

- webhook 地址等同于推送凭证，不要提交到 git
- 关键词必须与飞书机器人后台配置完全一致
- 监测器只处理启动后的新事件，不会回放历史记录
