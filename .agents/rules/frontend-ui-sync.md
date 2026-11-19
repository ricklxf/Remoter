---
trigger: always_on
---

# 前端 UI 四端同步规则

所有涉及前端 UI 的改动，**必须同步修改全部四个客户端**，保持视觉风格、交互逻辑、文案与开关配置一致，严禁只改其中一两个端：

1. **Web** & **Electron**：`Remoter-Client/src/renderer/`（共享 React 渲染层），修改后需执行 `npm run typecheck:web && npm run build:web && npm run build` 同步更新 Web 构建产物 `Remoter-Server/public/` 与 Electron 产物 `Remoter-Client/out/`。
2. **Windows 原生客户端**：`Remoter-WinClient/`（C# WinForms）。
3. **macOS 原生客户端**：`Remoter-MacClient/`（Swift AppKit）。
