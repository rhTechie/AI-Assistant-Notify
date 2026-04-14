# Codex Feishu Notify

这个仓库用于在 Codex 出现需要你回来处理的交互时，通过飞书机器人发提醒。

典型场景包括：

- 需要你授权执行命令
- 需要你确认文件修改
- 需要你手动选择某个选项

## 使用方式

1. 复制配置模板：

```bash
cp .env.example .env
```

2. 修改 `.env`：

- 把 `FEISHU_WEBHOOK` 改成你的飞书机器人 webhook
- 把 `FEISHU_KEYWORD` 改成飞书机器人安全设置里实际配置的关键词

3. 先测试飞书链路：

```bash
./scripts/watch_codex_approval.sh test-notify
```

4. 启动 watcher：

```bash
./scripts/watch_codex_approval.sh start
```

5. 查看状态：

```bash
./scripts/watch_codex_approval.sh status
```

6. 停止 watcher：

```bash
./scripts/watch_codex_approval.sh stop
```

## 配置生效方式

当前实现不会实时热加载 `.env`。

- 修改 `.env` 后，需要重启 watcher 才会生效
- `test-notify` 这类单次命令会读取执行当下的 `.env`

重启方式：

```bash
./scripts/watch_codex_approval.sh stop
./scripts/watch_codex_approval.sh start
```

## 命令说明

- `./scripts/watch_codex_approval.sh start`
  后台运行，适合日常使用
- `./scripts/watch_codex_approval.sh run`
  前台运行，适合调试
- `./scripts/watch_codex_approval.sh status`
  查看 watcher 状态
- `./scripts/watch_codex_approval.sh stop`
  停止 watcher
- `./scripts/watch_codex_approval.sh test-notify`
  测试飞书发送是否正常

## 环境变量

常用配置只需要关注这些：

- `FEISHU_WEBHOOK`
  飞书机器人 webhook，必填
- `FEISHU_KEYWORD`
  飞书机器人安全关键词，必须和机器人后台配置完全一致
- `CODEX_TUI_LOG_PATH`
  Codex 日志路径，默认是 `~/.codex/log/codex-tui.log`
- `CODEX_APPROVAL_WATCH_DEBUG`
  设为 `1` 时写 debug 日志

详细注释见 [.env.example](/workspace/git/codex-feishu-notify/.env.example)。

`CODEX_APPROVAL_NOTIFY_COOLDOWN` 和 `CODEX_APPROVAL_CONTEXT_WINDOW` 属于高级参数，通常不需要改。

## 漏报时怎么处理

如果某一种新的 Codex 交互没有发出飞书提醒，最简单的处理方式是：

1. 先从 `~/.codex/log/codex-tui.log` 找出对应的新事件名
2. 把事件名追加到 `.env` 里的 `CODEX_APPROVAL_EXTRA_EVENTS`
3. 重启 watcher

例如：

```bash
CODEX_APPROVAL_EXTRA_EVENTS="some_new_event"
```

然后执行：

```bash
./scripts/watch_codex_approval.sh stop
./scripts/watch_codex_approval.sh start
```

## 排障

推荐按这个顺序排：

1. 先看 watcher 是否在运行：

```bash
./scripts/watch_codex_approval.sh status
```

2. 再看飞书链路是否正常：

```bash
./scripts/watch_codex_approval.sh test-notify
```

3. 如果还不通，再看日志：

- `/tmp/codex-feishu-notify/watch-runtime.log`
- `/tmp/codex-feishu-notify/watch-errors.log`
- `/tmp/codex-feishu-notify/watch-debug.log`

## 说明

- watcher 只处理启动之后新增的日志内容，不回放旧交互
- `FEISHU_KEYWORD` 是飞书机器人的安全校验，不是本地筛选条件
- 这个方案监听的是全局 `codex-tui.log`，不是按 shell 单独隔离
- 对命令执行授权，只有真正可能弹出人工确认的命令才会提前提醒；已经被 Codex 规则放行的命令不会重复打扰
