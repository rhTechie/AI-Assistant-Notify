# AI Assistant Notify

监测 Codex 对话状态，并在提问、完成、中断或失败时通过飞书机器人发送通知。
当前脚本会自动兼容两类 Codex 本地数据源：

- 旧版 `~/.codex/log/codex-tui.log`
- 新版 `~/.codex/sessions/**/rollout-*.jsonl`

## 功能

- 监测 Codex 主会话 turn 的提问、完成、中断和失败事件
- 多 Agent 模式下忽略内部子会话，只通知用户主会话
- 提问通知提示返回 Codex 回答，不发送问题正文
- 通知只包含项目名和工具名，不发送完整命令参数或绝对路径
- 飞书临时失败支持有边界的超时与重试

## 使用前提

- 本机可运行 `bash`
- 本机可运行 `curl`
- 本机可运行 `flock`
- 本机可运行 `jq`（Codex 升级后的动态兼容性检查需要）
- 已经安装并在使用 Codex

## 获取仓库

```bash
git clone <your-repo-url>
cd AI-Assistant-Notify
```

## 快速开始

### 1. 创建飞书机器人

创建一个飞书自定义机器人，并拿到 webhook。

### 2. 初始化配置

推荐只在仓库根目录放一份 `.env`：

```bash
cp .env.example .env
```

配置示例：

```bash
CODEX_FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/your-codex-webhook"
CODEX_FEISHU_KEYWORD="Codex提醒"

# 可选，以下均为默认值
FEISHU_NOTIFY_CONNECT_TIMEOUT_SECONDS=5
FEISHU_NOTIFY_MAX_TIME_SECONDS=15
FEISHU_NOTIFY_MAX_ATTEMPTS=3
FEISHU_NOTIFY_RETRY_BACKOFF_SECONDS=1
```

配置文件固定为仓库根目录 `.env`。

### 3. 测试飞书通知链路

```bash
./bin/ai-assistant-notify test-notify
```

### 4. 启动监测

```bash
./bin/ai-assistant-notify start
```

### 5. 查看状态

```bash
./bin/ai-assistant-notify status
```

`Codex` 一行显示本机版本和当前数据源，例如 `Codex: 0.162.0 (rollout_jsonl)`。
`Core events` 表示核心事件格式的检查结果：

- `verified`：版本在项目已验证范围内
- `recognized`：从当前版本的主会话中识别出同一轮的开始和结束事件
- `unconfirmed`：缺少足够的匹配记录，或事件格式尚无法识别
- `unavailable`：缺少版本、数据源或 `jq`，无法检查

`recognized` 只表示核心事件格式可被识别，不代表所有通知场景都经过回归测试。Codex 更新后无需手动调整已验证版本上限；若事件格式变化，仍需更新 watcher 的解析逻辑。

### 6. 停止监测

```bash
./bin/ai-assistant-notify stop
```

## 测试与自检

语法检查、进程管理测试、飞书 mock 测试和 Codex watcher 回放测试：

```bash
./scripts/test.sh
```

如果脚本没有执行权限，可以先运行：

```bash
chmod +x ./scripts/test.sh ./scripts/test_process_utils.sh ./scripts/test_notify.sh ./scripts/test_codex_watcher.sh
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
- Codex 是否已经产生本地会话数据
- 若是旧版本 Codex，检查 `~/.codex/log/codex-tui.log` 是否存在
- 若是新版本 Codex，检查 `~/.codex/sessions/` 下是否已有 `rollout-*.jsonl`
- `status` 的 `Core events` 是否为 `unconfirmed` 或 `unavailable`
- watcher 是否已经启动
- 运行日志里是否出现 `notification sent watcher=codex type=turn_complete`
- 若 `test-notify` 成功但真实对话没有通知，优先检查运行日志
