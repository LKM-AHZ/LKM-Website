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
--
-- TTL 为固定默认值（30/180/365 天）；如需按环境调整，改本文件后重建数据卷
-- （`docker compose --profile clickhouse down -v` 后重起）。

CREATE DATABASE IF NOT EXISTS lkm;

-- ── 路 B：应用日志（vector → CH）──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS lkm.app_logs
(
    ts           DateTime64(3),
    level        LowCardinality(String),
    logger       LowCardinality(String),
    msg          String,
    request_id   String,
    trace_id     String,
    span_id      String,
    extra_fields String,
    exc_info     String,
    service      LowCardinality(String),
    ingested_at  DateTime64(3) DEFAULT now64(3)
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
    id            UInt64,
    event_id      String,
    routing_key   LowCardinality(String),
    payload_json  String,
    attempt_count UInt32,
    reason        String,
    folded_at     DateTime64(3),
    ingested_at   DateTime64(3) DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(ingested_at)
PARTITION BY toYYYYMM(folded_at)
ORDER BY id
TTL toDateTime(folded_at) + INTERVAL 180 DAY;

-- ── 路 A：auth 行为审计（周期增量导出）───────────────────────────────────────

CREATE TABLE IF NOT EXISTS lkm.audit_logs
(
    id          UInt64,
    user_id     Nullable(Int64),
    action      String,
    detail      String,
    ip_address  String,
    created_at  DateTime64(3),
    ingested_at DateTime64(3) DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(ingested_at)
PARTITION BY toYYYYMM(created_at)
ORDER BY id
TTL toDateTime(created_at) + INTERVAL 365 DAY;
