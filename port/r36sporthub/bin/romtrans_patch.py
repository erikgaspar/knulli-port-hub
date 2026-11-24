#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# =============================================================================
#  Knulli Port Hub - traducoes de ROMs: hashes, varredura e aplicadores
#  (chamado por src/core/romtrans.lua; so biblioteca padrao do python3)
#
#  Uso:
#    romtrans_patch.py hash <arquivo>...                -> 1 JSON por linha
#    romtrans_patch.py scan <pedido.json> <saida.json>  -> progresso "P\ti\tn\tnome"
#    romtrans_patch.py zipget <zip> <membro> <saida>
#    romtrans_patch.py zipput <zip> <membro> <novo> <saida.zip>
#    romtrans_patch.py pick <zip|pasta> <patch_file> <formato> <saida>
#    romtrans_patch.py strip512 <entrada> <saida>
#    romtrans_patch.py apply <ips|bps|ups|ppf|aps|xdelta> <rom> <patch> <saida> [--force]
#
#  Saida: "OK ..." e codigo 0; erro: "ERRO: motivo" em stderr e codigo 2.
#  Formatos:
#    IPS  - com RLE e o truncamento opcional depois de "EOF" (ate 16 MB)
#    BPS  - confere CRC32 da ROM de origem, do resultado e do proprio patch
#    UPS  - confere CRC32 (aceita aplicar no sentido inverso, como o formato preve)
#    PPF  - v1, v2 (confere bloco de validacao) e v3 (bloco/undo/FILE_ID.DIZ)
#    APS  - so o APS de N64 ("APS10"), confere ID/CRC do cartucho
#    xdelta (VCDIFF) - usa o xdelta3 do sistema; sem ele, decodificador proprio
#           (sem compressao secundaria nem tabela de codigos propria)
# =============================================================================
import hashlib
import json
import mmap
import os
import shutil
import struct
import subprocess
import sys
import zipfile
import zlib

BUF = 1 << 20


class PatchError(Exception):
    pass


def fail(msg):
    raise PatchError(msg)


# -----------------------------------------------------------------------------
# hashes
# -----------------------------------------------------------------------------
class Hasher:
    def __init__(self):
        self.crc = 0
        self.md5 = hashlib.md5()
        self.sha1 = hashlib.sha1()
        self.size = 0

    def update(self, b):
        self.crc = zlib.crc32(b, self.crc)
        self.md5.update(b)
        self.sha1.update(b)
        self.size += len(b)

    def result(self):
        return {"size": self.size, "crc32": "%08x" % (self.crc & 0xFFFFFFFF),
                "md5": self.md5.hexdigest(), "sha1": self.sha1.hexdigest()}


def hash_stream(f, total=None):
    """hashes do arquivo inteiro e, se o tamanho for 1024*n + 512 (header de
    copiadora SNES/SMC), tambem sem os 512 primeiros bytes (chave 'h512')."""
    full = Hasher()
    noh = None
    first = True
    while True:
        b = f.read(BUF)
        if not b:
            break
        if first:
            first = False
            if total is not None and total % 1024 == 512 and total > 512:
                noh = Hasher()
                full.update(b)
                noh.update(b[512:])
                continue
        full.update(b)
        if noh is not None:
            noh.update(b)
    r = full.result()
    if noh is not None:
        r["h512"] = noh.result()
    return r


def hash_file(path):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        r = hash_stream(f, size)
    r["path"] = path
    return r


def crc_file(path):
    c = 0
    with open(path, "rb") as f:
        while True:
            b = f.read(BUF)
            if not b:
                break
            c = zlib.crc32(b, c)
    return c & 0xFFFFFFFF


def cmd_hash(args):
    for p in args:
        try:
            print(json.dumps(hash_file(p)))
        except OSError as e:
            print(json.dumps({"path": p, "error": str(e)}))
    return 0


# -----------------------------------------------------------------------------
# varredura (com cache por caminho + tamanho + mtime)
# -----------------------------------------------------------------------------
SKIP_DIRS = {"images", "videos", "media", "manuals", "downloaded_images", "downloaded_videos",
             "snap", "snaps", "boxart", "wheel", "marquee", "screenshots", "titles", "bezels"}
SKIP_EXT = {"xml", "txt", "png", "jpg", "jpeg", "gif", "bmp", "webp", "mp4", "mkv", "avi", "pdf",
            "srm", "sav", "state", "auto", "cfg", "ini", "json", "m3u", "cue", "gdi", "ccd", "sub",
            "nfo", "dat", "db", "log", "sh", "md", "htm", "html", "lst", "bak", "tmp", "ips", "bps",
            "ups", "ppf", "xdelta", "aps", "7z", "rar"}


def write_json_atomic(path, data):
    tmp = path + ".tmp"
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def cmd_scan(args):
    """pedido = { root, systems: [ {sys, sizes: [..], any_size} ], cache, maxfull, cancel }"""
    req = json.load(open(args[0], encoding="utf-8"))
    out_path = args[1]
    root = req["root"]
    maxfull = int(req.get("maxfull") or 64 * 1024 * 1024)
    cancel = req.get("cancel") or ""
    cache_path = req.get("cache") or ""
    cache = {}
    if cache_path and os.path.exists(cache_path):
        try:
            cache = json.load(open(cache_path, encoding="utf-8"))
            if not isinstance(cache, dict) or cache.get("format") != 1:
                cache = {}
        except Exception:
            cache = {}
    entries = cache.get("files", {}) if cache else {}
    new_entries = {}
    files = []
    for s in req.get("systems", []):
        sysname = s["sys"]
        base = os.path.join(root, sysname)
        if not os.path.isdir(base):
            continue
        sizes = set(int(x) for x in s.get("sizes", []))
        any_size = bool(s.get("any_size"))
        sig = "any" if any_size else hashlib.md5(",".join(str(x) for x in sorted(sizes)).encode()).hexdigest()[:12]
        for dirpath, dirnames, filenames in os.walk(base):
            depth = dirpath[len(base):].count(os.sep)
            dirnames[:] = [d for d in dirnames if not d.startswith(".") and d.lower() not in SKIP_DIRS
                           and depth < 2]
            for fn in filenames:
                if fn.startswith(".") or fn.startswith("gamelist"):
                    continue
                ext = fn.rsplit(".", 1)[-1].lower() if "." in fn else ""
                if ext in SKIP_EXT:
                    continue
                full = os.path.join(dirpath, fn)
                files.append((sysname, full, os.path.relpath(full, base), sizes, any_size, sig))
    n = len(files)
    result = []
    errors = []
    for i, (sysname, full, rel, sizes, any_size, sig) in enumerate(files):
        if cancel and os.path.exists(cancel):
            break
        sys.stdout.write("P\t%d\t%d\t%s/%s\n" % (i, n, sysname, rel))
        sys.stdout.flush()
        try:
            st = os.stat(full)
        except OSError as e:
            errors.append("%s: %s" % (full, e))
            continue
        key = full
        c = entries.get(key)
        want = lambda sz: any_size or sz in sizes or (sz % 1024 == 512 and (sz - 512) in sizes)
        if c and c.get("size") == st.st_size and c.get("mtime") == int(st.st_mtime) \
                and c.get("maxfull") == maxfull and c.get("sig") == sig:
            rec = c
        else:
            rec = {"size": st.st_size, "mtime": int(st.st_mtime), "maxfull": maxfull, "sig": sig}
            try:
                if full.lower().endswith(".zip"):
                    rec["kind"] = "zip"
                    ents = []
                    with zipfile.ZipFile(full) as z:
                        for zi in z.infolist():
                            if zi.is_dir():
                                continue
                            e = {"name": zi.filename, "size": zi.file_size, "crc32": "%08x" % zi.CRC}
                            if zi.file_size <= maxfull and want(zi.file_size):
                                with z.open(zi) as zf:
                                    h = hash_stream(zf, zi.file_size)
                                e.update(h)
                            ents.append(e)
                    rec["entries"] = ents
                else:
                    rec["kind"] = "file"
                    if want(st.st_size) and (st.st_size <= maxfull or st.st_size in sizes
                                             or (st.st_size % 1024 == 512 and (st.st_size - 512) in sizes)):
                        with open(full, "rb") as f:
                            rec.update(hash_stream(f, st.st_size))
                        rec["size"] = st.st_size
            except (OSError, zipfile.BadZipFile, RuntimeError, NotImplementedError) as e:
                errors.append("%s: %s" % (full, e))
                rec = {"size": st.st_size, "mtime": int(st.st_mtime), "kind": "error", "error": str(e)}
        new_entries[key] = rec
        r = dict(rec)
        r["sys"] = sysname
        r["rel"] = rel.replace(os.sep, "/")
        r["path"] = full
        result.append(r)
    cancelled = bool(cancel and os.path.exists(cancel))
    # o cache guarda tambem o que nao foi visto agora (outros sistemas)
    for k, v in entries.items():
        if k not in new_entries and os.path.exists(k):
            new_entries[k] = v
    if cache_path:
        try:
            write_json_atomic(cache_path, {"format": 1, "files": new_entries})
        except OSError as e:
            errors.append("cache: %s" % e)
    write_json_atomic(out_path, {"files": result, "errors": errors, "cancelled": cancelled, "total": n})
    print("R\t%d" % len(result))
    return 3 if cancelled else 0


# -----------------------------------------------------------------------------
# zip / arquivos
# -----------------------------------------------------------------------------
def cmd_zipget(args):
    zpath, member, out = args
    with zipfile.ZipFile(zpath) as z:
        with z.open(member) as src, open(out, "wb") as dst:
            shutil.copyfileobj(src, dst, BUF)
    print("OK")
    return 0


def cmd_zipput(args):
    """recria o zip trocando so o conteudo de <membro> (mesmo nome, mesma ordem)."""
    zpath, member, newfile, out = args
    found = False
    with zipfile.ZipFile(zpath) as zin, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as zout:
        zout.comment = zin.comment
        for zi in zin.infolist():
            if zi.filename == member:
                found = True
                ni = zipfile.ZipInfo(zi.filename, date_time=zi.date_time)
                ni.compress_type = zipfile.ZIP_DEFLATED
                ni.external_attr = zi.external_attr
                ni.create_system = zi.create_system
                with open(newfile, "rb") as src, zout.open(ni, "w", force_zip64=os.path.getsize(newfile) > 0x7FFFFFFF) as dst:
                    shutil.copyfileobj(src, dst, BUF)
            else:
                with zin.open(zi) as src, zout.open(zi, "w") as dst:
                    shutil.copyfileobj(src, dst, BUF)
    if not found:
        os.remove(out)
        fail("o arquivo %s nao esta no zip" % member)
    with zipfile.ZipFile(out) as z:
        bad = z.testzip()
        if bad:
            fail("zip novo com erro em " + bad)
    print("OK")
    return 0


PATCH_EXT = {"ips": [".ips"], "bps": [".bps"], "ups": [".ups"], "ppf": [".ppf"], "aps": [".aps"],
             "xdelta": [".xdelta", ".xdelta3", ".vcdiff", ".delta", ".xd3"]}


def choose(names, patch_file, fmt):
    pf = (patch_file or "").replace("\\", "/").strip("/")
    if pf:
        for n in names:
            if n.replace("\\", "/").strip("/") == pf:
                return n
        low = pf.lower()
        for n in names:
            if n.replace("\\", "/").strip("/").lower() == low:
                return n
        base = low.rsplit("/", 1)[-1]
        hits = [n for n in names if n.replace("\\", "/").rsplit("/", 1)[-1].lower() == base]
        if len(hits) == 1:
            return hits[0]
    exts = PATCH_EXT.get(fmt, [])
    hits = [n for n in names if any(n.lower().endswith(e) for e in exts)]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        fail("o patch nao foi encontrado dentro do arquivo")
    fail("varios patches dentro do arquivo; o indice precisa dizer qual (patch_file)")


def cmd_pick(args):
    src, patch_file, fmt, out = args
    if os.path.isdir(src):
        names = []
        for dp, dn, fns in os.walk(src):
            for fn in fns:
                names.append(os.path.relpath(os.path.join(dp, fn), src).replace(os.sep, "/"))
        n = choose(names, patch_file, fmt)
        shutil.copyfile(os.path.join(src, n), out)
    else:
        with zipfile.ZipFile(src) as z:
            names = [zi.filename for zi in z.infolist() if not zi.is_dir()]
            n = choose(names, patch_file, fmt)
            with z.open(n) as s, open(out, "wb") as d:
                shutil.copyfileobj(s, d, BUF)
    print("OK " + n)
    return 0


def cmd_strip512(args):
    src, out = args
    size = os.path.getsize(src)
    if size % 1024 != 512:
        fail("a ROM nao tem header de 512 bytes")
    with open(src, "rb") as s, open(out, "wb") as d:
        s.seek(512)
        shutil.copyfileobj(s, d, BUF)
    print("OK")
    return 0


# -----------------------------------------------------------------------------
# aplicadores
# -----------------------------------------------------------------------------
def copy_to(src, out):
    shutil.copyfile(src, out)


def apply_ips(rom, patch, out, force=False):
    data = open(patch, "rb").read()
    if data[:5] != b"PATCH":
        fail("nao e um patch IPS")
    copy_to(rom, out)
    pos = 5
    n = len(data)
    with open(out, "r+b") as f:
        while True:
            if pos + 3 > n:
                fail("IPS terminou sem EOF")
            if data[pos:pos + 3] == b"EOF":
                pos += 3
                break
            if pos + 5 > n:
                fail("IPS cortado")
            off = (data[pos] << 16) | (data[pos + 1] << 8) | data[pos + 2]
            size = (data[pos + 3] << 8) | data[pos + 4]
            pos += 5
            f.seek(off)
            if size == 0:
                if pos + 3 > n:
                    fail("IPS cortado (RLE)")
                cnt = (data[pos] << 8) | data[pos + 1]
                f.write(bytes([data[pos + 2]]) * cnt)
                pos += 3
            else:
                if pos + size > n:
                    fail("IPS cortado (dados)")
                f.write(data[pos:pos + size])
                pos += size
        if pos + 3 <= n:
            trunc = (data[pos] << 16) | (data[pos + 1] << 8) | data[pos + 2]
            f.truncate(trunc)


def vlq_reader(data, pos):
    def read():
        nonlocal pos
        result, shift = 0, 1
        while True:
            if pos >= len(data):
                fail("patch cortado")
            x = data[pos]
            pos += 1
            result += (x & 0x7F) * shift
            if x & 0x80:
                break
            shift <<= 7
            result += shift
        return result

    def tell():
        return pos

    def seek(p):
        nonlocal pos
        pos = p
    return read, tell, seek


def open_map(path):
    f = open(path, "rb")
    size = os.fstat(f.fileno()).st_size
    if size == 0:
        f.close()
        return None, b""
    m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    f.close()
    return m, m


BPS_LIMIT = 320 * 1024 * 1024


def apply_bps(rom, patch, out, force=False):
    data = open(patch, "rb").read()
    if data[:4] != b"BPS1" or len(data) < 16:
        fail("nao e um patch BPS")
    pcrc = struct.unpack("<I", data[-4:])[0]
    if zlib.crc32(data[:-4]) & 0xFFFFFFFF != pcrc:
        fail("o patch BPS esta corrompido (CRC do patch nao confere)")
    scrc, tcrc = struct.unpack("<II", data[-12:-4])
    read, tell, seek = vlq_reader(data, 4)
    ssize = read()
    tsize = read()
    msize = read()
    seek(tell() + msize)
    if os.path.getsize(rom) != ssize and not force:
        fail("tamanho da ROM nao confere com o BPS (%d, esperado %d)" % (os.path.getsize(rom), ssize))
    if crc_file(rom) != scrc and not force:
        fail("a ROM nao e a versao certa para este BPS (CRC32 de origem nao confere)")
    if tsize > BPS_LIMIT:
        fail("resultado grande demais para BPS neste aparelho")
    mobj, src = open_map(rom)
    try:
        tgt = bytearray(tsize)
        outpos = 0
        sro = 0
        tro = 0
        end = len(data) - 12
        while tell() < end:
            cmd = read()
            action = cmd & 3
            length = (cmd >> 2) + 1
            if outpos + length > tsize:
                fail("BPS escreve alem do tamanho do resultado")
            if action == 0:      # SourceRead
                tgt[outpos:outpos + length] = src[outpos:outpos + length]
                outpos += length
            elif action == 1:    # TargetRead
                p = tell()
                tgt[outpos:outpos + length] = data[p:p + length]
                seek(p + length)
                outpos += length
            elif action == 2:    # SourceCopy
                d = read()
                sro += -(d >> 1) if d & 1 else (d >> 1)
                if sro < 0 or sro + length > len(src):
                    fail("BPS fora da ROM de origem")
                tgt[outpos:outpos + length] = src[sro:sro + length]
                sro += length
                outpos += length
            else:                # TargetCopy (pode sobrepor)
                d = read()
                tro += -(d >> 1) if d & 1 else (d >> 1)
                if tro < 0 or tro >= outpos:
                    fail("BPS com copia invalida")
                while length > 0:
                    chunk = min(length, outpos - tro)
                    tgt[outpos:outpos + chunk] = tgt[tro:tro + chunk]
                    outpos += chunk
                    tro += chunk
                    length -= chunk
        if zlib.crc32(tgt) & 0xFFFFFFFF != tcrc:
            fail("o resultado do BPS nao confere (CRC32 final)")
        with open(out, "wb") as f:
            f.write(tgt)
    finally:
        if mobj is not None:
            mobj.close()


def apply_ups(rom, patch, out, force=False):
    data = open(patch, "rb").read()
    if data[:4] != b"UPS1" or len(data) < 16:
        fail("nao e um patch UPS")
    if zlib.crc32(data[:-4]) & 0xFFFFFFFF != struct.unpack("<I", data[-4:])[0]:
        fail("o patch UPS esta corrompido (CRC do patch nao confere)")
    icrc, ocrc = struct.unpack("<II", data[-12:-4])
    read, tell, seek = vlq_reader(data, 4)
    isize = read()
    osize = read()
    rsize = os.path.getsize(rom)
    rcrc = crc_file(rom)
    if rsize == isize and rcrc == icrc:
        want_size, want_crc = osize, ocrc
    elif rsize == osize and rcrc == ocrc:      # UPS vale nos dois sentidos
        want_size, want_crc = isize, icrc
    elif force:
        want_size, want_crc = osize, None
    else:
        fail("a ROM nao e a versao certa para este UPS (CRC32 nao confere)")
    copy_to(rom, out)
    end = len(data) - 12
    with open(out, "r+b") as f:
        big = max(rsize, want_size)
        f.truncate(big)
        pos = 0
        while tell() < end:
            pos += read()
            p = tell()
            z = data.find(b"\x00", p, end)
            if z < 0:
                z = end
            chunk = data[p:z]
            if pos < big:
                f.seek(pos)
                cur = f.read(len(chunk))
                cur = cur + b"\x00" * (len(chunk) - len(cur))
                f.seek(pos)
                x = int.from_bytes(cur, "little") ^ int.from_bytes(chunk, "little")
                f.write(x.to_bytes(len(chunk), "little"))
            pos += len(chunk) + 1
            seek(z + 1)
        f.truncate(want_size)
    if want_crc is not None and crc_file(out) != want_crc:
        fail("o resultado do UPS nao confere (CRC32 final)")


def apply_ppf(rom, patch, out, force=False):
    data = open(patch, "rb").read()
    magic = data[:5]
    if magic not in (b"PPF10", b"PPF20", b"PPF30"):
        fail("nao e um patch PPF")
    ver = magic[3] - 48
    rsize = os.path.getsize(rom)
    n = len(data)
    undo = False
    if ver == 1:
        pos, end, offlen = 56, n, 4
    elif ver == 2:
        insize = struct.unpack("<I", data[56:60])[0]
        if insize != rsize and not force:
            fail("tamanho da imagem nao confere com o PPF (%d, esperado %d)" % (rsize, insize))
        block = data[60:1084]
        with open(rom, "rb") as f:
            f.seek(0x9320)
            if f.read(1024) != block and not force:
                fail("a imagem nao e a versao certa para este PPF (bloco de validacao)")
        pos, end, offlen = 1084, n, 4
        if data[-8:-4] == b".DIZ":
            dizlen = struct.unpack("<I", data[-4:])[0]
            end = n - dizlen - 38
    else:
        imagetype, blockcheck, undo = data[56], data[57], bool(data[58])
        pos, offlen = 60, 8
        if blockcheck:
            block = data[60:1084]
            with open(rom, "rb") as f:
                f.seek(0x80A0 if imagetype == 1 else 0x9320)
                if f.read(1024) != block and not force:
                    fail("a imagem nao e a versao certa para este PPF (bloco de validacao)")
            pos = 1084
        end = n
        if data[-6:-2] == b".DIZ":
            dizlen = struct.unpack("<H", data[-2:])[0]
            end = n - dizlen - 36
    copy_to(rom, out)
    with open(out, "r+b") as f:
        while pos < end:
            if pos + offlen + 1 > end:
                fail("PPF cortado")
            off = int.from_bytes(data[pos:pos + offlen], "little")
            ln = data[pos + offlen]
            pos += offlen + 1
            if pos + ln > end:
                fail("PPF cortado (dados)")
            f.seek(off)
            f.write(data[pos:pos + ln])
            pos += ln
            if undo:
                pos += ln


def apply_aps(rom, patch, out, force=False):
    data = open(patch, "rb").read()
    if data[:5] != b"APS10":
        if data[:4] == b"APS1":
            fail("APS de GBA nao suportado (so APS de N64)")
        fail("nao e um patch APS")
    ptype = data[5]
    if data[6] != 0:
        fail("APS com codificacao desconhecida")
    if ptype == 1:
        fmt = data[57]
        cart = data[58:61]
        crc = data[61:69]
        osize = struct.unpack("<I", data[74:78])[0]
        pos = 78
        with open(rom, "rb") as f:
            head = f.read(0x40)
        if len(head) < 0x40:
            fail("ROM de N64 curta demais")
        order = head[:4]
        if fmt == 1 and order != b"\x80\x37\x12\x40" and not force:
            fail("a ROM precisa estar no formato .z64 (ordem de bytes big-endian)")
        if fmt == 0 and order != b"\x37\x80\x40\x12" and not force:
            fail("a ROM precisa estar no formato .v64 (bytes trocados)")
        if fmt == 1 and not force:
            if head[0x3C:0x3F] != cart or head[0x10:0x18] != crc:
                fail("a ROM nao e a versao certa para este APS (ID/CRC do cartucho)")
    elif ptype == 0:
        osize = struct.unpack("<I", data[57:61])[0]
        pos = 61
    else:
        fail("tipo de APS desconhecido")
    copy_to(rom, out)
    n = len(data)
    with open(out, "r+b") as f:
        if os.path.getsize(rom) != osize:
            f.truncate(osize)
        while pos < n:
            if pos + 5 > n:
                fail("APS cortado")
            off = struct.unpack("<I", data[pos:pos + 4])[0]
            ln = data[pos + 4]
            pos += 5
            f.seek(off)
            if ln:
                f.write(data[pos:pos + ln])
                pos += ln
            else:
                f.write(bytes([data[pos]]) * data[pos + 1])
                pos += 2


# ---- VCDIFF (xdelta) --------------------------------------------------------
def vcd_table():
    NOOP, ADD, RUN, COPY = 0, 1, 2, 3
    t = [(RUN, 0, 0, NOOP, 0, 0)]
    t.append((ADD, 0, 0, NOOP, 0, 0))
    for s in range(1, 18):
        t.append((ADD, s, 0, NOOP, 0, 0))
    for m in range(9):
        t.append((COPY, 0, m, NOOP, 0, 0))
        for s in range(4, 19):
            t.append((COPY, s, m, NOOP, 0, 0))
    for m in range(6):
        for a in range(1, 5):
            for c in range(4, 7):
                t.append((ADD, a, 0, COPY, c, m))
    for m in range(6, 9):
        for a in range(1, 5):
            t.append((ADD, a, 0, COPY, 4, m))
    for m in range(9):
        t.append((COPY, 4, m, ADD, 1, 0))
    assert len(t) == 256
    return t


VCD_TABLE = None
VCD_LIMIT = 512 * 1024 * 1024


def apply_vcdiff_py(rom, patch, out, force=False):
    global VCD_TABLE
    if VCD_TABLE is None:
        VCD_TABLE = vcd_table()
    data = open(patch, "rb").read()
    if data[:3] != b"\xD6\xC3\xC4":
        fail("nao e um patch xdelta/VCDIFF")
    pos = 5
    ind = data[4]
    if ind & 0x01:
        fail("xdelta com compressao secundaria: precisa do xdelta3 instalado")
    if ind & 0x02:
        fail("xdelta com tabela de codigos propria: precisa do xdelta3 instalado")

    def rint():
        nonlocal pos
        v = 0
        while True:
            if pos >= len(data):
                fail("xdelta cortado")
            b = data[pos]
            pos += 1
            v = (v << 7) | (b & 0x7F)
            if not b & 0x80:
                return v
    if ind & 0x04:   # cabecalho de aplicacao do xdelta3 (nome dos arquivos)
        ln = rint()
        pos += ln
    mobj, src = open_map(rom)
    try:
        tgt = bytearray()
        while pos < len(data):
            wi = data[pos]
            pos += 1
            seg = None
            if wi & 0x03:
                slen = rint()
                spos = rint()
                if wi & 0x01:
                    if spos + slen > len(src):
                        fail("xdelta pede trecho fora da ROM (versao errada?)")
                    seg = src[spos:spos + slen]
                else:
                    if spos + slen > len(tgt):
                        fail("xdelta com janela invalida")
                    seg = bytes(tgt[spos:spos + slen])
            else:
                seg = b""
            rint()                       # tamanho da codificacao
            twin = rint()
            dind = data[pos]
            pos += 1
            if dind:
                fail("xdelta com secoes comprimidas: precisa do xdelta3 instalado")
            dlen, ilen, alen = rint(), rint(), rint()
            cks = None
            if wi & 0x04:
                cks = struct.unpack(">I", data[pos:pos + 4])[0]
                pos += 4
            dsec = data[pos:pos + dlen]
            pos += dlen
            isec = data[pos:pos + ilen]
            pos += ilen
            asec = data[pos:pos + alen]
            pos += alen
            if len(tgt) + twin > VCD_LIMIT:
                fail("resultado grande demais para o decodificador interno")
            win = bytearray()
            dp = ip = ap = 0
            near = [0, 0, 0, 0]
            nslot = 0
            same = [0] * (3 * 256)
            slen = len(seg)

            def iint():
                nonlocal ip
                v = 0
                while True:
                    b = isec[ip]
                    ip += 1
                    v = (v << 7) | (b & 0x7F)
                    if not b & 0x80:
                        return v

            def aint():
                nonlocal ap
                v = 0
                while True:
                    b = asec[ap]
                    ap += 1
                    v = (v << 7) | (b & 0x7F)
                    if not b & 0x80:
                        return v
            while ip < len(isec):
                code = isec[ip]
                ip += 1
                e = VCD_TABLE[code]
                for (typ, size, mode) in ((e[0], e[1], e[2]), (e[3], e[4], e[5])):
                    if typ == 0:
                        continue
                    if size == 0:
                        size = iint()
                    if typ == 1:          # ADD
                        win += dsec[dp:dp + size]
                        dp += size
                    elif typ == 2:        # RUN
                        win += bytes([dsec[dp]]) * size
                        dp += 1
                    else:                 # COPY
                        here = slen + len(win)
                        if mode == 0:
                            addr = aint()
                        elif mode == 1:
                            addr = here - aint()
                        elif mode < 6:
                            addr = near[mode - 2] + aint()
                        else:
                            b = asec[ap]
                            ap += 1
                            addr = same[(mode - 6) * 256 + b]
                        near[nslot] = addr
                        nslot = (nslot + 1) % 4
                        same[addr % (3 * 256)] = addr
                        if addr + size <= slen:
                            win += seg[addr:addr + size]
                        else:
                            k = 0
                            if addr < slen:
                                k = slen - addr
                                win += seg[addr:slen]
                            ta = addr + k - slen
                            left = size - k
                            while left > 0:
                                avail = len(win) - ta
                                if avail <= 0:
                                    fail("xdelta com copia invalida")
                                c = min(left, avail)
                                win += win[ta:ta + c]
                                ta += c
                                left -= c
            if len(win) != twin:
                fail("xdelta: janela com tamanho errado")
            if cks is not None and zlib.adler32(bytes(win)) & 0xFFFFFFFF != cks:
                fail("o resultado do xdelta nao confere (checksum da janela; ROM errada?)")
            tgt += win
        with open(out, "wb") as f:
            f.write(tgt)
    finally:
        if mobj is not None:
            mobj.close()


def find_xdelta3():
    env = os.environ.get("ROMTRANS_XDELTA3")
    if env is not None:
        return env or None          # vazio = forcar o decodificador interno
    for p in ("/usr/bin/xdelta3", "/usr/local/bin/xdelta3", "/bin/xdelta3"):
        if os.path.exists(p):
            return p
    return shutil.which("xdelta3")


def apply_xdelta(rom, patch, out, force=False):
    x = find_xdelta3()
    if x:
        args = [x, "-d", "-f"]
        if force:
            args.append("-n")
        args += ["-s", rom, patch, out]
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if p.returncode != 0:
            msg = (p.stderr or b"").decode("utf-8", "replace").strip().splitlines()
            fail("xdelta3 falhou: " + (msg[-1] if msg else "codigo %d" % p.returncode))
        return
    apply_vcdiff_py(rom, patch, out, force)


APPLY = {"ips": apply_ips, "bps": apply_bps, "ups": apply_ups, "ppf": apply_ppf, "aps": apply_aps,
         "xdelta": apply_xdelta, "xdelta3": apply_xdelta, "vcdiff": apply_vcdiff_py}


def cmd_apply(args):
    force = "--force" in args
    args = [a for a in args if a != "--force"]
    fmt, rom, patch, out = args
    fn = APPLY.get(fmt.lower())
    if not fn:
        fail("formato de patch nao suportado: " + fmt)
    try:
        fn(rom, patch, out, force)
    except PatchError:
        if os.path.exists(out):
            os.remove(out)
        raise
    print("OK %d" % os.path.getsize(out))
    return 0


CMDS = {"hash": cmd_hash, "scan": cmd_scan, "zipget": cmd_zipget, "zipput": cmd_zipput,
        "pick": cmd_pick, "strip512": cmd_strip512, "apply": cmd_apply}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        sys.stderr.write("uso: romtrans_patch.py <%s> ...\n" % "|".join(sorted(CMDS)))
        return 1
    try:
        return CMDS[sys.argv[1]](sys.argv[2:])
    except PatchError as e:
        sys.stderr.write("ERRO: %s\n" % e)
        return 2
    except (OSError, zipfile.BadZipFile, ValueError, IndexError, struct.error, KeyError) as e:
        sys.stderr.write("ERRO: %s\n" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
