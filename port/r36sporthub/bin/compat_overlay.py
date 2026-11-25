#!/usr/bin/env python3
"""Aplica somente o runtime oficial do DuckTales, preservando dados do dono."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import shlex
import shutil
import stat
import zipfile

LAUNCHER = "DuckTales - Remastered.sh"
OWNER_DIRS = {"gamedata", "data", "userdata", "saves", "save", "home", "cache"}
OWNER_FILES = {"NEXTOSSETTINGS.txt", "NEXTOSCONTROLLERS.gptk"}
MARKER = "# PORTHUB_DUCKTALES_1111"


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def apply_overlay(archive, stage, destination, expected_sha, firmware_libs="/usr/lib32", backup_dir=None):
    archive, stage, destination = Path(archive), Path(stage).resolve(), Path(destination)
    if digest(archive) != expected_sha:
        raise ValueError("SHA-256 do runtime nao confere")
    mali = Path(firmware_libs) / "libmali.so"
    with mali.open("rb") as f:
        header = f.read(20)
    if len(header) < 20 or header[:6] != b"\x7fELF\x01\x01" or int.from_bytes(header[18:20], "little") != 40:
        raise ValueError("O firmware precisa fornecer libmali.so ARM de 32 bits")
    if not (stage / "ducktales").is_dir():
        raise ValueError("Pasta ducktales ausente no pacote")

    # Valida todos os caminhos antes de gravar qualquer arquivo no stage.
    with zipfile.ZipFile(archive) as z:
        entries, seen = [], set()
        for item in z.infolist():
            p = PurePosixPath(item.filename)
            if p.is_absolute() or ".." in p.parts or "\\" in item.filename:
                raise ValueError("Caminho inseguro no runtime")
            if not p.parts or (p.parts[0] != "ducktales" and item.filename != LAUNCHER):
                raise ValueError("Arquivo fora da pasta do port")
            if stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError("Links nao sao permitidos no runtime")
            target = stage.joinpath(*p.parts)
            if not target.resolve().is_relative_to(stage) or target.is_symlink():
                raise ValueError("Destino fora da pasta temporaria")
            if item.filename in seen:
                raise ValueError("Arquivo duplicado no runtime")
            seen.add(item.filename)
            if len(p.parts) > 1 and (
                p.parts[1] in OWNER_DIRS or p.parts[1] in OWNER_FILES
                or p.parts[1].startswith(".runs")
                or p.parts[1:3] == (".nxrelease", "prepare-work")
            ):
                continue
            if not item.is_dir():
                entries.append((item, target))
        if LAUNCHER not in seen or "ducktales/runtime/ducktales" not in seen:
            raise ValueError("Runtime sem launcher ou executavel")
        if backup_dir and (destination / LAUNCHER).is_file():
            backup = Path(backup_dir) / "ducktales-remastered" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            backup.mkdir(parents=True, exist_ok=True)
            shutil.copy2(destination / LAUNCHER, backup / LAUNCHER)
        for item, target in entries:
            data = z.read(item)  # tambem confere o CRC do membro
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            executable = data.startswith(b"\x7fELF") or target.suffix in {".sh", ".py", ".exe"}
            target.chmod(0o755 if executable else 0o644)

    game = stage / "ducktales"
    for name in OWNER_DIRS:
        staged = game / name
        if (destination / "ducktales" / name).is_dir() and staged.is_dir():
            shutil.rmtree(staged)
    for name in OWNER_FILES:
        staged = game / name
        if (destination / "ducktales" / name).exists() and staged.is_file():
            staged.unlink()  # a mescla do instalador preserva a configuracao atual
    settings = game / "NEXTOSSETTINGS.txt"
    defaults = game / "defaults/NEXTOSSETTINGS.txt"
    if not (destination / "ducktales/NEXTOSSETTINGS.txt").exists():
        source = settings if settings.is_file() else defaults
        if source.is_file():
            settings.write_text(source.read_text(encoding="utf-8").replace("quality=auto", "quality=low", 1), encoding="utf-8", newline="\n")

    private = game / "runtime/lib/libGLESv2.so.2"
    private.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(mali, private)
    driver = shlex.quote(str(destination / "ducktales/runtime/lib/libGLESv2.so.2"))
    libs = shlex.quote(str(Path(firmware_libs)) + ":/lib32")
    block = (MARKER + "\nexport LD_LIBRARY_PATH=" + libs + '"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n'
             + "export SDL_VIDEO_EGL_DRIVER=" + driver + "\nexport SDL_VIDEO_GL_DRIVER=" + driver + "\n"
             + "export SPA_PLUGIN_DIR=/usr/lib32/spa-0.2\nexport PIPEWIRE_MODULE_DIR=/usr/lib32/pipewire-0.3\n")
    launcher = stage / LAUNCHER
    text = launcher.read_text(encoding="utf-8").replace("\r\n", "\n")
    first, separator, rest = text.partition("\n")
    if not separator or not first.startswith("#!"):
        raise ValueError("Launcher do runtime invalido")
    launcher.write_text(first + "\n" + block + rest, encoding="utf-8", newline="\n")
    launcher.chmod(0o755)
    (game / "porthub-runtime.json").write_text(json.dumps({
        "version": "1.1.11", "archive_sha256": expected_sha,
        "source": "https://github.com/NextOs-Ports/nextos-universal-ports/releases/tag/ducktales-v1.1.11",
    }, indent=2) + "\n", encoding="utf-8", newline="\n")
    return len(entries)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("archive"); parser.add_argument("stage"); parser.add_argument("destination"); parser.add_argument("sha256")
    parser.add_argument("--firmware-libs", default="/usr/lib32")
    parser.add_argument("--backup-dir")
    args = parser.parse_args()
    try:
        count = apply_overlay(args.archive, args.stage, args.destination, args.sha256, args.firmware_libs, args.backup_dir)
        print("DuckTales 1.1.11: runtime oficial aplicado (%d arquivos); dados e saves preservados" % count)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        parser.exit(1, str(error) + "\n")
