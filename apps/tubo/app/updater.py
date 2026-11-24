#!/usr/bin/env python3
# Tubo - atualizador do yt-dlp (roda como processo separado, com nice, sem travar a interface).
#   python3 updater.py --auto    so verifica se a ultima verificacao tem mais de 3 dias
#   python3 updater.py --force   verifica agora
#   python3 updater.py --build   so recompila o bin/yt-dlp.pyz a partir do bin/yt-dlp atual
# Baixa o asset oficial "yt-dlp" (zipapp) da release estavel do GitHub, testa, gera uma copia
# pre-compilada (.pyc, abre ~4x mais rapido no Cortex-A53) e troca os arquivos de forma atomica.
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
import compileall

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "bin")
DATA = os.path.join(HERE, "data")
ZIP = os.path.join(BIN, "yt-dlp")
PYZ = os.path.join(BIN, "yt-dlp.pyz")
STATE = os.path.join(DATA, "state.json")
STATUS = os.path.join(DATA, "update.json")
LATEST = "https://github.com/yt-dlp/yt-dlp/releases/latest"
ASSET = "https://github.com/yt-dlp/yt-dlp/releases/download/%s/yt-dlp"
UA = "Tubo-updater"
INTERVAL = 3 * 86400


def jload(p, d):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return d


def jsave(p, o):
    t = p + ".tmp"
    with open(t, "w") as f:
        json.dump(o, f, indent=1)
    os.replace(t, p)


def status(state, msg):
    jsave(STATUS, {"state": state, "msg": msg, "at": int(time.time())})
    logline("%s: %s" % (state, msg))


def logline(s):
    try:
        with open(os.path.join(DATA, "tubo.log"), "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") + " UPDATER " + s + "\n")
    except Exception:
        pass


def version_of(path):
    r = subprocess.run([sys.executable, path, "--version"], capture_output=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError("yt-dlp nao executou: " + r.stderr.decode(errors="replace")[-200:])
    return r.stdout.decode().strip()


def build_pyz(src_zip, dst):
    tmpd = tempfile.mkdtemp(prefix="tubo-build-", dir="/tmp")
    try:
        src = os.path.join(tmpd, "src")
        with zipfile.ZipFile(src_zip) as z:
            z.extractall(src)
        compileall.compile_dir(src, quiet=1, legacy=True)
        out = dst + ".new"
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            for root, _, fs in os.walk(src):
                for f in fs:
                    p = os.path.join(root, f)
                    if f.endswith(".py") and os.path.exists(p + "c"):
                        continue      # fica so o .pyc
                    z.write(p, os.path.relpath(p, src))
        return out
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)


def do_build(state):
    ver = version_of(ZIP)
    new = build_pyz(ZIP, PYZ)
    if version_of(new) != ver:
        os.remove(new)
        raise RuntimeError("copia pre-compilada nao confere")
    os.replace(new, PYZ)
    state["ytdlp_version"] = ver
    state["pyz_python"] = sys.version.split()[0]
    jsave(STATE, state)
    return ver


def main():
    mode = (sys.argv[1:] or ["--auto"])[0]
    os.makedirs(DATA, exist_ok=True)
    os.makedirs(BIN, exist_ok=True)
    if mode in ("--build", "--auto") and not os.path.exists(ZIP):
        mode = "--force"      # instalado sem o yt-dlp (primeira execucao): baixa agora
    lockf = open(os.path.join(DATA, "update.lock"), "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0       # ja tem um rodando
    try:
        os.nice(15)
    except OSError:
        pass
    state = jload(STATE, {})
    try:
        if mode == "--build":
            status("running", "Recompilando yt-dlp")
            v = do_build(state)
            status("ok", "yt-dlp %s pronto" % v)
            return 0
        if mode == "--auto" and time.time() - state.get("last_check", 0) < INTERVAL:
            return 0
        status("running", "Verificando nova versão do yt-dlp")
        req = urllib.request.Request(LATEST, headers={"User-Agent": UA}, method="HEAD")
        with urllib.request.urlopen(req, timeout=20) as r:
            tag = r.geturl().rstrip("/").rsplit("/", 1)[-1]
        if not tag or "latest" in tag:
            raise RuntimeError("nao achei a ultima versao (%s)" % tag)
        cur = state.get("ytdlp_version") if os.path.exists(ZIP) else None
        if not cur and os.path.exists(ZIP):
            cur = version_of(ZIP)
        state["last_check"] = int(time.time())
        if cur == tag and os.path.exists(PYZ) and state.get("pyz_python") == sys.version.split()[0]:
            state["ytdlp_version"] = cur
            jsave(STATE, state)
            status("uptodate", "yt-dlp %s já é a versão mais nova" % cur)
            return 0
        if cur != tag:
            status("running", "Baixando yt-dlp %s" % tag)
            tmp = ZIP + ".new"
            req = urllib.request.Request(ASSET % tag, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r, open(tmp, "wb") as f:
                shutil.copyfileobj(r, f)
            if os.path.getsize(tmp) < 1_000_000:
                raise RuntimeError("download incompleto")
            nv = version_of(tmp)
            os.replace(tmp, ZIP)
            logline("yt-dlp %s -> %s" % (cur, nv))
        status("running", "Preparando yt-dlp")
        v = do_build(state)
        status("ok", "yt-dlp atualizado para %s" % v)
        return 0
    except Exception as e:
        for p in (ZIP + ".new", PYZ + ".new"):
            try:
                os.remove(p)
            except OSError:
                pass
        if mode != "--build":
            state["last_check_fail"] = int(time.time())
            jsave(STATE, state)
        status("error", "Falha ao atualizar: %s" % str(e)[:160])
        return 1


if __name__ == "__main__":
    sys.exit(main())
