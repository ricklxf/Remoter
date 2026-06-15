# Remoter-Win

Windows远程桌面控制服务，基于WebSocket协议实现低延迟屏幕共享和输入控制。

## 功能特性

- 🖥️ **屏幕捕获**：支持DXGI桌面复制（GPU加速）和GDI回退方案
- ⌨️ **输入控制**：完整的鼠标和键盘事件转发
- 🔐 **端到端加密**：基于ECDH的密钥交换，AES加密通信
- 📋 **剪贴板同步**：支持文本和图片的双向同步
- 📁 **文件传输**：支持远程文件浏览和传输
- 🎯 **自适应画质**：根据网络带宽和CPU使用率自动调整FPS和质量
- 🚀 **低延迟**：延迟优先的编码策略，默认60 FPS

## 系统要求

- Windows 10/11
- .NET 8.0 Runtime
- 管理员权限（部分功能需要）

## 编译方法

### 前置条件

1. 安装 [.NET 8.0 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
2. 安装 [Visual Studio 2022](https://visualstudio.microsoft.com/) 或 [VS Code](https://code.visualstudio.com/)

### 使用命令行编译

```powershell
# 克隆或进入项目目录
cd d:\code\Remoter-Win

# Release模式编译（推荐）
dotnet build --configuration Release

# Debug模式编译
dotnet build --configuration Debug

# 或使用提供的批处理文件
.\build.bat
```

### 使用Visual Studio编译

1. 打开 `Remoter-Win.csproj` 文件
2. 选择 `Release` 或 `Debug` 配置
3. 点击 `生成` -> `生成解决方案` (Ctrl+Shift+B)

## 编译输出目录

编译后的文件位于以下目录：

```
Remoter-Win/
├── bin/
│   ├── Release/
│   │   └── net8.0-windows/
│   │       ├── RemoterWin.exe          # 主程序
│   │       ├── Remoter.ico             # 程序图标
│   │       ├── *.dll                   # 依赖的DLL文件
│   │       └── ...
│   └── Debug/
│       └── net8.0-windows/
│           ├── RemoterWin.exe
│           └── ...
└── publish/                            # 发布输出（使用dotnet publish）
    ├── RemoterWin.exe
    └── ...
```

### 发布独立可执行文件

```powershell
# 发布为独立程序（包含.NET运行时，无需安装.NET）
dotnet publish --configuration Release --self-contained true --runtime win-x64

# 发布输出在 publish/ 目录
```

## 运行方法

### 方法1：直接运行（开发/测试）

```powershell
# 进入编译输出目录
cd d:\code\Remoter-Win\bin\Release\net8.0-windows

# 运行程序
.\RemoterWin.exe
```

### 方法2：使用批处理文件

项目提供了便捷的批处理文件：

- `run.bat` - 启动程序
- `restart.bat` - 重启程序
- `build.bat` - 编译项目

### 方法3：作为Windows服务运行（推荐生产环境）

TODO: 添加Windows服务安装说明

## 配置说明

程序启动后会显示配置界面：

1. **Web端口**：WebSocket服务监听端口（默认7788）
2. **启用PIN码**：是否启用PIN码认证
3. **画面自适应**：根据网络状况自动调整画质
4. **最大CPU**：自适应模式下的CPU使用率上限

### PIN码认证

- 启用后，客户端连接需要提供PIN码
- PIN码会显示在界面上，可以点击"刷新"按钮生成新的PIN码
- 禁用PIN码时，客户端可以直接连接（不推荐公网使用）

## 客户端连接

使用WebSocket客户端连接到：

```
ws://<服务器IP>:7788
```

### 连接流程

1. 客户端连接WebSocket
2. 服务器发送 `hello` 消息（包含版本和公钥）
3. 客户端发送 `auth_pin` 或 `auth_token` 进行认证
4. 认证成功后，服务器开始发送屏幕画面

### Web客户端

项目包含简单的Web客户端测试页面：

- `web/index.html` - Web客户端界面
- `web/style.css` - 样式文件
- `web/app.js` - 客户端逻辑

使用方法：
1. 用浏览器打开 `web/index.html`
2. 输入服务器地址和PIN码
3. 点击连接

## 项目结构

```
Remoter-Win/
├── Admin/              # 管理接口
├── Auth/               # 认证相关
├── Capture/            # 屏幕捕获
├── Config/             # 配置管理
├── Crypto/             # 加密相关
├── Input/              # 输入控制
├── Logging/            # 日志系统
├── Protocol.cs         # 协议定义
├── Server/             # WebSocket服务器
│   ├── WebSocketServer.cs
│   ├── Session.cs
│   └── ...
├── Transfer/           # 文件传输
├── MainForm.cs         # 主界面
├── Program.cs          # 程序入口
├── Remoter-Win.csproj  # 项目文件
└── web/                # Web客户端
```

## 技术栈

- **.NET 8.0** - 运行时
- **C# 12** - 编程语言
- **Windows Forms** - UI框架
- **WebSocket** - 通信协议
- **DXGI Desktop Duplication** - 高性能屏幕捕获
- **Vortice.Direct3D11** - Direct3D 11绑定
- **System.Drawing** - 图像处理（JPEG编码）

## 性能优化

### 延迟优化策略

- 默认60 FPS，最低30 FPS
- JPEG质量默认50，最低30（延迟优先于画质）
- 目标带宽10MB/s
- 使用SemaphoreSlim控制并发发送

### 画质调整

可在界面上调整：
- 启用/禁用自适应画质
- 设置最大CPU使用率
- 手动调整JPEG质量（在Session.cs中修改 `_currentQuality`）

## 常见问题

### 1. 延迟太高怎么办？

- 降低JPEG质量：`Session.cs` 中设置 `_currentQuality = 30`
- 提高FPS：确保 `_currentFps` 设置为60
- 检查网络带宽是否充足

### 2. 无法捕获屏幕？

- 检查是否使用RDP会话（RDP会话中DXGI不可用，会自动回退到GDI）
- 确保有桌面访问权限

### 3. 输入控制不工作？

- 确保以管理员权限运行
- 检查是否启用了输入控制（默认启用）

## 开发计划

- [ ] 添加H.264/265硬件编码支持
- [ ] 实现增量编码（只发送变化区域）
- [ ] 添加音频传输
- [ ] 支持多显示器
- [ ] 移动端客户端

## 许可证

TODO: 添加许可证信息

## 贡献

欢迎提交Issue和Pull Request！

## 作者

ricklxf

## 更新日志

### v1.0.0 (2026-06-16)

- ✨ 初始版本发布
- ✨ 实现基本屏幕共享和输入控制
- ✨ 添加端到端加密
- ✨ 实现自适应画质
- ⚡ 优化延迟性能（延迟优先策略）
- 🎨 优化UI界面（现代化设计）
