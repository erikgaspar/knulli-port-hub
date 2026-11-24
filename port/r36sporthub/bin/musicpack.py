#!/usr/bin/env python3
# Knulli Port Hub - pacote de musicas de games (OverClocked ReMix).
# O repositorio so guarda o indice (knulli-music.json); cada console baixa as faixas dos
# espelhos oficiais do OC ReMix, uma por vez, com pausa e User-Agent identificado.
#
#   python3 -I musicpack.py install --index IDX --dest /userdata/music [--mode only|knulli]
#                           [--progress ARQ] [--cancel ARQ] [--pause 4]
#   python3 -I musicpack.py remove  --dest /userdata/music
#   python3 -I musicpack.py status  --dest /userdata/music [--index IDX]
#
# install: para cada faixa: baixa o MP3 (tenta os espelhos em ordem), confere com ffprobe
#   (mp3, duracao), converte para OGG Vorbis 96 kbps (ffmpeg), confere de novo e poe em
#   <dest>/ocremix/. Faixa ja instalada fica como esta; arquivo com o mesmo nome solto em
#   <dest> (instalado a mao antes) e conferido e movido para a pasta do pacote.
#   --mode knulli: copia tambem as musicas do Knulli (/usr/share/knulli/music) para
#   <dest>/knulli/ (o EmulationStation so toca as do sistema quando <dest> esta vazio).
#   --mode only: tira a copia das musicas do Knulli feita pelo pacote.
#   Gera <dest>/ocremix/CREDITOS.txt. Cancelar: criar o arquivo --cancel (para entre
#   faixas e no meio do download; o que ja foi instalado fica registrado).
# remove: apaga so o que o pacote instalou (registro <dest>/ocremix/.knulli-port-hub.json).
# Saida: linhas "STEP ...", "TRACK i n ok|fail|skip id", "OK ..." / "CANCELADO" / "ERRO ...".
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

UA = "Knulli-Port-Hub-music-pack/1.0 (+https://github.com/erikgaspar/knulli-port-hub; one track at a time)"
FOLDER = "ocremix"
KFOLDER = "knulli"
STATE_NAME = ".knulli-port-hub.json"
KNULLI_SRC = os.environ.get("PORTHUB_KNULLI_MUSIC", "/usr/share/knulli/music")
MIRRORS = ("https://ocrmirror.org/", "https://iterations.org/", "https://ocr.blueblue.fr/")


class Cancel(Exception):
    pass


def say(*a):
    print(*a, flush=True)


def jload(p, d=None):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return d


def jsave(p, o):
    t = p + ".tmp"
    with open(t, "w", encoding="utf-8") as f:
        json.dump(o, f, indent=1, ensure_ascii=False)
    os.replace(t, p)


def safe_file(n):
    n = str(n or "")
    if not n or "/" in n or "\\" in n or n.startswith(".") or not n.lower().endswith(".ogg"):
        raise ValueError("nome de arquivo invalido: %r" % n)
    return n


def load_index(path):
    d = jload(path)
    if not isinstance(d, dict) or not isinstance(d.get("tracks"), list):
        raise ValueError("indice invalido: %s" % path)
    out = []
    for t in d["tracks"]:
        if not isinstance(t, dict):
            continue
        urls = [u for u in t.get("mp3") or [] if isinstance(u, str) and u.startswith(MIRRORS)]
        if not urls:
            continue
        t = dict(t)
        t["file"] = safe_file(t.get("file"))
        t["mp3"] = urls
        out.append(t)
    return d, out


class Run:
    def __init__(self, a):
        self.a = a
        self.dest = a.dest.rstrip("/")
        self.pdir = os.path.join(self.dest, FOLDER)
        self.kdir = os.path.join(self.dest, KFOLDER)
        self.state_path = os.path.join(self.pdir, STATE_NAME)
        self.prog = {}

    # ------------------------------------------------------------------ util
    def state(self):
        s = jload(self.state_path, {}) or {}
        s.setdefault("tracks", {})
        s.setdefault("knulli", [])
        return s

    def progress(self, **kw):
        self.prog.update(kw)
        if self.a.progress:
            try:
                jsave(self.a.progress, self.prog)
            except OSError:
                pass

    def check_cancel(self):
        if self.a.cancel and os.path.exists(self.a.cancel):
            raise Cancel()

    def probe(self, p):
        r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration,format_name",
                            "-of", "json", p], capture_output=True, text=True, timeout=120)
        f = json.loads(r.stdout or "{}").get("format") or {}
        return f.get("format_name", ""), float(f.get("duration") or 0)

    def download(self, url, out, i, n):
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=60) as r, open(out, "wb") as f:
            total = int(r.headers.get("Content-Length") or 0)
            got = 0
            while True:
                self.check_cancel()
                b = r.read(128 * 1024)
                if not b:
                    break
                f.write(b)
                got += len(b)
                self.progress(phase="download", got=got, size=total)
        return got

    # ------------------------------------------------------------------ faixa
    def one(self, t, i, n, tmp):
        final = os.path.join(self.pdir, t["file"])
        dur = float(t.get("duration") or 0)
        loose = os.path.join(self.dest, t["file"])
        # instalada antes a mao (mesmo nome em <dest>): confere e move
        if os.path.isfile(loose) and not os.path.exists(final):
            fmt, d = self.probe(loose)
            if fmt == "ogg" and (not dur or abs(d - dur) < 3):
                shutil.move(loose, final)
                say("STEP aproveitado", t["file"])
                return "adopted"
        mp3 = os.path.join(tmp, t["id"] + ".mp3")
        ogg = os.path.join(tmp, t["id"] + ".ogg")
        last = "sem espelho"
        for url in t["mp3"]:
            self.check_cancel()
            self.progress(phase="download", got=0, size=int(t.get("mp3_size") or 0))
            try:
                self.download(url, mp3, i, n)
                fmt, d = self.probe(mp3)
                if fmt != "mp3" or d < 30 or (dur and abs(d - dur) > 5):
                    last = "arquivo nao confere (%s, %.0f s)" % (fmt, d)
                    continue
                self.check_cancel()
                self.progress(phase="convert")
                r = subprocess.run(["nice", "-n", "10", "ffmpeg", "-nostdin", "-v", "error", "-y", "-i", mp3,
                                    "-map", "0:a:0", "-map_metadata", "0", "-c:a", "libvorbis", "-b:a",
                                    "%dk" % self.a.bitrate, "-ar", "44100", "-ac", "2", ogg],
                                   capture_output=True, text=True, timeout=1800)
                if r.returncode != 0:
                    last = "ffmpeg: " + (r.stderr or "")[-160:]
                    continue
                fmt2, d2 = self.probe(ogg)
                if fmt2 != "ogg" or abs(d2 - d) > 1.5:
                    last = "conversao nao confere"
                    continue
                shutil.copyfile(ogg, final + ".tmp")
                os.replace(final + ".tmp", final)
                return "ok"
            except Cancel:
                raise
            except Exception as e:
                last = "%s: %s" % (type(e).__name__, str(e)[:120])
            finally:
                for p in (mp3, ogg):
                    try:
                        os.remove(p)
                    except OSError:
                        pass
                time.sleep(self.a.pause)
        say("STEP falhou", t["id"], last)
        return "fail"

    # ------------------------------------------------------------------ acoes
    def install(self):
        meta, tracks = load_index(self.a.index)
        os.makedirs(self.pdir, exist_ok=True)
        st = self.state()
        st["index_updated"] = meta.get("updated")
        tmp = os.path.join(self.pdir, ".tmp")
        os.makedirs(tmp, exist_ok=True)
        n = len(tracks)
        res = {"ok": 0, "fail": 0, "skip": 0}
        cancelled = False
        try:
            for i, t in enumerate(tracks, 1):
                self.check_cancel()
                self.progress(i=i, n=n, title="%s - %s" % (t.get("game", ""), t.get("title", "")), **res)
                final = os.path.join(self.pdir, t["file"])
                if os.path.isfile(final) and t["id"] in st["tracks"]:
                    res["skip"] += 1
                    say("TRACK", i, n, "skip", t["id"])
                    continue
                r = self.one(t, i, n, tmp)
                if r in ("ok", "adopted"):
                    st["tracks"][t["id"]] = t["file"]
                    jsave(self.state_path, st)
                    res["ok"] += 1
                else:
                    res["fail"] += 1
                say("TRACK", i, n, r, t["id"])
            self.check_cancel()
            self.knulli_mode(st)
        except Cancel:
            cancelled = True
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
            st["mode"] = self.a.mode if not cancelled else st.get("mode", "only")
            st["updated_at"] = int(time.time())
            jsave(self.state_path, st)
            self.credits(meta, tracks, st)
            self.progress(phase="done", **res)
        if cancelled:
            say("CANCELADO", res["ok"], res["fail"], res["skip"])
            return 3
        say("OK install", res["ok"], res["fail"], res["skip"], self.a.mode)
        return 0 if res["fail"] == 0 else 4

    def knulli_mode(self, st):
        """--mode knulli: copia as musicas do sistema para <dest>/knulli; only: tira a copia"""
        if self.a.mode == "knulli":
            if not os.path.isdir(KNULLI_SRC):
                say("STEP sem musicas do Knulli em", KNULLI_SRC)
                return
            os.makedirs(self.kdir, exist_ok=True)
            self.progress(phase="knulli")
            for f in sorted(os.listdir(KNULLI_SRC)):
                if not f.lower().endswith((".ogg", ".mp3")) or f.startswith("."):
                    continue
                self.check_cancel()
                dst = os.path.join(self.kdir, f)
                if not os.path.exists(dst):
                    shutil.copyfile(os.path.join(KNULLI_SRC, f), dst + ".tmp")
                    os.replace(dst + ".tmp", dst)
                if f not in st["knulli"]:
                    st["knulli"].append(f)
            jsave(self.state_path, st)
        else:
            self.remove_knulli(st)

    def remove_knulli(self, st):
        for f in list(st.get("knulli") or []):
            if "/" in f:
                continue
            try:
                os.remove(os.path.join(self.kdir, f))
            except OSError:
                pass
            st["knulli"].remove(f)
        try:
            os.rmdir(self.kdir)
        except OSError:
            pass

    def credits(self, meta, tracks, st):
        L = ["MÚSICAS DO MENU - OverClocked ReMix (https://ocremix.org)",
             "Pacote de músicas de games do Knulli Port Hub.",
             "Arranjos de fãs de músicas de videogame, distribuídos gratuitamente pelo OC ReMix.",
             "Os arranjos pertencem aos seus artistas; as composições originais, aos seus donos.",
             "Baixado dos espelhos oficiais do OC ReMix e convertido para OGG Vorbis %d kbps." % self.a.bitrate,
             "Para tirar: Knulli Port Hub > Utilitários > Pacote de músicas de games > Remover.",
             "", "-" * 70]
        k = 0
        for t in tracks:
            if t["id"] not in st["tracks"]:
                continue
            k += 1
            s = int(t.get("duration") or 0)
            L += ["%02d. %s - \"%s\"" % (k, t.get("game", ""), t.get("title", "")),
                  "    Artista(s): %s" % ", ".join(t.get("artists") or []),
                  "    Página: %s" % t.get("page", ""),
                  "    Arquivo: %s  (%d:%02d)" % (t["file"], s // 60, s % 60), ""]
        L.append("Total: %d faixas" % k)
        try:
            with open(os.path.join(self.pdir, "CREDITOS.txt"), "w", encoding="utf-8", newline="\r\n") as f:
                f.write("\n".join(L) + "\n")
        except OSError:
            pass

    def remove(self):
        st = self.state()
        n = 0
        for oid, f in list(st["tracks"].items()):
            if "/" in f:
                continue
            try:
                os.remove(os.path.join(self.pdir, f))
                n += 1
            except OSError:
                pass
        self.remove_knulli(st)
        for f in ("CREDITOS.txt", STATE_NAME):
            try:
                os.remove(os.path.join(self.pdir, f))
            except OSError:
                pass
        shutil.rmtree(os.path.join(self.pdir, ".tmp"), ignore_errors=True)
        try:
            os.rmdir(self.pdir)
        except OSError:
            pass
        say("OK remove", n)
        return 0

    def status(self):
        st = self.state()
        out = {"installed": len(st["tracks"]), "mode": st.get("mode"), "knulli": len(st.get("knulli") or []),
               "tracks": st["tracks"]}
        if self.a.index and os.path.exists(self.a.index):
            _, tracks = load_index(self.a.index)
            out["total"] = len(tracks)
            out["loose"] = sum(1 for t in tracks if os.path.isfile(os.path.join(self.dest, t["file"])))
        say(json.dumps(out, ensure_ascii=False))
        return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["install", "remove", "status"])
    ap.add_argument("--index")
    ap.add_argument("--dest", default="/userdata/music")
    ap.add_argument("--mode", choices=["only", "knulli"], default="only")
    ap.add_argument("--progress")
    ap.add_argument("--cancel")
    ap.add_argument("--pause", type=float, default=4.0)
    ap.add_argument("--bitrate", type=int, default=96)
    a = ap.parse_args()
    r = Run(a)
    try:
        if a.action == "install":
            if not a.index:
                say("ERRO falta --index")
                return 2
            if a.cancel and os.path.exists(a.cancel):
                os.remove(a.cancel)
            return r.install()
        if a.action == "remove":
            return r.remove()
        return r.status()
    except Exception as e:
        say("ERRO", "%s: %s" % (type(e).__name__, str(e)[:200]))
        return 1


if __name__ == "__main__":
    sys.exit(main())
