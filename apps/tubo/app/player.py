# Tubo - reproducao com mpv (sem Lua neste build do Knulli: sem ytdl_hook/OSC).
# O Tubo resolve as URLs com o yt-dlp e passa video + audio separados para o mpv.
# Controle no video: gptokeyb (PortMaster) converte o controle em teclas de mpv/input.conf (mpv/tubo.gptk).
# Modo so audio: o mpv roda sem video e o Tubo controla pela IPC (socket JSON).
import json
import os
import shlex
import socket
import subprocess
import threading
import time

from core import DATA, FONTS, MPVDIR, log

SOCK = "/tmp/tubo-mpv.sock"
MPV_LOG = os.path.join(DATA, "mpv-ultimo.log")


def base_args(r, settings, start=0):
    a = ["mpv", "--no-config", "--input-conf=" + os.path.join(MPVDIR, "input.conf"),
         "--no-input-default-bindings", "--input-ipc-server=" + SOCK,
         "--user-agent=" + r["ua"], "--force-media-title=" + r["title"],
         "--cache=yes", "--demuxer-max-bytes=50MiB", "--demuxer-max-back-bytes=16MiB",
         "--demuxer-readahead-secs=20", "--network-timeout=20", "--hwdec=no",
         "--msg-level=all=warn", "--term-osd=no", "--volume=80", "--volume-max=130",
         "--osd-fonts-dir=" + FONTS, "--osd-font=Inter", "--osd-font-size=28",
         "--osd-color=#F2F4F7", "--osd-outline-color=#0E1013", "--osd-outline-size=1.6",
         "--osd-bar-h=1.6", "--osd-bar-w=92", "--osd-bar-align-y=0.93", "--osd-duration=1800",
         "--sub-fonts-dir=" + FONTS, "--sub-font=Inter", "--sub-font-size=36",
         "--sub-outline-size=2", "--sub-margin-y=28"]
    if start:
        a.append("--start=%d" % int(start))
    if r.get("live"):
        a += ["--cache-secs=20"]
    extra = os.environ.get("TUBO_MPV_EXTRA")      # usado nos testes sem tela (ex.: --vo=null --ao=null --length=8)
    if extra:
        a += shlex.split(extra)
    return a


def video_cmd(r, settings, start=0):
    a = base_args(r, settings, start)
    # --input-gamepad=no: o gamepad do mpv abre o SDL antes e a saida --vo=sdl
    # falha ("Another component is using SDL already"); o controle vem do gptokeyb
    a += ["--vo=sdl", "--fs", "--keepaspect=yes", "--input-gamepad=no",
          "--video-sync=audio", "--framedrop=vo",
          "--panscan=%s" % ("1.0" if settings.get("fill") else "0.0"),
          "--osd-playing-msg=${media-title}", "--osd-playing-msg-duration=3000"]
    if r.get("audio_url"):
        a.append("--audio-file=" + r["audio_url"])
    # legendas so quando ligadas: cada arquivo e mais um pedido ao YouTube (429 Too Many Requests)
    subs = (r.get("subs") or []) if settings.get("sub_lang") != "off" else []
    for _, u in subs:
        a.append("--sub-file=" + u)
    if subs:
        a.append("--sid=1")
        a.append("--sub-visibility=%s" % ("yes" if settings.get("sub_lang") != "off" else "no"))
    else:
        a.append("--sid=no")
    if os.environ.get("TUBO_MPV_EXTRA"):
        a = [x for x in a if x not in ("--vo=sdl", "--fs")]
    a.append(r["url"])
    return a


def audio_cmd(r, settings, start=0):
    a = base_args(r, settings, start)
    a += ["--no-video", "--vo=null", "--input-gamepad=no", "--idle=no"]
    a.append(r["url"])
    return a


class Ipc:
    def __init__(self, path=SOCK):
        self.path = path
        self.s = None
        self.buf = b""
        self.rid = 0
        self.lock = threading.Lock()

    def connect(self, timeout=8.0):
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(1.0)
                s.connect(self.path)
                self.s = s
                return True
            except OSError:
                time.sleep(0.15)
        return False

    def cmd(self, *args):
        if not self.s:
            return None
        with self.lock:
            self.rid += 1
            rid = self.rid
            try:
                self.s.sendall(json.dumps({"command": list(args), "request_id": rid}).encode() + b"\n")
                t0 = time.time()
                while time.time() - t0 < 1.5:
                    while b"\n" in self.buf:
                        line, self.buf = self.buf.split(b"\n", 1)
                        try:
                            m = json.loads(line)
                        except ValueError:
                            continue
                        if m.get("request_id") == rid:
                            return m.get("data") if m.get("error") == "success" else None
                    chunk = self.s.recv(65536)
                    if not chunk:
                        self.close()
                        return None
                    self.buf += chunk
            except (OSError, socket.timeout):
                return None
        return None

    def get(self, prop):
        return self.cmd("get_property", prop)

    def close(self):
        try:
            if self.s:
                self.s.close()
        except OSError:
            pass
        self.s = None


class Mpv:
    """Processo mpv + monitor de posicao (para retomar e para o historico)."""

    def __init__(self, cmd):
        try:
            os.remove(SOCK)
        except OSError:
            pass
        log.info("mpv: %s", " ".join(x if len(x) < 90 else x[:90] + "..." for x in cmd))
        inhibit(True)
        self.logf = open(MPV_LOG, "w")
        self.keys = gptokeyb_start() if "--vo=sdl" in cmd else None
        self.p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=self.logf, stderr=subprocess.STDOUT)
        self.ipc = Ipc()
        self.pos = 0.0
        self.dur = None
        self.paused = False
        self.volume = 80
        self.buffering = True
        self.drops = (0, 0)
        self.alive = True
        threading.Thread(target=self._mon, daemon=True).start()

    def _mon(self):
        if not self.ipc.connect():
            log.warning("mpv: IPC nao conectou")
        mon = Ipc()
        mon.connect(2)
        while self.p.poll() is None:
            v = mon.get("time-pos")
            if isinstance(v, (int, float)):
                self.pos = float(v)
            d = mon.get("duration")
            if isinstance(d, (int, float)):
                self.dur = float(d)
            pz = mon.get("pause")
            if isinstance(pz, bool):
                self.paused = pz
            vol = mon.get("volume")
            if isinstance(vol, (int, float)):
                self.volume = vol
            ca = mon.get("paused-for-cache")
            self.buffering = bool(ca) or v is None
            fd, dd = mon.get("frame-drop-count"), mon.get("decoder-frame-drop-count")
            if isinstance(fd, int) or isinstance(dd, int):
                self.drops = (fd or 0, dd or 0)
            time.sleep(0.5)
        mon.close()
        self.alive = False

    def running(self):
        return self.p.poll() is None

    def command(self, *a):
        return self.ipc.cmd(*a)

    def stop(self):
        if self.running():
            self.ipc.cmd("quit", 4)
            try:
                self.p.wait(3)
            except subprocess.TimeoutExpired:
                self.p.kill()
        self.finish()

    def finish(self):
        rc = self.p.wait()
        gptokeyb_stop(self.keys)
        self.keys = None
        inhibit(False)
        self.ipc.close()
        try:
            self.logf.close()
        except Exception:
            pass
        try:
            os.remove(SOCK)
        except OSError:
            pass
        log.info("mpv saiu rc=%s pos=%.0f/%s quadros perdidos vo=%s decoder=%s",
                 rc, self.pos, self.dur, self.drops[0], self.drops[1])
        return rc


GPTOKEYB_PATHS = ("/userdata/system/.local/share/PortMaster/gptokeyb",
                  "/userdata/roms/ports/PortMaster/gptokeyb")


def gptokeyb_start():
    """Controle -> teclado durante o video (mapa em mpv/tubo.gptk)."""
    if os.environ.get("TUBO_MPV_EXTRA"):
        return None
    exe = next((p for p in GPTOKEYB_PATHS if os.access(p, os.X_OK)), None)
    if not exe:
        log.warning("gptokeyb nao encontrado: o controle nao funciona no video")
        return None
    try:
        p = subprocess.Popen([exe, "-1", "mpv", "-c", os.path.join(MPVDIR, "tubo.gptk")],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
        log.info("gptokeyb iniciado (pid %s)", p.pid)
        return p
    except OSError as e:
        log.warning("gptokeyb: %s", e)
        return None


def gptokeyb_stop(p):
    if not p:
        return
    try:
        p.terminate()
        p.wait(2)
    except Exception:
        try:
            p.kill()
        except Exception:
            pass


PAUSE_FILE = "/var/run/battery-saver/tubo.pause"


def inhibit(on):
    """Enquanto toca, impede o economizador do Knulli (idlewatcher) de escurecer/suspender:
    os hooks em /etc/idlewatcher pulam a acao se existir /var/run/battery-saver/*.pause."""
    try:
        if on:
            os.makedirs(os.path.dirname(PAUSE_FILE), exist_ok=True)
            open(PAUSE_FILE, "w").close()
        elif os.path.exists(PAUSE_FILE):
            os.remove(PAUSE_FILE)
    except OSError as e:
        log.info("inhibit: %s", e)


def screen(on):
    """Liga/desliga a tela pelo script do Knulli (guarda o brilho e restaura)."""
    if os.environ.get("TUBO_NO_SCREEN_CMD"):
        log.info("tela %s (simulado)", "on" if on else "off")
        return
    try:
        subprocess.run(["knulli-brightness", "dispon" if on else "dispoff"], timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        log.warning("knulli-brightness: %s", e)
