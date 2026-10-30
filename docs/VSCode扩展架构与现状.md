# LKM VS Code 扩展架构与代码实况

> **文档定位**：说明 `LKM-on-VSCode/` 如何把 LKM 平台的 Git 托管博客系列克隆到本地，并提供
> 多账号、拉取/推送、系列 CRUD 与自动同步能力。本文以扩展源码和 `package.json` 为准。
>
> **结构与入口核对日期**：2026-10-31。扩展版本 `0.0.1`，VS Code 引擎要求 `^1.85.0`。

## 1. 定位

LKM Blog on VS Code 是 LKM 平台的桌面编辑入口：

- 把 LKM 后端中的 blog 系列通过 Git 克隆到本地；
- 使用 VS Code 原生编辑体验编辑 Markdown/资源；
- 显式或自动地 pull/push 到系列仓库；
- 支持多账号及账号下的系列目录映射；
- 在 Activity Bar 提供 `LKM Series` TreeView。

## 2. 模块结构

| 模块               | 职责                                                            |
| ------------------ | --------------------------------------------------------------- |
| `src/extension.ts` | 激活装配：登记命令、TreeView、自动同步与停用清理 |
| `src/commands.ts` | 命令 ID、账号持久化与账号/系列/Git 命令处理 |
| `src/auto-sync.ts` | 定时、聚焦、保存监听；按仓库串行执行 Git 操作 |
| `src/accounts.ts`  | 账号元数据与 `repo_name → 本地目录/系列 id` 映射的纯函数        |
| `src/auth.ts`      | 用户名密码兑换 Bearer token、缓存失效与单飞登录             |
| `src/creds.ts`     | 账号凭证读写 VS Code `SecretStorage`                            |
| `src/api.ts`       | 后端 REST API 封装：系列列表、创建/删除、星标、克隆 URL         |
| `src/clone.ts`     | 系列选择、目录选择、Git clone 流程编排                          |
| `src/git.ts`       | 系统 Git clone、VS Code GitExtension pull/commit/push、凭证内联 |
| `src/sync.ts`      | 自动 pull 的时间判断、路径归属、拉取目标收集                    |
| `src/tree.ts`      | `LKM Series` TreeView 的节点构造与展示                          |

## 3. 命令与用户流程

| 命令                  | ID                  | 说明                                             |
| --------------------- | ------------------- | ------------------------------------------------ |
| `LKM: Add Account`    | `lkm.addAccount`    | 输入后端地址与用户名密码，凭证写入 SecretStorage |
| `LKM: Switch Account` | `lkm.switchAccount` | 切换当前账号及其系列映射                         |
| `LKM: Remove Account` | `lkm.removeAccount` | 删除账号并清理本扩展保存的凭证/映射              |
| `LKM: Clone Blog`     | `lkm.cloneBlog`     | 选择系列和本地目录，执行 Git clone               |
| `LKM: Pull`           | `lkm.pull`          | pull 当前打开的仓库                              |
| `LKM: Push`           | `lkm.push`          | push 当前打开的仓库                              |
| `LKM: Create Series`  | `lkm.createSeries`  | 调用后端创建系列并写入映射                       |
| `LKM: Delete Series`  | `lkm.deleteSeries`  | 删除后端系列并移除映射                           |
| `LKM: Toggle Star`    | `lkm.toggleStar`    | 加星/取消星                                      |

### 3.1 账号与凭证

- 账号唯一键为 `serverUrl:username`。
- 账号元数据（serverUrl、username、系列映射）存 `context.globalState`。
- 用户名和密码存 `context.secrets`，按账号 key 做 base64 编码后分键保存。
- Bearer token 只在运行时缓存，按 15 分钟 TTL 提前 60 秒重新兑换；401 后使缓存失效，下次操作重新登录，避免频繁触发登录限流。
- 删除账号会清理扩展 SecretStorage，但不会主动删除系统 Git Credential Manager 中的凭证。

### 3.2 Clone

1. 读取并清洗 `lkm.serverUrl`。
2. 登录换 Bearer token。
3. 调 `GET /api/v1/blog/series` 拉取 ACTIVE 系列。
4. 用户选择系列和本地目录。
5. 用系统 Git clone 系列仓库；Git URL 中的 Basic 凭证经 `embedBasicAuth` 安全编码后内联。
6. 成功后把 `repo_name`、本地绝对路径和系列 id 写入当前账号映射。

### 3.3 Pull / Push

- Pull/Push 依赖 VS Code 内置 GitExtension；扩展通过仓库目录解析当前 Git 仓库。
- 自动 pull 仅对**当前 VS Code 工作区已打开/加载**的仓库生效。
- 自动 push 默认关闭；开启后仅在保存已映射文件时提交**该文件**并 push。
- 暂存区已有其他改动时自动提交会中止，避免误提交无关文件；push 失败时本地提交保留，可手动重试。

## 4. 自动同步

配置项：

| 配置                           | 默认值  | 说明                                |
| ------------------------------ | ------- | ----------------------------------- |
| `lkm.serverUrl`                | 空      | LKM 后端地址；必填，不预设域名      |
| `lkm.sync.pullIntervalMinutes` | `5`     | 定时 pull 间隔；`<=0` 关闭          |
| `lkm.sync.pullOnFocus`         | `true`  | 窗口获得焦点时触发 pull             |
| `lkm.autoPush.enabled`         | `false` | 保存映射文件时自动提交该文件并 push |

`src/sync.ts` 的纯函数负责：

- `shouldPullNow`：处理首次、正常间隔、系统时钟回拨等边界；
- `pathBelongsToAccount`：按最长目录前缀判断文件属于哪个系列的本地目录，并处理 Windows/macOS
  大小写不敏感；
- `collectPullTargets`：按账号映射收集目录并去重；当前工作区仓库是否可用由调用方通过
  `getGitByDir` 判断。计时器、聚焦和保存事件在 `auto-sync.ts` 的 `startAutoSync` 中接线，
  由 `extension.ts` 激活并统一登记清理。

## 5. 安全边界

- 不把密码写入 globalState、日志或仓库配置；密码只进 SecretStorage。
- Git remote URL 内联凭证用于 clone/首次认证；不要把含凭证的 URL 提交到仓库或分享到日志。
- 后端地址来自用户配置，不能假设固定域名；扩展自身不内置服务端地址。
- API 返回统一 `ApiResp`，扩展先校验 HTTP 状态与业务码，再解包 data。
- Pull/Push 不绕过 Git 本身；冲突处理由 Git 和用户完成。

源码、测试与产物归属见 [扩展代码结构](../LKM-on-VSCode/README.md#代码结构)。

## 6. 开发与验证

```bash
pnpm install
pnpm run compile   # TypeScript 编译到 dist/
pnpm test          # Vitest，使用 test/mocks/vscode.ts 代替真实 VS Code API
pnpm run package   # 生成 VSIX（需 vsce）
```

测试覆盖账号/凭证、API、clone 流程、Git 操作、同步判断、自动 push、TreeView、扩展命令等模块。
涉及后端协议的改动，应同时核对 LKM-service 的 `/api/v1/blog` 与 `/blog/git` 行为。

## 7. 已知限制

- 自动 pull 只处理当前 VS Code 工作区已打开的仓库；未打开目录需手动 Pull 或加入工作区。
- 自动 push 依赖当前 Git 仓库状态；存在额外暂存改动时会主动中止。
- 系统 Git 凭证管理器可能另行保存凭证，扩展删除账号时不会清理它。
- 扩展默认不内置域名，首次使用必须显式配置 `lkm.serverUrl`。
