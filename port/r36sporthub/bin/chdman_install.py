#!/usr/bin/env python3
# =============================================================================
#  Knulli Port Hub - instalador do chdman (MAME) a partir do Debian oficial
#
#  O Knulli nao traz o chdman. Este script baixa os pacotes .deb listados em
#  chdman_debs.json (ao lado deste arquivo) direto de deb.debian.org, confere o
#  tamanho e o SHA256 de cada um (os valores vem do indice Packages.xz do
#  Debian 12 "bookworm", arm64), abre o .deb (formato ar + data.tar.xz) sem
#  precisar de ar/dpkg e copia SO o que e necessario (usr/bin/chdman e as bibliotecas que faltam):
#
#    <dest>/bin/chdman          o programa (pacote mame-tools)
#    <dest>/lib/*.so.*          bibliotecas que o Knulli nao tem (libutf8proc)
#    <dest>/chdman.sh           wrapper: LD_LIBRARY_PATH so com <dest>/lib
#    <dest>/licenses/<pacote>   arquivos de copyright dos pacotes
#    <dest>/installed.json      o que foi instalado (versoes, data)
#
#  As demais bibliotecas (libc, libstdc++, libgcc_s, libz, libFLAC) ja vem no
#  Knulli (glibc 2.40 >= 2.36 do bookworm). A instalacao e feita numa pasta
#  temporaria ao lado e so troca a antiga depois de "chdman --help" funcionar.
#
#  Uso:
#    python3 chdman_install.py [--dest DIR] [--manifest ARQ]   instala/atualiza
#    python3 chdman_install.py --uninstall [--dest DIR]          remove
#    python3 chdman_install.py --check [--dest DIR]              so confere
#  Saida para o app (uma por linha):
#    PROGRESS <feito> <total> <texto>   (bytes baixados)
#    STEP <texto>
#    OK <versao>        |   ERRO <mensagem>   (codigo de saida 1)
# =============================================================================
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request

DEFAULT_DEST = "/userdata/system/knulli-port-hub/tools/chdman"
HERE = os.path.dirname(os.path.abspath(__file__))
UA = "KnulliPortHub-chdman-installer"


def out(*a):
    print(*a, flush=True)


def fail(msg):
    out("ERRO " + str(msg).replace("\n", " "))
    sys.exit(1)


def wrapper_text():
    # LD_LIBRARY_PATH so com a pasta do chdman: o LOVE (e outros apps) exporta
    # as bibliotecas dele, que nao devem vazar para o chdman
    return (
        "#!/bin/sh\n"
        "# chdman do Debian (instalado pelo Knulli Port Hub)\n"
        "D=\"$(dirname \"$(readlink -f \"$0\")\")\"\n"
        "LD_LIBRARY_PATH=\"$D/lib\" exec \"$D/bin/chdman\" \"$@\"\n"
    )


def free_bytes(path):
    p = path
    while p and not os.path.exists(p):
        p = os.path.dirname(p)
    st = os.statvfs(p or "/")
    return st.f_bavail * st.f_frsize


def download(url, dst, size, done0, total):
    """baixa url -> dst com progresso. Tenta urllib; se falhar (SSL...), curl."""
    last = [0.0]

    def prog(n):
        now = time.time()
        if now - last[0] >= 0.3 or n >= size:
            last[0] = now
            out("PROGRESS %d %d %s" % (done0 + n, total, os.path.basename(url)))

    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=60) as r, open(dst, "wb") as f:
            n = 0
            while True:
                b = r.read(65536)
                if not b:
                    break
                f.write(b)
                n += len(b)
                prog(n)
        return
    except Exception as e:  # noqa: BLE001 - qualquer falha: tenta o curl
        out("STEP urllib falhou (%s); tentando curl" % e)
    p = subprocess.Popen(["curl", "-fsSL", "--retry", "2", "--connect-timeout", "20",
                          "-A", UA, "-o", dst, url])
    while p.poll() is None:
        try:
            prog(os.path.getsize(dst))
        except OSError:
            pass
        time.sleep(0.5)
    if p.returncode != 0:
        raise RuntimeError("download falhou (curl %d): %s" % (p.returncode, url))


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def ar_members(path):
    """membros de um arquivo ar (formato do .deb): nome -> bytes"""
    res = {}
    with open(path, "rb") as f:
        if f.read(8) != b"!<arch>\n":
            raise RuntimeError("não é um pacote .deb: " + path)
        while True:
            hdr = f.read(60)
            if len(hdr) < 60:
                break
            name = hdr[0:16].decode("ascii", "replace").strip().rstrip("/")
            size = int(hdr[48:58].decode("ascii").strip())
            data = f.read(size)
            if size % 2:
                f.read(1)
            res[name] = data
    return res


def open_data_tar(members):
    for name, data in members.items():
        if name.startswith("data.tar"):
            if name.endswith(".xz"):
                mode = "r:xz"
            elif name.endswith(".gz"):
                mode = "r:gz"
            elif name.endswith(".bz2"):
                mode = "r:bz2"
            elif name == "data.tar":
                mode = "r:"
            else:
                raise RuntimeError("compressão não suportada: " + name)
            return tarfile.open(fileobj=io.BytesIO(data), mode=mode)
    raise RuntimeError("data.tar não encontrado no .deb")


def norm(n):
    return n[2:] if n.startswith("./") else n


def extract_file(tf, want):
    """conteudo de um arquivo do tar (segue links simbolicos dentro do tar)"""
    index = {norm(m.name): m for m in tf.getmembers()}
    name = want
    for _ in range(10):
        m = index.get(name)
        if m is None:
            raise RuntimeError("arquivo não encontrado no pacote: " + want)
        if m.issym():
            base = os.path.dirname(name)
            name = os.path.normpath(os.path.join(base, m.linkname)) if not m.linkname.startswith("/") \
                else m.linkname.lstrip("/")
            continue
        if m.islnk():
            name = norm(m.linkname)
            continue
        if not m.isfile():
            raise RuntimeError("não é um arquivo: " + want)
        return tf.extractfile(m).read()
    raise RuntimeError("links demais: " + want)


def copyright_of(tf, pkg):
    for cand in ("usr/share/doc/%s/copyright" % pkg,):
        try:
            return extract_file(tf, cand)
        except RuntimeError:
            pass
    for m in tf.getmembers():
        if norm(m.name).endswith("/copyright") and m.isfile():
            return tf.extractfile(m).read()
    return None


def run_help(dest):
    try:
        r = subprocess.run([os.path.join(dest, "chdman.sh"), "--help"], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=30)
    except Exception as e:  # noqa: BLE001
        return False, str(e)
    text = r.stdout.decode("utf-8", "replace")
    # o chdman --help sai com codigo diferente de 0; o que vale e o texto
    ok = "chdman - MAME Compressed Hunks of Data" in text and "createcd" in text
    return ok, text


def missing_libs(dest):
    env = dict(os.environ, LD_LIBRARY_PATH=os.path.join(dest, "lib"))
    try:
        r = subprocess.run(["ldd", os.path.join(dest, "bin", "chdman")], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, env=env, timeout=20)
    except Exception:  # noqa: BLE001
        return []
    return [l.split()[0] for l in r.stdout.decode("utf-8", "replace").splitlines() if "not found" in l]


def safe_dest(dest):
    d = os.path.abspath(dest)
    if d in ("/", "/userdata", "/userdata/system") or len(d) < 12 or not d.rstrip("/").endswith("chdman"):
        fail("pasta de destino recusada: " + d)
    return d


def install(dest, manifest_path):
    try:
        with open(manifest_path, encoding="utf-8") as f:
            man = json.load(f)
    except Exception as e:  # noqa: BLE001
        fail("manifesto ilegível (%s): %s" % (manifest_path, e))
    debs = man.get("debs") or []
    total = sum(int(d.get("size") or 0) for d in debs)
    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    need = total * 4 + 16 * 1024 * 1024
    if free_bytes(parent) < need:
        fail("espaço insuficiente em %s (precisa de %d MB)" % (parent, need // (1 << 20)))
    work = dest + ".download"
    new = dest + ".new"
    for d in (work, new):
        shutil.rmtree(d, ignore_errors=True)
    os.makedirs(work)
    os.makedirs(os.path.join(new, "bin"))
    os.makedirs(os.path.join(new, "lib"))
    os.makedirs(os.path.join(new, "licenses"))
    try:
        done = 0
        files = []
        for d in debs:
            url, size, sha = d["url"], int(d["size"]), d["sha256"].lower()
            if not url.startswith("https://deb.debian.org/debian/pool/"):
                raise RuntimeError("endereço fora do repositório oficial do Debian: " + url)
            local = os.path.join(work, os.path.basename(url))
            out("STEP baixando " + d["package"] + " " + d["version"])
            download(url, local, size, done, total)
            got = os.path.getsize(local)
            if got != size:
                raise RuntimeError("%s: tamanho %d, esperado %d" % (d["package"], got, size))
            h = sha256_of(local)
            if h != sha:
                raise RuntimeError("%s: SHA256 não confere (%s)" % (d["package"], h))
            done += size
            out("PROGRESS %d %d %s" % (done, total, d["package"]))
            files.append((d, local))
        binrel = man.get("bin") or "usr/bin/chdman"
        for d, local in files:
            out("STEP extraindo " + d["package"])
            tf = open_data_tar(ar_members(local))
            for want in d.get("take") or []:
                data = extract_file(tf, want)
                if want == binrel:
                    dst = os.path.join(new, "bin", "chdman")
                else:
                    dst = os.path.join(new, "lib", os.path.basename(want))
                with open(dst, "wb") as f:
                    f.write(data)
                os.chmod(dst, 0o755)
            cp = copyright_of(tf, d["package"])
            if cp:
                with open(os.path.join(new, "licenses", d["package"] + ".copyright"), "wb") as f:
                    f.write(cp)
            tf.close()
        if not os.path.exists(os.path.join(new, "bin", "chdman")):
            raise RuntimeError("o chdman não veio nos pacotes")
        with open(os.path.join(new, "chdman.sh"), "w") as f:
            f.write(wrapper_text())
        os.chmod(os.path.join(new, "chdman.sh"), 0o755)
        with open(os.path.join(new, "licenses", "README.txt"), "w", encoding="utf-8") as f:
            f.write("chdman faz parte do MAME (GPL-2.0-or-later / BSD-3-Clause). Binários dos pacotes\n"
                    "oficiais do Debian (%s). Fontes: https://sources.debian.org/src/mame/\n"
                    % man.get("source", "Debian"))
        out("STEP conferindo o chdman")
        miss = missing_libs(new)
        if miss:
            raise RuntimeError("bibliotecas faltando: " + ", ".join(miss))
        ok, text = run_help(new)
        if not ok:
            raise RuntimeError("o chdman não abriu: " + text.strip()[:300])
        first = text.strip().splitlines()[0] if text.strip() else ""
        info = {
            "chdman": first,
            "version": man.get("chdman_version", ""),
            "source": man.get("source", ""),
            "packages": [{"package": d["package"], "version": d["version"], "sha256": d["sha256"]} for d, _ in files],
            "installed": time.strftime("%Y-%m-%d %H:%M:%S"),
            "download_bytes": total,
        }
        with open(os.path.join(new, "installed.json"), "w", encoding="utf-8") as f:
            json.dump(info, f, ensure_ascii=False, indent=1)
        # troca: antiga -> .old, nova -> dest
        old = dest + ".old"
        shutil.rmtree(old, ignore_errors=True)
        if os.path.exists(dest):
            os.rename(dest, old)
        os.rename(new, dest)
        shutil.rmtree(old, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
        out("OK " + (first or info["version"]))
    except Exception as e:  # noqa: BLE001
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(new, ignore_errors=True)
        fail(e)


def main():
    args = sys.argv[1:]
    dest, manifest = DEFAULT_DEST, os.path.join(HERE, "chdman_debs.json")
    mode = "install"
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--dest" and i + 1 < len(args):
            dest = args[i + 1]; i += 1
        elif a == "--manifest" and i + 1 < len(args):
            manifest = args[i + 1]; i += 1
        elif a == "--uninstall":
            mode = "uninstall"
        elif a == "--check":
            mode = "check"
        else:
            fail("argumento desconhecido: " + a)
        i += 1
    dest = safe_dest(dest)
    if mode == "uninstall":
        for d in (dest, dest + ".new", dest + ".old", dest + ".download"):
            shutil.rmtree(d, ignore_errors=True)
        out("OK removido")
        return
    if mode == "check":
        if not os.path.exists(os.path.join(dest, "chdman.sh")):
            fail("não instalado")
        ok, text = run_help(dest)
        if not ok:
            fail("o chdman não abriu: " + text.strip()[:300])
        out("OK " + text.strip().splitlines()[0])
        return
    install(dest, manifest)


if __name__ == "__main__":
    main()
