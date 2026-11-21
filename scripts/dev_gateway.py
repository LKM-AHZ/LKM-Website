#!/usr/bin/env python3
"""本地开发网关：按前缀把认证请求转给独立 AUTH 进程。

生产由 APISIX 分流；本地 ``dev.sh`` 没有网关，而客户端只配置一个 LKM 地址，
``/api/v1/auth/*`` 却只存在于 AUTH(:8001)。本脚本在 ``--listen``（默认 8002）
上转发：``/api/v1/auth/*`` → AUTH，其余 → backend。

- 仅供本地开发；不做连接复用。
- ponytail: 不转发 WebSocket 升级，聊天走独立的 Tinode/网关通道；需要时再补。
"""

from __future__ import annotations

import argparse
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_HOP_HEADERS = {
    "host",
    "connection",
    "content-length",
    "transfer-encoding",
    "keep-alive",
}
_AUTH_PREFIX = "/api/v1/auth/"


class _Upstream:
    def __init__(self, host: str, port: int) -> None:
        self.host = host
        self.port = port


_gateway: "_Gateway"


class _Gateway:
    def __init__(self, backend: _Upstream, auth: _Upstream) -> None:
        self.backend = backend
        self.auth = auth

    def target_for(self, path: str) -> _Upstream:
        if path.startswith(_AUTH_PREFIX):
            return self.auth
        return self.backend


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _forward(self) -> None:
        target = _gateway.target_for(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in _HOP_HEADERS
        }
        conn = http.client.HTTPConnection(target.host, target.port, timeout=120)
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            response = conn.getresponse()
            payload = response.read()
            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() not in _HOP_HEADERS:
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
        except OSError as exc:
            self.send_error(502, f"upstream unavailable: {exc}")
        finally:
            conn.close()

    do_GET = _forward
    do_HEAD = _forward
    do_POST = _forward
    do_PUT = _forward
    do_PATCH = _forward
    do_DELETE = _forward
    do_OPTIONS = _forward


def main() -> None:
    global _gateway
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", type=int, default=8002)
    parser.add_argument("--backend-port", type=int, default=8000)
    parser.add_argument("--auth-port", type=int, default=8001)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    _gateway = _Gateway(
        backend=_Upstream(args.host, args.backend_port),
        auth=_Upstream(args.host, args.auth_port),
    )
    server = ThreadingHTTPServer((args.host, args.listen), _Handler)
    server.daemon_threads = True
    print(
        f"[gateway] http://{args.host}:{args.listen} -> "
        f"auth :{args.auth_port} (/api/v1/auth/*), backend :{args.backend_port}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    _self = _Gateway(_Upstream("h", 1), _Upstream("h", 2))
    assert _self.target_for("/api/v1/auth/challenge").port == 2
    assert _self.target_for("/api/v1/admin/auth/me").port == 1
    main()
