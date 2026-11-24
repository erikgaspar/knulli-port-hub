#!/usr/bin/env python3
# Knulli Port Hub - instalador dos "apps do hub" (lista "apps" do knulli-catalog.json).
# Apps que nao sao ports: ficam fora de roms/ports (ex.: /userdata/system/knulli-tools/tubo)
# e ganham um atalho no menu Tools do Knulli.
#
#   python3 -I hubapp.py install|update|repair  MANIFESTO.json
#   python3 -I hubapp.py uninstall              MANIFESTO.json
#
# install/update/repair: baixa o zip da release (confere tamanho e sha256), extrai numa
# pasta nova ao lado da pasta do app, guarda o que o app declarou em "keep" (dados,
# cache, yt-dlp...), troca as pastas (desfaz se algo falhar), grava o atalho .sh e a capa
# na pasta do menu, poe o item na gamelist (arquivo + API do EmulationStation, sem
# reiniciar) e roda o "post_install" do app (ex.: baixar o yt-dlp; falha nao e fatal).
# uninstall: apaga a pasta do app, o atalho, a capa e o item da gamelist.
# Estado: <STATE>/<id>.json (versao, arquivos criados).
#
# Testes (sem tocar no sistema): PORTHUB_HUBAPP_ROOT=/tmp/x poe /tmp/x na frente de todos
# os caminhos do manifesto; PORTHUB_HUBAPP_STATE troca a pasta de estado;
# PORTHUB_ES_URL="" desliga a API do EmulationStation; PORTHUB_HUBAPP_ZIP=arquivo.zip usa
# um zip local no lugar do download (o sha256 continua conferido se vier no manifesto).
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from xml.sax.saxutils import escape

ROOT = os.environ.get("PORTHUB_HUBAPP_ROOT", "").rstrip("/")
STATE = os.environ.get("PORTHUB_HUBAPP_STATE") or "/userdata/system/knulli-port-hub/apps"
ES = os.environ.get("PORTHUB_ES_URL", "http://127.0.0.1:1234")
LOCAL_ZIP = os.environ.get("PORTHUB_HUBAPP_ZIP", "")
UA = "Knulli-Port-Hub"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")


class Fail(Exception):
    pass


def say(*a):
    print(*a, flush=True)


def real(p):
    """caminho do manifesto -> caminho no disco (com o prefixo de teste)"""
    return ROOT + p if ROOT else p


def jload(p, d=None):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return d


def jsave(p, o):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    t = p + ".tmp"
    with open(t, "w", encoding="utf-8") as f:
        json.dump(o, f, indent=1, ensure_ascii=False)
    os.replace(t, p)


def safe_name(n, what):
    n = str(n or "")
    if not n or "/" in n or n in (".", "..") or "\\" in n or "\0" in n:
        raise Fail("%s invalido: %r" % (what, n))
    return n


def rel_menu(n, what):
    """./Tubo.sh ou ./images/tubo-image.png (ate 1 subpasta, sem '..')"""
    n = str(n or "")
    m = re.match(r"^\./([^/]+(?:/[^/]+)?)$", n)
    if not m or ".." in n.split("/"):
        raise Fail("%s invalido: %r" % (what, n))
    return m.group(1)


def check(man):
    """valida o manifesto e devolve os caminhos (no disco) usados"""
    aid = str(man.get("id") or "")
    if not ID_RE.match(aid):
        raise Fail("id invalido: %r" % aid)
    ins = man.get("install") or {}
    dest = os.path.normpath(str(ins.get("destination") or ""))
    if not dest.startswith("/userdata/system/") or dest.count("/") < 4:
        raise Fail("pasta do app fora de /userdata/system/<pasta>/<app>: %r" % dest)
    p = {"id": aid, "dest": real(dest), "dest_v": dest,
         "launcher": safe_name(ins.get("launcher"), "launcher"), "keep": []}
    for k in ins.get("keep") or []:
        p["keep"].append(safe_name(k, "keep"))
    menu = ins.get("menu")
    if isinstance(menu, dict):
        gl = os.path.normpath(str(menu.get("gamelist") or ""))
        if not gl.startswith("/userdata/roms/") or not gl.endswith("/gamelist.xml") or gl.count("/") != 4:
            raise Fail("gamelist fora de /userdata/roms/<sistema>/gamelist.xml: %r" % gl)
        mdir = os.path.dirname(gl)
        p["system"] = os.path.basename(mdir)
        p["gamelist"] = real(gl)
        p["mdir"] = real(mdir)
        p["menu_path"] = "./" + rel_menu(menu.get("path"), "menu.path")
        if not p["menu_path"].endswith(".sh") or "/" in p["menu_path"][2:]:
            raise Fail("menu.path precisa ser ./Nome.sh")
        p["menu_name"] = str(menu.get("name") or man.get("name") or aid)
        p["menu_desc"] = str(menu.get("desc") or man.get("summary") or "")
        if menu.get("image"):
            p["menu_image"] = "./" + rel_menu(menu.get("image"), "menu.image")
            p["image_src"] = safe_name(menu.get("image_src") or os.path.basename(p["menu_image"]), "menu.image_src")
    return p


# --------------------------------------------------------------------------- download

def download(rel, tmpdir):
    url = str(rel.get("url") or "")
    size = int(rel.get("size") or 0)
    sha = str(rel.get("sha256") or "").lower()
    out = os.path.join(tmpdir, "pkg.zip")
    if LOCAL_ZIP:
        shutil.copyfile(LOCAL_ZIP, out)
    else:
        if not url.startswith("https://"):
            raise Fail("o app nao tem link de download (https)")
        say("STEP baixando", url)
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=60) as r, open(out, "wb") as f:
            shutil.copyfileobj(r, f, 256 * 1024)
    got = os.path.getsize(out)
    if size and got != size:
        raise Fail("download incompleto: %d de %d bytes" % (got, size))
    if sha:
        h = hashlib.sha256()
        with open(out, "rb") as f:
            for b in iter(lambda: f.read(1 << 20), b""):
                h.update(b)
        if h.hexdigest() != sha:
            raise Fail("sha256 nao confere (arquivo corrompido ou trocado)")
    elif not LOCAL_ZIP:
        raise Fail("o catalogo nao informou o sha256 do pacote")
    return out


def extract(zpath, to):
    with zipfile.ZipFile(zpath) as z:
        for i in z.infolist():
            n = i.filename
            if n.startswith("/") or "\\" in n or ".." in n.split("/"):
                raise Fail("pacote com caminho inseguro: %r" % n)
            if (i.external_attr >> 16) & 0o170000 == 0o120000:
                raise Fail("pacote com link simbolico: %r" % n)
        z.extractall(to)
        for i in z.infolist():
            mode = (i.external_attr >> 16) & 0o777
            if mode and not i.is_dir():
                os.chmod(os.path.join(to, i.filename), mode | 0o644)


# --------------------------------------------------------------------------- gamelist

def game_xml(p):
    x = ["<game>", "<path>%s</path>" % escape(p["menu_path"]), "<name>%s</name>" % escape(p["menu_name"])]
    if p["menu_desc"]:
        x.append("<desc>%s</desc>" % escape(p["menu_desc"]))
    if p.get("menu_image"):
        x.append("<image>%s</image>" % escape(p["menu_image"]))
        x.append("<thumbnail>%s</thumbnail>" % escape(p["menu_image"]))
    x.append("</game>")
    return x


GAME_RE = re.compile(r"[ \t]*<game\b[^>]*>.*?</game>[ \t]*\r?\n?", re.S)


def gamelist_file(p, add):
    """poe (ou tira) o item no gamelist.xml; outros itens ficam como estao"""
    gl = p["gamelist"]
    try:
        with open(gl, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        if not add:
            return
        text = '<?xml version="1.0"?>\n<gameList>\n</gameList>\n'
    want = p["menu_path"]

    def same(m):
        pm = re.search(r"<path>\s*(.*?)\s*</path>", m.group(0), re.S)
        return pm and pm.group(1).replace("&amp;", "&") in (want, want[2:])

    new, n = GAME_RE.subn(lambda m: "" if same(m) else m.group(0), text)
    if add:
        block = "\t" + "\n\t\t".join(game_xml(p)[:-1]) + "\n\t</game>\n"
        if "</gameList>" in new:
            i = new.rfind("</gameList>")
            new = new[:i] + block + new[i:]
        else:
            new = new.rstrip() + "\n<gameList>\n" + block + "</gameList>\n"
    elif new == text:
        return
    if os.path.exists(gl):
        shutil.copyfile(gl, gl + ".antes-hubapp")
    t = gl + ".tmp"
    with open(t, "w", encoding="utf-8") as f:
        f.write(new)
    os.replace(t, gl)


def es_call(path, body=None):
    if not ES:
        return None
    try:
        req = urllib.request.Request(ES + path, data=body, method="POST" if body is not None else "GET",
                                     headers={"Content-Type": "application/xml"})
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status
    except Exception as e:
        say("STEP EmulationStation:", path, "->", str(e)[:120])
        return None


def gamelist_es(p, add):
    xml = "<gameList>" + "".join(game_xml(p)) + "</gameList>"
    st = es_call(("/addgames/" if add else "/removegames/") + p["system"], xml.encode("utf-8"))
    say("STEP EmulationStation", "addgames" if add else "removegames", p["system"], st)
    return st


# --------------------------------------------------------------------------- acoes

def launcher_text(p):
    return "#!/bin/bash\n# criado pelo Knulli Port Hub (app %s)\nexec bash %s/%s \"$@\"\n" % (
        p["id"], p["dest_v"], p["launcher"])


def install(man, action):
    p = check(man)
    dest = p["dest"]
    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    tmpdir = tempfile.mkdtemp(prefix=".hubapp-%s-" % p["id"], dir=parent)
    old = dest + ".hubapp-old"
    swapped = False
    try:
        z = download(man.get("release") or {}, tmpdir)
        stage = os.path.join(tmpdir, "app")
        os.makedirs(stage)
        say("STEP extraindo")
        extract(z, stage)
        if not os.path.isfile(os.path.join(stage, p["launcher"])):
            raise Fail("o pacote nao tem %s" % p["launcher"])
        img_src = os.path.join(stage, p["image_src"]) if p.get("image_src") else None
        img_tmp = None
        if img_src and os.path.isfile(img_src):
            img_tmp = os.path.join(tmpdir, "cover")
            shutil.move(img_src, img_tmp)
        # dados do app (keep) passam da pasta atual para a nova
        if os.path.isdir(dest):
            for k in p["keep"]:
                src = os.path.join(dest, k)
                if os.path.lexists(src):
                    dst = os.path.join(stage, k)
                    if os.path.lexists(dst):
                        shutil.rmtree(dst) if os.path.isdir(dst) and not os.path.islink(dst) else os.remove(dst)
                    shutil.move(src, dst)
        # troca as pastas
        if os.path.lexists(old):
            shutil.rmtree(old, ignore_errors=True)
        if os.path.isdir(dest):
            os.rename(dest, old)
        swapped = True
        os.rename(stage, dest)
        os.chmod(os.path.join(dest, p["launcher"]), 0o755)
        created = []
        if p.get("mdir"):
            os.makedirs(p["mdir"], exist_ok=True)
            sh = os.path.join(p["mdir"], p["menu_path"][2:])
            with open(sh + ".tmp", "w") as f:
                f.write(launcher_text(p))
            os.chmod(sh + ".tmp", 0o755)
            os.replace(sh + ".tmp", sh)
            created.append(sh)
            if img_tmp and p.get("menu_image"):
                ip = os.path.join(p["mdir"], p["menu_image"][2:])
                os.makedirs(os.path.dirname(ip), exist_ok=True)
                shutil.copyfile(img_tmp, ip + ".tmp")
                os.replace(ip + ".tmp", ip)
                created.append(ip)
            gamelist_file(p, True)
        shutil.rmtree(old, ignore_errors=True)
    except BaseException:
        # desfaz: volta a pasta antiga (com os dados que tinham sido movidos)
        if swapped:
            if os.path.isdir(dest) and os.path.isdir(old):
                for k in p["keep"]:
                    src = os.path.join(dest, k)
                    if os.path.lexists(src) and not os.path.lexists(os.path.join(old, k)):
                        shutil.move(src, os.path.join(old, k))
                shutil.rmtree(dest, ignore_errors=True)
            if os.path.isdir(old):
                os.rename(old, dest)
        elif os.path.isdir(dest) and os.path.isdir(os.path.join(tmpdir, "app")):
            stage = os.path.join(tmpdir, "app")
            for k in p["keep"]:
                src = os.path.join(stage, k)
                if os.path.lexists(src) and not os.path.lexists(os.path.join(dest, k)):
                    shutil.move(src, os.path.join(dest, k))
        raise
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    if p.get("system"):
        gamelist_es(p, True)
    st = {"id": p["id"], "version": str(man.get("version") or ""), "action": action,
          "installed_at": int(time.time()), "destination": p["dest_v"], "created": created,
          "manifest": man}
    jsave(os.path.join(STATE, p["id"] + ".json"), st)
    post = (man.get("install") or {}).get("post_install")
    if isinstance(post, list) and post and all(isinstance(a, str) for a in post):
        say("STEP preparando", " ".join(post))
        try:
            r = subprocess.run(post, cwd=dest, stdin=subprocess.DEVNULL, capture_output=True, timeout=900)
            say("POST", "ok" if r.returncode == 0 else "falhou rc=%d" % r.returncode)
        except Exception as e:
            say("POST falhou:", str(e)[:160])
    say("OK", action, p["id"], st["version"])


def uninstall(man):
    p = check(man)
    st = jload(os.path.join(STATE, p["id"] + ".json"), {}) or {}
    dest = p["dest"]
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    shutil.rmtree(dest + ".hubapp-old", ignore_errors=True)
    if p.get("mdir"):
        targets = [os.path.join(p["mdir"], p["menu_path"][2:])]
        if p.get("menu_image"):
            targets.append(os.path.join(p["mdir"], p["menu_image"][2:]))
        for f in targets:
            if os.path.lexists(f):
                os.remove(f)
        gamelist_file(p, False)
        gamelist_es(p, False)
    for f in st.get("created") or []:
        f = str(f)
        if f.startswith(ROOT + "/userdata/") and os.path.isfile(f):
            os.remove(f)
    try:
        os.remove(os.path.join(STATE, p["id"] + ".json"))
    except FileNotFoundError:
        pass
    say("OK uninstall", p["id"])


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("install", "update", "repair", "uninstall"):
        say("uso: hubapp.py install|update|repair|uninstall MANIFESTO.json")
        return 2
    man = jload(sys.argv[2])
    if not isinstance(man, dict):
        say("ERRO manifesto ilegivel")
        return 2
    try:
        if sys.argv[1] == "uninstall":
            uninstall(man)
        else:
            install(man, sys.argv[1])
        return 0
    except Fail as e:
        say("ERRO", str(e))
    except Exception as e:
        say("ERRO", "%s: %s" % (type(e).__name__, str(e)[:200]))
    return 1


if __name__ == "__main__":
    sys.exit(main())
