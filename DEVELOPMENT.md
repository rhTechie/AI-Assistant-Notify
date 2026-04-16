# Development Guide

面向本仓库的维护者和二次开发者。

## 本地开发

推荐直接使用仓库里的 CLI 入口，并显式指定当前仓库配置：

```bash
AI_ASSISTANT_NOTIFY_ENV="$PWD/.env" ./bin/ai-assistant-notify status
AI_ASSISTANT_NOTIFY_ENV="$PWD/.env" ./bin/ai-assistant-notify test-notify
AI_ASSISTANT_NOTIFY_ENV="$PWD/.env" ./bin/ai-assistant-notify start codex
```

也可以通过 npm script 调试：

```bash
AI_ASSISTANT_NOTIFY_ENV="$PWD/.env" npm run dev -- status
AI_ASSISTANT_NOTIFY_ENV="$PWD/.env" npm run dev -- start codex
```

如果要绕过 CLI 包装层，直接调主脚本：

```bash
AI_ASSISTANT_NOTIFY_ENV="$PWD/.env" bash scripts/watch.sh status
AI_ASSISTANT_NOTIFY_ENV="$PWD/.env" bash scripts/watch.sh start
```

## 配置策略

开发调试时建议显式指定：

```bash
AI_ASSISTANT_NOTIFY_ENV="$PWD/.env"
```

这样可以避免被全局配置 `~/.config/ai-assistant-notify/.env` 干扰。

## npm 安装行为

```bash
npm install -g .
```

这条命令在本地开发时通常会把全局包链接到当前仓库，不是完整复制安装。优点是你修改仓库代码后，全局命令会立即生效。

如果要验证“真正发布后用户安装的形态”，用 tarball：

```bash
npm pack
npm install -g ./ai-assistant-notify-0.1.0.tgz
```

## 常用开发命令

```bash
npm test
npm run pack:dry-run
AI_ASSISTANT_NOTIFY_ENV="$PWD/.env" npm run dev -- status
AI_ASSISTANT_NOTIFY_ENV="$PWD/.env" npm run dev -- start
```

## 发布流程

```bash
npm test
npm pack --dry-run
npm config set //registry.npmjs.org/:_authToken token
npm whoami --registry https://registry.npmjs.org 
npm publish --access public --registry https://registry.npmjs.org
npm view ai-assistant-notify --registry https://registry.npmjs.org
```

发布前检查：

- `package.json` 的 `name` 未被占用
- `version` 已递增
- `.env` 未提交到 git

## 项目结构

```text
bin/
  ai-assistant-notify        npm CLI 入口
scripts/
  watch.sh                   主入口
  lib_env.sh                 配置加载
  lib_notify.sh              飞书通知
  watchers/
    codex_watcher.sh
    claude_watcher.sh
  utils/
    process_utils.sh
    log_utils.sh
```

## 调试检查点

- 配置加载结果：`ai-assistant-notify status`
- 运行日志：`/tmp/ai-assistant-notify/watch-runtime.log`
- 错误日志：`/tmp/ai-assistant-notify/watch-errors.log`
- 打包清单：`npm pack --dry-run`
