#!/bin/sh
# 把宿主机 docker 里的镜像注入 kind 节点（按平台裁剪 OCI 索引）。
#
#   sh load-image.sh lkm-service:latest [更多镜像...]
#
# 为什么不用 `kind load docker-image`：宿主机 docker 若启用 containerd 镜像存储
# （Storage Driver: overlayfs / io.containerd.snapshotter），`docker save` 会导出一个
# OCI 索引，里面列着**全部平台**（amd64/arm/386/ppc64le/…）外加 attestation 清单，而本机
# 实际只有当前平台的 blob。kind 的导入固定带 `--all-platforms` → 遍历索引时撞上缺失的
# blob，报 `content digest sha256:...: not found` 直接失败（多平台的 pulsar 必踩）。
# 去掉 `--all-platforms` 也不行：ctr 仍会按索引逐个解析。
# 故：先把索引裁成只剩本平台，再 `ctr images import`。
set -eu

NODE="${NODE:-lkm-control-plane}"

# 默认按宿主机架构裁剪：写死 amd64 在 arm64 机器上会去裁一个本机根本没有的平台，
# 报错只剩一句「索引里找不到 amd64/linux 平台」，很难定位
case "$(uname -m)" in
    x86_64|amd64)  _host_arch=amd64 ;;
    aarch64|arm64) _host_arch=arm64 ;;
    armv7l|armhf)  _host_arch=arm ;;
    *)             _host_arch="$(uname -m)" ;;
esac
WANT_ARCH="${WANT_ARCH:-$_host_arch}"

[ "$#" -gt 0 ] || { echo "用法: sh load-image.sh <image> [image...]" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "需要 docker" >&2; exit 1; }

for img in "$@"; do
    # 早失败：镜像不在宿主机时，docker save 的报错不如这一句直观
    docker image inspect "$img" >/dev/null 2>&1 || {
        echo "宿主机没有镜像 $img（先 docker pull / docker compose build）" >&2
        exit 1
    }
    tmp="$(mktemp -d)"
    # docker save / 内联 python / ctr import 任一失败都会被 set -eu 直接中止整个脚本，
    # 没有 trap 的话解包出来的数百 MB blob 就留在 $TMPDIR 里了
    trap 'rm -rf "$tmp"' EXIT INT TERM
    docker save "$img" -o "$tmp/src.tar"
    WANT_ARCH="$WANT_ARCH" python3 - "$tmp" <<'PY'
import json, os, sys, tarfile
from pathlib import Path

tmp = Path(sys.argv[1])
want = os.environ.get("WANT_ARCH", "amd64")

def blob_path(root, digest):
    # digest 形如 sha256:<hex>；算法写死 sha256 会在别的布局上取错路径，
    # 而 split(":")[1] 遇到没有前缀的摘要是 IndexError（只剩一句看不懂的 traceback）
    algo, sep, hexdigest = digest.partition(":")
    if not sep or algo not in ("sha256", "sha512") or not hexdigest:
        sys.exit(f"不支持的镜像摘要：{digest!r}（只处理 sha256:/sha512: 前缀）")
    return root / "blobs" / algo / hexdigest


def extract_all(tf, dest):
    # filter="data" 要 3.12（及 3.8.17/3.9.17/3.10.12/3.11.4 起的回移版本），老解释器会
    # TypeError。回退到显式成员校验，保留「成员不得逃出目标目录」这条约束。
    try:
        tf.extractall(dest, filter="data")
        return
    except TypeError:
        pass
    root = dest.resolve()
    members = tf.getmembers()
    for m in members:
        if m.issym() or m.islnk():
            sys.exit(f"tar 内含链接成员，拒绝解包: {m.name}")
        target = (root / m.name).resolve()
        if target != root and root not in target.parents:
            sys.exit(f"tar 成员逃逸出目标目录: {m.name}")
    tf.extractall(root, members=members)


with tarfile.open(tmp / "src.tar") as tf:
    extract_all(tf, tmp / "root")

root = tmp / "root"
index_p = root / "index.json"
index = json.loads(index_p.read_text())

# index.json 通常只有一条，指向镜像的（可能是多平台的）索引
entry = index["manifests"][0]
blob = blob_path(root, entry["digest"])
target = json.loads(blob.read_text())

if "manifests" in target:
    keep = [
        m
        for m in target["manifests"]
        if m.get("platform", {}).get("architecture") == want
        and m.get("platform", {}).get("os") == "linux"
        and m.get("annotations", {}).get("vnd.docker.reference.type") != "attestation-manifest"
    ]
    if not keep:
        sys.exit(f"索引里找不到 {want}/linux 平台")
    # 同一架构可能带多个变体（arm64/v8 vs v9、arm/v6 vs v7）：优先取没有变体的基准项，
    # 并在真有多个变体时把选择打到 stderr——静默取第一个可能选到本机 blob 缺失的那个
    variants = {m.get("platform", {}).get("variant") for m in keep}
    if len(variants) > 1:
        print(
            f"warn: {want} 有多个变体 {sorted(v for v in variants if v)}，取基准项",
            file=sys.stderr,
        )
    m = next((x for x in keep if not x.get("platform", {}).get("variant")), keep[0])
    # 只保留必要字段：原样展开 entry 会把过期的 platform/annotations 一并带上，
    # 与新指向的 manifest 不一致；annotations 里只留 ctr 认的镜像引用名
    manifest = {"mediaType": m["mediaType"], "digest": m["digest"], "size": m["size"]}
    ref_name = (entry.get("annotations") or {}).get("org.opencontainers.image.ref.name")
    if ref_name:
        manifest["annotations"] = {"org.opencontainers.image.ref.name": ref_name}
    index["manifests"] = [manifest]
    index_p.write_text(json.dumps(index))

# 重新打包（保持 OCI 布局）
with tarfile.open(tmp / "out.tar", "w") as tf:
    for name in ("blobs", "index.json", "oci-layout", "manifest.json"):
        p = root / name
        if p.exists():
            tf.add(p, arcname=name)
PY
    docker exec -i "$NODE" ctr --namespace=k8s.io images import \
        --digests --snapshotter=overlayfs - < "$tmp/out.tar" >/dev/null
    rm -rf "$tmp"
    echo "   loaded $img"
done
