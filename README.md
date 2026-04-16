# AI Assistant Notify

监测 Codex、Claude Code 的工作状态，并在完成或中断时通过飞书机器人发送通知。

## 这份 README 给谁看

这份 README 面向“安装后直接使用这个工具的人”。

如果你要在本仓库里继续开发、调试、发布，请看 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 功能

- 监测 Codex turn 完成和中断事件
- 监测 Claude Code 会话结束事件
- Codex 和 Claude Code 可分别配置不同飞书机器人
- 支持按 watcher 单独启动或停止

## 安装

发布到 npm 后：

```bash
npm install -g ai-assistant-notify
```

安装后可用命令：

```bash
ai-assistant-notify
aanotify
```

## 快速开始

### 1. 创建飞书机器人

为 Codex 和 Claude Code 分别创建飞书自定义机器人，并拿到 webhook。

### 2. 初始化配置

推荐全局配置：

```bash
ai-assistant-notify init --global
```

也可以只在当前目录生成：

```bash
ai-assistant-notify init --local
```

默认配置路径：

- 全局：`~/.config/ai-assistant-notify/.env`
- 当前项目：`./.env`

两个命令的区别：

- `ai-assistant-notify init --global`：生成全局默认配置，适合长期日常使用
- `ai-assistant-notify init --local`：只在当前目录生成配置，适合项目单独覆盖或本地调试

如果全局配置和当前目录配置同时存在，当前目录 `.env` 会覆盖全局同名配置。

配置示例：

```bash
CODEX_FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/your-codex-webhook"
CODEX_FEISHU_KEYWORD="Codex提醒"

CLAUDE_FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/your-claude-webhook"
CLAUDE_FEISHU_KEYWORD="Claude提醒"
```

### 3. 测试通知

```bash
ai-assistant-notify test-notify
```

### 4. 启动监测

```bash
ai-assistant-notify start
```

只启动单个 watcher：

```bash
ai-assistant-notify start codex
ai-assistant-notify start claude
```

### 5. 查看状态

```bash
ai-assistant-notify status
```

### 6. 停止监测

```bash
ai-assistant-notify stop
```

## 配置加载规则

如果显式设置了 `AI_ASSISTANT_NOTIFY_ENV`，只加载这个文件。

否则按下面顺序加载，后加载覆盖先加载：

1. `~/.config/ai-assistant-notify/.env`
2. 当前目录 `.env`
3. 源码目录内 `.env`，仅当前两者都不存在时兜底

## 常用命令

```bash
ai-assistant-notify init --global
ai-assistant-notify init --local
ai-assistant-notify test-notify
ai-assistant-notify start
ai-assistant-notify start codex
ai-assistant-notify status
ai-assistant-notify stop
```

## 排障

查看状态：

```bash
ai-assistant-notify status
```

查看日志：

- 运行日志：`/tmp/ai-assistant-notify/watch-runtime.log`
- 错误日志：`/tmp/ai-assistant-notify/watch-errors.log`

常见检查项：

- webhook 地址是否正确
- 飞书关键词是否和机器人配置一致
- Codex 日志文件 `~/.codex/log/codex-tui.log` 是否存在
- Claude 会话目录 `~/.claude/sessions` 是否存在

## 更多信息

- 本地开发与调试：[DEVELOPMENT.md](DEVELOPMENT.md)
