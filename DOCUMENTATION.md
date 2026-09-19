# LKM 文档地图

本文档说明每份技术文档的读者、范围和权威边界。站点新闻、公告、隐私政策及用户条款属于产品内容，不属于工程操作文档。

## 从哪里开始

| 需求 | 首选文档 | 补充文档 |
|---|---|---|
| 第一次了解项目 | [README.md](./README.md) | 各子项目 README |
| 本地启动和开发 | [DEVELOPMENT.md](./DEVELOPMENT.md) | 动态前端的 [GETTING_STARTED.md](./LKM-official-website/GETTING_STARTED.md) |
| 单机生产部署 | [DEPLOYMENT.md](./DEPLOYMENT.md) | [OPS-CHEATSHEET.md](./OPS-CHEATSHEET.md) |
| Kubernetes 部署 | [deploy/k8s/README.md](./deploy/k8s/README.md) | `deploy/k8s/` 清单 |
| 后端接口和测试 | [LKM-service/README.md](./LKM-service/README.md) | 运行时 `/docs`、`/redoc` |
| 动态前端开发 | [LKM-official-website/README.md](./LKM-official-website/README.md) | `CODING_STANDARDS.md`、`AGENTS.md` |
| 静态官网开发 | [LKM-official-static/README.md](./LKM-official-static/README.md) | `package.json` |
| VS Code 扩展 | [LKM-on-VSCode/README.md](./LKM-on-VSCode/README.md) | 扩展 `package.json` |
| 理解后端目标架构 | [后端规划.md](./LKM社区开发方案/后端规划.md) | [执行路线图.md](./LKM社区开发方案/执行路线图.md) |

## 文档职责

### 根级文档

- `README.md`：项目总览、最短启动路径和跨仓库入口。
- `DEVELOPMENT.md`：开发环境、日常命令、测试门禁和本地排错。
- `DEPLOYMENT.md`：Compose 生产架构、配置、上线、回滚、备份和可选组件。
- `OPS-CHEATSHEET.md`：已经部署后的常用命令；不是首次部署教程。
- `deploy/k8s/README.md`：Kustomize 清单、集群差异和已知限制。

### 子项目文档

- 动态前端：`README.md` 讲架构，`GETTING_STARTED.md` 面向新人，`CODING_STANDARDS.md` 定义门禁，`AGENTS.md` 记录代码代理约束。
- 后端：`README.md` 讲服务边界、运行、迁移与验证；接口字段以运行时 OpenAPI 为准。
- 静态站：`README.md` 讲双语内容结构、构建和验证。
- VS Code 扩展：`README.md` 讲安装、账号、同步行为和限制。

### 规划文档

`LKM社区开发方案/` 下的文档是架构决策和实施历史，不替代当前部署手册。标记“已完成”的条目仍可能保留背景说明；判断当前实现必须回到源码和可执行配置。

### 不作为操作手册的 Markdown

- `LKM-official-website/LICENSE.md` 是许可证原文，只随许可证变更而更新。
- `LKM-service/app/modules/articles/markdown-test.md` 是 Markdown 渲染测试夹具，不是面向用户或运维人员的说明文档。
- `LKM-official-static/src/content/docs/{zh,en}/` 是双语站点内容；同主题文件应保持结构与事实口径一致，但允许为不同语言调整表达。

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
# 检查 Markdown 中引用的仓库内相对路径是否存在
cd LKM-official-website
pnpm run build
pnpm run check:links

# 检查双语静态站内容、类型和格式
cd ../LKM-official-static
pnpm run check
pnpm run test
pnpm run build

# 核对 Compose 配置可解析
cd ..
docker compose config --quiet
```

涉及命令变更时，还应实际运行对应子项目的构建或测试，不以文档审阅代替验证。
