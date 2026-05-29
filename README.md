# AI Assistant Notify

监测 Codex 对话状态，并在完成或中断时通过飞书机器人发送通知。
当前脚本会自动兼容两类 Codex 本地数据源：

- 旧版 `~/.codex/log/codex-tui.log`
- 新版 `~/.codex/sessions/**/rollout-*.jsonl`

## 功能

- 监测 Codex turn 完成和中断事件
- 发送 Codex 完成通知
- 发送 Codex 中断通知

## 使用前提

- 本机可运行 `bash`
- 本机可运行 `curl`
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

`status` 会额外显示当前 watcher 实际使用的数据源，例如 `legacy_log` 或 `rollout_jsonl`。
同时会显示几条版本信息：

- `Codex installed`：当前本机已安装版本
- `Codex verified`：当前工具已验证通过的版本上限
- `Codex latest`：当前检测到的可升级最新版本
- `Compatibility`：当前已安装版本是否还在已验证范围内

如果 `Compatibility` 显示为 `recheck needed`，说明当前已安装版本已经高于脚本已验证范围，最好重新做一次兼容性检查。

### 6. 停止监测

```bash
./bin/ai-assistant-notify stop
```

## 测试与自检

语法检查加 Codex watcher 回放测试：

```bash
./scripts/test.sh
```

如果脚本没有执行权限，可以先运行：

```bash
chmod +x ./scripts/test.sh ./scripts/test_codex_watcher.sh
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
- `status` 是否提示当前 Codex 版本已经高于脚本已验证版本
- watcher 是否已经启动
- 运行日志里是否出现 `notification sent watcher=codex type=turn_complete`
- 若 `test-notify` 成功但真实对话没有通知，优先检查运行日志
