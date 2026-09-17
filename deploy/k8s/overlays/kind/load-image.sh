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
WANT_ARCH="${WANT_ARCH:-amd64}"

[ "$#" -gt 0 ] || { echo "用法: sh load-image.sh <image> [image...]" >&2; exit 2; }

for img in "$@"; do
    tmp="$(mktemp -d)"
    docker save "$img" -o "$tmp/src.tar"
    WANT_ARCH="$WANT_ARCH" python3 - "$tmp" <<'PY'
import json, os, sys, tarfile
from pathlib import Path

tmp = Path(sys.argv[1])
want = os.environ.get("WANT_ARCH", "amd64")

with tarfile.open(tmp / "src.tar") as tf:
    tf.extractall(tmp / "root", filter="data")

root = tmp / "root"
index_p = root / "index.json"
index = json.loads(index_p.read_text())

# index.json 通常只有一条，指向镜像的（可能是多平台的）索引
entry = index["manifests"][0]
blob = root / "blobs" / "sha256" / entry["digest"].split(":")[1]
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
    m = keep[0]
    index["manifests"] = [
        {**entry, "mediaType": m["mediaType"], "digest": m["digest"], "size": m["size"]}
    ]
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
