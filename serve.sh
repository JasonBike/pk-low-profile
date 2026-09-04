#!/usr/bin/env bash
# 本地起静态服务托管 PK 撮合可视化页面，并同源代理固定 BOSS 地址以规避浏览器 CORS。
# 绑 0.0.0.0,同网段同事用你的内网 IP 即可访问(= 分享 index)。
#
# 用法:
#   ./serve.sh            # 默认端口 8765
#   ./serve.sh 9000       # 指定端口
#
# 分享步骤:把要给别人看的 dump json 放进 ./dumps/,
# 然后把脚本打印的 http://<内网IP>:<端口>/?dump=<文件名> 发出去即可。

set -euo pipefail

PORT="${1:-8765}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$ROOT"

if ! command -v python3 >/dev/null 2>&1; then
  echo "需要 python3,未找到。请先安装 python3。" >&2
  exit 1
fi

# 取本机内网 IP。不写死 en0:Wi-Fi 是 en0,有线/雷雳网卡可能是 en5 等,
# 所以遍历活跃网卡取第一个非回环 IPv4。
IP=""
for dev in $(ifconfig -l 2>/dev/null); do
  case "$dev" in lo*|utun*|awdl*|llw*|bridge*|gif*|stf*) continue ;; esac
  candidate="$(ipconfig getifaddr "$dev" 2>/dev/null || true)"
  if [ -n "$candidate" ]; then IP="$candidate"; break; fi
done
if [ -z "$IP" ]; then
  IP="$(ifconfig 2>/dev/null | awk '/inet /{if($2!="127.0.0.1"){print $2; exit}}')"
fi
[ -z "$IP" ] && IP="127.0.0.1"

count=0
if [ -d dumps ]; then
  for f in dumps/*.json; do
    [ -e "$f" ] || continue
    count=$((count + 1))
  done
fi

echo "PK 撮合可视化 静态服务已启动"
echo "  项目根 : $ROOT"
echo "  本机   : http://127.0.0.1:${PORT}/"
echo "  分享   : http://${IP}:${PORT}/"
echo "  BOSS   : /boss/* -> https://boss.hdslb.com/*"
echo "  dumps  : ./dumps/ 下 ${count} 个 json,访客打开上面链接即可在页面里直接选"
if [ "$count" -eq 0 ]; then
  echo "  提示   : dumps/ 是空的,把要分享的 json 放进去再刷新页面。"
fi
echo "  Ctrl-C 停止"
echo

# 绑 0.0.0.0 让内网可访问。
# python -m http.server 会发 Last-Modified 且支持 304,改了 index.html 或 dump 后
# 浏览器常规刷新可能仍然吃旧缓存(之前这里注释写着 no-cache,其实并没有生效)。
# 所以套一层 handler:强制 no-store,并丢掉条件请求头让 304 不再发生。
exec python3 - "$PORT" <<'PYSERVE'
import os
import sys
import urllib.error
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

BOSS_ORIGIN = 'https://boss.hdslb.com'
BOSS_PROXY_PREFIX = '/boss'
BOSS_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class NoCacheHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        super().end_headers()

    def send_head(self):
        # 去掉条件请求头,否则父类会回 304,浏览器继续用旧文件。
        for name in ('If-Modified-Since', 'If-None-Match'):
            if name in self.headers:
                del self.headers[name]
        return super().send_head()

    def do_GET(self):
        if self.path == BOSS_PROXY_PREFIX or self.path.startswith(BOSS_PROXY_PREFIX + '/'):
            self.proxy_boss_get()
            return
        if self.serve_range():
            return
        super().do_GET()

    def serve_range(self):
        # 支持 Range: bytes=-N(尾部 N 字节)和 bytes=A-[B]。
        # 页面标记 dump 是否有双方确认数据时,只需读文件末尾的 confirm_stats,
        # 不必把整个 1~3MB dump 拉下来(19 个文件合计 24MB)。
        header = self.headers.get('Range')
        if not header or not header.strip().lower().startswith('bytes='):
            return False
        spec = header.strip()[6:].strip()
        if ',' in spec:
            return False  # 多段 Range 不支持,交回父类整体返回
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            return False
        size = os.path.getsize(path)
        try:
            if spec.startswith('-'):
                length = int(spec[1:])
                if length <= 0:
                    return False
                start = max(0, size - length)
                end = size - 1
            else:
                first, _, last = spec.partition('-')
                start = int(first)
                end = int(last) if last else size - 1
        except ValueError:
            return False
        if start >= size or start < 0:
            self.send_response(416)
            self.send_header('Content-Range', 'bytes */%d' % size)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return True
        end = min(end, size - 1)
        length = end - start + 1
        try:
            with open(path, 'rb') as handle:
                handle.seek(start)
                chunk = handle.read(length)
        except OSError:
            return False
        self.send_response(206)
        self.send_header('Content-Type', self.guess_type(path))
        self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
        self.send_header('Content-Length', str(len(chunk)))
        self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()
        self.wfile.write(chunk)
        return True

    def proxy_boss_get(self):
        # 只代理一个固定 BOSS host，避免把本地服务变成任意 URL 开放代理。
        upstream = BOSS_ORIGIN + self.path[len(BOSS_PROXY_PREFIX):]
        request = urllib.request.Request(upstream, headers={
            'Accept': self.headers.get('Accept', 'application/json'),
            'User-Agent': 'pk-match-viz/1.0',
        })
        try:
            response = BOSS_OPENER.open(request, timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        except urllib.error.URLError as error:
            self.send_error(502, 'BOSS proxy failed: %s' % error.reason)
            return

        try:
            self.send_response(response.status)
            for name in ('Content-Type', 'Content-Length', 'ETag', 'Last-Modified'):
                value = response.headers.get(name)
                if value:
                    self.send_header(name, value)
            self.end_headers()
            self.wfile.write(response.read())
        finally:
            response.close()


ThreadingHTTPServer(('0.0.0.0', int(sys.argv[1])), NoCacheHandler).serve_forever()
PYSERVE
