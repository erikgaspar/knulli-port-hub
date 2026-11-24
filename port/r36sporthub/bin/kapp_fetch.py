#!/usr/bin/env python3
# =============================================================================
#  Knulli Port Hub - copia do instalador da Knulli App Store (Apps do Knulli)
#
#  O hub instala/atualiza/remove os apps do Knulli pelo instalador da propria
#  Knulli App Store (knulli-app, projeto da comunidade jellydn/knulli-app-store,
#  licenca MIT). Para funcionar sem a loja instalada em ports, o hub mantem uma
#  copia so com o necessario, sempre da MESMA release oficial do GitHub:
#
#    <dest>/knulli-app               instalador (CLI)
#    <dest>/catalog-index.json       lista assinada de apps
#    <dest>/catalog-index.json.sig   assinatura ed25519 da lista
#    <dest>/README.txt               leia-me da release
#    <dest>/LICENSE                  licenca do projeto (MIT), da mesma tag
#    <dest>/installed.json           tag, data, asset, tamanho e sha256
#
#  A release publica um ZIP unico (com a interface grafica knulli-app-ui,
#  ~31 MB descompactada, que o hub nao usa) e o SHA256SUMS.txt. O ZIP e baixado
#  uma vez para uma pasta temporaria ao lado de <dest>, conferido (tamanho e
#  sha256 informados pela API do GitHub e pelo SHA256SUMS.txt da release) e so
#  os 4 arquivos acima sao extraidos (o resto e descartado). A copia nova fica
#  em <dest>.new e so troca a antiga (rename) depois de "knulli-app --help"
#  responder e de "knulli-app validate" aceitar os manifestos da lista nova.
#
#  Assinatura: o knulli-app (CLI) so GERA a assinatura (catalogue
#  -signing-key); quem a confere e a interface grafica (knulli-app-ui, chave
#  publica embutida), que o hub nao usa. Aqui a confianca vem do download
#  HTTPS da release oficial (URL do proprio repositorio), do sha256 publicado
#  e de nunca misturar binario, lista e assinatura de builds diferentes.
#
#  Uso:
#    python3 -I kapp_fetch.py [--dest DIR] [--force] [--progress ARQ]  baixa/atualiza
#    python3 -I kapp_fetch.py --check [--dest DIR]                     so consulta
#  Saida para o app (uma por linha):
#    LATEST <tag> <bytes do zip> <publicada em>
#    CURRENT <tag>  (copia ja esta na release mais nova)
#    OK <tag> updated|current   |   ERRO <mensagem>   (codigo de saida 1)
#  --progress: grava "<feito> <total>" (bytes) nesse arquivo durante o download.
# =============================================================================
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile

DEFAULT_DEST = "/userdata/system/knulli-port-hub/tools/knulli-app"
OWNER_REPO = "jellydn/knulli-app-store"
API = "https://api.github.com/repos/%s/releases?per_page=15" % OWNER_REPO
DL_PREFIX = "https://github.com/%s/releases/download/" % OWNER_REPO
ASSET_RE = re.compile(r"^knulli-app-store-knulli-aarch64-glibc-sdl2-experimental-[A-Za-z0-9._-]+\.zip$")
UA = "KnulliPortHub-kapp-fetch"
# arquivos que o hub usa (nome dentro do zip -> nome na copia)
MEMBERS = {
    "knulli-app-store/knulli-app": "knulli-app",
    "knulli-app-store/catalog-index.json": "catalog-index.json",
    "knulli-app-store/catalog-index.json.sig": "catalog-index.json.sig",
    "knulli-app-store/README.txt": "README.txt",
}
MAX_ZIP = 200 * 1024 * 1024
MAX_MEMBER = 64 * 1024 * 1024


def out(*a):
    print(*a, flush=True)


def fail(msg):
    out("ERRO " + str(msg).replace("\n", " "))
    sys.exit(1)


def http_get(url, timeout=30):
    """conteudo pequeno (API, SHA256SUMS, LICENSE). urllib; se falhar, curl"""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read(8 * 1024 * 1024)
    except Exception:  # noqa: BLE001 - tenta o curl
        p = subprocess.run(["curl", "-fsSL", "--connect-timeout", "20", "-m", str(timeout + 30),
                            "-A", UA, "-H", "Accept: application/vnd.github+json", url],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if p.returncode != 0:
            raise RuntimeError("falha ao acessar %s (curl %d)" % (url, p.returncode))
        return p.stdout


def write_progress(path, done, total):
    if not path:
        return
    try:
        with open(path + ".t", "w") as f:
            f.write("%d %d\n" % (done, total))
        os.replace(path + ".t", path)
    except OSError:
        pass


def download(url, dst, size, progress):
    """baixa url -> dst (curl segue o redirecionamento do GitHub)"""
    p = subprocess.Popen(["curl", "-fsSL", "--retry", "2", "--connect-timeout", "20",
                          "-A", UA, "-o", dst, url])
    while p.poll() is None:
        try:
            write_progress(progress, os.path.getsize(dst), size)
        except OSError:
            pass
        time.sleep(0.4)
    if p.returncode != 0:
        raise RuntimeError("download falhou (curl %d)" % p.returncode)
    write_progress(progress, size, size)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def latest_release():
    """release mais nova (inclui pre-releases oficiais, como o atualizador da
    propria loja; ignora rascunhos) que tenha o ZIP do perfil aarch64"""
    try:
        rels = json.loads(http_get(API).decode("utf-8"))
    except Exception as e:  # noqa: BLE001
        raise RuntimeError("não consegui consultar as releases no GitHub: %s" % e)
    if not isinstance(rels, list):
        raise RuntimeError("resposta inesperada da API do GitHub")
    for r in rels:
        if not isinstance(r, dict) or r.get("draft"):
            continue
        tag = str(r.get("tag_name") or "")
        if not re.match(r"^[A-Za-z0-9._-]+$", tag):
            continue
        assets = r.get("assets") or []
        z = sums = None
        for a in assets:
            name = str(a.get("name") or "")
            url = str(a.get("browser_download_url") or "")
            if not url.startswith(DL_PREFIX + tag + "/"):
                continue
            if ASSET_RE.match(name) and z is None:
                z = a
            elif name == "SHA256SUMS.txt":
                sums = a
        if z:
            return {"tag": tag, "published_at": str(r.get("published_at") or ""),
                    "prerelease": bool(r.get("prerelease")), "zip": z, "sums": sums}
    raise RuntimeError("nenhuma release do GitHub traz o pacote aarch64 da Knulli App Store")


def expected_sha(rel):
    """sha256 do zip: o 'digest' da API e o SHA256SUMS.txt (os dois, se houver,
    precisam bater). Sem nenhum dos dois: recusa"""
    z = rel["zip"]
    shas = []
    dg = str(z.get("digest") or "")
    if dg.startswith("sha256:") and re.match(r"^[0-9a-f]{64}$", dg[7:]):
        shas.append(dg[7:])
    if rel["sums"]:
        try:
            txt = http_get(rel["sums"]["browser_download_url"]).decode("utf-8", "replace")
            for line in txt.splitlines():
                m = re.match(r"^([0-9a-fA-F]{64})\s+\*?(\S.*)$", line.strip())
                if m and m.group(2).strip() == z["name"]:
                    shas.append(m.group(1).lower())
        except Exception as e:  # noqa: BLE001
            out("STEP SHA256SUMS.txt indisponível (%s)" % e)
    if not shas:
        raise RuntimeError("a release não publica o SHA-256 do pacote; download recusado")
    if len(set(shas)) != 1:
        raise RuntimeError("o SHA-256 da API e o do SHA256SUMS.txt não batem; download recusado")
    return shas[0]


def read_installed(dest):
    try:
        with open(os.path.join(dest, "installed.json")) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def copy_ok(dest):
    return all(os.path.isfile(os.path.join(dest, n)) for n in MEMBERS.values())


def extract(zpath, new):
    """extrai so os arquivos de MEMBERS (confere CRC ao ler; nada de links)"""
    with zipfile.ZipFile(zpath) as zf:
        names = {i.filename: i for i in zf.infolist()}
        for src, dst in MEMBERS.items():
            info = names.get(src)
            if info is None:
                raise RuntimeError("o pacote não traz %s" % src)
            if info.file_size > MAX_MEMBER or info.is_dir():
                raise RuntimeError("item inesperado no pacote: %s" % src)
            mode = (info.external_attr >> 16) & 0o170000
            if mode and mode != 0o100000:
                raise RuntimeError("item não é arquivo comum: %s" % src)
            target = os.path.join(new, dst)
            with zf.open(info) as r, open(target, "wb") as w:
                shutil.copyfileobj(r, w, 1 << 20)
            # mesma data do zip (o hub compara com a loja instalada pela data da lista)
            t = time.mktime(info.date_time + (0, 0, -1))
            os.utime(target, (t, t))
    os.chmod(os.path.join(new, "knulli-app"), 0o755)


def check_copy(new):
    """o binario roda, a lista e a assinatura sao da forma esperada e o
    validate do proprio knulli-app aceita os manifestos da lista"""
    ka = os.path.join(new, "knulli-app")
    p = subprocess.run([ka, "--help"], cwd=new, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    if b"Knulli App Store installer core" not in p.stdout:
        raise RuntimeError("o knulli-app baixado não respondeu ao --help")
    with open(os.path.join(new, "catalog-index.json")) as f:
        cat = json.load(f)
    if cat.get("schema") != "org.knulli.app-store/catalog-index/v1" or not isinstance(cat.get("packages"), list):
        raise RuntimeError("lista de apps em formato desconhecido")
    with open(os.path.join(new, "catalog-index.json.sig")) as f:
        sig = json.load(f)
    if sig.get("schema") != "org.knulli.app-store/catalog-signature/v1" or sig.get("algorithm") != "ed25519" \
            or not re.match(r"^[0-9a-f]{128}$", str(sig.get("signature") or "")):
        raise RuntimeError("assinatura da lista em formato desconhecido")
    total, ok = 0, 0
    tmp = os.path.join(new, ".validate.json")
    for e in cat["packages"]:
        pkg = e.get("package") if isinstance(e, dict) else None
        if not isinstance(pkg, dict):
            continue
        total += 1
        with open(tmp, "w") as f:
            json.dump(pkg, f)
        r = subprocess.run([ka, "validate", tmp], cwd=new, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        if r.returncode == 0:
            ok += 1
    try:
        os.remove(tmp)
    except OSError:
        pass
    if total == 0 or ok == 0:
        raise RuntimeError("o knulli-app não aceitou os manifestos da lista nova")
    return total, ok


def main():
    args = sys.argv[1:]
    dest = DEFAULT_DEST
    progress = None
    if "--dest" in args:
        dest = args[args.index("--dest") + 1]
    if "--progress" in args:
        progress = args[args.index("--progress") + 1]
    dest = os.path.abspath(dest)
    try:
        rel = latest_release()
    except Exception as e:  # noqa: BLE001
        fail(e)
    z = rel["zip"]
    size = int(z.get("size") or 0)
    out("LATEST %s %d %s" % (rel["tag"], size, rel["published_at"]))
    cur = read_installed(dest)
    if cur.get("tag") == rel["tag"] and copy_ok(dest) and "--force" not in args:
        out("CURRENT " + rel["tag"])
        out("OK %s current" % rel["tag"])
        return
    if "--check" in args:
        return
    if size <= 0 or size > MAX_ZIP:
        fail("tamanho do pacote inesperado (%d bytes)" % size)

    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    # uma execucao por vez
    lock = open(os.path.join(parent, ".knulli-app.lock"), "w")
    try:
        import fcntl
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (ImportError, OSError):
        fail("outra atualização da lista de apps já está em andamento")
    st = os.statvfs(parent)
    if st.f_bavail * st.f_frsize < size + 16 * 1024 * 1024:
        fail("espaço livre insuficiente em %s" % parent)

    work = dest + ".dl"
    new = dest + ".new"
    old = dest + ".old"
    for d in (work, new):
        shutil.rmtree(d, ignore_errors=True)
    os.makedirs(work)
    os.makedirs(new)
    try:
        sha = expected_sha(rel)
        zpath = os.path.join(work, "pkg.zip")
        out("STEP baixando %s" % z["name"])
        download(z["browser_download_url"], zpath, size, progress)
        got = os.path.getsize(zpath)
        if got != size:
            raise RuntimeError("tamanho do download não confere (%d de %d bytes)" % (got, size))
        if sha256_of(zpath) != sha:
            raise RuntimeError("SHA-256 do download não confere")
        if not zipfile.is_zipfile(zpath):
            raise RuntimeError("o download não é um ZIP válido")
        out("STEP extraindo")
        extract(zpath, new)
        shutil.rmtree(work, ignore_errors=True)   # descarta o zip (interface grafica etc.)
        # licenca do projeto na mesma tag (opcional)
        try:
            lic = http_get("https://raw.githubusercontent.com/%s/%s/LICENSE" % (OWNER_REPO, rel["tag"]), 20)
            if lic and len(lic) < 256 * 1024:
                with open(os.path.join(new, "LICENSE"), "wb") as f:
                    f.write(lic)
        except Exception:  # noqa: BLE001
            out("STEP LICENSE indisponível (o projeto é MIT)")
        out("STEP conferindo")
        total, ok = check_copy(new)
        info = {
            "schema": "knulli-port-hub/knulli-app-copy/v1",
            "source": "https://github.com/" + OWNER_REPO,
            "tag": rel["tag"], "published_at": rel["published_at"], "prerelease": rel["prerelease"],
            "asset": z["name"], "url": z["browser_download_url"], "size": size, "sha256": sha,
            "files": {n: sha256_of(os.path.join(new, n)) for n in sorted(os.listdir(new))},
            "validated": "%d/%d" % (ok, total),
            "installed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        with open(os.path.join(new, "installed.json"), "w") as f:
            json.dump(info, f, indent=2)
        # troca atomica: antiga -> .old, nova -> dest; desfaz se o segundo rename falhar
        shutil.rmtree(old, ignore_errors=True)
        had = os.path.isdir(dest)
        if had:
            os.rename(dest, old)
        try:
            os.rename(new, dest)
        except OSError:
            if had:
                os.rename(old, dest)
            raise
        shutil.rmtree(old, ignore_errors=True)
    except Exception as e:  # noqa: BLE001
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(new, ignore_errors=True)
        fail(e)
    finally:
        if progress:
            try:
                os.remove(progress)
            except OSError:
                pass
    out("OK %s updated" % rel["tag"])


if __name__ == "__main__":
    main()
