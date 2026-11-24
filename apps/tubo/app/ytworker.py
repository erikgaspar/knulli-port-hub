# Tubo - processo do yt-dlp que fica aberto (importar o yt-dlp custa ~3 s no Cortex-A53;
# aberto, uma busca leva ~2-3 s em vez de ~8 s). Protocolo: 1 JSON por linha no stdin/stdout.
#   pedido:   {"id": 1, "url": "...", "opts": {...opcoes do YoutubeDL...}}
#   resposta: {"id": 1, "ok": true, "data": {...igual ao -J...}}  ou  {"id": 1, "ok": false, "err": "..."}
import json
import sys

exe, cache = sys.argv[1], sys.argv[2]
sys.path.insert(0, exe)
out = sys.stdout
sys.stdout = sys.stderr          # qualquer print do yt-dlp vai para o log, nao para o protocolo

import yt_dlp  # noqa: E402


class Log:
    def __init__(self):
        self.msgs = []

    def debug(self, m):
        pass

    def info(self, m):
        pass

    def warning(self, m):
        self.msgs.append("WARNING: " + m)
        sys.stderr.write("WARNING: " + m + "\n")

    def error(self, m):
        self.msgs.append(m)
        sys.stderr.write(m + "\n")


out.write(json.dumps({"id": 0, "ok": True, "data": {"version": yt_dlp.version.__version__}}) + "\n")
out.flush()

for line in sys.stdin:
    try:
        req = json.loads(line)
    except ValueError:
        continue
    lg = Log()
    opts = {"quiet": True, "no_warnings": False, "logger": lg, "cachedir": cache, "socket_timeout": 15,
            "noprogress": True}
    opts.update(req.get("opts") or {})
    try:
        with yt_dlp.YoutubeDL(opts) as y:
            info = y.sanitize_info(y.extract_info(req["url"], download=False))
        resp = {"id": req.get("id"), "ok": True, "data": info}
    except BaseException as e:   # noqa
        if isinstance(e, KeyboardInterrupt):
            break
        msg = str(e)
        resp = {"id": req.get("id"), "ok": False,
                "err": "\n".join(lg.msgs + [msg if msg.startswith("ERROR") else "ERROR: " + msg])}
    out.write(json.dumps(resp) + "\n")
    out.flush()
