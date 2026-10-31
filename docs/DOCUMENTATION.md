# LKM 文档地图

本文档说明每份技术文档的读者、范围和权威边界。站点新闻、公告、隐私政策及用户条款属于产品内容，不属于工程操作文档。

## 从哪里开始

| 需求 | 首选文档 | 补充文档 |
|---|---|---|
| 第一次了解项目 | [根 README.md](../README.md) | [文档索引](./README.md)、各子项目 README |
| 本地启动和开发 | [DEVELOPMENT.md](./DEVELOPMENT.md) | 动态前端的 [GETTING_STARTED.md](../LKM-official-website/GETTING_STARTED.md) |
| 单机生产部署 | [DEPLOYMENT.md](./DEPLOYMENT.md) | [OPS-CHEATSHEET.md](./OPS-CHEATSHEET.md) |
| Kubernetes 部署 | [deploy/k8s/README.md](../deploy/k8s/README.md) | `deploy/k8s/` 清单 |
| 后端接口和测试 | [LKM-service/README.md](../LKM-service/README.md) | 运行时 `/docs`、`/redoc` |
| 动态前端开发 | [LKM-official-website/README.md](../LKM-official-website/README.md) | `CODING_STANDARDS.md`、`AGENTS.md` |
| 社区机器人（LKM Bot） | [DEPLOYMENT.md](./DEPLOYMENT.md) 的「LKM Bot」一节 | [LKM-bot/README.md](../LKM-bot/README.md)（发行版与开发入口） |
| VS Code 扩展 | [LKM-on-VSCode/README.md](../LKM-on-VSCode/README.md) | 扩展 `package.json` |
| 理解后端目标架构 | [后端架构与现状.md](./后端架构与现状.md) | [社区需求与开发规划.md](./社区需求与开发规划.md) |

## 文档职责

### 部署与开发文档

- `README.md`（根仓库）：项目总览、最短启动路径和跨仓库入口。
- `docs/DEVELOPMENT.md`：开发环境、日常命令、测试门禁和本地排错。
- `docs/DEPLOYMENT.md`：Compose 生产架构、配置、上线、回滚、备份、恢复演练和可选组件。
- `docs/OPS-CHEATSHEET.md`：已经部署后的常用命令；不是首次部署教程。
- `deploy/k8s/README.md`（未移动）：Kustomize 清单、集群差异和已知限制。

### 子项目文档

- 动态前端：`README.md` 是新手教程，`README2.md` 讲当前架构与命令，`GETTING_STARTED.md` 补充开发环境，`CODING_STANDARDS.md` 定义门禁，`AGENTS.md` 记录代码代理约束。
- 后端：`README.md` 讲服务边界、运行、迁移与验证；接口字段以运行时 OpenAPI 为准。
- 社区机器人：上游 AstrBot 文档在 `LKM-bot/docs/`（平台接入、provider 配置等）；**部署**以
  `docs/DEPLOYMENT.md` 为准——bot 自带的 `compose.yml`/`k8s/` 示例已删除，收编进根编排，上游文档
  里指向它们的步骤在本仓库不再适用。
- VS Code 扩展：`README.md` 讲安装、账号、同步行为和限制。

### 规划文档

`docs/` 下的架构与规划文档（`后端架构与现状.md`、`前端架构与现状.md`、`社区需求与开发规划.md` 等）
是架构决策和实施历史，不替代当前部署手册。标记“已完成”的条目仍可能保留背景说明；判断当前实现必须回到源码和可执行配置。

### 不作为操作手册的 Markdown

- `LKM-official-website/LICENSE.md` 是许可证原文，只随许可证变更而更新。
- `LKM-service/app/modules/content/articles/markdown-test.md` 是 Markdown 渲染测试夹具，不是面向用户或运维人员的说明文档。

## 代码导航与修改归属

目录与入口核对日期：2026-10-31。四个应用目录均是 `.gitmodules` 声明的独立 Git 子模块。

| 修改内容 | 从哪里进入 | 代码与文档归属 |
|---|---|---|
| 页面、社区交互、编辑器 | `LKM-official-website/src/pages/` → `features/` → `lib/api/` | 前端子仓库；[结构说明](../LKM-official-website/README2.md#架构) |
| API、认证、异步任务 | `LKM-service/main.py` → `boot/backend.py` → `app/`、`auth/`、`core/` | 后端子仓库；[结构说明](../LKM-service/README.md#项目结构) |
| Bot 消息、管理面板、社区 SSO | `LKM-bot/main.py` → `astrbot/core/initial_loader.py`；WebUI 在社区站 `bot-panel/` | Bot 子仓库；[开发导航](../LKM-bot/README.md#代码结构与开发入口) |
| VS Code 命令、账号、Git 同步 | `LKM-on-VSCode/src/extension.ts` | 扩展子仓库；[结构说明](../LKM-on-VSCode/README.md#代码结构) |
| 统一启动、网关、容器、跨项目契约 | `dev.sh` / `dev.ps1`、`docker-compose.yml`、`deploy/`、`scripts/` | 根仓库；本目录保存跨项目架构、开发和部署文档 |

应用行为变更的测试与注释放在所属子仓库；跨服务路由、环境变量或协议变化还需同步根仓库文档和
`LKM-service/tests/deploy/` 中的相关契约。不要把 `node_modules/`、`.venv/`、构建产物或运行期数据
当作源码目录整理，也不要手改图标、词典或 API 客户端生成文件。

提交时先在子仓库提交并推送，再在根仓库单独提交相应 gitlink 指针。根仓库的 `git diff` 不展示
子仓库文件内容，应同时查看 `git -C <子仓库> diff`；根目录显示子模块有修改可能表示指针不同、
子仓库有未提交文件，或两者都有。修改前先记录各仓库状态，避免把已有变更混入本次提交。

## 更新规则

1. 命令必须可从文档注明的工作目录直接执行。
2. 环境变量只记录名称、用途和示例，不写真实密钥。
3. 新增服务、端口、worker 或部署 profile 时，同步更新根 README、对应部署文档和运维速查。
4. 修改前端脚本或后端测试门禁时，同步更新对应子项目 README。
5. 架构计划与当前实现分开写，使用“当前”“计划”“已废弃”明确状态。
6. 不在多个文档复制大段易变配置；详细配置以 `.env.example` 和可执行清单为单一来源。

## 文档检查

提交前至少执行：

```sh
# 在根仓库检查工程文档的相对文件链接（不递归检查子模块）
python3 scripts/check_doc_links.py

# 以下检查前端构建产物中的站内 URL；与 Markdown 文件链接检查用途不同
cd LKM-official-website
pnpm run build
pnpm run check:links

# 核对 Compose 配置可解析
cd ..
docker compose config --quiet
```

涉及命令变更时，还应实际运行对应子项目的构建或测试，不以文档审阅代替验证。
