# Remoter Project Memory & Rules

## 前端 UI 四端同步原则（强制）

**所有涉及前端 UI 的改动，必须同步修改全部四个客户端，保持视觉风格、交互逻辑、文案与开关配置一致：**

1. **Web & Electron 客户端**：`Remoter-Client/`（共享 `src/renderer/src/`）
   - Web 构建产物输出至：`Remoter-Server/public/`
   - 验证与构建命令：
     ```bash
     cd Remoter-Client
     npm run typecheck:web && npm run build:web && npm run build
     ```
2. **Windows 原生客户端**：`Remoter-WinClient/`（C# / .NET WinForms）
   - 验证与构建命令：
     ```bash
     cd Remoter-WinClient
     dotnet build
     ```
3. **macOS 原生客户端**：`Remoter-MacClient/`（Swift / AppKit）
   - 验证与构建命令：
     ```bash
     cd Remoter-MacClient
     swift build
     ```

## 优先参考 UU 远程逆向源码与二进制实现（强制）

**所有架构、音视频编码/码控、采集渲染、输入法/键鼠及 UI/UX 改动，都必须优先参考 UU 远程的逆向源码与二进制实现**：

- **逆向蓝图文档**：`/Users/lxf/Code/uu 远程逆向/UU_Remote_Reconstruction_Blueprint.md`
- **反编译/符号参考二进制**：`/Users/lxf/Code/uu 远程逆向/thinned/`（`UURemote`、`UURemoteServer`、`libstreamer.dylib`、`uuyc-cli`）

## 修改代码后立刻推送并自动重启本机 MacServer（强制）

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
