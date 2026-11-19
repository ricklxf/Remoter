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
