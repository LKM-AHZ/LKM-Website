-- LKM 社区 · ClickHouse 分析库初始化（M5 7.2.6）
--
-- 由 clickhouse-server 镜像的 /docker-entrypoint-initdb.d 机制在**数据卷首次初始化**时执行
-- （compose `clickhouse` 服务挂载本文件只读）。已有数据卷不会重跑——改表结构请手动 ALTER。
--
-- 三张表：
--   app_logs       —— 路 B：vector 采集的容器 stdout/stderr 结构化 JSON（core/logging.py 格式）
--   event_failures —— 路 A：outbox relay 耗尽重试折叠的失败事件（周期增量导出）
--   audit_logs     —— 路 A：auth 行为审计（周期增量导出）
--
-- 幂等/去重：两张导出表用 ReplacingMergeTree(ingested_at) + ORDER BY id，配合应用侧
-- 「CH 侧 max(id) 水位」双保险——重跑导出不产生重复行。日志表由 vector 直接写入，无水位。
-- ⚠ 去重三处边界（读这份数据的人请知情）：
--   ① 只在**后台 merge** 时发生：直接 SELECT（BI/临时排查）要自带 FINAL，否则可能看到
--      极小窗口的重复 id（应用侧 /admin/analytics 是知情取舍，见
--      app/modules/admin/analytics_router.py 开头注释）；
--   ② 去重按**分区**独立进行：同一 id 两次导出的 folded_at/created_at 若跨月落进不同分区，
--      两份都会留下；
--   ③ 版本列 ingested_at 用 now64(3)，同毫秒内重导会并列、保留哪行不确定（正常
--      「导出一次 + 水位不重导」下不会触发）。
--
-- 主键口径（UUID 改造后）：PG 侧 AuditLog.id / EventFailure.id 与 users.id 均为 uuid7，
-- 导出到 CH 一律存**字符串形式**（列类型 String / Nullable(String)）。uuid7 前 48 位是
-- 毫秒时间戳，其字符串字典序 == 时间序 == 原自增整数顺序，故既有 ORDER BY id 与
-- 「SELECT max(id) 水位」的增量语义不变（CH 的 String 支持 max()）。
--
-- 注意：本文件只在**数据卷首次初始化**时执行，已有数据卷不会重跑。上面的整型→String
-- 属破坏性表结构变更：需重建 CH 数据卷（`docker compose --profile clickhouse down -v`
-- 后重起），或手动 ALTER ... MODIFY COLUMN 迁移。
--
-- TTL 锚在**事件时间**（app_logs.ts / event_failures.folded_at / audit_logs.created_at），与各自
-- 的分区键同源——口径是「保留最近 N 天的事件」而不是「导入后再留 N 天」。故补录/迟到导入的
-- 旧事件会直接落进过期窗口（下一次 merge 即清），这是刻意选择而非疏漏。
-- （TTL 里的 toDateTime() 把 DateTime64 降到秒精度：ClickHouse 不接受 DateTime64 直接作 TTL
--  表达式，对 30/180/365 天量级的保留期没有实际影响。）
-- TTL 为固定默认值（30/180/365 天）；如需按环境调整，改本文件后重建数据卷
-- （`docker compose --profile clickhouse down -v` 后重起）。

CREATE DATABASE IF NOT EXISTS lkm;

-- ── 路 B：应用日志（vector → CH）──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS lkm.app_logs
(
    -- 显式钉 UTC：vector 写进来的是「无时区后缀的 UTC 字符串」，若哪天有人给 CH 容器加了 TZ
    -- （例如照抄 lkmbot 的 TZ: Asia/Shanghai），无后缀串会按服务器时区解释 —— 全表偏 8 小时，
    -- 而分区键/TTL/ORDER BY 全建立在这列上。DateTime64 带 tz 参数即按该时区解释无后缀串。
    ts           DateTime64(3, 'UTC'),
    level        LowCardinality(String),
    logger       LowCardinality(String),
    msg          String,
    request_id   String,
    trace_id     String,
    span_id      String,
    extra_fields String,
    exc_info     String,
    service      LowCardinality(String),
    ingested_at  DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (service, ts)
-- TTL 表达式须返回 DateTime/Date（ClickHouse 不接受 DateTime64 直接作 TTL 表达式，报
-- BAD_TTL_EXPRESSION 并使整个 init.sql 中止），故用 toDateTime(ts) 降到秒精度。
TTL toDateTime(ts) + INTERVAL 30 DAY;

-- ── 路 A：outbox 失败事件（周期增量导出）──────────────────────────────────────

CREATE TABLE IF NOT EXISTS lkm.event_failures
(
    -- PG event_failures.id（uuid7）的字符串形式；字典序即时间序，水位取 max(id)。
    -- 由 UInt64 改为 String 是破坏性变更：已有数据卷需重建
    -- （docker compose --profile clickhouse down -v）或手动 MODIFY COLUMN，见文件头。
    id            String,
    event_id      String,
    routing_key   LowCardinality(String),
    payload_json  String,
    attempt_count UInt32,
    reason        String,
    -- 时间列一律钉 UTC（理由见 app_logs.ts 处注释）——导出侧写的是无后缀 UTC 串
    folded_at     DateTime64(3, 'UTC'),
    ingested_at   DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(ingested_at)
PARTITION BY toYYYYMM(folded_at)
ORDER BY id
TTL toDateTime(folded_at) + INTERVAL 180 DAY;

-- ── 路 A：auth 行为审计（周期增量导出）───────────────────────────────────────

CREATE TABLE IF NOT EXISTS lkm.audit_logs
(
    -- PG audit_logs.id（uuid7）的字符串形式；字典序即时间序，水位取 max(id)。
    id          String,
    -- PG users.id（uuid7）的字符串形式；审计行可无关联用户（SET NULL），故可空。
    -- 两列由整数改为 String 是破坏性变更：已有数据卷需重建
    -- （docker compose --profile clickhouse down -v）或手动 MODIFY COLUMN，见文件头。
    user_id     Nullable(String),
    action      String,
    detail      String,
    ip_address  String,
    -- 时间列一律钉 UTC（理由见 app_logs.ts 处注释）
    created_at  DateTime64(3, 'UTC'),
    ingested_at DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(ingested_at)
PARTITION BY toYYYYMM(created_at)
ORDER BY id
TTL toDateTime(created_at) + INTERVAL 365 DAY;
