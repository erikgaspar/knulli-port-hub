# Tubo - nucleo: caminhos, log, dados locais (JSON), yt-dlp, RSS e miniaturas.
# Toda chamada de rede/yt-dlp roda fora da thread da interface (ver Job em tubo.py).
import json
import logging
import logging.handlers
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import xml.etree.ElementTree as ET
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "bin")
DATA = os.path.join(HERE, "data")
CACHE = os.path.join(HERE, "cache")
THUMBS = os.path.join(CACHE, "thumbs")
FONTS = os.path.join(HERE, "fonts")
MPVDIR = os.path.join(HERE, "mpv")
YTDLP_ZIP = os.path.join(BIN, "yt-dlp")          # zipapp oficial
YTDLP_PYZ = os.path.join(BIN, "yt-dlp.pyz")      # mesmo conteudo pre-compilado (.pyc) -> abre ~4x mais rapido
THUMB_LIMIT = 30 * 1024 * 1024
UA = "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

for d in (DATA, THUMBS):
    os.makedirs(d, exist_ok=True)

log = logging.getLogger("tubo")


def setup_log():
    if log.handlers:
        return
    h = logging.handlers.RotatingFileHandler(os.path.join(DATA, "tubo.log"), maxBytes=256 * 1024,
                                             backupCount=1, encoding="utf-8")
    h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S"))
    log.addHandler(h)
    log.setLevel(logging.INFO)


# ---------------------------------------------------------------- dados JSON

_lock = threading.Lock()


def load_json(name, default):
    p = os.path.join(DATA, name)
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except Exception as e:
        log.warning("json %s ilegivel (%s), usando padrao", name, e)
        return default


def save_json(name, obj):
    p = os.path.join(DATA, name)
    tmp = p + ".tmp"
    with _lock:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, indent=1)
        os.replace(tmp, p)


DEFAULT_SETTINGS = {
    "height": 360,          # 240 / 360 / 480
    "autoplay": True,
    "audio_default": False,
    "sub_lang": "off",      # off / pt / en
    "resume": True,
    "fill": False,          # preencher a tela (corta as laterais do 16:9)
}


class Store:
    """Configuracoes, historico, assistir mais tarde, inscricoes e buscas."""

    def __init__(self):
        s = dict(DEFAULT_SETTINGS)
        s.update(load_json("settings.json", {}))
        self.settings = s
        self.history = load_json("history.json", [])      # mais recente primeiro
        self.later = load_json("later.json", [])
        self.subs = load_json("subs.json", [])            # [{id, name, added}]
        self.searches = load_json("searches.json", [])
        self.state = load_json("state.json", {})

    def save(self, what):
        save_json(what + ".json", getattr(self, what))

    # historico ------------------------------------------------------------
    def add_history(self, v, pos=0.0, dur=None):
        e = slim(v)
        e["pos"] = round(pos or 0, 1)
        if dur:
            e["duration"] = dur
        e["at"] = int(time.time())
        self.history = [h for h in self.history if h["id"] != v["id"]]
        self.history.insert(0, e)
        del self.history[100:]
        self.save("history")

    def resume_pos(self, vid):
        for h in self.history:
            if h["id"] == vid:
                p, d = h.get("pos") or 0, h.get("duration") or 0
                if p > 30 and (not d or p < d - 30):
                    return p
        return 0

    # assistir mais tarde ----------------------------------------------------
    def in_later(self, vid):
        return any(x["id"] == vid for x in self.later)

    def toggle_later(self, v):
        if self.in_later(v["id"]):
            self.later = [x for x in self.later if x["id"] != v["id"]]
            r = False
        else:
            self.later.insert(0, slim(v))
            r = True
        self.save("later")
        return r

    # inscricoes ---------------------------------------------------------------
    def subscribed(self, cid):
        return any(s["id"] == cid for s in self.subs)

    def toggle_sub(self, cid, name):
        if not cid:
            return None
        if self.subscribed(cid):
            self.subs = [s for s in self.subs if s["id"] != cid]
            r = False
        else:
            self.subs.append({"id": cid, "name": name or cid, "added": int(time.time())})
            self.subs.sort(key=lambda s: s["name"].lower())
            r = True
        self.save("subs")
        return r

    # buscas -----------------------------------------------------------------
    def add_search(self, q):
        q = q.strip()
        if not q:
            return
        self.searches = [s for s in self.searches if s.lower() != q.lower()]
        self.searches.insert(0, q)
        del self.searches[12:]
        self.save("searches")


def slim(v):
    keys = ("id", "title", "channel", "channel_id", "duration", "views", "published", "live")
    return {k: v.get(k) for k in keys if v.get(k) is not None}


# ---------------------------------------------------------------- rede

def internet_ok(timeout=3.0):
    for host in ("www.youtube.com", "1.1.1.1"):
        try:
            s = socket.create_connection((host, 443), timeout=timeout)
            s.close()
            return True
        except OSError:
            continue
    return False


class Cancelled(Exception):
    pass


class TuboError(Exception):
    """Erro com mensagem pronta para o usuario."""


def friendly_error(stderr):
    t = stderr or ""
    low = t.lower()
    table = [
        ("confirm your age", "Vídeo com restrição de idade. Só abre com conta Google logada."),
        ("inappropriate for some users", "Vídeo com restrição de idade. Só abre com conta Google logada."),
        ("not a bot", "O YouTube pediu verificação anti-robô. Tente de novo mais tarde ou atualize o yt-dlp."),
        ("private video", "Este vídeo é privado."),
        ("members-only", "Vídeo exclusivo para membros do canal."),
        ("join this channel", "Vídeo exclusivo para membros do canal."),
        ("this live event will begin", "Esta transmissão ao vivo ainda não começou."),
        ("premieres in", "Esta estreia ainda não começou."),
        ("not available in your country", "Vídeo bloqueado no seu país."),
        ("copyright", "Vídeo removido por direitos autorais."),
        ("video unavailable", "Vídeo indisponível."),
        ("video is unavailable", "Vídeo indisponível."),
        ("this video is not available", "Vídeo indisponível."),
        ("has been removed", "Vídeo removido."),
        ("requested format is not available", "Nenhum formato compatível encontrado para este vídeo."),
        ("http error 429", "Muitas requisições: o YouTube limitou o acesso. Espere alguns minutos."),
        ("unable to download webpage", "Falha de rede ao falar com o YouTube. Verifique a internet."),
        ("timed out", "A conexão demorou demais. Verifique a internet."),
        ("name or service not known", "Sem internet (DNS). Verifique o Wi-Fi."),
        ("temporary failure in name resolution", "Sem internet (DNS). Verifique o Wi-Fi."),
        ("does not have a videos tab", "Este canal não tem aba de vídeos."),
    ]
    for k, msg in table:
        if k in low:
            return msg
    errs = [l for l in t.splitlines() if l.startswith("ERROR")]
    if errs:
        m = re.sub(r"^ERROR:\s*(\[[^\]]+\]\s*)?([\w-]+:\s*)?", "", errs[-1]).strip()
        return "Erro do yt-dlp: " + m[:160]
    return "Falha inesperada do yt-dlp."


class YtDlp:
    """yt-dlp num processo que fica aberto (ytworker.py); se ele falhar, cai para 1 processo por chamada."""

    def __init__(self):
        self.lock = threading.Lock()
        self.p = None
        self.q = None
        self.rid = 0
        self.worker_broken = False

    def exe(self):
        # o .pyz pre-compilado so vale para a mesma versao do python que o gerou
        st = load_json("state.json", {})
        if os.path.exists(YTDLP_PYZ) and st.get("pyz_python") == sys.version.split()[0]:
            return YTDLP_PYZ
        return YTDLP_ZIP

    def base_cmd(self):
        return [sys.executable, self.exe(), "--ignore-config", "--no-progress", "--socket-timeout", "15",
                "--cache-dir", os.path.join(CACHE, "ytdlp")]

    # ------------------------------------------------------------------ processo persistente
    def _spawn(self):
        import queue
        errf = open(os.path.join(DATA, "ytworker.log"), "w")
        self.p = subprocess.Popen([sys.executable, "-u", os.path.join(HERE, "ytworker.py"), self.exe(),
                                   os.path.join(CACHE, "ytdlp")],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errf)
        errf.close()
        q = queue.Queue()
        self.q = q
        p = self.p

        def reader():
            for line in p.stdout:
                q.put(line)
            q.put(None)
        threading.Thread(target=reader, daemon=True).start()
        log.info("ytworker iniciado (pid %s)", p.pid)

    def warm(self):
        """Abre o worker antes da 1a busca (chamado numa thread ao abrir o app)."""
        with self.lock:
            if not self.worker_broken and (self.p is None or self.p.poll() is not None):
                try:
                    self._spawn()
                except Exception as e:
                    log.warning("ytworker nao abriu: %s", e)
                    self.worker_broken = True

    def restart(self):
        with self.lock:
            if self.p and self.p.poll() is None:
                self.p.kill()
            self.p = None
            self.worker_broken = False

    def stop(self):
        try:
            if self.p and self.p.poll() is None:
                self.p.kill()
        except Exception:
            pass

    def call(self, url, opts, cli_args, timeout=60, job=None):
        import queue
        if self.worker_broken:
            return self.run(cli_args, timeout, job)
        log.info("yt-dlp* %s %s", url[:100], json.dumps(opts)[:160])
        t0 = time.time()
        with self.lock:
            if self.p is None or self.p.poll() is not None:
                self._spawn()
            p, q = self.p, self.q
            if job is not None:
                job.procs.append(p)       # cancelar mata o worker; ele reabre na proxima chamada
            self.rid += 1
            rid = self.rid
            try:
                p.stdin.write((json.dumps({"id": rid, "url": url, "opts": opts}) + "\n").encode())
                p.stdin.flush()
            except OSError:
                self.p = None
                raise TuboError("O yt-dlp fechou inesperadamente. Tente de novo.")
            while True:
                left = timeout - (time.time() - t0)
                try:
                    line = q.get(timeout=max(0.1, left))
                except queue.Empty:
                    p.kill()
                    self.p = None
                    raise TuboError("O yt-dlp demorou demais (mais de %d s). Tente de novo." % timeout)
                if line is None:
                    self.p = None
                    if job is not None and job.cancelled:
                        raise Cancelled()
                    raise TuboError("O yt-dlp fechou inesperadamente. Tente de novo.")
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                if m.get("id") == rid:
                    break
        if job is not None and job.cancelled:
            raise Cancelled()
        dt = time.time() - t0
        if not m.get("ok"):
            err = m.get("err") or ""
            log.warning("yt-dlp* falhou em %.1fs: %s", dt, err.strip()[-600:])
            if not internet_ok():
                raise TuboError("Sem internet. Conecte o Wi-Fi e tente de novo.")
            raise TuboError(friendly_error(err))
        log.info("yt-dlp* ok em %.1fs", dt)
        return m.get("data") or {}

    def run(self, args, timeout=60, job=None):
        cmd = self.base_cmd() + args
        log.info("yt-dlp %s", " ".join(a if len(a) < 120 else a[:120] + "..." for a in args))
        t0 = time.time()
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL)
        if job is not None:
            job.procs.append(p)
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            p.communicate()
            raise TuboError("O yt-dlp demorou demais (mais de %d s). Tente de novo." % timeout)
        if job is not None and job.cancelled:
            raise Cancelled()
        err = err.decode("utf-8", "replace")
        dt = time.time() - t0
        if p.returncode != 0:
            log.warning("yt-dlp rc=%s em %.1fs: %s", p.returncode, dt, err.strip()[-600:])
            if not internet_ok():
                raise TuboError("Sem internet. Conecte o Wi-Fi e tente de novo.")
            raise TuboError(friendly_error(err))
        log.info("yt-dlp ok em %.1fs", dt)
        try:
            return json.loads(out.decode("utf-8", "replace"))
        except ValueError:
            raise TuboError("Resposta inválida do yt-dlp.")

    def version(self):
        st = load_json("state.json", {})
        return st.get("ytdlp_version") or "?"

    # ------------------------------------------------------------------ alto nivel
    def search(self, q, job=None, n=20):
        u = "ytsearch%d:%s" % (n, q)
        d = self.call(u, {"extract_flat": "in_playlist"}, [u, "--flat-playlist", "-J"], timeout=60, job=job)
        return [norm_entry(e) for e in d.get("entries") or [] if e and e.get("id")]

    def channel(self, cid, job=None, n=24):
        url = "https://www.youtube.com/channel/%s/videos" % cid
        d = self.call(url, {"extract_flat": "in_playlist", "playlist_items": "1:%d" % n},
                      [url, "--flat-playlist", "-I", "1:%d" % n, "-J"], timeout=60, job=job)
        name = d.get("channel") or d.get("uploader") or d.get("title") or ""
        name = re.sub(r"\s+-\s+Videos$", "", name)
        vids = []
        for e in d.get("entries") or []:
            if not e or not e.get("id"):
                continue
            v = norm_entry(e)
            v.setdefault("channel", name)
            v.setdefault("channel_id", cid)
            vids.append(v)
        return name, vids

    def resolve(self, vid, height=360, audio_only=False, sub_lang="off", job=None):
        h = int(height)
        if audio_only:
            fmt = "ba[ext=m4a]/ba/b[height<=%d]/b" % h
        else:
            fmt = ("bv*[height<=%(h)d][vcodec^=avc1][fps<=30]+ba[ext=m4a]/"
                   "bv*[height<=%(h)d][vcodec^=avc1]+ba[ext=m4a]/"
                   "b[height<=%(h)d][vcodec^=avc1]/"
                   "bv*[height<=%(h)d]+ba/b[height<=%(h)d]/w") % {"h": h}
        url = "https://www.youtube.com/watch?v=" + vid
        d = self.call(url, {"format": fmt, "noplaylist": True},
                      ["-f", fmt, "-J", "--no-playlist", url], timeout=60, job=job)
        fmts = d.get("requested_formats") or [d]
        video = audio = None
        for f in fmts:
            if f.get("vcodec") not in (None, "none"):
                video = f
            if f.get("acodec") not in (None, "none") and (audio is None or f.get("vcodec") in (None, "none")):
                audio = f
        if audio_only:
            main, extra = (audio or fmts[0]), None
        else:
            main = video or fmts[0]
            extra = audio if (audio is not None and audio is not main) else None
        r = {
            "id": vid,
            "title": d.get("title") or vid,
            "channel": d.get("channel") or d.get("uploader") or "",
            "channel_id": d.get("channel_id") or "",
            "duration": d.get("duration"),
            "views": d.get("view_count"),
            "live": bool(d.get("is_live")),
            "url": main["url"],
            "audio_url": extra["url"] if extra else None,
            "ua": (main.get("http_headers") or {}).get("User-Agent") or UA,
            "format": "+".join(f.get("format_id", "?") for f in fmts),
            "desc": "%s %sp %s" % (
                (video or {}).get("vcodec") or "-", (video or {}).get("height") or "-",
                (audio or {}).get("acodec") or "-"),
            "subs": pick_subs(d, sub_lang),
        }
        log.info("resolvido %s formato %s (%s)", vid, r["format"], r["desc"])
        return r


def pick_subs(d, pref):
    """Devolve [(lang, url_vtt)] na ordem de preferencia (manual antes de automatica)."""
    langs = ["pt-BR", "pt", "pt-PT", "en", "en-US", "en-GB", "en-orig"]
    if pref == "en":
        langs = ["en", "en-US", "en-GB", "en-orig", "pt-BR", "pt"]
    out = []
    for src in (d.get("subtitles") or {}, d.get("automatic_captions") or {}):
        for lg in langs:
            for t in src.get(lg) or []:
                if t.get("ext") == "vtt" and t.get("url"):
                    out.append((lg, t["url"]))
                    break
        if out:
            break
    return out[:2]


def norm_entry(e):
    v = {
        "id": e.get("id"),
        "title": e.get("title") or "(sem título)",
        "channel": e.get("channel") or e.get("uploader") or "",
        "channel_id": e.get("channel_id") or e.get("uploader_id") or "",
        "duration": e.get("duration"),
        "views": e.get("view_count"),
    }
    if e.get("live_status") == "is_live":
        v["live"] = True
    ts = e.get("timestamp") or e.get("release_timestamp")
    if ts:
        v["published"] = int(ts)
    return {k: x for k, x in v.items() if x not in (None, "")}


# ---------------------------------------------------------------- RSS (inscricoes)

NS = {"a": "http://www.w3.org/2005/Atom", "yt": "http://www.youtube.com/xml/schemas/2015",
      "m": "http://search.yahoo.com/mrss/"}


def fetch_rss(cid, timeout=12):
    url = "https://www.youtube.com/feeds/videos.xml?channel_id=" + cid
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        root = ET.fromstring(r.read())
    out = []
    name = root.findtext("a:title", "", NS)
    for en in root.findall("a:entry", NS):
        vid = en.findtext("yt:videoId", "", NS)
        if not vid:
            continue
        v = {"id": vid, "title": en.findtext("a:title", "", NS), "channel": name, "channel_id": cid}
        pub = en.findtext("a:published", "", NS)
        try:
            v["published"] = int(time.mktime(time.strptime(pub[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone)
        except Exception:
            pass
        st = en.find("m:group/m:community/m:statistics", NS)
        if st is not None and st.get("views", "").isdigit():
            v["views"] = int(st.get("views"))
        out.append(v)
    return name, out


def fetch_feed(subs, job=None):
    vids, fails = [], 0
    with ThreadPoolExecutor(max_workers=4) as ex:
        futs = [ex.submit(fetch_rss, s["id"]) for s in subs]
        for s, f in zip(subs, futs):
            try:
                _, vs = f.result()
                vids.extend(vs)
            except Exception as e:
                fails += 1
                log.warning("rss %s falhou: %s", s["id"], e)
            if job is not None and job.cancelled:
                raise Cancelled()
    if subs and fails == len(subs):
        if not internet_ok():
            raise TuboError("Sem internet. Conecte o Wi-Fi e tente de novo.")
        raise TuboError("Não consegui ler os canais inscritos agora. Tente mais tarde.")
    vids.sort(key=lambda v: v.get("published", 0), reverse=True)
    return vids[:80], fails


# ---------------------------------------------------------------- miniaturas

def thumb_path(vid):
    return os.path.join(THUMBS, re.sub(r"[^\w-]", "_", vid) + ".jpg")


def prune_thumbs(limit=THUMB_LIMIT):
    try:
        fs = []
        for n in os.listdir(THUMBS):
            p = os.path.join(THUMBS, n)
            st = os.stat(p)
            fs.append((st.st_mtime, st.st_size, p))
        total = sum(f[1] for f in fs)
        fs.sort()
        removed = 0
        while total > limit and fs or (removed and total > limit * 0.85 and fs):
            _, sz, p = fs.pop(0)
            os.remove(p)
            total -= sz
            removed += 1
        if removed:
            log.info("cache de miniaturas: %d removidas", removed)
        return total
    except Exception as e:
        log.warning("prune_thumbs: %s", e)
        return 0


def dir_size(path):
    t = 0
    for root, _, fs in os.walk(path):
        for f in fs:
            try:
                t += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return t


class Thumbs:
    """Baixa miniaturas (mqdefault 320x180) em 2 threads; a interface pede get(id) a cada quadro."""

    def __init__(self):
        self.q = []
        self.cv = threading.Condition()
        self.ready = {}          # id -> caminho no disco (pronto para carregar)
        self.failed = set()
        self.pending = set()
        self.surfs = OrderedDict()
        self.stop = False
        for _ in range(2):
            threading.Thread(target=self._worker, daemon=True).start()

    def request(self, vid):
        if vid in self.ready or vid in self.failed or vid in self.pending:
            return
        p = thumb_path(vid)
        if os.path.exists(p):
            self.ready[vid] = p
            return
        with self.cv:
            self.pending.add(vid)
            self.q.append(vid)
            self.cv.notify()

    def prioritize(self, vids):
        with self.cv:
            first = [v for v in vids if v in self.q]
            self.q = first + [v for v in self.q if v not in first]

    def _worker(self):
        while not self.stop:
            with self.cv:
                while not self.q:
                    self.cv.wait()
                vid = self.q.pop(0)
            p = thumb_path(vid)
            try:
                for name in ("mqdefault.jpg", "hqdefault.jpg"):
                    try:
                        req = urllib.request.Request("https://i.ytimg.com/vi/%s/%s" % (vid, name),
                                                     headers={"User-Agent": UA})
                        with urllib.request.urlopen(req, timeout=10) as r:
                            data = r.read()
                        break
                    except urllib.error.HTTPError:
                        data = None
                if not data:
                    raise IOError("sem miniatura")
                tmp = p + ".part"
                try:
                    from PIL import Image
                    import io
                    im = Image.open(io.BytesIO(data)).convert("RGB")
                    if im.width / max(1, im.height) < 1.5:      # hqdefault 4:3 com tarjas -> recorta 16:9
                        hh = im.width * 9 // 16
                        top = (im.height - hh) // 2
                        im = im.crop((0, top, im.width, top + hh))
                    im = im.resize((320, 180), Image.BILINEAR)
                    im.save(tmp, "JPEG", quality=82)
                except Exception:
                    with open(tmp, "wb") as f:
                        f.write(data)
                os.replace(tmp, p)
                self.ready[vid] = p
            except Exception as e:
                self.failed.add(vid)
                log.info("miniatura %s: %s", vid, e)
            finally:
                self.pending.discard(vid)

    def get(self, vid, size):
        """Surface do pygame no tamanho pedido (ou None enquanto baixa)."""
        import pygame
        key = (vid, size)
        s = self.surfs.get(key)
        if s is not None:
            self.surfs.move_to_end(key)
            return s
        p = self.ready.get(vid)
        if not p:
            self.request(vid)
            return None
        try:
            img = pygame.image.load(p)
            s = pygame.transform.smoothscale(img, size)
            try:
                s = s.convert()
            except pygame.error:
                pass
        except Exception as e:
            log.info("miniatura invalida %s: %s", vid, e)
            self.ready.pop(vid, None)
            self.failed.add(vid)
            try:
                os.remove(p)
            except OSError:
                pass
            return None
        self.surfs[key] = s
        while len(self.surfs) > 160:
            self.surfs.popitem(last=False)
        return s

    def clear(self):
        self.surfs.clear()
        self.ready.clear()
        self.failed.clear()


# ---------------------------------------------------------------- formatacao PT-BR

def fmt_dur(s):
    if not s:
        return ""
    s = int(s)
    h, m, sec = s // 3600, (s // 60) % 60, s % 60
    return "%d:%02d:%02d" % (h, m, sec) if h else "%d:%02d" % (m, sec)


def fmt_views(n):
    if n is None:
        return ""
    n = int(n)
    if n >= 1_000_000_000:
        t = "%.1f bi" % (n / 1e9)
    elif n >= 1_000_000:
        t = ("%.1f mi" % (n / 1e6)) if n < 10_000_000 else "%d mi" % (n // 1_000_000)
    elif n >= 1000:
        t = "%d mil" % (n // 1000)
    else:
        return "%d visualizaç%s" % (n, "ão" if n == 1 else "ões")
    return t.replace(".0 ", " ").replace(".", ",") + " de visualizações"


def fmt_ago(ts):
    if not ts:
        return ""
    d = time.time() - ts
    if d < 3600:
        return "há %d min" % max(1, d // 60)
    if d < 86400:
        h = int(d // 3600)
        return "há %d hora%s" % (h, "s" if h > 1 else "")
    days = int(d // 86400)
    if days < 30:
        return "há %d dia%s" % (days, "s" if days > 1 else "")
    if days < 365:
        m = days // 30
        return "há %d %s" % (m, "mês" if m == 1 else "meses")
    y = days // 365
    return "há %d ano%s" % (y, "s" if y > 1 else "")


def fmt_size(b):
    if b >= 1024 * 1024:
        return "%.1f MB" % (b / 1048576)
    return "%d KB" % (b // 1024)
