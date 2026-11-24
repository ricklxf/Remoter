---
trigger: always_on
---

# 修改代码后立刻推送并自动重启本机与 mac2 的 MacServer & 双机查日志（强制）

## 1. 每次查日志必须双机同查（本机 + `mac2`）
- 每次排查问题查看日志时，除了查看本机 `~/Library/Logs/Remoter/connections.log`，**必须顺带通过 SSH 查看 `mac2`（`lxf@Ricks-Mac-mini-2.local`）** 的 `~/Library/Logs/Remoter/connections.log` 及 `RemoterAgent` 进程状态。

## 2. 修改传输/输入/快捷键代码前必须通过回归自测（强制）
- 任何涉及 UDP 传输、码率控制、编码器、输入延迟或快捷键（Keybot）的改动，**提交推送前必须先运行**：
  ```bash
  cd /Users/lxf/Code/Remoter/Remoter-MacServer && swift build && .build/debug/RemoterAgent --self-test
  ```
- 全部用例通过后方可提交；若新增了新的边界坑，必须顺手补一条对应回归用例。

## 3. 每次修改代码后立刻推送并重启本机 + `mac2` 的 MacServer
**每次修改项目代码并验证构建/测试通过后，必须立刻执行以下完整闭环，无需等待用户再次提醒：**

1. **立刻提交并推送到远端**：
   - 使用中文 Conventional Commits 格式（`type(scope): 中文描述`）提交并推送到当前分支（`git push origin main`，若遇 HTTP/2 帧报错可用 `git -c http.version=HTTP/1.1 push origin main`）。
2. **自动编译打包并重启本机 `Remoter-MacServer`（`RemoterAgent.app`）**：
   - `Remoter-MacServer/scripts/build-app.sh` 会自动编译 MacServer 并打包嵌入最新 Web 客户端产物。
   - 执行命令通过 LaunchAgent（`KeepAlive=true` 崩溃自动拉起）重启本机服务，确保本机始终运行最新版本：
     ```bash
     cd /Users/lxf/Code/Remoter/Remoter-MacServer
     bash scripts/build-app.sh
     bash scripts/install-launchagent.sh
     ```
   - 启动后确认本机 `RemoterAgent` 进程已正常运行（`pgrep -fl RemoterAgent`）。
3. **同步通过 SSH 让 `mac2` 拉取最新代码、编译并重启 `RemoterAgent.app`（LaunchAgent 保活）**：
   ```bash
   ssh -o ConnectTimeout=5 -o BatchMode=yes lxf@Ricks-Mac-mini-2.local '
     export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
     cd ~/Code/Remoter && git -c http.version=HTTP/1.1 pull --ff-only &&
     cd ~/Code/Remoter/Remoter-MacServer && bash scripts/build-app.sh &&
     bash scripts/install-launchagent.sh
   '
   ```
   - 确认 `mac2` 上 `RemoterAgent` 进程已成功重启运行。
