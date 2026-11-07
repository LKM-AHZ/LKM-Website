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
3. **对上游 AstrBot 的改动控制在 8 处、约 45 行以内**，其余全部是新增文件，保证 LKM-bot 仍能
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
| 1 | `bot/core/pipeline/stage_order.py` | `STAGES_ORDER` 依次插入 `LifeIngestStage` / `LifeReactionStage` / `LifeAcpStage` / `LifeTurnStage` | 4 |
| 2 | `bot/core/pipeline/bootstrap.py` | `_BUILTIN_STAGE_MODULES` 与 `_EXPECTED_STAGE_NAMES` 各加四项 | 8 |
| 3 | `bot/core/core_lifecycle.py` | 创建 `star_context` 后初始化 `LifeService`，停止时收尾 | 2~3 |
| 4 | `bot/dashboard/api/router.py` + 新增 `bot/dashboard/api/life.py` | 挂载 `life` 路由（状态 / 消息 / 配置） | 2 |
| 5 | `bot/core/pipeline/waking_check/stage.py` | 识别 `_life_force_wake`，让合并后的环境回合继续跑管线 | 5 |
| 6 | `bot/core/pipeline/result_decorate/stage.py` | 出站前调用 `postprocess_life_reply`（Markdown / 错字 / 长度 / 分段 / 引用） | 3 |
| 7 | `bot/core/agent/runners/tool_loop_agent_runner.py` | `_materialize_large_tool_result` 入口先问生命层（新增参数、一个分支与一个 helper） | ~12 |
| 8 | `bot/core/pipeline/process_stage/follow_up.py` | `get_active_runner`：子任务结论回注活动 run 的只读 getter | 9 |

> 接缝总数：8 个文件、约 43 行。其中第 5、6 条是“管线里必须有一句话才能工作”的位置——
> 唤醒判定与出站改写。第 6 条由 `tests/life/test_life_reply.py` 的 17 条用例覆盖行为，接缝本身
> 只有一次调用，回退只需删掉那一行并设 `life.reply.enabled=false`。

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

> 实施说明（S0 工具链已完成）：一键重放是 `scripts/life/replay_runner.py`（决策流 JSONL），
> 五项指标是 `scripts/life/life_metrics.py`（无标注时触发/时机报 0 覆盖而不是编造数字，
> 传 `--reference` 可按验收阈值输出 pass/fail 并以退出码 2 拦截）。P2 的范围以 D4 为准
> （全部纳入主计划），本条「P2 不再保留」为早期表述。剩余退出项只有三件数据类工作：
> 300 段生产语料、MaiBot 同模型对照跑分、人工标注；外加 D5/D6 两次签字。

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

> 实施说明（S2 已落地）：上游 `a-memorix` 改为**可选依赖**接入而非 subtree（理由见附录 G 偏差 4）。
> 默认引擎是 `bot/life/memory/` 内的本地 SQLite 实现，`upstream.engine=a_memorix` 时切换到上游引擎，
> 不可用时自动回落。P95 已用 `scripts/life/memory_tool.py bench` 实测；「命中率 ≥ MaiBot 90%」
> 依赖 S0 的 1000 条真实语料与对照模型，尚未执行。

### 5.5 S3 人物、表达、黑话、表情（6 周 / 56 人日，与 S2 并行）

- 人物：`life_person` / `life_person_fact`，画像生成、关系值、群名片与别名归一。
- 事实校验：冲突检测、置信度衰减、复审任务。
- 表达：学到的表达（场景/风格/权重）、向量索引复用 `vec_db/faiss_impl`、生成时选择。
- 黑话：挖掘、释义、上下文匹配，避免“学了不用 / 乱用”。
- 表情包：库、去重、语义标签、发送策略（何时发表情而不是文字）。

**验收**：每类都有“学习 → 入库 → 命中 → 可解释 → 可删除”闭环；面板可见；
误学习率 < 5%（人工抽检 100 条）。

> 实施说明（人物域 + 表达学习已落地）：`life.person.enabled` 打开后，归档批次会 `observe` 发言人
> （`life_person`，关系值按时间半衰递减、别名保留最近 12 个、群名片装饰与全角/零宽字符在入库前归一），
> 记忆摘要抽出的事实经 `on_facts` 回调写入 `life_person_fact`。冲突检测用同类别 + 二元组 Jaccard
> ≥ 0.6 标记 `conflicted`，`PATCH /api/v1/life/people/fact` 让复审选择保留或拒绝（保留会 supersede 对手）。
> 画像按 `profile_ttl_minutes` 缓存，LLM 不可用时回退抽取式；画像与事实都带 id，删除走
> `DELETE /api/v1/life/people`。
>
> `life.expression.enabled` 打开后，学习任务按 `learn_interval_minutes` 从归档增量挖句：
> 启发式按标点/空格切片，保留 2–16 字、带语气词且重复出现的片段，用所在句作“情景”；
> LLM 通道一次批处理产出 `(情景, 说法)` 对。两路都落 `life_expression`，FAISS 索引
> （复用 `vec_db/faiss_impl`）是派生结构，embedding 不可用时自动退化为关键词打分。
> 生成时按“相似度 0.7 + 衰减权重 0.3”选前 `top_k` 注入 `<life_expression>` 块，并累加使用次数。
>
> `life.jargon.enabled` 打开后，黑话按定义句式（`X 就是 Y`、`X 指的是 Y`、`Y 简称 X`，引号内允许单字）
> 与 LLM 抽取两路入库；同一个词出现第二种释义时**不覆盖**，整条转 `pending` 等人工复审，
> 避免“学错就乱用”。注入规则是从紧的：只有当前 prompt 里真的出现了这个词，才附一行释义，
> 并明确要求模型“不要主动使用没把握的黑话”。复审与删除走 `PATCH/DELETE /api/v1/life/jargon`。
>
> `life.emoji.enabled` 打开后，采集任务从归档里取图片组件（http(s) 或本地路径；归档时已折叠的
> base64 无法恢复，直接跳过），用 SHA-256 去重后按会话落盘到 `data/life/emoji/`，标签取自图片
> 所在消息的文本，向量可选（走同一套 embedding 配置）。发送由 Agent 工具 `send_meme` 触发：
> 选择分 = 0.8×相似度 + 0.2×热度，另有每会话冷却与每小时上限两道闸门；`send_meme` 经 `LifeSender`
> 真发一条图片消息并记录 `life_outbound`。`PATCH/DELETE /api/v1/life/emojis` 支持改标签/状态与删除。
> S3 四类（人物 / 表达 / 黑话 / 表情包）至此全部落地。

### 5.6 S4 心流（8 周 / 80 人日，最高风险，第 3 周起与 S2 并行）

- 防抖：三档（快速/自然/沉稳）+ 8 秒上限 + @ 加速 + 同人续发规则。
- 门控：`reply_likelihood` 离线权重 + `dynamic_gate` 动态阈值 + 空闲退避。
- Focus：会话时间线、完整轮次压缩、检查点与恢复。
- 运行时：会话状态机、Planner 调用、超时/取消/打断、并发上限。
- 工具：`reply` / `wait` / `react` / `quote_reply` / `search_memory` / `get_person_profile`。
- 注意力漂移与回钩、主动搭话、快速反应模式（流式 + 新消息打断）。

**验收**：回放集上 reply/no-reply 的 F1 ≥ MaiBot 的 0.9；时机 P90 偏差 ≤ 3s；
空闲会话 0 误触发；单会话 token 成本 ≤ MaiBot 的 1.3 倍。

> S4a（决策链路）已落地：`bot/life/heartflow/` 拆成三个纯函数模块，运行时与离线重放共用同一条决策路径。
>
> `debounce.py` 负责把一段话合成一个回合：三档静默窗口（快速 1.2s / 自然 2.5s / 沉稳 4.0s），
> 从首条消息起算 8 秒硬上限，被 @/唤醒/回复机器人时走快速档，同一个人连发时窗口只加一次
> `same_sender_extra_seconds`（未知发送者不合并）。`DebounceAccumulator` 是运行时要用的有状态版本，
> 提供 `due(now)` / `pop()`；算法本身不读时钟，全部由调用方传入时间戳。
>
> `gates.py` 是 `reply_likelihood`：九个可解释特征（@ 机器人、回复机器人、唤醒词、机器人名、
> 问号、@ 了别人、纯表情、回合消息数、关系值）加权求和再过 sigmoid，权重写在
> `life.heartflow.gate.weights` 里可离线调。阈值是动态的：空闲越久越高（`idle_actionable_seconds`
> 之后线性抬升，封顶 `idle_rise_max`），连续沉默次数越多越高（`backoff_step` 累计，封顶 `backoff_max`）。
> 否决规则顺序固定：命令 → 刚回过（`reply_cooldown_seconds`）→ 直接点名（放行）→ 长时间无机器人活动的
> 会话（`idle_silence_seconds`，保证“空闲会话 0 误触发”）→ 似然比阈值。
>
> `policy.py` 把两者串起来，`HeartFlowPolicy.decide_session()` 按时间顺序模拟一个会话（含机器人消息
> 对回合的截断与计时器回写），`replay_runner.py --decider heart_flow` 直接用它产出决策流，
> 所以 `life_metrics.py` 量到的触发 F1 就是运行时门控的 F1。配置文件里的
> `life.heartflow.{debounce,gate}` 与面板 `/api/v1/life/config` 已经可以读写这些参数。
>
> S4b（Focus）已落地：`bot/life/heartflow/focus/` 把“会话时间线”做成可检查点恢复的状态。
>
> `timeline.py` 是纯模型：连续消息按 `gap_seconds`（默认 300 秒）归为一个回合，机器人回复把回合
> 收尾；`compress()` 把最旧的回合折进摘要（保留最后 `keep_turns` 个回合原文），摘要按行累积、
> 超 `digest_max_chars` 先丢最旧的行并加“更早的内容已省略”标记，所以时间线永远有界。
> `checkpoint()/from_checkpoint()` 是同一份状态的序列化，重启后不需要重放归档。
>
> `store.py` 落两张表：`life_focus`（每会话一行摘要 + 计数器）与 `life_focus_turn`（每回合一行，
> `(session_key, turn_index)` 唯一）。回合按索引 upsert，`prune(max_turns)` 只留最近 60 个回合，
> 折叠过的回合保留 `summary`、清空 `messages`，因此既省空间又保留可核对的历史。
>
> `service.py` 负责调度：归档 flush 把消息喂进时间线（`_flush` 里与 `person.observe_messages` 并列），
> `LifeService.send_text` 发送成功后调用 `note_reply()` 收尾回合，`_focus_loop` 每
> `checkpoint_interval_minutes` 把脏时间线写回库，6 小时维护任务顺带做一次全量压缩。
> 提示词侧只注入**折叠摘要**（`<life_focus>`），最近对话已经在模型上下文里，不重复占 token。
> `GET/DELETE /api/v1/life/focus` 可以按会话看时间线与摘要、也可以整段遗忘。
>
> 尚未接线：会话状态机、Planner 调用与中断（S4c）。S4b 提供的是运行时需要的会话状态与上下文压缩。
>
> S4c（运行时接管）已落地：`bot/life/heartflow/runtime.py` + `LifeTurnStage`，`heartflow.enabled`
> 从这里开始真正改变收发。
>
> 作用面是**明确收窄**的：只接管“群聊里没有被点名的话”。私聊、`@`、回复机器人、唤醒前缀指令、
> `/` 指令、按钮交互一律原样放行，所以插件、指令、会话控制与私聊行为完全不受影响。
>
> `LifeTurnStage` 排在 `LifeIngestStage` 之后、`WakingCheckStage` 之前：普通群消息交给
> `TurnRuntime`，第一条消息成为“回合主”并等待防抖窗口（三档 + 8 秒硬上限，另有
> `max_wait_seconds` 兜住未来时间戳）；期间到达的新消息并入同一回合并延长窗口，这就是
> “新消息打断/steering”的实现层。窗口到期后，回合主用与离线重放**完全相同**的门控打分：
> `wait` 就停掉自己的事件（消息已归档、不回），`reply` 就把合并后的文本写回
> `event.message_str`、打上 `_life_force_wake` 继续走管线；同一回合的其它消息一律停掉
> （内容已经在合并文本里）。
>
> 上游只加了一个 5 行接缝：`WakingCheckStage` 看到 `_life_force_wake` 就直接认定 `is_wake`，
> 否则这条群消息会在唤醒检查处被丢掉——这是“心流能主动接话”的最小必要条件。
> `tests/life/test_life_heartflow_stage.py` 用正反两个用例把这条接缝钉死。
>
> 影子模式 `heartflow.runtime.shadow=true` 只记录 `would_reply`、不实际接管，可直接用于灰度观察；
> `max_pending_turns` 给同时挂起的回合封顶，超出的消息既不等待也不回复。
> `GET /api/v1/life/status` 的 `heartflow` 块给出计数器与最近 50 条决策
> （`decide` / `reason` / `likelihood` / `threshold` / 合并条数），可直接对照离线重放。
>
> 尚未做：`wait` / `react` / `quote_reply` 三个模型工具（`wait` 已是门控级决策，让模型再等一次
> 只会白花一次调用；引用与补充按方案属于 S5 后处理），以及生成过程中的 token 级中途打断
> （当前只在防抖层 steering）。
>
> S4d（注意力 / 主动 / 快速反应）已落地：`bot/life/heartflow/{attention,idle,proactive}.py` 与
> `life_talk` 表，S4 至此收官。
>
> **注意力漂移与回钩**：每会话一个 `focus`，机器人答完话置 1，按 `half_life_minutes`（默认 40 分钟）
> 指数衰减；落到 `hook_focus_min..hook_focus_max`（默认 0.05–0.5）这段“还记得但已经走神”的区间、
> 且距上次搭话至少 `hook_min_gap_minutes` 时，才往系统提示词追加一个 `<life_attention>` 块，
> 给出“大约 N 分钟前聊过什么 + 关键词”，并明确要求“接得上就自然回钩，接不上别硬提”。
> `focus` 低于 `min_focus` 就整条忘掉——这才是“漂移”，不是永远记得。状态只在内存：重启前的
> 回钩提示本来也已经过期。
>
> **主动搭话 / 沉默 / 空闲退避**：`life_talk` 按会话存 `talk_value`（起 0.5，被回答 +0.1，主动搭话被
> 无视 −0.2）与 `attempts`。每 10 分钟扫一次，以下条件**全部**满足才允许先开口：静默
> `min_idle_minutes`（45）到 `max_idle_minutes`（720）之间、`talk_value ≥ min_talk_value`（0.55）、
> 当日已发 < `daily_cap`（2）、本地时间不在 `quiet_hours`、且距上次尝试超过
> `backoff_base_minutes × 2^(attempts-1)`（封顶 1440 分钟）。开场白必须由聊天模型生成
> （喂焦点摘要 + 最近 8 条），没有可用 provider 就整轮跳过，绝不发“在吗”模板。
> 上一句还没被回答时不会追问；过了 `answer_window_minutes`（30）没人接就记一次“被无视”。
>
> **快速反应**：`runtime.hot_window_seconds`（60）内刚答过话的会话，新的环境回合直接走快速档
> （1.2s）而不是自然档（2.5s）；`fast_max_chars`（8）以内的短句（“在吗”“？”）同样走快速档并
> 提前释放。生成过程中的 token 级打断仍由上游的 follow-up 机制负责，心流不重复实现。
> 面板侧新增 `GET /api/v1/life/attention`（注意力快照 + 主动搭话状态 + 单会话 `talk_value`）。

### 5.7 S5 人格与回复后处理（4 周 / 52 人日）

- 人格扩展：`life_persona_profile`（按 `persona_id` 关联，不改上游 `Persona` 表），
  群聊/私聊提示词、引用频率、多段概率、额外 Prompt。
- 提示词组装：人格 + 心流指令 + 记忆 + 人物 + 表达 + 群上下文，顺序与裁剪策略固定。
- 后处理：分段、错别字、关键词反应、引用、补充、文档回复。
- 约束：禁 Markdown、长度分布、段数分布对齐 MaiBot。

> **S5 切分**：S5a 人格档案 → S5b 提示词组装 → S5c 回复后处理 → S5d 分布对齐与验收。
> 四刀都能独立上线：S5a 只改提示词、不碰出站；S5b 只调整注入顺序与预算；S5c 才第一次改动
> 真正发出去的文字；S5d 用回放与统计验证前两刀没有把风格带偏。

> **S5a（人格档案）已落地**：`bot/life/persona/`（models / store / service）、`life_persona_profile`
> 表按 `persona_id` 唯一，空 `persona_id` 是默认档案（未配置人格的部署也能用）。字段包含
> 基础 / 群聊 / 私聊三段额外 Prompt、引用率、多段概率、错字率、单条长度上限、是否允许 Markdown。
> 注入点在 `inject.py` 的固定序列表首位，`PersonaService.inject` 把 `<life_persona>` **前置**到
> 系统提示词，其余生命层块顺序不变；`persona_id` 取自上游已解析的 `_trace_persona_id`，不查、
> 不改上游 `Persona` 表。解析结果按 `cache_ttl_seconds` 缓存，档案写入 / 删除时整体失效。
> 面板新增 `GET /api/v1/life/persona`、`GET|PUT|DELETE /api/v1/life/persona/{persona_id}`
> （路径段 `default` 指向空 `persona_id` 的默认档案），`/life/status` 增加 `persona` 块。
> 实测：群聊档案输出「人设 + 群设定 + 长度 / 分段 / 引用 / 禁 Markdown」五行约束；私聊档案只出
> 私聊设定；把三项概率都设为 0 且允许 Markdown 的档案只剩长度一行，说明 0 值不会被默认值覆盖。

> **S5b（提示词组装）已落地**：`bot/life/prompt.py` 的 `PromptAssembler` 在全部注入器跑完后做一次
> 统一整理：固定顺序（persona → memory → expression → jargon → focus → attention）、跨块去重
> （完全相同且 ≥ 8 字的行只留最早一份）、单块上限 `max_block_chars`（按行切，不切半句）、
> 总预算 `max_total_chars`（超预算时从最不重要的块整块丢弃，persona 永不丢，最后才截断）、
> 丢块后折叠多余空行。注入器仍各自决定“这块要不要出现”，组装器只管顺序与大小。每次组装把
> 块名、字数、丢弃清单记到 `service.prompt`，`/life/status` 的 `prompt` 块暴露预算、计数器与
> 最近一次组装。实测：同一行同时出现在记忆与焦点块时只保留一份；persona 单块超上限时先丢比例
> 说明、保留长度与禁 Markdown 两条硬约束（规则顺序就是优先级）。

> **S5c（回复后处理）已落地**：`bot/life/reply/postprocess.py`，S5 里唯一真正改写用户看到的文字的
> 一步，按顺序做五件事：剥 Markdown（除非档案允许）→ 至多一处错字（相邻汉字互换或叠字）→
> 按档案长度上限在句末截断 → 按 `multi_segment_prob` 拆成最多三段（上游分段回复开启时让位上
> 游，避免双重切分）→ 按 `quote_rate` 插入引用。拆出来的尾段由后台任务按
> `segment_delay_seconds` 逐条 `event.send`，因为上游只在 `segmented_reply.enable` 时才按组件
> 边界分条发送，组件个数本身不会变成多条消息。只处理非流式 LLM 结果：命令、插件输出、流式
> 增量与 runner 错误不碰。上游接缝是 `ResultDecorateStage` 末尾的 3 行调用，失败只记日志、绝不
> 阻断回复。`/life/status` 新增 `reply` 块（开关 + 七类计数器）。

> **S5d（分布对齐与验收）已落地**：`bot/life/reply/style.py` + `scripts/life/style_metrics.py`。
> 输入两选一：一份出站消息 JSONL（`{"text": ...}`，可带 `segments` / `quoted`），或保存下来的
> `/api/v1/life/status`（用 `reply.recent` 环形缓冲，只含长度、段数、引用、泄漏标记，不存原文）。
> 输出长度分布（均值 / 中位 / P90 / 最大）、段数分布（均值 / P90 / 多段占比）、引用率、Markdown
> 泄漏数；给 `--reference` 时对长度做两样本 KS 检验（纯 Python 实现，含小样本修正），给
> `--expected-quote-rate` 时校验引用率是否在容差内。退出码即门禁：0 通过、2 长度分布显著不同、
> 3 有 Markdown 泄漏、4 引用率超容差。`ReplyPostProcessor` 同时新增 `reply.recent`（最近 50 条，
> 含 `chars` / `segments` / `quoted` / `markdown` / `leak` / `capped`），不保存原文。
> 实测：16 条样例经真实后处理后 `segments(mean/share_multi)=1.44/0.25`、`quote_rate=0.75`、
> `leaks=0`；`--sample` 与 `--status` 两条入口给出完全一致的数字；把同一批回复与一组短回复做
> 对照，KS `D=0.875, p<0.001`，门禁以退出码 2 拦下——说明“分布拉得开会被抓到”这件事本身有效。

**验收**：回复长度/段数分布与对照组无显著差异（KS 检验 p > 0.05）；
引用率符合配置；禁词与 Markdown 泄漏为 0。

### 5.8 S6 工具、周边与面板（7 周 / 58 人日）

- 工具结果压缩、子任务、计划器监控、推理过程展示。
- ACP 适配、文件服务（群文件上传/下载、临时文件与清理）。
- 面板 8 页：记忆、人物、表达、黑话、表情、心流监控、学习审核、数据迁移。
- 统计与诊断：复用现有 stats，补心流指标与记忆健康度。

**验收**：面板 CRUD 全通；权限与审计到人；移动端可用；ACP、文件服务两项均可独立关闭。

> 实施说明（S6a 已落地）：工具结果压缩不新增一条独立链路，而是挂在
> `ToolLoopAgentRunner._materialize_large_tool_result` 的入口：生命层关闭时该方法逐字不变，
> 生命层开启但拒绝（结果偏短、工具在排除名单、会话不在灰度、整理调用失败/超时/没缩短）时仍走
> 上游“超长结果落文件 + read_tool 提示”的原有路径。整理调用是一个**不带父上下文**的临时
> 补全，只看到结果头部（`max_input_chars`）与模型调用工具前那句想法（`intent_max_chars`）；
> 原文按会话暂存在内存（每会话 20 条 / 20 万字、最多 200 个会话），整理后的文本里给出
> `read_tool_result(result_id="rN")` 的取回方式，支持 `keyword` 与 `offset`/`limit` 分页。
> 配置在 `life.tool_result.*`，默认关闭；`/life/status` 增加 `tool_result` 块（计数器 + 暂存统计）。
>
> 实施说明（S6b 已落地）：子任务走 `bot/life/subagent/`，与主对话**不共享上下文**：只拿到
> 任务原文、自己的系统提示与一组显式授权的工具（`allowed_tools` 为空即纯文本子代理；模型传的
> `tools` 要与允许名单取交集，并受 `max_granted_tools` 限制）。执行器是精简版，只把工具文本结果
> 交给子代理，不发消息、不写聊天历史、不登记后台任务。容量为进程级 `max_running` + 会话级
> `max_running_per_session`，整轮与单次工具调用各有超时。结论不直接发消息：会话还有活动 run 时
> 作为 follow-up 追加进该轮（真唤醒），否则进会话收件箱，下一轮以 `<life_subagent>` 注入；活动
> run 没消费 follow-up 时由后台检查落回收件箱。
>
> 实施说明（S6c 已落地）：监控不新增接缝，只在既有位置记录：`LifeTurnStage` 记录心流决策
> （action / 是否回复 / likelihood / threshold / reason），`postprocess_life_reply` 记录一次投递
> （字数、段数、截断后的 `reasoning_content`），即使回复后处理关闭也照记。记录只有数值与片段、
> 不存消息原文，内存 ring 默认 100 条，`GET /api/v1/life/monitor` 与 `/life/status` 的
> `monitor` 块读取。关键词反应新增 `LifeReactionStage`（`STAGES_ORDER` 第 2 位）：命中规则的
> 消息直接由固定回复作答并 `stop_event`，模型看不到这条消息；命令、灰度外会话不匹配，冷却按
> （规则, 会话）内存保存。
>
> 实施说明（S6d 已落地）：ACP 适配在 `bot/life/acp/`，自带一个**最小 ACP v1 客户端**：子进程
> stdio 上的 NDJSON JSON-RPC、`initialize` 握手（必须协商 v1）、每会话一个 `session/new`、
> 文本取 `agent_message_chunk`、按 `timeout_seconds` 硬超时、失败即关进程并返回 None。
> 外部 Agent 的 `session/request_permission` 一律 `cancelled`，其余 peer 请求回 `-32601`，不给
> fs/terminal，也不把宿主工具经 MCP 暴露出去。两种用法：`takeover=false` 时只注册
> `ask_external_agent` 工具；`takeover=true` 时 `LifeAcpStage` 直接接管范围内纯文本消息并
> `stop_event`，失败自动回退本地模型。
>
> 实施说明（S6e 已落地）：文件服务在 `bot/life/files/`，沙箱目录 `<life>/files`（`out/` 文档、
> `tmp/` 临时），文件名归一化（去目录、非法字符替换、Windows 保留名拒绝）+ 扩展名白名单 +
> 大小上限 + TTL 清理（每小时）。三个工具：`send_document`（模型产出正文 → 落盘 → 以 `File`
> 消息段发送，即 S5c 延期的「文档回复」）、`send_file`（发送已有文件）、`download_file`（仅
> http(s)，流式下载并即时按 `max_file_bytes` 截断，不自动发送）。`send_text` 泛化为
> `send_chain` 以便文件与文本共用出站记账。
>
> 实施说明（S6f 已落地）：面板 8 页在 `LKM-official-website/bot-panel` 的 `src/views/life/`
> （记忆 / 人物 / 表达 / 黑话 / 表情 / 心流时间线 / 计划器监控 / 数据迁移），侧边栏新增
> 「生命层」分组，中英双语词条齐备；数据层是手写的 `src/api/life.ts`，走同一个 axios 实例与
> 鉴权拦截器，直接复用既有 `/api/v1/life/*` 端点，没有新增后端接口。页面能力：记忆列表 / 检索 /
> 删除 / 导出，人物列表 / 画像 / 事实现实删除，表达列表 / 删除，黑话复审与删除，表情启停与删除，
> 心流会话摘要与回合详情 / 删除，监控记录与推理片段，迁移页的记忆导出 + 配置读写。仍未做：
> 统计诊断（S6g）、人物关系值与表情标签的编辑、MaiBot 历史语料导入（S7）。
>
> 实施说明（S6g 已落地）：诊断报告在 `bot/life/diagnostics.py`，只读地复用
> `LifeService.status()`，派生心流回复率 / 等待率 / 合并率、记忆向量覆盖率与最新记忆年龄、
> 复习积压（待复审事实 + 冲突 + pending 黑话）以及各特性计数器，产出 `pass`/`warn` 检查，
> `overall` 只在报告本身构建失败时为 `fail`。`GET /api/v1/life/diagnostics` 与
> `scripts/life/diagnostics.py --status` 同一份报告，CLI 退出码 0/1/2 可直接进值班脚本。

### 5.9 S7 双跑、迁移与切换（5 周 / 24 人日）

- 影子模式：生命层只出决策、不发送，记录 `would_reply` / `would_wait` / 时机。
- A/B 灰度：按 UMO / 群白名单放量，1% → 10% → 50% → 100%。
- 数据迁移工具：MaiBot 聊天记录、人物、表达、黑话、表情、A_memorix 数据目录。
- 回滚演练、值班手册、用户公告。

**退出条件**：灰度连续 2 周无 P1；回滚 < 10 分钟且不丢数据；MaiBot 转只读归档。

> 实施说明（S7a 已落地）：灰度放量在 `bot/life/rollout/`。`scope.rollout_percent`
> （0–100）按群做稳定哈希分桶（私聊按会话），同一群不会在消息之间翻转；显式
> `enabled_umos` / `enabled_group_ids` 绕过百分比，`disabled_umos` 始终优先；
> `scope.rollout_salt` 可在窗口之间整体重排。影子观测复用
> `heartflow.runtime.shadow`（只决策、不唤醒、不发送），并把每个释放回合写入
> `life_turn_decision`（决策 / 动作 / 门控分数 / debounce 等待毫秒 / 文本长度，
> 不含任何原文），重启后仍可复盘两周边界；`GET /api/v1/life/rollout?days=14`
> 与 `/life/status` 的 `rollout` 块给出回复率、P50/P90 等待、最活跃会话与最近决策，
> 诊断新增 `rollout_observation` / `rollout_activity` 两项检查。回滚只需把
> `rollout_percent` 置 0 或把 `shadow` 打回 true，不动数据。顺带修掉一个 S4c 遗留 bug：
> `LifeService._note_heartflow_reply` 原本是 `async`，而运行时是同步调用，协程被丢弃，
> 导致注意力与主动搭话的“已回复”记录从未生效；现已改为同步回调。
>
> 实施说明（S7b 已落地）：迁移在 `bot/life/migration/`（source / service / models），
> 以 `mode=ro` 打开 MaiBot 1.4 的 `data/MaiBot.db`，只写 Life 表。六个数据集：聊天记录
> （跳过机器人账号与 `is_notify` 群通知）、人物 + `memory_points`（转为事实；`is_known=0`
> 默认跳过，`--include-unknown` 才导入）、表达（`checked=0` 落为 `pending`，与 MaiBot「只用
> 人工审核过的表达」一致）、黑话（跳过非黑话）、表情（跳过非 emoji 与被禁用项，文件复制到
> `data/life/emoji/<session>/<sha256>`）、A_memorix `paragraphs`（导入为 global 记忆）。
> A_memorix 的 `knowledge_type` 按 `structured`/`narrative`/`factual`/`quote`/`mixed` 映射为
> `note`/`episode`/`fact`/`note`/`note`，事实记忆因此能进人物事实与召回通道；没有任何时间戳
> 的段落按「无日期」（`ts=0`）导入，不伪造成迁移时刻。会话键复用运行时格式：`qq*` →
> `aiocqhttp`，按群 / 私聊生成 `GroupMessage` / `FriendMessage`；未知平台计入
> `unknown_platform`。所有写入都是 `ON CONFLICT DO NOTHING`，可重复执行；重跑的冲突计入
> `skipped_reasons.duplicate`，保证 `written + duplicate == ready`，被列宽截断的取值计入
> `truncated`。每次真实导入在 `life_migration_run` 记录各表行号水位，`rollback` 只删
> `before < id <= after`，并在删完后清理不再被引用的表情文件与空目录；因此导入后新增的行不受
> 影响，失败批次没有 before 水位时回滚是 no-op（迁移期间应停 bot）。`--timezone` 指定源部署的
> IANA 时区，避免源机与迁移机时区不同导致时间整体平移。入口是 `scripts/life/migrate.py`
> 的 `inspect` / `preview` / `import` / `runs` / `rollback` 五条子命令；面板入口留到 S7c。
>
> 实施说明（S7c 已落地）：面板新增「灰度看板」（`LifeRolloutPage.vue`）：7/14/30 天窗口、
> 回合 / 回复 / 影子回复 / 回复率 / 等待 P50-P90、最活跃会话与最近决策，并可直接修改
> `scope.mode`、`scope.rollout_percent`、`scope.rollout_salt`、`heartflow.runtime.shadow`
> 后保存（重启生效，百分比置 0 即回滚）。「数据迁移」页接入 `GET /life/migration/runs`、
> `POST /life/migration/preview`（只读干跑，默认限 500 条消息）与
> `POST /life/migration/rollback`（带确认框），真实导入仍走 CLI。新增
> `bot/life/migration/drill.py` + `scripts/life/drill.py`：在数据库副本上生成合成 MaiBot 源 →
> 导入 → 插入一条“线上流量”哨兵 → 回滚 → 核对基线，输出 import/rollback 秒数并追加
> `data/life/drill/history.jsonl` 演练记录，退出码即门禁（600 秒）。运行手册补 S7c：
> P1 信号与五分钟处置、四级回滚阶梯、用户公告中英模板、S7 退出清单。

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
| 2026-11-07 | D5 MaiBot 保留期 | 旧实例只读保留 3 个月，之后归档离线 |
| 2026-11-07 | D6 首发平台 | QQ（aiocqhttp）优先，微信次之 |

## 附录 G：实施进度

| 阶段 | 状态 | 交付 |
| --- | --- | --- |
| S0 | 工具链完成，数据待补 | `collect_replay.py`（采集）、`replay_stats.py`（语料统计）、`replay_runner.py`（一键重放 → 决策流）、`life_metrics.py`（五项指标 + 与基准对比的门禁退出码）；本地开发库已端到端跑通（1 会话 / 57 条，非基线）；300 段语料、MaiBot 对照与人工标注待生产数据与预算 |
| S1 | 已完成 | `bot/life/`（config / ingest / models / store / sender / session / service / pipeline）、`LifeIngestStage` 置首、`life_messages` + `life_outbound`、主动发送封装、`/api/v1/life/*`、`tests/life` 22 条用例 |
| S2 | 已完成（代码层面） | `bot/life/memory/`（models / store / embedding / digest / adapter / inject / tools / upstream / importer）、`life_memory` + `life_memory_cursor`、五模式检索、`OnLLMRequestEvent` 注入、三个 Agent 工具、MaiBot 导入与运维 CLI、`/api/v1/life/memory*`、`tests/life` 新增 29 条用例（合计 51 条） |
| S3（人物域已落地） | 部分完成 | `bot/life/person/`（names / models / store / service）、`life_person` + `life_person_fact` + `life_person_profile`、别名与群名片归一、关系值衰减、事实冲突检测与复审、画像缓存（LLM/抽取式双通道）、`/api/v1/life/people*`、`get_person_profile` 接真画像、`tests/life` 新增 17 条；S3 四类已全部落地 |
| S3b（表达学习） | 部分完成 | `bot/life/expression/`（models / store / learn / index / select / service）、`life_expression` + `life_expression_cursor`、启发式挖句（标点切片 + 语气词 + 重复度）与 LLM 抽双通道、FAISS 索引复用 `vec_db/faiss_impl`（不可用时回退关键词）、情景/权重/场景三维打分、`<life_expression>` 提示块、`/api/v1/life/expressions`、`tests/life` 新增 26 条；S3 四类已全部落地 |
| S3c（黑话） | 部分完成 | `bot/life/jargon/`（models / store / learn / service）、`life_jargon` + `life_jargon_cursor`、定义句式挖掘（「X」就是 Y / X 指的是 Y / Y 简称 X）+ LLM 抽取双通道、同词异义转 pending 人工复审、只在当前上下文出现该词时注入释义、`/api/v1/life/jargon`、`tests/life` 新增 23 条（合计 127 条）；S3 四类已全部落地 |
| S3d（表情包） | 部分完成 | `bot/life/emoji/`（models / store / collect / select / service / tools）、`life_emoji` + `life_emoji_cursor`、按 SHA-256 去重并按会话存盘、从归档图片采集（http(s)/本地路径，base64 不可恢复则跳过）、标签检索 + 向量可选、冷却与每小时上限、`send_meme` Agent 工具走 LifeSender 真发、`/api/v1/life/emojis`、`tests/life` 新增 22 条（合计 149 条） |
| S4a（心流决策链路） | 部分完成 | `bot/life/heartflow/`（debounce / gates / policy）、三档防抖 + 8s 硬上限 + @ 加速 + 同人续发、九特征似然 + 动态阈值（空闲抬升 / 连续沉默退避 / 刚回过抑制）、`replay_runner.py --decider heart_flow` 复用同一条决策路径产出决策流、`life.heartflow.*` 配置与面板读写、`tests/life` 新增 40 条（合计 189 条） |
| S4b（会话时间线 / 压缩 / 检查点） | 部分完成 | `bot/life/heartflow/focus/`（timeline / models / store / service）、`life_focus` + `life_focus_turn`、按空闲间隔回合化、最旧回合折叠成摘要（丢最旧行 + 省略标记）、检查点与重启恢复、`_focus_loop` 定时回写、`send_text` 回复收尾、`<life_focus>` 只注入折叠摘要、`/api/v1/life/focus`、`tests/life` 新增 42 条（合计 231 条） |
| S4c（运行时接管） | 部分完成 | `bot/life/heartflow/runtime.py`（回合主 / 合并 / 门控 / 影子 / 并发上限）、`LifeTurnStage`（`STAGES_ORDER` 第 2 位）只接管未被点名的群消息、合并文本 + `_life_force_wake` 续跑管线、`WakingCheckStage` 5 行接缝、`GET /life/status` 的 `heartflow` 块（计数器 + 最近 50 条决策）、`tests/life` 新增 27 条（合计 258 条） |
| S4d（注意力 / 主动 / 快速反应） | 部分完成 | `bot/life/heartflow/{attention,idle,proactive}.py` + `life_talk` 表、注意力指数衰减 + 漂移区间回钩提示（`<life_attention>`）、主动搭话六道闸门（静默区间 / talk_value / 日上限 / 免打扰时段 / 指数退避 / 待答不追问）、被无视降权与被回答提权、LLM 生成开场白（无 provider 跳过）、快速反应（热会话与短句走快速档）、`/api/v1/life/attention`、`tests/life` 新增 38 条（合计 296 条） |
| S5a（人格档案） | 部分完成 | `bot/life/persona/`（models / store / service）、`life_persona_profile`（`persona_id` 唯一，空值即默认档案）、基础 / 群聊 / 私聊三段额外 Prompt + 引用率 / 多段概率 / 错字率 / 长度上限 / 允许 Markdown、`<life_persona>` 前置注入与 5 分钟缓存（写入即失效）、`inject.py` 固定注入序列表（persona 居首）、`/api/v1/life/persona*` 面板 CRUD 与 `persona` 状态块、`tests/life` 新增 23 条（合计 319 条） |
| S5b（提示词组装） | 部分完成 | `bot/life/prompt.py`（`PromptAssembler`）、固定顺序 + 跨块去重（≥ 8 字整行）+ 单块 / 总预算（整块丢弃、persona 不丢、按行截断、丢块后折叠空行）、`life.prompt.*` 配置、`/life/status` 的 `prompt` 块（预算 / 计数器 / 最近一次块清单）、persona 规则顺序改为「长度 → 禁 Markdown → 比例」使截断先丢概率、`tests/life` 新增 13 条（合计 332 条） |
| S5c（回复后处理） | 部分完成 | `bot/life/reply/postprocess.py`（`ReplyPostProcessor`）、Markdown 剥离、单处错字、句末截断、按概率拆段（尾段延迟发送，上游分段开启时让位）、按概率引用（仅 `aiocqhttp`）、只处理非流式 LLM 结果、`ResultDecorateStage` 末尾 3 行接缝、`life.reply.*` 配置与 `/life/status` 的 `reply` 块、`tests/life` 新增 19 条（合计 351 条） |
| S5d（分布对齐与验收） | 部分完成 | `bot/life/reply/style.py`（percentile / 两样本 KS / JSONL 与 status 两种输入 / `evaluate` 门禁）+ `scripts/life/style_metrics.py`、`reply.recent` 环形缓冲（最近 50 条，不存原文）、门禁退出码 0/2/3/4、`tests/life` 新增 19 条（合计 370 条）；与真实 MaiBot 的对照仍待生产语料 |
| S6a（工具结果压缩） | 部分完成 | `bot/life/toolresult/`（condense / store / read）、`life.tool_result.*` 配置、`ToolLoopAgentRunner._materialize_large_tool_result` 接缝（生命层关闭时逐字不变，拒绝时回退上游落文件路径）、无父上下文的整理补全（结果头部 + 调用意图尾部）、按会话内存暂存原文（20 条 / 20 万字 / 200 会话）、`read_tool_result` 工具（keyword / offset / limit）、`/life/status` 的 `tool_result` 块、`tests/life` 新增 23 条（合计 393 条）+ 1 条接缝测试；子任务、计划器监控与推理展示留到 S6b/S6c |
| S6b（子任务） | 部分完成 | `bot/life/subagent/`（models / tasks / runner / inbox / notify / tools）、`life.subagent.*` 配置与 `subagent` / `subagent_status` / `subagent_stop` 三个工具、无父上下文的受限工具循环（`allowed_tools` 交集 + 单次调用超时）、进程级与会话级并发上限、结论经 active-run follow-up 或 `<life_subagent>` 收件箱回注、`/life/status` 的 `subagent` 块、`tests/life` 新增 22 条（合计 415 条） |
| S6c（计划器监控 / 推理展示 / 关键词反应） | 部分完成 | `bot/life/monitor/recorder.py`（决策 + 投递 ring，不存原文，截断推理片段）、`LifeTurnStage` 决策记录、`postprocess_life_reply` 投递记录、`GET /api/v1/life/monitor` 与 `/life/status` 的 `monitor` 块、`bot/life/reaction/` + `LifeReactionStage`（命中即固定回复并 stop_event，会话级冷却）、`life.monitor.*` / `life.reaction.*` 配置、`tests/life` 新增 18 条（合计 433 条） |
| S6d（ACP 外部 Agent） | 部分完成 | `bot/life/acp/`（protocol / client / service / tools）最小 ACP v1 客户端：NDJSON JSON-RPC、握手协商、每会话 `session/new`、`agent_message_chunk` 聚合、硬超时与失败重置；peer 请求一律拒绝；`ask_external_agent` 工具与 `LifeAcpStage` 接管两种用法；`life.acp.*` 配置与 `/life/status` 的 `acp` 块；`tests/life` 新增 15 条（合计 448 条） |
| S6e（群文件服务） | 部分完成 | `bot/life/files/`（store / service / tools）沙箱存储（`out/` 文档、`tmp/` 临时）、文件名归一化与扩展名白名单、大小上限、TTL 清理循环、`send_document` / `send_file` / `download_file` 三个工具、`send_text` 泛化为 `send_chain`、`life.files.*` 配置与 `/life/status` 的 `files` 块、`tests/life` 新增 15 条（合计 463 条） |
| S6f（面板 8 页） | 部分完成 | `bot-panel/src/views/life/`（8 页 + 共享页壳 / 确认框 / 格式化）、`src/api/life.ts`（复用 `/api/v1/life/*`）、侧边栏「生命层」分组与 8 条路由、中英 `features/life.json` 与导航词条；记忆 / 人物 / 表达 / 黑话 / 表情 / 心流 / 监控 / 迁移八页的列表、检索、复审、启停、删除、导出与配置读写；`pnpm typecheck`、`pnpm build`、`pnpm i18n:check` 与 81 条 node 测试通过 |
| S6g（统计与诊断） | 部分完成 | `bot/life/diagnostics.py`（`derive_metrics` / `evaluate_checks` / `build_report` / `exit_code`）、11 项 pass-warn 检查、`GET /api/v1/life/diagnostics`、`scripts/life/diagnostics.py --status`（退出码 0/1/2）、`files` 状态补 `max_files`、`tests/life` 新增 13 条（合计 476 条） |
| S7a（灰度放量与影子观测） | 部分完成 | `bot/life/rollout/`（buckets / models / store / service）：`scope.rollout_percent` 稳定分桶、`scope.rollout_salt` 重排、`life_turn_decision` 决策日志（无原文，默认留 90 天）、`GET /api/v1/life/rollout?days=14`、`/life/status` 的 `rollout` 块、诊断新增 `rollout_observation` / `rollout_activity`、运行手册 S7a 小节、`tests/life` 新增 22 条（合计 498 条） |
| S7b（MaiBot 数据迁移） | 部分完成 | `bot/life/migration/`（source / service / models）：只读打开 `data/MaiBot.db`，六数据集迁移（聊天记录 / 人物+事实 / 表达 / 黑话 / 表情+文件 / A_memorix paragraphs），`ON CONFLICT DO NOTHING` 幂等、`life_migration_run` 行号水位与 `rollback`、`scripts/life/migrate.py`（inspect / preview / import / runs / rollback，`--json`）、记忆导入支持 `scope=global` 与来源标记、运行手册 S7b 小节、`tests/life` 新增 31 条（合计 529 条） |
| S7c（回滚演练与交接） | 部分完成 | 面板 `LifeRolloutPage.vue`（灰度看板 + 放量配置）与迁移页的预览 / 批次 / 回滚；`GET /life/migration/runs`、`POST /life/migration/preview`、`POST /life/migration/rollback`；`bot/life/migration/drill.py` + `scripts/life/drill.py`（副本上的导入→哨兵→回滚演练，600 秒门禁，`history.jsonl`）；运行手册 S7c（P1 信号、五分钟处置、四级回滚阶梯、用户公告模板、退出清单）；`tests/life` 新增 7 条（合计 536 条） |

S0/S1/S2/S3a 与方案的偏差：

1. Life 配置落在独立文件 `data/life/config.json`，未写入 `cmd_config.json`；S6 面板接管编辑前由该文件开关。
2. 初始化接缝实际落在 `bot/core/core_lifecycle.py`（`initial_loader.py` 只负责装配生命周期），位置更靠近 `star_context`。
3. 关闭开关时只创建 `data/life/config.json` 并在启动日志提示，不建表、不写消息、不改变流水线行为。
4. S2 未以 git subtree 复制 10 万行上游代码，改为**可选依赖 + 适配层**：`a-memorix` 按 commit 固定安装（`scripts/life/README.md` 有命令），`bot/life/memory/upstream.py` 通过 `NamespaceHostPorts(embedding_provider=...)` 接入，未安装时自动回落到本地引擎。理由是上游 2.x 已是可安装包、内部使用绝对导入，subtree 到 `bot/...` 前缀会让 `import a_memorix` 失效，且把 alpha 代码锁进 fork 会破坏上游可合并性。
5. 记忆注入接缝落在 `internal.py`（本地 Agent 路径）`call_event_hook(OnLLMRequestEvent)` 之后，保证插件改写系统提示词后记忆仍然生效；`third_party.py`（Dify/Coze/DeerFlow）暂不注入。
6. 本地引擎候选集上限 600 行，检索召回有上界；1000 与 5000 行实测 P95 分别 82.6 ms / 84.2 ms（`memory_tool.py bench`，不含 embedding 网络耗时）。
7. S3a 事实冲突检测是启发式（同类别 + 二元组 Jaccard ≥ 0.6），只能标记待复审，不能自动判定谁对；复审走面板 API，人工或后续模型裁决。误学习率需要通过人工抽检标定，当前未测。
8. S3a 的关系值、置信度衰减只在归档 flush 与 6 小时维护任务里推进，不依赖逐条消息的定时任务。
9. S3b 的启发式挖句偏保守（要求语气词 + 重复，且切片后 2–16 字），召回天然低于 MaiBot 的 LLM 学习；
   它的价值是在没有模型预算时也能跑通「学习 → 入库 → 命中 → 删除」，质量调优要靠 LLM 通道与人工抽检。
10. S3b 复用 `FaissVecDB` 时按其具体类实例化（它要求 `EmbeddingProvider` 抽象基类），用轻量适配器
    提供 `get_dim`/`get_embedding(s)`；索引是派生数据，删库后可全量重建，不进备份契约。
11. 注入接缝从 `inject_memory_context` 改名为 `inject_life_context`，同一处 `internal.py` 调用点按顺序注入
    记忆、表达、黑话三个块，核心改动仍是 1 个 import + 1 次调用。
12. S3c 的挖掘以“带释义的定义句”为前提（裸词不入库），所以召回偏低但误学习少；LLM 通道才是主力，
    启发式负责在没有模型预算时跑通闭环。引号内的单字词（如「典」）允许入库，未加引号的单字词一律丢弃。
13. S3c 只在上下文命中该词时注入释义，不做“主动科普”也不让模型主动使用黑话；误用率因此压到很低，
    代价是很多学会的词暂时不会出现（可观测：`usage_count` 长期为 0 的词需要人工判断是否值得保留）。
14. S3d 只采集“还能取回”的图片：归档时 base64 已被折叠成 `base64://<N chars>`，因此纯 base64 图片
    （不少平台的默认形式）采集不到；要覆盖它们需要在 S1 归档阶段就落盘，属于后续优化。
15. S3d 的语义标签取自图片所在消息的文本，不是图像理解；向量相似度也要靠这段文本，所以“图不对文”
    的梗图召回会差。真正的图像描述需要视觉模型，不在本期范围。
16. S3d 的发送闸门（冷却、每小时上限）是进程内状态，重启即清零；它防的是刷屏循环，不是防重启。
17. S4a 的离线评估只覆盖“回不回”这一层：`heart_flow` 决策器不计 Planner 的生成内容与耗时，所以词表里的“时机 P90 ≤ 3s”目前只反映防抖窗口的相对延迟，不含模型延迟。
18. 语料里没有机器人 id 时，`at` 一律按“点名机器人”处理（`--bot-ids` 可消除歧义）；`reply` 组件无法反查被回复者的身份，因此 `reply_to_bot` 在离线重放中恒为 false，该特征要等运行时拿到真实回复关系才准确。
19. S4b 的时间线只记录归档里的入站消息；机器人自己的回复只有走 `LifeService.send_text` 的主动
    发送才会入线。S4c 的接管发生在决策层（放行后由上游 Agent 生成并发送），不经过 `send_text`，
    所以普通回复仍不进时间线；要补需要在响应成功后回写。压缩是模板式抽取（回合原文拼接 + 截断），
    没有 LLM 摘要，质量要靠后续的 `use_llm` 通道提升。
20. S4c 的接管面只有“未被点名的群消息”：`@`、回复机器人、唤醒前缀、`/` 指令、私聊仍然走原始上游
    链路，所以“心流”目前不改变被点名时的措辞或时机（那部分本来就由人格与 S5 后处理负责）。
21. S4c 没有把 `wait` / `react` / `quote_reply` 做成模型工具：`wait` 在调用模型之前就已经决定，
    再给模型一个 `wait` 只会浪费调用；`react` 由已有的 `send_meme` 承担；引用与补充按方案归 S5
    后处理。合并投递只改 `event.message_str`，不重建消息链，所以同回合后续消息里的图片不会进入
    这一轮的模型输入。
22. S4d 的主动搭话默认关闭，且必须先“答过话”才有资格：`talk_value` 从 0.5 起、门槛 0.55，新群
    不会被一上来就搭话。开场白只能由模型生成，没有 provider 就整轮跳过；被无视会降权并指数退避，
    所以调错一次不会连续挨骂。
23. S4d 的注意力状态只在内存（重启即清空），且回钩只是提示词里的一句上下文，不保证模型真的回钩；
    “打断”仍停在防抖层，上游 follow-up 机制负责生成中的 token 级打断，但被心流挂起的消息不会进
    上游 follow-up——同一会话的追问会变成一个新的快速档回合。
24. S5a 的人格档案只负责“告诉模型该怎么说话”，还不会改写模型吐出来的东西：引用率、多段概率、
    错字率目前只是提示词里的比例说明，真正按概率插入引用、拆分多条、制造错字要等 S5c 的后处理；
    Markdown 禁令同理，S5a 只能要求模型别写，S5c 才会在出站前剥掉残留的 Markdown。
25. S5b 只做“事后整理”：注入器仍然直接往 `req.system_prompt` 里写块，组装器在末尾解析标签、
    去重、截断、丢块。好处是六个服务的接口一行没改，坏处是块内容本身写错时组装器看不出来——
    标签不配对的那段会原样留在提示词里，也不会被计入预算。
26. S5c 只做“已经生成完的文字怎么改”：剥 Markdown、错字、截断、拆段、引用。MaiBot 的「补充」
    与「文档回复」需要模型配合产出附加内容或文件，不在纯文本后处理能安全伪造的范围内，留到 S6
    与工具、文件服务一起做；关键词反应同理，它更接近“收到某类消息时的固定回应”，放进 S6 的
    触发器里比塞进回复后处理更合理。
27. S5c 的分段依赖后台发送：上游 `RespondStage` 只有在 `segmented_reply.enable` 为真时才按组件
    发送多条消息，否则整条链合成一条。所以尾段由 `asyncio` 任务按 `segment_delay_seconds` 逐条
    `event.send`。代价是它发生在管线收尾之后——同一会话若在此期间又被触发，两条回复的先后
    顺序不保证。默认 1.2 秒的间隔是为了让首段先发出去。
28. S5d 的“对照组”目前是本地构造的短回复样本，不是真实 MaiBot 的产出：S0 仍缺 300 段生产语料与
    同模型参考 run，所以 KS 门禁只证明了“工具能识别分布差异”，不能证明“与 MaiBot 无显著差异”。
    拿到语料后只需 `style_metrics.py --reference <mai bot 出站 JSONL>`，门禁与退出码不变。
29. S5d 的 `reply.recent` 只保留最近 50 条、且不存回复原文（只有长度与标记），所以事后复盘能看
    分布是否漂移，但看不到具体某条回复被改成了什么；需要原文时得靠平台侧日志。
30. S6a 的工具结果暂存在**进程内存**里（每会话 20 条 / 20 万字、最多 200 会话），重启即清空，
    多进程部署时某个 worker 整理的结果只有该 worker 能取回。暂存的是原文，没进数据库也没落盘；
    需要跨重启或跨进程时，得改成与 S1 归档同库的表。
31. S6a 的整理调用**阻塞该轮工具执行**（一次普通补全的时间，默认上限 30 秒）。它省的是后续每一轮
    的上下文，不是当轮的等待；provider 不可用时记为 `failed` 并保留原文，不阻断工具调用。
    另外“调用意图”取的是模型调用工具前那句文本，模型不写想法时整理会退化成“只看结果猜意图”，
    所以默认阈值 4000 字偏保守。
32. S6b 的“唤醒”只在**会话还有活动 run** 时成立（结论作为 follow-up 追加进该轮）。LKM-bot 的
    Agent 是按消息触发的一次性运行，后台任务无法自己发起新一轮；没有活动 run 时结论只能进收件箱，
    等下一轮 prompt 才被看到——用户不说话的群，子任务跑完也不会主动冒泡。真正的“主动醒来”要等
    S7 影子/常驻循环，或给生命层一个可注入事件的入口。
33. S6b 的子代理执行器是**精简版**：它不做主执行器的权限校验、历史落库与后台任务登记，只把工具
    文本结果交给子代理；因此 `allowed_tools` 必须保守（默认空 = 纯文本）。另外收件箱在注入时即
    消费，若这次 provider 调用随后失败，结论不会重试；`notice_max_age_minutes` 到期即丢弃。
34. S6c 的监控记录**不含消息原文**，只存 gate 数值、原因、长度与截断后的推理片段；但推理片段可能
    仍带用户内容，且没有脱敏——面板必须留在 system scope 后面。ring 与冷却表都是进程内存：重启清空，
    多 worker 各看各的，跨重启的审计要等 S6g 的统计落库。
35. S6c 的关键词反应命中后**直接 `stop_event`**，模型完全看不到那条消息，所以规则要保守；冷却按
    （规则, 会话）存内存，重启清零；只支持纯文本固定回复，表情/图片回复随 S6e 的文件服务一起做。
36. S6d 的 ACP 是**单向**的：只发 prompt、收文本。外部 Agent 的权限请求一律拒绝，没有
    fs/terminal 能力，也没有把宿主工具经 MCP 暴露出去；要让它用工具，得在外部 Agent 侧配置。
    一个进程串行处理所有会话的 prompt，慢 Agent 会阻塞其它会话直到超时。
37. S6d 的 `takeover` 在 `LifeTurnStage` 之前，所以外部 Agent 回答时：人格、记忆注入、S5c
    回复后处理、心流门控都**不生效**——它自己维护上下文。这是“可独立关闭”的代价；只想借用
    外部 Agent 的能力时用 `ask_external_agent` 工具而非接管。
38. S6e 的文件发送走平台 `File` 消息段（aiocqhttp 把本地路径转成 `file://` 段）。协议端若只实现
    `upload_group_file` 而不认消息段，发送会失败并返回 `error:`，不会静默；图片/语音不走这条路径。
    文件存的是普通目录、不进数据库，也没有配额统计之外的占用上限。
39. S6e 的「文档回复」只生成纯文本 / Markdown（允许名单内的扩展），不做 PDF/Word 转换；
    `download_file` 只接受 http(s)，不处理认证、代理与断点续传，超时按
    `download_timeout_seconds` 整次计算。
40. S6f 的面板数据层是手写 `src/api/life.ts`，没有走 `pnpm generate:api` 的生成 SDK：生成客户端
    对绝对路径会叠加部署前缀，且重新生成需要运行中的 bot 与 `pnpm generate:api`。等下次统一
    重生成时再切换，接口本身没有变化。
41. S6f 的 8 页只做到「列表 + 关键动作」：人物关系值、表情标签、心流/监控的时间范围筛选与
    策略参数可视化还没做，策略参数目前仍走配置 JSON（迁移页可整体读写）。数据迁移页只提供记忆
    导出与配置读写；MaiBot 历史语料的批量导入属于 S7，面板届时接同一入口。
42. S6g 的阈值是手写经验值（回复率 2%–80%、向量覆盖 50%、积压 20、失败率 30%），不是实测基线，
    等 S0 语料到位后要在回放上重新标定；`memory_freshness` 用墙钟时间比较，安静一周的群即使一切
    正常也会告警。面板还没有独立诊断页，只有端点与 CLI，健康卡片留到后续接入。
43. S7a 的影子是**决策级**：影子回合不调用模型，因此没有草稿可与 MaiBot 逐条比对，人格一致性仍
    只能靠 S0 回放集；`life_turn_decision` 有意不存消息与回复原文（只有长度、门控分数、debounce
    等待毫秒），跨重启可复盘两周窗口，但要审阅具体内容仍需平台侧日志。影子回合会把门控状态按
    「已回复」推进（冷却与退避照常生效），这是「如果真回了」的反事实，不等于完全静默下的回复率。
    百分比按群（私聊按会话）
    做稳定哈希，群很少时 1% 可能一个群都覆盖不到，放量前先看 `turns`；改 `rollout_salt` 会整体
    重排，窗口内应保持不变。面板的灰度页还没做，S7a 只有端点与运行手册。
44. S7b 的字段映射绑定 MaiBot 1.4 的库结构（`mai_messages` / `person_info` / `expressions` /
    `jargons` / `images` / `chat_sessions` / `bot_platform_accounts` 与 A_memorix `paragraphs`），
    旧版或自定义导出的记忆仍只能走 `memory_tool.py import`。人物导入后 `relation_score` 从 0
    开始，只带 `know_counts` 作为互动次数——关系值靠上线后的真实聊天累积，不按历史消息数放大。
    A_memorix 记忆先可关键词检索，向量按每轮摘要 40 条补齐，大库要数天才能满覆盖；迁移必须停
    bot，否则并发写入可能落进行号水位区间被回滚误删。面板入口（迁移页接 CLI）留到 S7c。
45. S7c 的面板迁移页只做只读预览：`preview` 默认限 500 条消息，真实导入仍必须用 CLI（长请求会
    占住 HTTP 连接）；回滚按钮虽带确认框，但只适合刚导完、尚未产生大量后续数据的批次，且不会
    回滚配置改动。演练使用固定列的合成 MaiBot 源，验证的是回滚机制与耗时，不是真实数据的字段
    差异；600 秒门限是在数据库副本上测的，生产负载更高时按实测值收紧。值班手册与用户公告是
    runbook 文本，没有接入 pager 或公告机器人；退出清单靠人工勾选并把输出贴进发布单。
    `preview` 以 system scope 读取服务器上的任意路径，权限等同 CLI，不要把 system scope 开给
    非管理员；回滚确认框只是前端提示，真正的保护是鉴权。
46. S7b 的「保真度」边界（审查后明确，不是待办）：`raw_content` 是 msgpack 原件，未解码，因此
    图片 URL、QQ 表情 ID、at 目标都进不了 `life_messages.components`，只重建为 `image`/`at`/
    `reply` 类型标记；`person_info.name_reason`/`first_known_time`、`mai_messages.account_id`/
    `scope`/`group_name`/`additional_config`/`reply_frequency` 等列不迁移。A_memorix 只迁
    `paragraphs`，`entities`/`relations`/`person_identities` 与摘要 checkpoint 不迁，旧图谱丢失，
    记忆退化为「文本 + 关键词/向量」。表情按目标会话各存一份（沿用运行时
    `<session>/<sha256>` 布局），N 个群 = N 份副本。列宽截断（表达变体 >20、表情标签 >8、
    黑话证据 >20、别名 >12、黑话 `term` >64）会计入 `truncated` 而不是静默丢弃；`term` 的
    checksum 改按落库值计算，避免截断后同前缀词出现两行同词不同 checksum。

