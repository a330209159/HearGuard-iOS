#!/usr/bin/env python3
"""
HearGuard 本地纯音测听服务启动脚本
支持电脑端浏览器直接访问，也支持同一 Wi-Fi 下手机戴耳机打开测试。
所有数据 100% 保存在浏览器本地 LocalStorage，不上传任何外部服务器。
"""

import http.server
import os
import socket
import socketserver
import sys
import webbrowser


def get_lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def find_free_port(preferred=8125):
    for port in [preferred, 8126, 8127, 8080, 0]:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("0.0.0.0", port))
                return s.getsockname()[1]
            except OSError:
                continue
    return 8125


class QuietThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(base_dir)

    no_open = "--no-browser" in sys.argv
    port = find_free_port(8125)
    lan_ip = get_lan_ip()
    local_url = f"http://127.0.0.1:{port}"
    lan_url = f"http://{lan_ip}:{port}"

    handler = http.server.SimpleHTTPRequestHandler
    handler.extensions_map.update({
        ".js": "application/javascript; charset=utf-8",
        ".css": "text/css; charset=utf-8",
        ".json": "application/json; charset=utf-8",
        ".html": "text/html; charset=utf-8",
    })

    print("=" * 68)
    print("  HearGuard · 突发性耳聋纯音测听与双耳听力曲线工作台 (125Hz → 8000Hz)")
    print("=" * 68)
    print(f"  ▶ 本机电脑浏览器访问 : {local_url}")
    print(f"  ▶ 同 Wi-Fi 手机访问  : {lan_url}")
    print("  ▶ 按 Ctrl + C 可随时关闭本地服务")
    print("=" * 68)

    if not no_open:
        webbrowser.open(local_url)

    with QuietThreadingHTTPServer(("0.0.0.0", port), handler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n已安全停止本地测听服务。")


if __name__ == "__main__":
    main()
