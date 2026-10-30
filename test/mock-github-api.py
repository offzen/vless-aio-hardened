#!/usr/bin/env python3
"""离线单测用的 GitHub Releases mock API（只实现 sync-release.sh 用到的那几个路由）。

用法：python3 mock-github-api.py <port|0>
     stdout 第一行打印实际监听端口，之后常驻。

控制接口（不属于 GitHub API，仅本 mock 提供）：
    POST /__reset   body: {"releases": [...], "latest_override": "vX"}  重置内存状态
    GET  /__requests                            返回已收到的请求列表（校验 POST 载荷用）
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"releases": [], "requests": [], "latest_override": ""}
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # 静音
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        with LOCK:
            STATE["requests"].append({"method": "GET", "path": self.path})
            if path == "/__requests":
                return self._send(200, STATE["requests"])
            if path.startswith("/repos/"):
                if path.endswith("/releases"):
                    return self._send(200, STATE["releases"])
                if "/releases/tags/" in path:
                    tag = path.rsplit("/", 1)[1]
                    for rel in STATE["releases"]:
                        if rel.get("tag_name") == tag:
                            return self._send(200, rel)
                    return self._send(404, {"message": "Not Found"})
                if path.endswith("/releases/latest"):
                    if STATE.get("latest_override"):
                        return self._send(200, {"tag_name": STATE["latest_override"]})
                    if not STATE["releases"]:
                        return self._send(404, {"message": "Not Found"})
                    # 与 GitHub 一致：非 draft / 非 prerelease 中 created_at 最新的那个
                    cands = [r for r in STATE["releases"]
                             if not r.get("draft") and not r.get("prerelease")]
                    if not cands:
                        return self._send(404, {"message": "Not Found"})
                    return self._send(200, cands[-1])
        return self._send(404, {"message": "Not Found"})

    def do_POST(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            data = {}
        with LOCK:
            if path == "/__reset":
                STATE["releases"] = data.get("releases", [])
                STATE["latest_override"] = data.get("latest_override", "")
                STATE["requests"] = []
                return self._send(200, {"ok": True})
            STATE["requests"].append({"method": "POST", "path": self.path, "body": data})
            if path.startswith("/repos/") and path.endswith("/releases"):
                tag = data.get("tag_name")
                if any(r.get("tag_name") == tag for r in STATE["releases"]):
                    return self._send(422, {"message": "Validation Failed: already_exists"})
                rel = {
                    "tag_name": tag,
                    "name": data.get("name"),
                    "draft": bool(data.get("draft")),
                    "prerelease": bool(data.get("prerelease")),
                    "target_commitish": data.get("target_commitish"),
                    "body": data.get("body", ""),
                }
                STATE["releases"].append(rel)
                return self._send(201, rel)
        return self._send(404, {"message": "Not Found"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(srv.server_address[1], flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
