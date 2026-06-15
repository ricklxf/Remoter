# Web 客户端构建说明

## 问题说明

`Remoter-Win` 本身不包含 Web 客户端文件，需要单独构建 `Remoter-Client` 项目来生成 `web` 目录。

## 前提条件

1. **Node.js** (版本 16 或更高)
   - 下载: https://nodejs.org/
   - 验证: 打开命令行，运行 `node --version`

2. **Git**
   - 下载: https://git-scm.com/
   - 验证: 打开命令行，运行 `git --version`

## 方法一: 使用自动化脚本 (推荐)

1. 双击运行 `build-web.bat`
2. 等待脚本完成（首次运行需要下载依赖，可能需要几分钟）
3. 脚本会自动完成所有步骤

## 方法二: 手动构建

### 步骤 1: 克隆项目

```bash
# 在 D:\code 目录下
git clone https://github.com/ricklxf/Remoter.git
```

### 步骤 2: 安装依赖并构建

```bash
# 进入 Remoter-Client 目录
cd D:\code\Remoter\Remoter-Client

# 安装依赖
npm install

# 构建 Web 版本
npm run build:web
```

### 步骤 3: 复制 web 文件

构建完成后，web 文件会在 `D:\code\Remoter\Remoter-Server\public\` 目录。

复制到 Remoter-Win:
```bash
# 创建 web 目录
mkdir D:\code\Remoter-Win\web

# 复制文件
xcopy /E /Y "D:\code\Remoter\Remoter-Server\public\*" "D:\code\Remoter-Win\web\"
```

## 验证

构建成功后，应该看到 `D:\code\Remoter-Win\web\` 目录包含以下文件:
- index.html
- 其他 JS/CSS 文件

## 测试

1. 编译 Remoter-Win: `build.bat`
2. 启动程序: `run.bat`
3. 访问 Web 界面: http://localhost:7788

## 常见问题

### Q: npm install 很慢或失败?
A: 可以使用国内镜像:
```bash
npm config set registry https://registry.npmmirror.com
npm install
```

### Q: 构建后 web 目录还是无法访问?
A: 检查:
1. `web` 目录是否在 `Remoter-Win` 根目录
2. 程序是否正常启动（查看 remoter.log）
3. 防火墙是否阻止端口 7788

### Q: 端口 7788 被占用?
A: 可以指定其他端口:
```bash
# 手动启动程序并指定端口
D:\code\Remoter-Win\bin\Release\net8.0-windows\RemoterWin.exe --port 8080
```
然后访问 http://localhost:8080

## 项目结构说明

```
Remoter (完整项目)
├── Remoter-Client    # 控制端 (Electron + React)
│   └── npm run build:web  # 构建 Web 版本
├── Remoter-Win       # Windows 被控端 (当前目录)
│   └── web\          # Web 客户端文件 (需要构建后才有)
├── Remoter-Mac       # Mac 被控端
└── Remoter-Server    # 中继服务器
    └── public\       # Web 构建输出目录
```
