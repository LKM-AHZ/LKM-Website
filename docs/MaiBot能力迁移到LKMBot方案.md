# MaiBot 全量能力迁移到 LKMBot 实施方案

> **迁移基线**：MaiBot `1.3.19`（`c6429547a`，2026-10-30）、LKM-bot `d9855e96c`（2026-11-01）。
> **方案核对日期**：2026-11-05。
> **文档性质**：实施计划，不描述现状。两边的架构事实以源码为准，现状见
> [Bot平台架构与现状](./Bot平台架构与现状.md)；本文只回答“迁什么、按什么顺序迁、怎么验收”。

## 0. 结论摘要

1. **不能整体合并，只能按能力域解耦迁移。** 两套系统在控制模型（心流 vs 事件驱动）、消息底座、
   插件运行时、面板、配置与数据库上全部不同，任何“fork 合并”都会产生双份全局状态和双套生态。
2. **目标形态是“宿主 + 生命层”。** LKM-bot 继续做宿主（平台 / Provider / Agent / 插件 / 工具 /
   面板），MaiBot 的能力以新增的 `bot/life/` 旁路子系统接入，独立开关、独立数据目录、独立故障域。
3. **对上游 AstrBot 的改动控制在 4 处、约 15 行以内**，其余全部是新增文件，保证 LKM-bot 仍能
   逐版本合并 AstrBot 上游。
4. **记忆引擎不经过 MaiBot 拷贝。** `A_memorix` 本身是独立上游项目
   （`A-Dawn/A_memorix`，AGPL-3.0，与 LKM-bot 同协议），直接以 subtree 引入，只写适配层。
5. **规模**：矩阵覆盖 38 项能力（36 项有实际工作量）、**351 人日**（按 390 人日排期，含 10% 余量）；
   2 后端 + 1 前端（半时）+ QA（兼职）约 **26 周**；只有 2 人时约 8.5 个月。
   **拟人闭环 MVP 约 160 人日**（2 人约 4 个月），可先交付。
6. **明确不迁 7 项**：MaiBot 插件运行时与插件市场、maim-message 协议栈、自带 WebUI/启动器、
   桌宠（原生 GUI）、遥测、自动更新、TOML 配置体系。理由见附录 A。

## 1. 为什么不能整体合并

| 维度 | MaiBot 1.3.19 | LKM-bot（AstrBot 发行版） | 直接合并的后果 |
| --- | --- | --- | --- |
| 控制模型 | 心流：Planner 决定“说不说、何时说、说什么” | 事件：唤醒 → 插件/Agent → 回复 | 两套调度器互抢消息，回复时序不可预测 |
| 消息底座 | `maim-message` + `platform_io` 路由 | 10+ 平台适配器 + `BotMessageEvent` | 消息模型双份，组件语义对不齐 |
| 平台宽度 | 以 QQ/NapCat 为主 | QQ/Telegram/Discord/Slack/飞书/微信/企微/KOOK 等 | 心流假设的“@、引用、群名片、撤回”并非全平台可用 |
| 存储 | SQLite + FAISS + 独立 A_memorix 库 | `data_v4.db` + 知识库 FAISS + 面板配置 | 两套建表与迁移机制冲突 |
| 插件 | 子进程 Runner + SDK 2.20 + hooks | 进程内 Star + 1000+ 插件生态 | 双插件生态，作者与用户都分裂 |
| 面板 | React 独立包（`maibot-dashboard`） | Vue 3 + 社区站 `/bot/` 托管 | 双面板、双认证 |
| 配置 | TOML + pydantic + 版本升级钩子 | `cmd_config.json` + profile + 面板 schema | 两套配置真源 |
| 异步模型 | 双事件循环 + 同步 SQLite | 单 asyncio + 异步 SQLAlchemy | 阻塞主循环，面板与消息一起卡死 |
| 上游关系 | 自主演进 | 跟随 AstrBot | 大改主干后，上游同步成本指数上升 |
| 许可 | GPL-3.0 | AGPL-3.0 | 可合并（AGPL §13），但必须保留版权与声明 |

三个硬约束决定了策略：

- **全局单例冲突**：两边都有 `global_config`、`config_manager`、`prompt_manager`、DB 单例、
  i18n、日志。直接 `import` MaiBot 模块会在同一进程里出现两份真源。
- **控制反转**：AstrBot 的 pipeline 是“阶段式、每阶段做完就往下走”；心流需要“消息先入池、
  延迟决策、可放弃、可主动发送”。这不是加一个阶段能解决的，必须新增会话级运行时。
- **上游可维护**：LKM-bot 的价值之一是持续吸收 AstrBot 上游。任何侵入式改造都要按“接缝数量”计价。

## 2. 目标形态：宿主 + 生命层

### 2.1 分层

```text
┌──────────────────────────────────────────────────────────────┐
│ L3 面板   bot-panel：记忆 / 人物 / 表达 / 黑话 / 表情 / 心流监控 │
├──────────────────────────────────────────────────────────────┤
│ L2 生命层 bot/life/                                           │
│   ingest → session(debounce/gate/focus) → planner → tools     │
│   memory(A_memorix) · person · expression · jargon · emoji    │
│   reply(分段/引用/错字/关键词) · drive(漂移/主动/退避)          │
├──────────────────────────────────────────────────────────────┤
│ L1 宿主   LKM-bot 既有                                        │
│   platform · provider · agent runner · star · kb · cron       │
│   computer · mcp · skills · dashboard · lkm(社区集成)          │
└──────────────────────────────────────────────────────────────┘
```

原则：**生命层只依赖 L1 的公开接口**（`StarContext`、Provider、Agent Runner、DB Helper、
Platform Manager），不反向修改 L1 的内部实现；L1 不需要知道生命层存在。

### 2.2 对上游的接缝（全部改动）

| # | 文件 | 改动 | 行数 |
| --- | --- | --- | --- |
| 1 | `bot/core/pipeline/stage_order.py` | `STAGES_ORDER` 首位插入 `LifeIngestStage` | 1 |
| 2 | `bot/core/pipeline/bootstrap.py` | `_BUILTIN_STAGE_MODULES` 与 `_EXPECTED_STAGE_NAMES` 各加一项 | 2 |
| 3 | `bot/core/core_lifecycle.py` | 创建 `star_context` 后初始化 `LifeService`，停止时收尾 | 2~3 |
| 4 | `bot/dashboard/api/router.py` + 新增 `bot/dashboard/api/life.py` | 挂载 `life` 路由（状态 / 消息 / 配置） | 2 |

> 已验证：LLM 上下文注入**不需要**改核心。`InternalAgentSubStage` 会在请求前触发
> `OnLLMRequestEvent`（`bot/core/pipeline/process_stage/method/agent_sub_stages/internal.py`），
> 生命层注册该事件处理器即可追加记忆/人物/表达片段；主动发送走
> `platform.send_by_session` / `StarContext.send_message`，也不依赖当前事件。

### 2.3 代码落点

```text
bot/life/
├── service.py          # LifeService：生命周期、开关、健康检查
├── config.py           # LifeConfig（面板可编辑，默认关闭）
├── pipeline.py         # LifeIngestStage（只记录，不拦截）
├── bus.py              # 内部事件：ingested / batch_ready / replied / idle
├── session/
│   ├── registry.py     # UMO → SessionRuntime，重启恢复
│   ├── runtime.py      # 会话状态机
│   ├── debounce.py     # 移植自 chat/debounce
│   ├── gates.py        # 移植自 maisaka/turn_trigger
│   └── focus.py        # 移植自 maisaka/focus
├── planner/
│   ├── loop.py         # 心流主循环（消费 Agent Runner）
│   ├── prompt.py       # 提示词组装（复用 persona_mgr）
│   └── tools.py        # reply / wait / react / quote / search_memory …
├── memory/             # A_memorix 适配层 + 工具
├── person/             # 画像、关系、事实校验
├── expression/         # 表达学习与选择
├── jargon/             # 黑话
├── emoji/              # 表情包
├── reply/              # 分段 / 引用 / 错字 / 关键词 / 补充
└── drive/              # 注意力漂移 / 主动 / 空闲退避
```

面板侧新增 `bot/dashboard/api/life.py` 与 `bot-panel/src/features/life/*`。

### 2.4 数据落点

| 数据 | 位置 | 理由 |
| --- | --- | --- |
| 结构化业务表（person/expression/jargon/emoji/session_state） | 主库 `data_v4.db` 新增 `life_*` 表 | 跟现有备份、迁移、面板查询一条链路；不改上游表结构 |
| 长期记忆（A_memorix） | `data/life/memory/`（自带 schema v26） | 引擎自有版本与迁移，隔离故障域 |
| 运行时状态（focus 时间线、门控计数） | 内存 + `data/life/state/*.json` 快照 | 高频读写不落库，重启可恢复 |
| 图片/表情素材 | 现有 `bot/core/media_storage.py` → LKM-service | 复用已有内容寻址、签名与清理策略 |

## 3. 迁移方法论

### 3.1 四类策略

| 策略 | 适用 | 例子 |
| --- | --- | --- |
| **复用** | LKM 已有且更强 | 平台接入、Provider、MCP、沙箱、知识库、TTS/STT、面板框架 |
| **适配** | 概念同构，只换数据源 | 人格、内部聊天、统计、图片理解、ACP |
| **移植** | 算法自洽，只需去掉 MaiBot 全局依赖 | 防抖、门控、分段、错字、关键词、表达/黑话、注意力漂移 |
| **新建** | 与 MaiBot 运行时强耦合 | 心流运行时、Planner 循环、记忆写入链路、人物流水线、面板页面 |

### 3.2 迁移单元模板（每个单元必须独立可关、可测、可回滚）

```text
WP-xx 名称
输入   ：事件 / 数据 / 配置
输出   ：决策 / 消息 / 记录
落点   ：bot/life/<domain>/...
数据   ：新表 / 文件 / 迁移脚本
开关   ：life.<domain>.enabled（默认 false，可按 UMO 灰度）
验收   ：用例 + 指标门限（见 §7）
回滚   ：关开关 + 保留数据，不回滚 schema
```

### 3.3 排序原则

1. **先底座后智能**：没有可靠的消息归档与主动发送，心流和记忆都无从验证。
2. **先可逆后可感**：记忆、人物、表达可以静默上线；心流会改变用户可感知的回复节奏，必须最后灰度。
3. **先独立后耦合**：记忆、人物、表达三条线互不依赖，可并行；心流分别依赖“归档”和“人格”。
4. **每阶段有退出条件**：不达标不进入下一阶段，禁止“边迁边修底座”。

## 4. 全量功能清单与差距矩阵

图例：✅ 已有且可复用 ｜ 🟡 有弱版或部分能力 ｜ ❌ 缺失

| # | 能力 | MaiBot 实现 | LKM 现状 | 策略 | 阶段 | 人日 |
| --- | --- | --- | --- | --- | --- | --- |
| **A 接入与消息** | | | | | | |
| 1 | 平台接入与消息归一 | `platform_io/*`、`maim_message` | ✅ 10+ 平台适配器 | 复用 | — | 0 |
| 2 | 出站路由 / 去重 / 回执 | `platform_io/{routing,dedupe,outbound_tracker}` | 🟡 散落在各适配器 | 适配 | S1 | 5 |
| 3 | 全量消息归档 | `chat/message_receive/message_repository` | 🟡 `PlatformMessageHistory` 只存对话流水，缺 message_id/引用/标志位 | 新建 | S1 | 8 |
| 4 | 会话注册与生命周期 | `chat/message_receive/chat_manager` | ✅ `ConversationV2` + `PlatformSession` | 适配 | S1 | 3 |
| 5 | 消息组件映射（图/表情/转发/引用） | `common/data_models/message_component` | ✅ `bot/core/message/components` | 映射 | S1 | 5 |
| 6 | 内部聊天（网页聊天统一身份） | `core/internal_chat`、`internal_chat_profile` | 🟡 WebChat 已有，身份未统一 | 适配 | S6 | 5 |
| **B 认知** | | | | | | |
| 7 | 长期记忆引擎 | `A_memorix`（67k 行，独立上游） | ❌ 无（`provider_ltm_settings` 只是群聊上下文） | 引入上游依赖 | S2 | 18 |
| 8 | 记忆写入（摘要 / 事实 / Episode） | `services/memory_flow_service`、`person_fact_*` | ❌ | 重写 | S2 | 12 |
| 9 | 记忆检索与上下文注入 | `services/memory_service` + 双路检索 | 🟡 知识库 RAG 可参考 | 新建 | S2 | 8 |
| 10 | 记忆管理 / 导入 / 迁移 | `A_memorix` admin + `memory_import_admin` | ❌ | 移植 | S2 | 10 |
| 11 | 人物画像 | `person_info/person_info.py` | ❌ | 移植 | S3 | 12 |
| 12 | 事实校验与去重 | `services/person_fact_verifier` | ❌ | 移植 | S3 | 6 |
| 13 | 表达学习 | `learners/expression_*` | ❌ | 移植 | S3 | 10 |
| 14 | 表达向量索引与选择 | `replyer/expression_vector_index`、`maisaka_expression_selector` | 🟡 有 FAISS `vec_db`，无表达库 | 移植 | S3 | 6 |
| 15 | 黑话学习 | `learners/jargon_*` | ❌ | 移植 | S3 | 8 |
| 16 | 表情包系统 | `emoji_system/*` | ❌ | 移植 | S3 | 10 |
| 17 | 图片理解与视觉记忆 | `visual`、`image_system` | ✅ 多模态 Provider | 复用 | S3 | 4 |
| **C 表达** | | | | | | |
| 18 | 人格模型 | `personality_service`、`PersonalityConfig` | 🟡 `Persona`/`Personality` 字段较少 | 适配 | S5 | 8 |
| 19 | 回复生成 | `replyer/*`、`prompts/*` | ✅ Agent Runner（但无拟人约束） | 重写 | S5 | 16 |
| 20 | 多段回复与分段 | `response_splitter`、`multiple_reply` | ❌ | 移植 | S5 | 10 |
| 21 | 错别字与口语化 | `chinese_typo` | ❌ | 移植 | S5 | 5 |
| 22 | 关键词反应 | `keyword_reaction` | ❌（可用插件实现） | 移植 | S5 | 5 |
| 23 | 引用 / 补充 / 文档回复 | `maisaka/quote`、`reply_supplement`、`document_generator` | ❌ | 移植 | S5 | 8 |
| **D 心流** | | | | | | |
| 24 | 消息防抖 | `chat/debounce/*` | ❌ | 移植 | S4 | 8 |
| 25 | 触发门控 | `maisaka/turn_trigger/*`（likelihood + dynamic gate） | ❌ | 移植 | S4 | 12 |
| 26 | Focus 时间线与检查点 | `maisaka/focus/*` | ❌ | 移植 | S4 | 10 |
| 27 | 心流运行时 / Planner 循环 | `chat/heart_flow/*`、`maisaka/runtime.py` | ❌ | 重写 | S4 | 20 |
| 28 | 回复决策工具集 | `maisaka/builtin_tool`、`chat_loop_service` | 🟡 工具体系已有 | 新建 | S4 | 8 |
| 29 | 注意力漂移 / 回钩 | `maisaka/attention_drift` | ❌ | 移植 | S4 | 5 |
| 30 | 主动搭话 / 沉默 / 空闲退避 | `idle_backoff`、`talk_value` | 🟡 `active_reply` 概率版 | 移植 | S4 | 9 |
| 31 | 快速反应 / 打断 | `planner_message_steering` | ❌ | 适配 | S4 | 8 |
| **E 工具与周边** | | | | | | |
| 32 | 工具结果压缩 / 子任务 | `tool_result_condenser`、`subagent_tasks` | 🟡 上下文压缩已有 | 移植 | S6 | 8 |
| 33 | 计划器监控 / 推理过程 | `planner`、`reasoning_process` | 🟡 trace 已有 | 适配 | S6 | 6 |
| 34 | ACP 外部 Agent | `agent/acp*` | 🟡 第三方 runner（Dify/Coze 等） | 适配 | S6 | 6 |
| 35 | MCP / 沙箱 / 搜索 / 语音 | `mcp_module`、`computer`、`web_search`、`voice` | ✅ 全部已有 | 复用 | — | 0 |
| 36 | 管理面板页面 | `dashboard`、`src/webui` | 🟡 bot-panel 已有框架 | 新建 | S6 | 22 |
| 37 | 统计 / 诊断 / 运维 | `statistics`、`memory_diagnostics` | 🟡 stats 已有 | 适配 | S6 | 5 |
| 38 | 文件服务（群文件上传 / 下载 / 临时文件与清理） | `files/*` | 🟡 附件与媒体已有，缺群文件传输 | 适配 | S6 | 6 |

**合计**：核心 351 人日（含 S0 基线 12 / S7 双跑切换 24）；建议按 **390 人日** 排期。

> 人日为“设计 + 编码 + 自测 + 联调”的净投入，不含跨团队等待。估算假设：执行者已熟悉 Python
> 异步与其中一套代码库；前端按“复用 bot-panel 组件”计。

## 5. 分阶段实施

### 5.1 排期总览（3 人：后端 A 认知线、后端 B 心流线、前端 C 半时）

| 周 | A（记忆/表达） | B（心流/底座） | C（面板） |
| --- | --- | --- | --- |
| W1 | S0 基线 | S0 基线 | 回放集采集 |
| W1–W3 | S1 归档与表结构 | S1 骨架与发送通道 | — |
| W3–W9 | S2 记忆 | S4 防抖 / 门控 / Focus | 面板原型 |
| W9–W14 | S3 人物 / 表达 / 黑话 / 表情 | S4 运行时 / 漂移 / 主动 | 资源页 |
| W11–W14 | S5 人格与后处理 | S5 生成约束 | — |
| W14–W21 | S6 工具与统计 | S6 周边与联调 | 面板 8 页 |
| W21–W26 | S7 双跑 | S7 迁移与切换 | 灰度看板 |

```text
S0 ─ S1 ─┬─ S2 ────────┬─ S5 ─┬─ S6 ─ S7
         └─ S4 ────────┘      │
              S3（与 S2 并行）─┘
```

关键路径是 **S1 → S4 → S5 → S7**；S2/S3 可并行，但不能晚于 S5（人格提示词要引用记忆与人物）。

### 5.2 S0 立项与基线（1 周 / 12 人日）

- 冻结范围：P0/P1 全部纳入、P2 不再保留；确认 §9 决策点并写入附录 F。
- 起两套基准环境：MaiBot 与 LKM-bot 接同一模型、同一套测试群。
- 采集 **300 段真实会话**（脱敏，每段 50~200 条），标注“回/不回、时机、是否引用”。
- 落度量脚本与看板：触发准确率、时机偏差、记忆命中、成本、P95 延迟。

**退出条件**：回放集可一键重放；指标脚本出数；范围签字。

### 5.3 S1 生命层骨架与消息底座（2 周 / 21 人日）

- `bot/life/` 包、`LifeService`、`LifeConfig`、结构化日志、指标埋点。
- `LifeIngestStage`：位于 `STAGES_ORDER` 首位，只做归档与通知，永不拦截事件。
  （必须在 `WakingCheckStage` 之前，否则未被唤醒的消息心流永远看不到，无法“读空气”。）
- `life_messages` 表 + 写入幂等（`UNIQUE(platform_id, message_id)`）。
- `SessionRegistry`：UMO → 运行时，懒创建、空闲回收、重启恢复。
- `LifeSender`：封装 `platform.send_by_session`，失败重试与平台降级。

**验收**：全量消息入库率 100%（含未唤醒）；开关关闭时与上游行为逐字节等价（diff 用例）；
重启后会话状态不丢；发送失败可观测。

### 5.4 S2 长期记忆（6 周 / 48 人日）

- 以 subtree 引入上游 `A-Dawn/A_memorix`（**不要**从 MaiBot 目录拷贝），保留 LICENSE 与版权头。
- `MemoryAdapter`：Embedding 走 LKM Provider（`ProviderType.EMBEDDING`），数据目录
  `data/life/memory`，提供健康检查、超时、熔断。
- 写入链路：批次摘要 → `ingest_summary`；事实抽取 → 人物域（S3 接口）；Episode 状态机。
- 检索链路：`search/time/hybrid/episode/aggregate` 五模式，接入 `OnLLMRequestEvent` 注入。
- 工具：`search_memory` / `remember` / `get_person_profile`，注册到 Agent 工具集。
- 导入：MaiBot 记忆目录迁移、LPMM 转换、运行时自检脚本。

**验收**：1000 条语料检索命中率 ≥ MaiBot 同配置的 90%；P95 < 300ms；关闭开关后零调用；
用户级删除/导出可用。

### 5.5 S3 人物、表达、黑话、表情（6 周 / 56 人日，与 S2 并行）

- 人物：`life_person` / `life_person_fact`，画像生成、关系值、群名片与别名归一。
- 事实校验：冲突检测、置信度衰减、复审任务。
- 表达：学到的表达（场景/风格/权重）、向量索引复用 `vec_db/faiss_impl`、生成时选择。
- 黑话：挖掘、释义、上下文匹配，避免“学了不用 / 乱用”。
- 表情包：库、去重、语义标签、发送策略（何时发表情而不是文字）。

**验收**：每类都有“学习 → 入库 → 命中 → 可解释 → 可删除”闭环；面板可见；
误学习率 < 5%（人工抽检 100 条）。

### 5.6 S4 心流（8 周 / 80 人日，最高风险，第 3 周起与 S2 并行）

- 防抖：三档（快速/自然/沉稳）+ 8 秒上限 + @ 加速 + 同人续发规则。
- 门控：`reply_likelihood` 离线权重 + `dynamic_gate` 动态阈值 + 空闲退避。
- Focus：会话时间线、完整轮次压缩、检查点与恢复。
- 运行时：会话状态机、Planner 调用、超时/取消/打断、并发上限。
- 工具：`reply` / `wait` / `react` / `quote_reply` / `search_memory` / `get_person_profile`。
- 注意力漂移与回钩、主动搭话、快速反应模式（流式 + 新消息打断）。

**验收**：回放集上 reply/no-reply 的 F1 ≥ MaiBot 的 0.9；时机 P90 偏差 ≤ 3s；
空闲会话 0 误触发；单会话 token 成本 ≤ MaiBot 的 1.3 倍。

### 5.7 S5 人格与回复后处理（4 周 / 52 人日）

- 人格扩展：`life_persona_profile`（按 `persona_id` 关联，不改上游 `Persona` 表），
  群聊/私聊提示词、引用频率、多段概率、额外 Prompt。
- 提示词组装：人格 + 心流指令 + 记忆 + 人物 + 表达 + 群上下文，顺序与裁剪策略固定。
- 后处理：分段、错别字、关键词反应、引用、补充、文档回复。
- 约束：禁 Markdown、长度分布、段数分布对齐 MaiBot。

**验收**：回复长度/段数分布与对照组无显著差异（KS 检验 p > 0.05）；
引用率符合配置；禁词与 Markdown 泄漏为 0。

### 5.8 S6 工具、周边与面板（7 周 / 58 人日）

- 工具结果压缩、子任务、计划器监控、推理过程展示。
- ACP 适配、文件服务（群文件上传/下载、临时文件与清理）。
- 面板 8 页：记忆、人物、表达、黑话、表情、心流监控、学习审核、数据迁移。
- 统计与诊断：复用现有 stats，补心流指标与记忆健康度。

**验收**：面板 CRUD 全通；权限与审计到人；移动端可用；ACP、文件服务两项均可独立关闭。

### 5.9 S7 双跑、迁移与切换（5 周 / 24 人日）

- 影子模式：生命层只出决策、不发送，记录 `would_reply` / `would_wait` / 时机。
- A/B 灰度：按 UMO / 群白名单放量，1% → 10% → 50% → 100%。
- 数据迁移工具：MaiBot 聊天记录、人物、表达、黑话、表情、A_memorix 数据目录。
- 回滚演练、值班手册、用户公告。

**退出条件**：灰度连续 2 周无 P1；回滚 < 10 分钟且不丢数据；MaiBot 转只读归档。

## 6. 关键设计

### 6.1 事件与会话

```text
平台事件 → LifeIngestStage(记录+通知) → SessionRuntime(UMO)
              │                            ├─ debounce 合并批次
              │                            ├─ gates 决定是否进入 Planner
              │                            └─ focus 维护时间线
              └─ life_messages              ↓
                                      Planner(Agent Runner)
                                        ├─ reply  → LifeSender → 平台
                                        ├─ wait   → 继续收集
                                        └─ react  → 表情/短反应
```

- **单会话串行**：每个 UMO 一把 `asyncio.Lock` + 一个有界队列，禁止同一会话并发 Planner。
- **背压**：队列满时丢弃最旧的“待判断批次”并计数，不阻塞平台事件循环。
- **超时**：Planner 单轮硬超时（默认 60s），超时按 `wait` 处理并记录。

### 6.2 发送通道

- 统一走 `platform.send_by_session(MessageSession, MessageChain)`；
  生命周期内需要事件上下文时用 `StarContext.send_message`。
- 平台能力探测：引用、@、表情、撤回、卡片；不支持时降级为纯文本 + 前缀说明。
- 所有出站写 `life_outbound` 记录（去重、回执、失败重试），与 MaiBot 的 outbound tracker 对齐。

### 6.3 配置

- 新配置域 `life` 写入 `cmd_config.json`，由面板 schema 渲染，**不引入 TOML**。
- 默认全部关闭；`life.scope.enabled_umos` 支持按会话/群灰度。
- MaiBot 配置到 `life.*` 的映射见附录 B；旧 MaiBot 配置可被导入工具一次性转换。

### 6.4 多平台降级

| 平台 | 心流 | 引用 | 表情包 | 人物（群名片） |
| --- | --- | --- | --- | --- |
| QQ（aiocqhttp） | 全量 | ✅ | ✅ | ✅ |
| Telegram / Discord | 全量 | 部分 | ✅ | 部分 |
| 飞书 / 企微 / 钉钉 | 简化（无表情） | ❌ | ❌ | 部分 |
| WebChat / 内部聊天 | 简化（无平台回执） | ❌ | ✅（图片） | 仅昵称 |
| 其他 | 仅文本 + 记忆 | ❌ | ❌ | ❌ |

降级必须在面板明确标注，不能让用户以为“功能坏了”。

### 6.5 隐私与数据治理

- 人物画像与记忆属敏感数据：提供按用户查询、导出、删除；删除走软删 + 定期物理清理。
- 记忆写入前做敏感信息过滤（手机号、证件号、地址等），规则可配置。
- 回放集与影子日志脱敏后才能进测试仓库；生产日志默认不落原文。

## 7. 验收与质量门禁

### 7.1 三层验证

| 层 | 方法 | 频次 |
| --- | --- | --- |
| 单元 | `tests/life/**`，纯函数与状态机 | 每次提交 |
| 回放 | 300 段脱敏会话，逐条重放，对比决策与内容 | 每阶段 |
| 影子 | 生产流量双跑，只记录不发送 | 灰度期持续 |

### 7.2 指标门限（建议值，S0 后可调）

| 指标 | 门限 |
| --- | --- |
| 触发 F1（回/不回） | ≥ MaiBot 基线 × 0.90 |
| 回复时机 P90 偏差 | ≤ 3s |
| 记忆检索命中率 | ≥ MaiBot 基线 × 0.90 |
| 记忆检索 P95 | < 300ms |
| 人格一致性（LLM judge 1~5） | ≥ 4.0，且不低于基线 |
| 单条回复成本 | ≤ MaiBot 基线 × 1.3 |
| 消息处理 P95 | < 2s（不含 LLM 生成） |
| 误触发（空闲会话主动发言） | 0 次/千条 |

### 7.3 回归门禁

- `python -m pytest tests/life` 全绿；
- LKM-bot 既有测试全绿（迁移不得引入存量失败）；
- 上游合并后额外跑 `tests/life/test_upstream_contract.py`（校验 4 个接缝仍在）。

## 8. 风险与对策

| # | 风险 | 触发信号 | 对策 |
| --- | --- | --- | --- |
| 1 | 架构阻抗（同步 SQLite / 双循环） | 主循环卡顿日志、面板超时 | 所有移植代码走 `asyncio.to_thread`；单写者；禁止在事件循环里直连 SQLite |
| 2 | 心流延迟与成本失控 | P95 上升、token 超预算 | 本地门控优先，LLM 只处理批次；会话级预算与降级 |
| 3 | AstrBot 上游合并冲突 | 每次 sync 冲突 > 30 分钟 | 接缝清单 + 契约测试；新代码零侵入 |
| 4 | SQLite / FAISS 并发损坏 | `database is locked`、索引异常 | WAL、独立连接池、写入串行、启动自检 |
| 5 | 记忆膨胀与错误记忆 | 库体积、用户投诉“记错了” | 分层摘要、置信度、TTL、用户可纠正与删除 |
| 6 | 隐私与合规 | 审计问题 | 最小化采集、脱敏、导出/删除 API、保留期 |
| 7 | 平台差异导致体验割裂 | 某平台“像换了个 bot” | 降级矩阵前置，按平台裁剪能力并标注 |
| 8 | 插件生态双轨 | 作者重复投入 | 明确不迁 MaiBot 插件运行时（§9 D1） |
| 9 | 许可与署名 | 法务/社区质疑 | AGPL §13 兼容；保留版权头；新增 NOTICE；面板“关于”声明 |
| 10 | 范围蔓延 | 阶段延期 > 20% | 阶段门禁 + 决策点签字；高风险项单独排期 |

## 9. 需要拍板的决策

| # | 决策 | 选项 | 建议 |
| --- | --- | --- | --- |
| D1 | 是否迁移 MaiBot 插件运行时与插件市场 | 迁 / 不迁 / 做兼容层 | **不迁（已定 2026-11-06）**。执行层可双宿主共存，契约层无法合并；双插件生态成本远高于收益。评估见附录 E |
| D2 | 记忆库位置 | 主库 / 独立目录 | **独立目录 `data/life/memory`（已定 2026-11-06）**，与引擎 schema 版本解耦 |
| D3 | 心流是否替换默认应答 | 全局替换 / 按会话灰度 / 仅新会话 | **按会话白名单灰度（已定 2026-11-06）**，默认关闭，白名单放量 |
| D4 | ACP、文件服务是否在范围内 | 全量 / 延后 | **全部纳入（已定 2026-11-06）**；桌宠同日移出范围。ACP、文件服务进 S6，可独立关闭 |
| D5 | MaiBot 保留期 | 立即下线 / 只读 3 个月 | **只读 3 个月**，作为对照与回滚兜底 |
| D6 | 首发平台 | QQ / 多平台 | **QQ 优先**，其余平台按降级矩阵跟进 |

## 10. 立即可以开工的五件事

1. 建 `bot/life/` 骨架与 `LifeConfig`（默认关闭），在 `initial_loader` 中托管生命周期。
2. 加 `LifeIngestStage` 到 `STAGES_ORDER` 首位，落 `life_messages` 表与幂等写入。
3. 以 subtree 引入 `A-Dawn/A_memorix`，写 `MemoryAdapter`，用 1000 条语料打通
   “写入 → 检索 → 注入”最小闭环。
4. 在 `OnLLMRequestEvent` 上挂记忆/人物注入，验证不改核心即可生效。
5. 采集并脱敏 300 段回放集，跑出 MaiBot 基线指标（触发、时机、成本）。

## 附录 A：不迁移清单

| 项 | 理由 | 替代 |
| --- | --- | --- |
| 插件运行时（子进程 Runner、SDK、hooks） | 与 Star 生态冲突，迁移成本高于收益 | LKM Star + 事件钩子；常用 hook 逐个补齐 |
| 插件市场 | 双市场运营不可持续 | LKM 现有插件市场 |
| `maim-message` 协议栈 | 与 10+ 平台适配器重复 | `BotMessageEvent` + 现有适配器 |
| 自带 WebUI / 启动器 / 桌面 GUI | 已有 bot-panel 与社区站；GUI 是客户端形态 | 面板新增页面 |
| 桌宠（`desktop_pet`） | 原生置顶小窗是客户端形态，服务端单体无法交付；Web 版收益不足 | 不做；如确需另立桌面客户端项目 |
| 遥测与调查问卷 | LKM 已移除遥测，隐私优先 | 本地统计 |
| 自动更新 / 模型预设 / 数据包市场 | 与 LKM 更新与部署体系冲突 | 现有 updater 与备份 |
| TOML 配置与升级钩子 | 双配置真源 | `life` 配置域 + 迁移导入工具 |

## 附录 B：配置映射（MaiBot → life）

| MaiBot 配置 | LKM 配置 | 说明 |
| --- | --- | --- |
| `[personality]` | `life.persona.*` + `life_persona_profile` 表 | 多字段扩展，不改上游 `Persona` |
| `[chat.reply_timing]` | `life.heartflow.*` | 防抖档位、talk_value、快速反应 |
| `[chat.reply_style]` | `life.reply.*` | 群/私聊提示词、引用频率、多段概率 |
| `[attention_drift]` | `life.attention.*` | 漂移档位、回钩策略、反应风格 |
| `[expression]` | `life.expression.*` | 学习开关、阈值、审核 |
| `[jargon]` | `life.jargon.*` | 挖掘频率、解释阈值 |
| `[emoji]` | `life.emoji.*` | 库路径、发送概率、清理 |
| `[a_memorix]` | `life.memory.*` | 检索模式、embedding、阈值 |
| `[response_post_process]` / `[chinese_typo]` / `[keyword_reaction]` | `life.postprocess.*` / `life.keyword.*` | 分段、错字、关键词 |
| `[visual]` / `[voice]` | 复用 Provider | 不新增配置 |
| `[message_receive]` | `life.ingest.*` | 归档开关、保留期 |
| `[webui]` / `[telemetry]` / `[debug]` | 不迁移 | 面板与日志已有 |

## 附录 C：数据表草案

```sql
-- 全量消息归档（与 PlatformMessageHistory 并存，后者继续服务 LLM 对话）
life_messages(
  id INTEGER PRIMARY KEY,
  platform_id TEXT NOT NULL,
  session_key TEXT NOT NULL,        -- 归一后的 UMO
  message_id TEXT NOT NULL,
  ts INTEGER NOT NULL,
  sender_id TEXT, sender_name TEXT, group_id TEXT,
  components JSON NOT NULL,          -- MessageChain 序列化
  plain_text TEXT,
  reply_to TEXT,
  flags JSON,                        -- at/mention/image/emoji/command
  ingested_at INTEGER NOT NULL,
  UNIQUE(platform_id, message_id)
);

life_person(person_id TEXT PRIMARY KEY, platform TEXT, user_id TEXT,
            nickname TEXT, cardnames JSON, profile JSON,
            relation REAL DEFAULT 0, first_seen INTEGER, last_seen INTEGER);

life_person_fact(id INTEGER PRIMARY KEY, person_id TEXT, fact TEXT,
                 confidence REAL, source_msg_ids JSON, status TEXT,
                 created_at INTEGER, updated_at INTEGER);

life_expression(id INTEGER PRIMARY KEY, scene TEXT, style TEXT, content TEXT,
                weight REAL, source TEXT, status TEXT, vector_id TEXT);

life_jargon(id INTEGER PRIMARY KEY, term TEXT UNIQUE, meaning TEXT,
            context TEXT, weight REAL, status TEXT);

life_emoji(id INTEGER PRIMARY KEY, file_id TEXT, description TEXT,
           tags JSON, usage_count INTEGER, enabled BOOL);

life_persona_profile(persona_id TEXT PRIMARY KEY, fields JSON);

life_session_state(session_key TEXT PRIMARY KEY, state JSON, updated_at INTEGER);

life_outbound(id INTEGER PRIMARY KEY, session_key TEXT, message_id TEXT,
              status TEXT, platform_msg_id TEXT, retry INTEGER, created_at INTEGER);
```

> 新表由 `SQLModel.metadata.create_all` 自动创建，不改上游表；A_memorix 使用自有 schema v26。

## 附录 D：许可与合规

- LKM-bot：**AGPL-3.0**；MaiBot：**GPL-3.0**；A_memorix：**AGPL-3.0**。
- AGPLv3 §13 明确允许与 GPLv3 代码结合，结合后的整体按 AGPLv3 分发。移植时：
  1. 保留每个源文件的版权头与许可声明；
  2. 新增 `NOTICE`/`THIRD_PARTY_LICENSES`，列明 MaiBot 与 A_memorix 的来源、版本、提交；
  3. 面板“关于”页与 README 声明衍生关系；
  4. 不把移植代码用于闭源分发。
- `A_memorix` 有 `MODIFICATION_POLICY.md`：核心实现改动应回上游 `MaiBot_branch`，
  MaiBot 侧只允许改接入层。我们作为新宿主，适配层写在自己的 `bot/life/memory/`，不要改它的 `core/`。

## 附录 E：插件运行时能否与 AstrBot 合并

> 2026-11-06 补充，回应“MaiBot 插件运行时能否与 AstrBot 插件运行时合并”。

**结论：执行层可以共存（双宿主），契约层无法合并（一套 ABI），生态层不建议合并。**

### E.1 两套运行时的硬差异

| 维度 | MaiBot 插件运行时 | AstrBot / LKM-bot 插件运行时 | 合并障碍 |
| --- | --- | --- | --- |
| 进程模型 | Host + 两个子进程 Supervisor（内置 / 第三方），MsgPack RPC over UDS/TCP/命名管道 | 同进程 `importlib` 加载，直接持有对象 | 隔离 vs 直连；异常、阻塞、崩溃语义完全不同 |
| 入口契约 | `MaiBotPlugin` 子类 + `_manifest.json`（manifest v2、SDK 1.0–2.99、host 版本区间） | `star.Star` 子类 + `metadata.yaml` + `@filter.*` 装饰器 | 生命周期与注册方式不可互换 |
| 事件 / 钩子 | 23 个声明式 hook（`chat.*`、`maisaka.*`、`expression.*`、`jargon.*`、`emoji.*`、`agent.acp.*`） | 16 个 `EventType` + 9 类 filter | 只有约 6 个 hook 能找到近似对应，且是“阶段内子节点” |
| 能力面 | **81 个 capability**（`send.*`/`llm.*`/`config.*`/`database.*`/`chat.*`/`message.*`/`personality.*`/`desktop_pet.*`/`webui.*`/`market.*`），逐项令牌授权 | `Context` 约 25 个方法 + 可直接 import `bot.core.*` | 授权模型缺失；81 项映射是主要工作量 |
| 配置 UI | pydantic `ConfigBase` + `config_schema.json`，由 MaiBot 面板渲染 | `_conf_schema.json`，由 bot-panel 渲染 | 两套渲染器与校验器 |
| 面板扩展 | `webui.json` + `@API` + `@HomeCard`，React 渲染 | `metadata.pages`/`views` + `register_web_api`，Vue 渲染 | 前端协议不兼容 |
| 依赖 | Host 侧依赖冲突检测 + 补装，Runner 独立进程 | 主进程 `pip_installer` | 依赖冲突处理与回滚策略不同 |
| 热重载 | 重载 Runner / 单插件 | `importlib` reload | 不可共用 |
| 代码量 | `plugin_runtime/` 约 2.4 万行 + 外部 `maibot-plugin-sdk` | `bot/core/star/` 约 6.5 千行 | 合并等于重写其中一套 |

### E.2 三条路径与成本

| 路径 | 做法 | 成本 | 结论 |
| --- | --- | --- | --- |
| **A 双宿主** | LKM-bot 内嵌 MaiBot 的 Host+Runner 子进程，桥接消息、命令、工具与核心能力 | MVP 约 55 人日；覆盖率提升到 81 项约 150 人日 | **可行**，但运维两套运行时 |
| **B SDK 兼容层** | 在 AstrBot 进程内实现 `maibot_sdk` 的 `ctx`，让 MaiBot 插件以 Star 方式加载 | 约 120–180 人日 | **不推荐**：等于重写 SDK 与 81 项能力，且丢掉子进程隔离 |
| **C 中立 ABI** | 定义第三种插件协议（如 MCP/WASM），两边各写适配器 | 6–12 个月 | **不现实**：AstrBot 1000+ 插件无法全量迁移，MaiBot 生态也要重写 |

### E.3 真正的缺口在“业务生命周期”，不在“加载器”

23 个 MaiBot hook 里，只有 `chat.receive.*`、`maisaka.planner.*`、`maisaka.replyer.*`、
`maisaka.reply.before_post_process` 这几类能在 AstrBot 的 `AdapterMessageEvent`、
`OnLLMRequestEvent`、`OnLLMResponseEvent`、`OnDecoratingResultEvent` 上找到近似对应。
其余 `expression.*`、`jargon.*`、`emoji.*`、`agent.acp.*` 都是 MaiBot 心流/学习管线的内部节点，
AstrBot 里根本不存在，需要先由生命层补出这些节点。

所以顺序上应当是：**先迁生命层（S2–S5），再谈插件兼容**。生命层落地后，如果还要运行
MaiBot 插件，桥接的是生命层暴露的内部事件，而不是把整个 MaiBot 运行时搬进来。

### E.4 什么情况下才值得做双宿主

同时满足以下三条才建议启动：

1. 明确要上架/运行 **20 个以上** MaiBot 插件，且这些插件无法用 1–2 天改写成 Star；
2. 接受长期维护两套运行时（两套依赖、两套日志、两套面板、两套升级路径）；
3. 有至少 0.5 人长期负责兼容层，且能跟着 MaiBot 的 manifest/SDK 版本演进。

否则，**按需移植个别插件**（每个约 3–5 人日）远低于任何运行时级方案。

### E.5 推荐

- 默认：**不合并**，延续 §9 的 D1 决策；MaiBot 的差异化能力直接进 `bot/life/`，不经过插件层。
- 若未来确有生态诉求：先取 10 个真实 MaiBot 插件做兼容性试跑（测 `send.*` / `llm.*` /
  `config.*` / `database.*` 的覆盖率与失败模式），再决定是否投 55 人日做双宿主 MVP。
- 无论哪条路，都不要把 MaiBot 插件加载进 AstrBot 主进程：既失去隔离，又会让两套授权模型同时失效。

## 附录 F：决策记录

| 日期 | 决策 | 结论 |
| --- | --- | --- |
| 2026-11-05 | 迁移总体形态 | 宿主 + 生命层，不做整体 fork |
| 2026-11-06 | D1 插件运行时 | 不迁；评估见附录 E |
| 2026-11-06 | D2 记忆库位置 | 独立目录 `data/life/memory` |
| 2026-11-06 | D3 心流替换方式 | 按会话白名单灰度，默认关闭 |
| 2026-11-06 | D4 P2 范围 | 全部纳入主计划：ACP、文件服务 |
| 2026-11-06 | 桌宠 | 移出范围，不再迁移 |
| 待定 | D5 MaiBot 保留期 | 建议只读 3 个月 |
| 待定 | D6 首发平台 | 建议 QQ 优先 |

## 附录 G：实施进度

| 阶段 | 状态 | 交付 |
| --- | --- | --- |
| S0 | 部分完成 | 回放采集与统计脚本 `scripts/life/collect_replay.py`、`replay_stats.py`；300 段真实语料需接入生产库与对照模型后补跑 |
| S1 | 已完成 | `bot/life/`（config / ingest / models / store / sender / session / service / pipeline）、`LifeIngestStage` 置首、`life_messages` + `life_outbound`、主动发送封装、`/api/v1/life/*`、`tests/life` 22 条用例 |
| S2 | 未开始 | 引入上游 `A-Dawn/A_memorix` 并打通记忆写入/检索 |

S0/S1 与方案的偏差：

1. Life 配置落在独立文件 `data/life/config.json`，未写入 `cmd_config.json`；S6 面板接管编辑前由该文件开关。
2. 初始化接缝实际落在 `bot/core/core_lifecycle.py`（`initial_loader.py` 只负责装配生命周期），位置更靠近 `star_context`。
3. 关闭开关时只创建 `data/life/config.json` 并在启动日志提示，不建表、不写消息、不改变流水线行为。
