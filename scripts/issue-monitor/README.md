# Remoter GitHub Issue 自动监控与修复工具

配合 Antigravity 定时自动化（每 15 分钟巡检一次）使用：

- **新 Issue 巡检**：通过 `gh` CLI 拉取 `ricklxf/Remoter` 的 Open Issues，自动过滤已处理和忽略标签（`wontfix`/`invalid`/`duplicate`）。
- **Bug 自动修复**：确认为 Bug 时，在独立的 `git worktree` 分支 `fix/issue-<N>` 上修复（不干扰当前工作区）、运行验证测试、创建 PR、在 Issue 下回复说明，并推送 Telegram 通知。
- **需求类推送 TG**：判断为功能需求 / 改进建议时，整理摘要后直接推送到你的 Telegram。

## 1. 配置 Telegram Bot 推送

本地配置文件位于 `~/.config/remoter-issue-monitor/config.json`（不提交到 Git，权限 `600`）：

```bash
python3 /Users/lxf/Code/Remoter/scripts/issue-monitor/issue_monitor.py init \
  --repo ricklxf/Remoter \
  --bot-token "<你的_TELEGRAM_BOT_TOKEN>" \
  --chat-id "<你的_TELEGRAM_CHAT_ID>"
```

### 如何快速获取 Bot Token 和 Chat ID
1. 在 Telegram 中找到 `@BotFather`，发送 `/newbot` 按提示创建机器人，拿到 `Bot Token`。
2. 在 Telegram 中给刚创建的机器人随便发一条消息（例如 `/start`）。
3. 在终端执行（把 `<TOKEN>` 换成你的 Token）查看 `"chat":{"id": ...}`：
   ```bash
   curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | python3 -m json.tool
   ```

### 发送一条测试通知

```bash
python3 /Users/lxf/Code/Remoter/scripts/issue-monitor/issue_monitor.py notify \
  --type test \
  --title "监控通道连通性测试" \
  --summary "Remoter Issue 监控已就绪！"
```

## 2. 常用命令

```bash
# 查看当前配置与已处理记录
python3 /Users/lxf/Code/Remoter/scripts/issue-monitor/issue_monitor.py status

# 手动检查新 Issue
python3 /Users/lxf/Code/Remoter/scripts/issue-monitor/issue_monitor.py check

# 预览通知格式（不实际发送）
python3 /Users/lxf/Code/Remoter/scripts/issue-monitor/issue_monitor.py notify \
  --type feature --issue 1 --title "测试需求" \
  --url "https://github.com/ricklxf/Remoter/issues/1" \
  --summary "测试需求摘要" --dry-run
```
