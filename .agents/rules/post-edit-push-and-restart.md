---
trigger: always_on
---

# 修改代码后立刻推送并自动重启本机 MacServer（强制）

**每次修改项目代码并验证构建/测试通过后，必须立刻执行以下完整闭环，无需等待用户再次提醒：**

1. **立刻提交并推送到远端**：
   - 使用中文 Conventional Commits 格式（`type(scope): 中文描述`）提交并推送到当前分支（`git push origin main`）。
2. **自动编译打包并重启本机 `Remoter-MacServer`（`RemoterAgent.app`）**：
   - `Remoter-MacServer/scripts/build-app.sh` 会自动编译 MacServer 并打包嵌入最新 Web 客户端产物。
   - 执行命令重启本机服务，确保本机始终运行最新版本：
     ```bash
     cd /Users/lxf/Code/Remoter/Remoter-MacServer
     bash scripts/build-app.sh
     pkill RemoterAgent 2>/dev/null || true
     sleep 1
     open build/RemoterAgent.app
     ```
   - 启动后确认 `RemoterAgent` 进程已正常运行（`pgrep -fl RemoterAgent`）。
