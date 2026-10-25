# LKM 告警投递配置**模板**——把 deploy/prometheus/rules 算出来的告警真正送到人手上。
#
# 谁渲染它：deploy/alertmanager/render.sh 把 __ALERT_RECEIVER_BODY__ 展开成实值，写进
# rendered/alertmanager.yml，再由 alertmanager 服务只读挂载（compose 用一次性的
# alertmanager-render 容器，k8s 用 initContainer，两边跑的是**同一份** render.sh）。
#
# 为什么必须渲染、而不是静态提交一份：
#   1. 接收地址就是凭证（webhook URL 泄露即可被灌垃圾/伪造告警），不能进 git；
#   2. Alertmanager 自己不支持环境变量展开（只吃 --config.file），没有 env 注入这条路。
# 故沿用 deploy/apisix/render.sh 同一套「模板 + 运行时展开」做法，不引入第二套机制。
#
# 已知边界：Alertmanager **不自动重载**配置。改 LKM_ALERT_WEBHOOK_URL 后需
# `docker compose restart alertmanager`（k8s 侧改 Secret 后 rollout restart）。
# 见 DEPLOYMENT.md「告警投递」。
global:
  # firing → resolved 至少隔这么久才认 resolved：压掉阈值边缘抖动造成的「响了又好了」。
  resolve_timeout: 5m

route:
  # 兜底接收器：未匹配下面任何子路由的告警（= 绝大多数 warning）走这里。
  receiver: lkm-alerts
  # 按「告警名 + 级别」聚组：一次池打满常同时触发多条同类告警，聚组成一条通知。
  group_by: ['alertname', 'severity']
  # 首次通知前先攒 30s，把同一根因的并发触发并成一条。
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    # critical 单独提速：漏一条 critical 的代价远高于多重几条通知，故不攒、且 1h 复读。
    - matchers:
        - severity="critical"
      receiver: lkm-alerts
      group_wait: 10s
      repeat_interval: 1h
    # info 降噪：不需要 4 小时复读一次，24h 提醒一次足够。
    - matchers:
        - severity="info"
      receiver: lkm-alerts
      repeat_interval: 24h

# 抑制规则：只压「同一根因的派生噪声」，绝不压根因本身。
# 新增抑制前请先读对应规则的 expr——把真告警压掉比多收几条更糟。
inhibit_rules:
  # 连接池已耗尽时，同一 pool 的「占用率 > 80%」没有增量信息（它是前者的低级别前兆）。
  # 用 equal: ['pool'] 限定同池：web 池耗尽不应压住 worker 池的占用率告警。
  - source_matchers:
      - alertname="DBPoolExhausted"
    target_matchers:
      - alertname="DBPoolSaturationHigh"
    equal: ['pool']

receivers:
  - name: lkm-alerts
__ALERT_RECEIVER_BODY__
