# Codex Feishu Notify

这个仓库用于在 Codex 异步工作结束或被中断时，通过飞书机器人提醒你回来查看。

适合配合 Codex 的 `--yolo` 使用：不处理审批流程，只关注当前这一问是否已经结束。

## 使用方式

1. 复制配置模板：

```bash
cp .env.example .env
```

2. 修改 `.env`：

- 把 `FEISHU_WEBHOOK` 改成你的飞书机器人 webhook
- 把 `FEISHU_KEYWORD` 改成飞书机器人安全设置里实际配置的关键词

3. 测试飞书链路：

```bash
./scripts/watch_codex_notify.sh test-notify
```

4. 启动 watcher：

```bash
./scripts/watch_codex_notify.sh start
```

5. 查看状态：

```bash
./scripts/watch_codex_notify.sh status
```

6. 停止 watcher：

```bash
./scripts/watch_codex_notify.sh stop
```

## 通知规则

- 正常完成的 `user_input` 轮次会发送结束通知
- 被 `interrupt` 打断的轮次会发送中断通知
- 被打断的轮次不会再重复发送完成通知
- watcher 只处理启动之后新增的日志内容，不回放旧交互

## 配置

`.env` 只需要配置飞书机器人：

- `FEISHU_WEBHOOK`
  飞书机器人 webhook，必填
- `FEISHU_KEYWORD`
  飞书机器人安全关键词，必须和机器人后台配置完全一致

脚本默认监听 `~/.codex/log/codex-tui.log`。

## 飞书机器人配置

这个工具使用飞书群聊的自定义机器人 webhook，只负责往群里推送文本消息。

1. 在飞书里创建或打开一个用于接收 Codex 通知的群聊。
2. 打开群聊设置，进入群机器人管理。
3. 选择添加机器人，然后选择自定义机器人。
4. 填写机器人名称，例如 `Codex提醒`。
5. 在安全设置里建议选择自定义关键词，关键词填写成 `.env` 里的 `FEISHU_KEYWORD`，例如 `Codex提醒`。
6. 创建完成后复制 webhook 地址，填入 `.env` 的 `FEISHU_WEBHOOK`。
7. 回到本仓库执行 `./scripts/watch_codex_notify.sh test-notify`，确认群里能收到测试消息。

注意：

- 如果开启了关键词安全设置，发送内容里必须包含该关键词，否则飞书会拒收消息。
- 当前脚本只支持关键词校验，不支持飞书的签名校验。
- webhook 地址等同于推送凭证，不要提交到 git。


## 排障

推荐按这个顺序排：

1. 先看 watcher 是否在运行：

```bash
./scripts/watch_codex_notify.sh status
```

2. 再看飞书链路是否正常：

```bash
./scripts/watch_codex_notify.sh test-notify
```

3. 如果还不通，再看日志：

- `/tmp/codex-feishu-notify/watch-runtime.log`
- `/tmp/codex-feishu-notify/watch-errors.log`

日志用途：

- `watch-runtime.log` 记录 watcher 自己的运行状态，比如启动时间、监听的 Codex 日志路径、通知是否已经发送。
- `watch-errors.log` 记录通知发送失败的原因，比如 webhook 配错、关键词不匹配、网络请求失败、飞书接口返回错误。

## 依赖

- `bash`：运行脚本，当前 watcher 使用了 bash 语法。
- `curl`：调用飞书 webhook 发送通知。
- `flock`：加锁，避免重复启动多个 watcher。
- `tail`：持续监听 Codex 的 `codex-tui.log` 新增内容。
- `sed`：从 Codex 日志行里提取 thread、turn、cwd 等字段。
- `grep`：判断日志行是否是 turn 开始、完成、中断或工具调用。
