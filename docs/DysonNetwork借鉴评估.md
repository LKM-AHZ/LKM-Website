# DysonNetwork 可借鉴点评估

> **文档定位**：评估仓库外项目 DysonNetwork（Solar Network 服务端）中哪些业务建模与协议设计
> 值得 LKM-service 借鉴，哪些应明确不采纳。
> **核对日期**：2026-11-15。代码事实以两侧仓库源码、迁移与部署配置为准；本文是决策记录，
> 不是实施清单，也不替代《社区需求与开发规划》中的优先级与验收口径。

## 1. 结论摘要

DysonNetwork 的工程底座并不比 LKM 强：它没有测试（其 `AGENTS.md` 明写 "No testing"），
当前副本的 `DysonNetwork.Shared` 子模块（NeTo）尚未初始化，部分文档已落后于迁移。
**值得借的是业务建模和客户端协议，不是技术栈和拆分形态。**

最值得关注的四项：

1. **聊天房间的单调序列与断线补洞**——若一期确定做聊天，这是最完整的参考。
2. **题库与试卷分离、激活门槛、可分享 trial**——直接对应路线图“真实赛事 + 赛后题库”。
3. **资源级成员/角色/邀请模型**——补项目协作的权限与加入流程。
4. **Block/Mute 语义及逐面强制规则**——补用户级屏蔽，树洞尤其需要。

其次：标签/专栏/单帖订阅、内容互动增强、链接卡片、发现页反馈、任务与勋章、活动日历。
明确不采纳：ActivityPub 联邦、钱包与支付、直播、NFC/Nearby/Meet、开发者平台，
以及按 DysonNetwork 形态拆微服务或更换消息总线。

**只借设计，不搬代码。** 两边虽同为 AGPLv3，但 C#/EF Core 与 FastAPI/SQLAlchemy 的
类型、事务和缓存语义不同，移植成本高于按现有模块重写。

## 2. 判读前提

| 项 | 事实 | 对结论的影响 |
|---|---|---|
| 项目定位 | Solar Network（solian.app）服务端，.NET 微服务集合 | 业务域比 LKM 宽，需按 LKM 定位裁剪 |
| 许可证 | AGPLv3；LKM-service 亦为 AGPLv3 | 法律上可参考；仍不建议整段移植 |
| 测试 | `AGENTS.md` 写明 "No testing" | 只能当设计参考，不能当正确性基准 |
| 文档 | `docs/` 约 200 篇，但存在滞后 | 引用前必须回查代码/迁移 |
| 共享库 | `DysonNetwork.Shared` 子模块当前为空 | 本地无法编译，不能作为运行环境 |
| 部署 | 官方声明不自托管，品牌与外部服务硬编码 | 不适合作为部署方案参考 |

已知文档滞后示例：`docs/POST_SUBSCRIPTIONS.md` 仍描述帖子订阅，但迁移
`20260927043440_ReplacePostSubscriptionsWithWatchPreferences` 已把帖子订阅改为
watch preferences；判断现状应看 `DysonNetwork.Sphere/Post/PostWatch.cs`、
`PostWatchController.cs` 和迁移，而不是旧文档。

## 3. 对照基线

LKM-service 当前已有且无需重复建设：模块化单体 + 独立 AUTH、事务发件箱 + 幂等消费 + DLQ、
双级缓存、只读 GraphQL、通知偏好与推送 token、积分/成就/任务进度、文件库、搜索三引擎、
RBAC0-3。详见 [后端架构与现状](./后端架构与现状.md)。

现状缺口以 [社区需求与开发规划](./社区需求与开发规划.md) 为准：项目协作、竞赛题库、
聊天室、标签订阅、推荐排序是主要方向。本文只补“可借鉴的具体做法”。

## 4. 优先级清单

| 优先级 | DysonNetwork 参考 | LKM 落点 | 借鉴内容 |
|---|---|---|---|
| P0 | `Messager/Chat/`、`docs/CHAT_ROOM_SEQUENCE_SYNC.md` | `app/ws/`；聊天若立项则新建模块 | 房间内单调序列、补洞同步、未读/已读、成员治理 |
| P0 | `Passport/Examination/` | `app/modules/exam/` | 题库分组、题型/判分模式、激活门槛、可分享 trial、人工阅卷 |
| P0 | `Sphere/Publisher/`、`Passport/Realm/` | `app/modules/projects/` | 资源级成员/角色/邀请、加入申请状态机 |
| P1 | `docs/BLOCK_SYSTEM.md` | `app/modules/interaction/`、树洞 | block 双向、mute 单向及逐面强制规则 |
| P1 | `PostWatchController`、category/tag/collection 订阅 | interaction + notification | 统一订阅目标、互动后自动 watch 单帖 |
| P1 | `Sphere/Post/PostActionController.cs` 等 | content/comment | 表情反应、置顶/精选回复、编辑历史、合集前后篇 |
| P1 | `Sphere/Reader/` 与各类 Embed | content 渲染 | 外链标题/摘要/封面解析（需 SSRF 防护） |
| P2 | `Timeline/TimelineDiscoveryController.cs` | `app/modules/feed/` | 不感兴趣反馈、兴趣权重、发现画像 |
| P2 | `Passport/Progression/`、日历/签到/Rewind | points、活动运营 | quest 式任务、勋章 manifest、手动 grant、年度回顾 |
| P2 | 事件日历/纪念日/倒计时 | 竞赛与活动 | 报名截止、倒计时、订阅他人日历 |
| 不采纳 | ActivityPub、Wallet、Live、NFC/Nearby/Meet、Develop | — | 与当前定位不匹配或成本过高 |

## 5. 重点借鉴项

### 5.1 聊天：借可恢复序列，不借 MLS

LKM 已有 WebSocket 与 Redis 定向推送，缺的是持久化、排序与断线恢复语义。
DysonNetwork Messager 的关键设计：

- 每个房间用 `chat_room_counters.last_sequence` 原子分配 `room_sequence`；同房间严格递增，
  仅用于房间内排序和缺口检测，不承担跨房间顺序。
- WS 只负责实时投递（`messages.new/update/delete`、`messages.reaction.added/removed`），
  客户端发现序号缺口后调用 `POST /chat/rooms/sync` 补拉；文档另定义全局同步模型。
- 房间能力包括成员角色、邀请、成员 timeout/禁言、退出、在线成员、通知开关；消息能力包括
  反应、置顶、搜索、已读标记、未读汇总、语音、占位消息与转发消息。
- 端到端加密（MLS）是独立体系，与基础聊天解耦。

对 LKM 的建议：

- 新增 `chat_rooms`、`chat_room_members`、`chat_messages`、`chat_room_counters` 四张核心表；
  复用现有 outbox 保证消息事件不丢，复用 `core/bus` 做跨进程推送。
- 首期只做文本消息、成员权限、撤回、举报、未读/已读、断线补洞；**不要做 MLS/E2EE**。
- 无论一期是否做聊天，都应把 `app/ws/` 的包类型、序号、重连与补拉规则写成协议文档，
  供桌面端和 Bot 端共同遵守；现有运行期 OpenAPI 覆盖不到 WS。

验收建议：消息只对有权限成员可见；重连后不丢已提交消息；序号缺口可被客户端检测并补拉；
被禁言/移除成员无法继续发送。

### 5.2 题库：练习与考试分层

LKM 当前 `exam_questions` 直接挂在试卷上，缺少可复用题库。DysonNetwork Examination 的做法：

- 题目归属 `QuestionGroup`，题型为单选/多选/自由文本，判分分自动/人工，带难度、分值、
  排序与 `Config` 扩展位。
- 试卷/测试可被分享为 trial；作答状态包含进行中、待人工阅卷、通过、失败、过期。
- 公开测试有列表与访问限制；激活状态可要求已验证联系方式等门槛。
- 后台按题库组维护题目并可导出，前台只暴露参与者可见的题目快照。

对 LKM 的建议：在现有 `exams / exam_questions / exam_attempts` 基础上补
`question_groups`、题目判分模式、`PendingReview` 状态与错题记录；赛后由管理员确认后把赛题
发布到练习题库。不要重写整条考试链路。

验收建议：真实赛事的报名/答题/提交/结果全链路可用；未审核题目不会进入练习库；
人工阅卷可追溯；断线续答与争议题处理有明确规则。

### 5.3 项目协作：资源级角色而非 Publisher 实体

DysonNetwork Publisher 是作者/机构实体，成员角色为 Owner/Manager/Editor/Viewer，
邀请、角色变更、成员移除都围绕它完成。LKM 已有专栏与板块，**不需要再引入 Publisher**，
但项目模块缺的正是这套：

- `project_members(role)` 四级角色，所有写操作按“角色 ≥ 某级”判定。
- 邀请、接受、拒绝、移除成员形成独立流程，走通知与审计。
- 加入项目申请与“孵化申请”分离，申请关联项目、申请人、审核状态。

可以顺带借鉴 Realm 的“成员身份/标签”展示，但不要复制 boost、NFC、Meet 等无关能力。

验收建议：发起人可更新招募、进度与报告且历史可追溯；用户可申请加入具体项目并查询结果；
无权限用户不能修改项目或处理申请。

### 5.4 Block/Mute：语义清晰、逐面强制

`docs/BLOCK_SYSTEM.md` 定义了两种用户关系：

- Block（`-100`）：双向，双方不可见、不可互动。
- Mute（`-50`）：单向，仅屏蔽方看不到对方，对方不受影响。

文档逐面列明对帖子互动、信息流、搜索/自动补全、通知、@提及、私信、关注请求的影响。
LKM 目前只有举报、审核与板块禁言，缺用户级屏蔽；树洞匿名对话尤其需要。

对 LKM 的建议：落在 `app/modules/interaction/`，与现有关系表同域；过滤点至少覆盖 feed、
搜索、通知、@提及、树洞会话与聊天（若上线）。语义按“block 双向、mute 单向”实现，
避免各模块各自解释。

验收建议：被 block 用户不出现在对方 feed/搜索/通知中；双向互动被拒绝；mute 不影响对方；
树洞私密会话无法因屏蔽失效而泄露。

### 5.5 订阅与 watch：统一目标，避免重复建表

DysonNetwork 当前有两类路径：

- category/tag/collection 订阅：新帖匹配订阅目标时通知。
- 单帖 watch：用户对帖子产生收藏、反应、回复后自动关注该帖，后续反应/回复/编辑时通知。

LKM 已有 `board_follows`、收藏与通知偏好，建议将其统一为
`content_subscriptions(target_type, target_id)`（板块/标签/专栏等），发帖时由 fanout 按订阅
生产通知；单帖 watch 可映射到现有 interaction 域。注意 DysonNetwork 的相关文档已过时，
实现以 `PostWatch.cs` 与迁移为准。

验收建议：订阅目标新增内容只通知订阅者；用户关闭某类通知后不再收到；取消订阅立即生效；
板块关注与标签订阅的行为一致。

### 5.6 内容互动与链接卡片

可低成本借鉴：表情反应、置顶回复、精选回复、编辑历史、合集内前后篇导航。
LKM 已有赞/藏/评论，缺少“多表情反应”和“作者置顶/精选”，这两项对问答与悬赏场景价值较高。

链接卡片参考 `Sphere/Reader/` 与 `LocationEmbed`/`MeetEmbed`/`SurveyEmbed` 的做法：
服务端抓取外链标题、摘要与封面并缓存。实现时必须做 URL 白名单、重定向链校验、超时与
内容大小限制，避免 SSRF 和内网探测。

### 5.7 推荐反馈与发现页

信息流从关注流走向推荐时，可参考 `TimelineDiscoveryController` 的反馈模型：

- “不感兴趣”记录、兴趣权重调整、发现画像查询与重置。
- 基于标签/板块/作者兴趣生成推荐，并保留反馈入口。

LKM 的 `app/modules/feed/` 已有物化时间线与 fanout，建议在 P2 推荐排序启动时再引入，
不要在关注流阶段提前建设。

### 5.8 参与度与运营

DysonNetwork 的 Progression 把成就、任务、grant 分开，并提供勋章 manifest 给客户端；
另有签到、纪念日、日历与年度回顾。LKM 已有积分规则引擎、成就与任务进度，**不要重建**，
只需按需补：

- 任务式 quest（周期目标、进度、奖励）在现有 `task_definitions` 上扩展。
- 勋章 manifest 端点，供桌面端统一渲染与展示当前佩戴勋章。
- 运营手动 grant，用于补偿、活动奖励与申诉处理。
- 竞赛日历、倒计时与年度回顾属于运营增强，等赛事和社区数据稳定后再做。

## 6. 工程细节

| 做法 | DysonNetwork 证据 | LKM 可借鉴点 |
|---|---|---|
| 统一配额响应 | `ResourceQuotaResponse<T>` 在 Realm/Publisher/Develop 共用 | 文件上传、项目数、专栏数等限额统一结构 |
| 资源级功能开关 | `/publishers/{name}/features` 返回功能布尔表 | 在 `manifest.toml` 的模块级开关外，增加板块/专栏级灰度 |
| 协议文档 | chat 文档完整描述包类型、序列、补洞与回填 | 为 LKM WS/事件协议补稳定契约文档 |
| 订阅通知分层 | 目标订阅 + 单帖 watch + 通知偏好 | 复用 `notification_preferences`，不要新建通知体系 |

## 7. 不建议借鉴

| 项 | 原因 |
|---|---|
| ActivityPub/WebFinger/NodeInfo 联邦 | 与 LKM 封闭社区/教育定位不符，协议与审核成本极高 |
| 钱包、订单、订阅计费、商户结算 | LKM 用积分经济与悬赏托管即可；真实支付涉及合规与对账 |
| 直播推流、HLS、打赏 | 当前无直播场景，基础设施成本高 |
| NFC、Nearby、Meet、Apple Wallet 会员卡 | 线下场景，与产品方向无关 |
| 开发者平台、Mini App、应用商品与分成 | LKM-bot 已有插件生态，避免再造第二套平台 |
| 按 DysonNetwork 拆微服务、引入 gRPC/NATS | LKM 的模块化单体与 Pulsar/RabbitMQ 是既有决策，架构文档已明确不采纳 gRPC |

## 8. 落地顺序

1. **题库化 + 项目协作**：都对应路线图 P0，改动局限在 `exam` 与 `projects` 模块。
2. **Block/Mute**：先于树洞隐私验收，属于安全底线。
3. **标签/专栏订阅 + 单帖 watch**：复用 interaction 与 notification，成本低。
4. **聊天**：若一期批准再做，按房间序列 + 补洞同步设计；否则只补 WS 协议文档。
5. **反应/置顶/链接卡片/发现反馈**：内容体验与推荐，按 P1/P2 推进。
6. **签到/日历/年度回顾/quest**：运营向，等赛事与社区数据稳定后实施。

每一步以《社区需求与开发规划》对应章节的验收口径为准，不以“已借鉴”替代“已验收”。

## 9. 来源索引

DysonNetwork：

- 聊天：`DysonNetwork/DysonNetwork.Messager/Chat/`、`DysonNetwork/docs/CHAT_ROOM_SEQUENCE_SYNC.md`、
  `CHAT_GLOBAL_SYNC.md`、`CHAT_GROUPS.md`
- 考试：`DysonNetwork/DysonNetwork.Passport/Examination/`（题型与判分见 `SnTest.cs`）
- 发布者角色：`DysonNetwork/DysonNetwork.Sphere/Publisher/`（角色映射见 `PublisherServiceGrpc.cs`）
- 社区角色：`DysonNetwork/DysonNetwork.Passport/Realm/`
- 屏蔽：`DysonNetwork/docs/BLOCK_SYSTEM.md`
- 订阅/watch：`DysonNetwork/DysonNetwork.Sphere/Post/PostWatch.cs`、
  `PostWatchController.cs`、`DysonNetwork/docs/POST_SUBSCRIPTIONS.md`（注意滞后）
- 发现：`DysonNetwork/DysonNetwork.Sphere/Timeline/TimelineDiscoveryController.cs`
- 阅读器：`DysonNetwork/DysonNetwork.Sphere/Reader/`
- 参与度：`DysonNetwork/DysonNetwork.Passport/Progression/`
- 工程约定：`DysonNetwork/AGENTS.md`

LKM：

- 现状与边界：[后端架构与现状](./后端架构与现状.md)
- 需求与验收：[社区需求与开发规划](./社区需求与开发规划.md)
- 认证与用户：`LKM-service/auth/`
- 业务模块：`LKM-service/app/modules/{exam,projects,interaction,notification,feed,points}/`
- 实时推送：`LKM-service/app/ws/`
- 内容与评论：`LKM-service/app/modules/{content,comment}/`
