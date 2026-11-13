# LKM 项目编排

LKM（理科迷）的本地开发与部署编排仓库，包含 Flutter 桌面客户端、FastAPI 后端和社区机器人。根目录负责容器编排、后端启动脚本和跨项目文档。

## 项目组成

| 目录                    | 技术栈                                           |                       默认端口 | 用途                                        |
| ----------------------- | ------------------------------------------------ | -----------------------------: | ------------------------------------------- |
| `LKM-desktop/` | Flutter、Dart、Vue/WebF | — | 桌面客户端与内置 StarHope |
| `LKM-service/`          | FastAPI、SQLAlchemy、PostgreSQL、Pulsar/RabbitMQ |                `8000` / `8001` | 业务 API、AUTH 服务及后台 worker            |
| `LKM-bot/`              | Python、AstrBot fork                             | `6185`（仅经网关 `/bot/`） | 社区机器人面板，可选组件（`--profile bot`） |
| `deploy/`               | APISIX、Kustomize、可观测性配置                  |                   `80` / `443` | Compose/Kubernetes 部署资产                 |

各子目录是独立 Git 仓库；根仓库只管理编排、部署资产和跨项目文档。提交前请在实际修改的仓库中分别检查 `git status`。

首次检出或切换根仓库版本后，在没有未保存子仓库改动的前提下初始化对应版本：

```sh
git submodule update --init --recursive
git submodule status
```

代码入口、修改归属和子模块提交流程见 [文档地图的代码导航](./docs/DOCUMENTATION.md#代码导航与修改归属)。

## 文档导航

| 入口                                                           | 用途                                             |
| -------------------------------------------------------------- | ------------------------------------------------ |
| [docs/README.md](./docs/README.md)                             | 跨项目文档索引、阅读路径与维护约定               |
| [docs/后端架构与现状.md](./docs/后端架构与现状.md)             | 后端服务拓扑、数据模型、认证、消息链路与模块边界 |
| [docs/Bot平台架构与现状.md](./docs/Bot平台架构与现状.md)       | Bot 核心、消息流水线、插件生态与管理面板         |
| [docs/社区需求与开发规划.md](./docs/社区需求与开发规划.md)     | 一期业务现状、差距、优先级与验收口径             |
| [DEVELOPMENT.md](./docs/DEVELOPMENT.md)                             | 本地开发、环境变量与常用命令                     |
| [DEPLOYMENT.md](./docs/DEPLOYMENT.md)                               | Compose/Kubernetes 部署、网关、证书与运维        |

## 快速开始

### 环境要求

- Flutter/Dart（版本与命令见 `LKM-desktop/README.md`）；Bot 面板使用 Node.js 24+ 和其声明的 pnpm 版本
- Python `>=3.13`、[uv](https://docs.astral.sh/uv/)
- PostgreSQL（后端必需；先启动并创建 `lkm` 数据库，连接参数见 `LKM-service/.env.example`）
- Git
- Docker Engine + Docker Compose（运行完整基础设施时需要）

### 本地开发

```sh
# Linux / macOS：安装依赖并启动后端
./dev.sh
./dev.sh --no-run  # 仅安装后端依赖

# 桌面客户端
cd LKM-desktop
flutter pub get
flutter run
```

Windows 使用 `.\dev.ps1`，安装了 pwsh 的 Linux/macOS 使用 `pwsh ./dev.ps1`；
`--no-run` 仅安装后端依赖。脚本兼容 `back` / `all` 参数，均只操作后端。

后端 API 地址为 `http://127.0.0.1:8000`，Swagger UI 为 `http://127.0.0.1:8000/docs`。
桌面客户端在设置中配置服务地址。

完整步骤、环境变量和排错见 [DEVELOPMENT.md](./docs/DEVELOPMENT.md)。

### 完整容器栈

```sh
cp .env.example .env
# 编辑 .env，至少替换所有生产密钥和密码
docker compose config
docker compose up -d --build
docker compose ps
```

不要把 `.env`、私钥、数据库备份或访问令牌提交到 Git。生产部署前必须阅读 [DEPLOYMENT.md](./docs/DEPLOYMENT.md)。

## 常用验证

```sh
# 桌面客户端
cd LKM-desktop
flutter analyze && flutter test

# 后端
cd ../LKM-service
uv run pytest
uv run ty check
uv run ruff check

# 社区机器人面板（可选组件，默认不随主栈起）
cd ../LKM-bot
python -m pytest
```

## 文档

从 [DOCUMENTATION.md](./docs/DOCUMENTATION.md) 查看文档地图、适用场景和权威来源。常用入口：

- [本地开发](./docs/DEVELOPMENT.md)
- [Compose 生产部署](./docs/DEPLOYMENT.md)
- [运维速查](./docs/OPS-CHEATSHEET.md)
- [Kubernetes 部署](./deploy/k8s/README.md)
- [后端设计方案](./docs/后端架构与现状.md)
- [后端执行路线图](./docs/社区需求与开发规划.md)

## 文档与实现的优先级

发生冲突时，按以下顺序判断当前行为：

1. 可执行配置与源码（`package.json`、`pyproject.toml`、`docker-compose.yml`、Kustomize 清单）；
2. 对应子项目 README；
3. 根级开发、部署与运维文档；
4. 规划和路线图中的历史记录。

发现文档过期时，应在同一个改动中修正文档，并给出可执行的验证命令。
