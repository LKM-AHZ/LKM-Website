# LKM Bot 平台架构与代码实况

> **文档定位**：说明 `LKM-bot/` 的进程拓扑、消息处理流水线、插件/平台/模型抽象、管理面板
> 以及 LKM 定制层。本文以该子仓库源码与配置为准。
>
> **结构与入口核对日期**：2026-10-31。内部 Python 包名仍为 `astrbot`，面向用户的产品名和命令为
> `LKMBot` / `lkmbot`。

## 1. 定位

LKMBot 是 LKM 维护的 AstrBot 发行版，面向多 IM 平台的 LLM 聊天机器人与插件运行框架。它同时包含：

- **Bot Core**：平台接入、消息事件流水线、模型提供商、插件（Stars）、工具、知识库、定时任务。
- **Dashboard**：基于 Vue 3 + Vuetify 的管理面板，由 Python 后端以静态站点 + API 提供。
- **LKM 定制层**：`astrbot/lkm/` 中与社区站配套的 SSO、子路径部署等逻辑。

## 2. 进程拓扑

```text
main.py
  ├─ runtime_bootstrap / 路径与运行环境初始化
  └─ InitialLoader
       ├─ AstrBotCoreLifecycle
       │    ├─ 平台适配器、消息流水线、插件、Provider、定时任务
       │    └─ SQLite / 配置 / 日志 / 更新器
       └─ AstrBotDashboard
            ├─ FastAPI ASGI API
            ├─ Hypercorn
            └─ dashboard/dist 静态面板
```

- 默认 HTTP 服务端口为 `6185`（`astrbot/core/config/default.py` 的 `dashboard.port`）。
- 管理面板代码在 `dashboard/`，生产构建产物复制到 `astrbot/dashboard/dist`。
- 启动命令为 `uv run main.py`；容器镜像暴露 `6185`，入口同为 `python main.py`。

## 3. 消息处理流水线

核心阶段定义在 `astrbot/core/pipeline/stage_order.py`：

1. `WakingCheckStage`：检查是否需要唤醒 Bot。
2. `WhitelistCheckStage`：检查群聊/私聊白名单。
3. `SessionStatusCheckStage`：检查会话是否启用。
4. `RateLimitStage`：会话级频率限制。
5. `ContentSafetyCheckStage`：内容安全。
6. `PreProcessStage`：消息预处理。
7. `ProcessStage`：交给 Stars/插件或 LLM Agent 处理。
8. `ResultDecorateStage`：回复前缀、T2I、语音等结果装饰。
9. `RespondStage`：发送最终消息。

Pipeline 的上下文、调度器和阶段基类位于 `astrbot/core/pipeline/`；平台事件先归一为
`AstrMessageEvent`，再进入统一流水线。

## 4. 核心模块

| 目录                           | 职责                                                         |
| ------------------------------ | ------------------------------------------------------------ |
| `astrbot/core/platform/`       | 平台抽象、消息事件、会话与平台管理器                         |
| `astrbot/core/provider/`       | LLM/Embedding/TTS/STT/Rerank 等 Provider 抽象与注册          |
| `astrbot/core/agent/`          | Agent Runner、工具调用、上下文压缩、MCP 客户端、工具图片缓存 |
| `astrbot/core/star/`           | 插件（Star）生命周期、命令注册、配置、会话级插件状态         |
| `astrbot/core/tools/`          | 内置工具：cron、知识库、消息、Web 搜索等                     |
| `astrbot/core/knowledge_base/` | 知识库管理与检索                                             |
| `astrbot/core/cron/`           | 定时任务管理器与事件                                         |
| `astrbot/core/db/`             | SQLite 持久化、ORM 模型与 Repository                         |
| `astrbot/core/computer/`       | 本地文件/终端/沙箱访问与权限控制                             |
| `astrbot/core/config/`         | 配置模型、默认值、配置 profile 与迁移                        |
| `astrbot/builtin_stars/`       | 内置命令与群聊上下文插件                                     |
| `astrbot/api/`                 | 对插件开发者暴露的稳定 API 面                                |

## 5. 平台、Provider 与插件

- **平台**：QQ、Telegram、Discord、Slack、飞书/Lark、微信、企业微信、KOOK、Mattermost 等
  适配器通过统一平台接口接入；部分平台同时支持 Webhook/WebSocket/长连接模式。
- **Provider**：OpenAI 兼容、Anthropic、Gemini、DashScope、Xinference 等模型源通过 Provider
  注册表注册，支持文本、视觉、Embedding、Rerank、TTS/STT 等能力。
- **插件（Stars）**：插件可以注册命令、事件处理器、工具、配置项和 Dashboard 自定义页面。
  插件依赖可在运行期安装；生产镜像因此保留编译工具链与 `git`/`ripgrep`。
- **MCP/Skills**：`astrbot/core/agent/mcp_client.py` 与 `astrbot/core/skills/` 支持 MCP Server
  和技能包；工具调用统一经 `ToolExecutor` 与权限层。

## 6. 管理面板

### 6.1 后端

- `astrbot/dashboard/api/` 提供认证、平台、Provider、插件、配置、会话、聊天、知识库、备份、
  统计、日志、Cron、文件、OpenAPI、Skills 等路由。
- `astrbot/dashboard/services/` 承接业务逻辑，API 层保持薄。
- 配置服务分别位于 `config_profile_service.py`（配置档/系统设置）、
  `config_routing_service.py`（会话路由）、`config_display_service.py`（配置元数据）、
  `config_file_service.py`（配置附件）、`bot_config_service.py`（平台）、
  `provider_config_service.py`（模型源）；共享验证与保存逻辑在 `config_service.py`，
  装配入口是 `astrbot/dashboard/api/app.py`。路由直接依赖具体服务。
- `astrbot/dashboard/server.py` 负责 Hypercorn、静态资源、上传大小限制、限流、TOTP、CORS/安全头
  和 Dashboard base path。
- `astrbot/dashboard/api/open_api.py` 对外提供 OpenAPI 能力，供社区站或其他服务调用。

### 6.2 前端

`dashboard/` 是基于 Vuetify 的 Vue 3 SPA：

| 路由组         | 功能                                    |
| -------------- | --------------------------------------- |
| `/auth/*`      | 登录、首次初始化密码                    |
| `/welcome`     | 欢迎页与运行状态                        |
| `/platforms`   | 消息平台配置                            |
| `/providers`   | 模型 Provider 与模型源                  |
| `/extension/*` | 已安装插件、插件市场、MCP、Skills、组件 |
| `/config`      | AstrBot 核心配置与配置 profile          |
| `/persona`     | 人设、能力与绑定                        |
| `/data/*`      | 统计、会话、控制台、Trace               |
| `/chat`        | 独立聊天与调试面板                      |

前端构建期通过 `VITE_BASE_PATH` 决定面板挂在根路径还是子路径；API/WS/EventSource/iframe
路径由 `src/api/base.ts` 与拦截器统一补前缀。

## 7. LKM 定制层

`astrbot/lkm/` 只放本 fork 相对上游新增的社区集成代码：

- **Dashboard 子路径**：`base_path.py` 规范化 `ASTRBOT_DASHBOARD_BASE_PATH`，用于 cookie Path
  和 302 Location；默认空 = 根路径。
- **面板 SSO**：`sso.py` 用社区后台签发的一次性 RS256 票据换取面板会话：
  - 校验 `iss` / `aud=lkm:bot` / `type=bot_sso` / `account_level=admin`；
  - 校验 `jti` 一次性，失败统一 302 回面板登录页；
  - 公钥只读，票据 60 秒过期，响应带 `no-store` / `no-referrer`；
  - 当前 `jti` 表在进程内存，**默认假设面板单副本**；扩多副本前必须改为共享存储。

## 8. 数据与配置

- 运行期数据目录默认由 `astrbot/core/utils/astrbot_path.py` 解析，包含：
  - `data_v4.db`：主 SQLite 数据库；
  - `cmd_config.json`：核心配置；
  - `knowledge_base/kb.db`：知识库数据库；
  - `mcp_server.json`、`skills.json`、`t2i_templates/`、附件与临时文件。
- 生产环境应使用持久卷挂载数据目录；容器镜像内的 `data/` 仅用于开发/样例。
- 配置可通过 Dashboard、`data/cmd_config.json` 或环境变量覆盖；敏感值不应提交到仓库。

## 9. 开发与验证

```bash
# Core
uv sync
uv run main.py

# Dashboard
cd dashboard
pnpm install
pnpm dev          # 默认 3000，/api 代理到 127.0.0.1:6185
pnpm build
pnpm generate:api # 后端 OpenAPI 变化后重新生成客户端

# 质量门禁
uv run ruff check .
uv run ty check .
uv run pytest
```

目录归属和生成产物规则见 [Bot 开发入口](../LKM-bot/README.md#代码结构与开发入口)。
API 路由在 `astrbot/dashboard/api/` 装配，前端客户端由 `openspec/openapi-v1.yaml` 生成到
`dashboard/src/api/generated/`；修改规格和路由后须同步生成客户端。

## 10. 维护边界

- `astrbot/` 大部分是上游 AstrBot 代码，LKM 定制集中在 `astrbot/lkm/`；合并上游时优先减少
  对上游文件的本地修改。
- 插件 API、Dashboard API 和 OpenAPI schema 变更时，必须同步更新 Dashboard client 与测试。
- 面板部署在子路径时，所有浏览器可见的绝对路径必须经过 base path 工具，不得直接拼 `/api`。
- SSO 是显式票据换取，不允许降级为“信任社区 Cookie”；没有公钥时必须回落到面板登录页。
