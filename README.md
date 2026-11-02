# AI Assistant Notify

监测 Codex 和 Claude Code 的对话状态，并在需要用户返回处理时通过飞书机器人发送通知。

当前脚本支持两个独立监听器：

- Codex：兼容旧版 `~/.codex/log/codex-tui.log` 与新版 `~/.codex/sessions/**/rollout-*.jsonl`
- Claude Code：监听 `~/.claude/projects/<项目>/<session-uuid>.jsonl` 主会话记录

两个监听器可以分别启停，也可以一起运行。配置和进程模型保持一致，不需要修改 Claude Code 的 `~/.claude/settings.json`。

## 功能

- 监测 Codex 主会话的提问、完成、中断和失败事件
- 监测 Claude Code 主会话的一轮完整问答结束，以及 `AskUserQuestion` 提问
- 多 Agent 模式下忽略内部子会话，只通知用户主会话
- Claude Code 的子 agent 记录按文件排除，子 agent 结束不会触发通知
- 提问通知提示返回对应会话回答，不发送问题正文
- 通知只包含项目名，以及结束通知中的最近工具名；不发送完整命令参数、绝对路径或 session id
- 飞书临时失败支持有边界的超时与重试

## 原理

### Codex 数据源

Codex 监听器会自动选择本机可用的数据源，并优先使用新版会话文件：

- 旧版：`~/.codex/log/codex-tui.log`
- 新版：`~/.codex/sessions/**/rollout-*.jsonl`

只处理主会话记录。多 Agent 模式下的内部子会话会被过滤，避免子任务完成时重复通知。

### Claude Code 数据源

Claude Code 监听器读取主会话的 JSONL 文件：

```text
~/.claude/projects/<项目>/<session-uuid>.jsonl
```

该文件逐行追加记录。监听器只跟随主会话文件，并在文件层面排除子 agent：

```text
~/.claude/projects/<项目>/<session-uuid>/subagents/agent-*.jsonl
```

子 agent 记录带有 `isSidechain=true`。由于监听器不读取这些文件，子 agent 或内部并行任务结束时不会产生用户通知。

Claude Code 只在以下两类场景发送通知：

1. **一轮完整问答结束**：记录中出现 `assistant.message.stop_reason=end_turn`，或 `system.subtype=turn_duration`。同一轮只通知一次。
2. **Claude 向用户提问**：记录中出现 `AskUserQuestion`。

中断（`[Request interrupted by user]`）不通知。监听器只把用户输入（`promptSource=typed` 或 `queued`，或 `origin.kind=human`）的记录视为新一轮开始；后台任务通知、系统提醒和斜杠命令输出不会触发完成通知。

**权限审批不在监听范围内。** Claude Code 等待工具授权（权限审批弹窗）时不属于 `AskUserQuestion`，也不会写入上述主会话事件，因此不会发送飞书通知。如果用户等待的是工具授权，本工具不会有提醒。

通知正文只包含项目名，以及结束通知中的最近一次工具名；不包含提问正文、工具参数、绝对路径或 session id。

## 使用前提

- 本机可运行 `bash`
- 本机可运行 `curl`
- 本机可运行 `flock`
- 本机可运行 `jq`（事件解析与兼容性检查需要）
- 已安装并在使用 Codex 和/或 Claude Code
- 至少配置一个飞书机器人 webhook

使用 Claude Code 监听器时，还需要：

- Claude Code 未关闭会话持久化
- 本机已经产生 `~/.claude/projects/` 下的主会话 JSONL 记录

## 获取仓库

```bash
git clone <your-repo-url>
cd AI-Assistant-Notify
```

## 快速开始

### 1. 创建飞书机器人

在飞书群中创建自定义机器人，并拿到 webhook。

建议为 Codex 和 Claude Code 分别创建机器人，便于区分通知来源。如果复用同一个机器人，请确保消息中的关键词满足该机器人的关键词校验。

### 2. 初始化配置

推荐只在仓库根目录放一份 `.env`：

```bash
cp .env.example .env
```

配置示例：

```bash
# Codex
CODEX_FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/your-codex-webhook"
CODEX_FEISHU_KEYWORD="Codex提醒"

# Claude Code
CLAUDE_FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/your-claude-webhook"
CLAUDE_FEISHU_KEYWORD="Claude提醒"

# 可选，以下均为默认值
FEISHU_NOTIFY_CONNECT_TIMEOUT_SECONDS=5
FEISHU_NOTIFY_MAX_TIME_SECONDS=15
FEISHU_NOTIFY_MAX_ATTEMPTS=3
FEISHU_NOTIFY_RETRY_BACKOFF_SECONDS=1
```

配置文件固定为仓库根目录 `.env`。只配置一个监听器也可以正常运行；`start` 和 `run` 只会启动已经配置 webhook 的监听器。

### 3. 测试飞书通知链路

```bash
./bin/ai-assistant-notify test-notify
```

该命令会向所有已配置的监听器发送测试消息。只配置了 Codex 时，只测试 Codex；只配置了 Claude Code 时，只测试 Claude Code。

### 4. 启动监测

```bash
./bin/ai-assistant-notify start
```

第二个参数默认为 `all`，即启动所有已配置的监听器。也可以只启动一个：

```bash
./bin/ai-assistant-notify start codex
./bin/ai-assistant-notify start claude
```

`start` 在后台运行。需要在前台运行时使用 `run`：

```bash
./bin/ai-assistant-notify run claude
```

### 5. 查看状态

```bash
./bin/ai-assistant-notify status
```

输出示例（未运行时）：

```text
Runtime log: /tmp/ai-assistant-notify/watch-runtime.log
Error log: /tmp/ai-assistant-notify/watch-errors.log
Config files: /path/to/AI-Assistant-Notify/.env

codex watcher is not running.
Codex: 0.162.0 (rollout_jsonl)
Core events: verified

claude watcher is not running.
Claude: 2.1.314 (projects_jsonl)
Core events: verified
```

`Codex` 或 `Claude` 一行显示本机版本和当前数据源。Claude Code 的数据源标识为 `projects_jsonl`。

`Core events` 表示核心事件格式的检查结果，两个监听器含义相同：

- `verified`：版本在项目已验证范围内
- `recognized`：从当前版本的主会话中识别出同一轮的开始和结束事件
- `unconfirmed`：缺少足够的匹配记录，或事件格式尚无法识别
- `unavailable`：缺少版本、数据源或 `jq`，无法检查

`recognized` 只表示核心事件格式可被识别，不代表所有通知场景都经过回归测试。Codex 或 Claude Code 升级后无需手动调整已验证版本上限；若事件格式变化，仍需更新 watcher 的解析逻辑。

### 6. 停止监测

```bash
./bin/ai-assistant-notify stop
```

同样可以只停止一个监听器：

```bash
./bin/ai-assistant-notify stop codex
./bin/ai-assistant-notify stop claude
```

## CLI 参数

```text
./bin/ai-assistant-notify run    [codex|claude|all]
./bin/ai-assistant-notify start  [codex|claude|all]
./bin/ai-assistant-notify stop   [codex|claude|all]
./bin/ai-assistant-notify status [codex|claude|all]
./bin/ai-assistant-notify test-notify
```

- 第二个参数可省略，默认 `all`
- `all` 表示所有已在 `.env` 中配置 webhook 的监听器
- `run` 在当前终端前台运行，适合调试
- `start` 在后台启动，并写入 `/tmp/ai-assistant-notify/` 下的 pid 和 lock 文件
- `stop` 停止对应监听器；使用 `all` 时会依次处理 Codex 和 Claude Code
- `status` 查看运行状态、版本、数据源和核心事件兼容性
- `test-notify` 不依赖监听器进程，直接测试飞书 webhook

## 配置项

| 变量 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `CODEX_FEISHU_WEBHOOK` | 使用 Codex 时必填 | 无 | Codex 通知的飞书 webhook |
| `CODEX_FEISHU_KEYWORD` | 否 | `Codex提醒` | 拼接在 Codex 消息开头的关键词 |
| `CLAUDE_FEISHU_WEBHOOK` | 使用 Claude 时必填 | 无 | Claude Code 通知的飞书 webhook |
| `CLAUDE_FEISHU_KEYWORD` | 否 | `Claude提醒` | 拼接在 Claude 消息开头的关键词 |
| `FEISHU_NOTIFY_CONNECT_TIMEOUT_SECONDS` | 否 | `5` | curl 连接超时 |
| `FEISHU_NOTIFY_MAX_TIME_SECONDS` | 否 | `15` | 单次请求总超时 |
| `FEISHU_NOTIFY_MAX_ATTEMPTS` | 否 | `3` | 最大尝试次数 |
| `FEISHU_NOTIFY_RETRY_BACKOFF_SECONDS` | 否 | `1` | 线性重试退避基数 |

关键词会作为消息前缀发送。飞书机器人如果启用了关键词校验，消息中的关键词必须与机器人配置一致。

## 测试与自检

语法检查、进程管理测试、飞书 mock 测试、Codex watcher 回放测试和 Claude watcher 回放测试：

```bash
./scripts/test.sh
```

如果脚本没有执行权限，可以先运行：

```bash
chmod +x ./bin/ai-assistant-notify ./scripts/test.sh ./scripts/test_*.sh
```

## 排障

先看状态：

```bash
./bin/ai-assistant-notify status
```

再看日志：

- 运行日志：`/tmp/ai-assistant-notify/watch-runtime.log`
- 错误日志：`/tmp/ai-assistant-notify/watch-errors.log`

常见检查项：

- webhook 地址是否正确
- 飞书关键词是否和机器人配置一致
- 对应监听器是否已在 `.env` 中配置 webhook
- `status` 中对应监听器是否显示 `running`
- `status` 的 `Core events` 是否为 `unconfirmed` 或 `unavailable`
- 运行日志里是否出现 `notification sent watcher=codex type=turn_complete`
- 运行日志里是否出现 `notification sent watcher=claude type=turn_complete` 或 `notification sent watcher=claude type=question_requested`
- `test-notify` 成功但真实对话没有通知时，优先检查运行日志和会话数据

Claude Code 相关检查：

- `~/.claude/projects/` 是否存在
- 对应项目目录下是否已有 `<session-uuid>.jsonl` 主会话文件
- 是否只看到 `<session-uuid>/subagents/agent-*.jsonl`。这些是子 agent 记录，按设计不会触发通知
- `status` 中 `Claude` 行的数据源是否为 `projects_jsonl`
- `status` 中 Claude 的 `Core events` 是否正常
- 是否在等待权限审批。权限审批弹窗不写入 `AskUserQuestion` 事件，因此不会通知
- 是否在等待 `AskUserQuestion`。只有这种提问会触发提问通知

Codex 相关检查：

- 若是旧版本 Codex，检查 `~/.codex/log/codex-tui.log` 是否存在
- 若是新版本 Codex，检查 `~/.codex/sessions/` 下是否已有 `rollout-*.jsonl`
- `status` 中 Codex 的 `Core events` 是否正常