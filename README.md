# Codex Feishu Notify

用于将 Codex 任务中的“等待确认”或其他人工介入信号，通过飞书群机器人 webhook 发送到指定群聊。

本仓库包含两层能力：

- `feishu_notify.sh`: 负责发送飞书消息
- `watch_approval_log.sh` / `run_with_watch.sh`: 负责监听日志中的审批关键词，并在匹配时自动调用飞书通知

## 目录结构

- `scripts/feishu_notify.sh`: 发送飞书文本消息
- `scripts/watch_approval_log.sh`: 监听日志文件中的审批关键词并自动通知
- `scripts/run_with_watch.sh`: 启动一个命令并自动挂载 watcher
- `.env.example`: 环境变量示例

## 快速开始

1. 复制环境变量模板：

```bash
cp .env.example .env
```

2. 把 `.env` 中的 `FEISHU_WEBHOOK` 替换成你的真实 webhook。

真实 webhook 只保存在你本机的 `.env` 中，不会写入仓库。

3. 加载环境变量：

```bash
set -a
source .env
set +a
```

4. 发送测试消息：

```bash
./scripts/feishu_notify.sh "任务卡在权限确认，请回来处理。"
```

## 安全配置说明

不要把真实 webhook 写入仓库文件。

推荐做法：

1. 仓库中只保留 `.env.example`
2. 本机创建 `.env`
3. `.env` 已被 `.gitignore` 忽略
4. 所有脚本优先从环境变量读取 `FEISHU_WEBHOOK`
5. 如果环境变量未显式设置，脚本会尝试自动加载仓库根目录下的 `.env`

推荐的 `.env` 内容示例：

```bash
FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/your-real-webhook"
FEISHU_KEYWORD="Codex审批"
WATCH_PATTERNS="require_escalated|approval|Do you want me to|需要确认|等待确认|审批"
WATCH_NOTIFY_COOLDOWN=600
```

## 环境变量

- `FEISHU_WEBHOOK`: 必填，飞书自定义机器人 webhook
- `FEISHU_KEYWORD`: 可选，消息前缀，默认 `Codex审批`

## 典型用法

直接发送提醒：

```bash
./scripts/feishu_notify.sh "Jenkins 构建需要人工确认。"
```

自定义前缀：

```bash
FEISHU_KEYWORD="Codex提醒" ./scripts/feishu_notify.sh "新的审批请求已出现。"
```

监听一个已有日志文件：

```bash
./scripts/watch_approval_log.sh /tmp/codex.log
```

一旦日志里出现审批关键词，就会自动发送飞书消息。

直接包住一条命令并自动监听：

```bash
./scripts/run_with_watch.sh /tmp/codex.log -- your-command-here
```

例如：

```bash
./scripts/run_with_watch.sh /tmp/codex.log -- bash -lc 'your-codex-command 2>&1'
```

这个脚本会：

1. 启动 watcher
2. 执行目标命令
3. 把输出写入日志文件
4. 一旦 watcher 发现审批关键词，就自动发飞书提醒

## 默认审批关键词

默认会匹配这些内容：

- `require_escalated`
- `approval`
- `Do you want me to`
- `需要确认`
- `等待确认`
- `审批`

你可以通过 `WATCH_PATTERNS` 环境变量覆盖。

## 防刷屏机制

为了避免同一类审批提示反复刷屏，watcher 默认使用冷却时间：

- `WATCH_NOTIFY_COOLDOWN=600`

表示 600 秒内，重复匹配不会再次通知。

你可以按需调整。

## 说明

当前仓库只负责“飞书通知 + 审批状态监听”这件事，不和其他 skill 或构建仓库耦合。

如果后续要接入更复杂的能力，例如：

- 飞书里按钮确认后反向驱动本地执行
- 多种通知渠道并发发送
- 更复杂的状态分类和告警策略

建议在这个仓库基础上继续扩展，而不是继续塞回其他仓库。
