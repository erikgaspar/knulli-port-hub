#!/usr/bin/env python3
# Tubo - cliente leve de YouTube para Knulli (RG35XXH 640x480), so com o controle.
# Interface em pygame; busca/canais via yt-dlp; reproducao no mpv; dados locais em data/*.json.
import math
import os
import subprocess
import sys
import threading
import time
import traceback

os.environ.setdefault("SDL_GAMECONTROLLER_ALLOW_BACKGROUND_EVENTS", "1")
os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
import pygame

import core
import player
from core import (Cancelled, Store, Thumbs, TuboError, YtDlp, fmt_ago, fmt_dur, fmt_size, fmt_views,
                  internet_ok, log)

VERSION = "1.0.1"
W, H = 640, 480
BG = (14, 16, 19)
CARD = (23, 26, 31)
CARD2 = (31, 35, 42)
LINE = (44, 49, 58)
TXT = (242, 244, 247)
MUTED = (154, 163, 175)
DIM = (98, 106, 118)
ACC = (184, 241, 90)
ORANGE = (242, 169, 59)
RED = (240, 96, 88)
TOP, FOOT = 58, 36          # altura do cabecalho e do rodape


# ======================================================================= texto

class Fonts:
    def __init__(self):
        f = lambda s, w: pygame.font.Font(os.path.join(core.FONTS, "Inter-%s.ttf" % w), s)
        self.logo = f(23, "ExtraBold")
        self.title = f(21, "ExtraBold")
        self.h = f(17, "Bold")
        self.b = f(15, "SemiBold")
        self.r = f(14, "Regular")
        self.s = f(13, "SemiBold")
        self.sr = f(12, "Regular")
        self.xs = f(11, "Bold")
        self.key = f(17, "SemiBold")
        self.big = f(19, "Bold")


_tcache = {}


def render(font, text, color):
    k = (id(font), text, color)
    s = _tcache.get(k)
    if s is None:
        if len(_tcache) > 900:
            _tcache.clear()
        s = font.render(text, True, color)
        _tcache[k] = s
    return s


def ellipsize(font, text, maxw):
    if font.size(text)[0] <= maxw:
        return text
    lo, hi = 0, len(text)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if font.size(text[:mid].rstrip() + "…")[0] <= maxw:
            lo = mid
        else:
            hi = mid - 1
    return text[:lo].rstrip() + "…"


_wcache = {}


def wrap(font, text, maxw, maxlines=2):
    k = (id(font), text, maxw, maxlines)
    if k in _wcache:
        return _wcache[k]
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if font.size(t)[0] <= maxw:
            cur = t
            continue
        if cur:
            lines.append(cur)
        cur = w
        if len(lines) == maxlines:
            break
    if cur and len(lines) < maxlines:
        lines.append(cur)
    if len(lines) == maxlines and " ".join(lines) != " ".join(words):
        lines[-1] = ellipsize(font, lines[-1] + " " + " ".join(words[len(" ".join(lines).split()):]), maxw)
    lines = [ellipsize(font, l, maxw) for l in lines] or [""]
    if len(_wcache) > 600:
        _wcache.clear()
    _wcache[k] = lines
    return lines


def text(s, font, t, color, x, y, maxw=None, align="left"):
    if maxw:
        t = ellipsize(font, t, maxw)
    img = render(font, t, color)
    if align == "center":
        x -= img.get_width() // 2
    elif align == "right":
        x -= img.get_width()
    s.blit(img, (x, y))
    return img.get_width()


def rrect(s, color, rect, r=10, width=0):
    pygame.draw.rect(s, color, rect, width, border_radius=r)


def alpha_rect(s, color, rect, alpha, r=0):
    surf = pygame.Surface((rect[2], rect[3]), pygame.SRCALPHA)
    pygame.draw.rect(surf, color + (alpha,), (0, 0, rect[2], rect[3]), border_radius=r)
    s.blit(surf, (rect[0], rect[1]))


# ======================================================================= icones (vetor)

def icon(s, name, cx, cy, color, k=1.0):
    def P(x, y):
        return (int(cx + x * k), int(cy + y * k))
    lw = max(2, int(3 * k))
    if name == "search":
        pygame.draw.circle(s, color, P(-3, -3), int(8 * k), lw)
        pygame.draw.line(s, color, P(3, 3), P(10, 10), lw + 1)
    elif name == "subs":
        pygame.draw.line(s, color, P(-8, -11), P(8, -11), lw - 1)
        pygame.draw.line(s, color, P(-10, -7), P(10, -7), lw - 1)
        rrect(s, color, (*P(-12, -3), int(24 * k), int(15 * k)), int(3 * k))
        pygame.draw.polygon(s, BG, [P(-3, 0), P(-3, 9), P(5, 4.5)])
    elif name == "later":
        pygame.draw.circle(s, color, P(0, 0), int(11 * k), lw)
        pygame.draw.line(s, color, P(0, 0), P(0, -6), lw)
        pygame.draw.line(s, color, P(0, 0), P(5, 3), lw)
    elif name == "history":
        r = pygame.Rect(*P(-11, -11), int(22 * k), int(22 * k))
        pygame.draw.arc(s, color, r, math.radians(-200), math.radians(110), lw)
        pygame.draw.polygon(s, color, [P(-14, -5), P(-6, -5), P(-10, 1)])
        pygame.draw.line(s, color, P(0, 0), P(0, -6), lw)
        pygame.draw.line(s, color, P(0, 0), P(4, 4), lw)
    elif name == "play":
        pygame.draw.circle(s, color, P(0, 0), int(12 * k), lw)
        pygame.draw.polygon(s, color, [P(-3, -6), P(-3, 6), P(6, 0)])
    elif name == "gear":
        for i in range(8):
            a = i * math.pi / 4
            pygame.draw.line(s, color, P(math.cos(a) * 7, math.sin(a) * 7),
                             P(math.cos(a) * 12, math.sin(a) * 12), int(5 * k))
        pygame.draw.circle(s, color, P(0, 0), int(9 * k))
        pygame.draw.circle(s, CARD2, P(0, 0), int(4 * k))
    elif name == "note":
        pygame.draw.line(s, color, P(-2, 8), P(-2, -10), lw)
        pygame.draw.line(s, color, P(-2, -10), P(9, -7), lw)
        pygame.draw.circle(s, color, P(-6, 8), int(5 * k))
    elif name == "user":
        pygame.draw.circle(s, color, P(0, -5), int(5 * k))
        pygame.draw.ellipse(s, color, (*P(-10, 2), int(20 * k), int(11 * k)))


def logo(s, x, y, f):
    rrect(s, ACC, (x, y + 3, 32, 23), 7)
    pygame.draw.polygon(s, BG, [(x + 12, y + 8), (x + 12, y + 21), (x + 23, y + 14.5)])
    text(s, f.logo, "Tubo", TXT, x + 41, y - 1)


# ======================================================================= controle

class Input:
    """SDL GameController (o Knulli passa SDL_GAMECONTROLLERCONFIG).
    Acoes: a (B fisico, confirma), b (A fisico, volta), x (Y fisico), y (X fisico), l1 r1 l2 r2,
    start select menu, setas; Menu+Start ou Alt+F4 = quit."""
    REPEAT = ("up", "down", "left", "right", "l1", "r1", "l2", "r2")

    def __init__(self):
        self.ctrl, self.joys = [], []
        self.held = {}
        self.axes = {}
        self._c = None
        self.open()

    def open(self):
        self.held.clear()
        self.axes.clear()
        try:
            from pygame._sdl2 import controller
            controller.init()
            self._c = controller
            for i in range(controller.get_count()):
                if controller.is_controller(i):
                    self.ctrl.append(controller.Controller(i))
        except Exception as e:
            log.info("controller: %s", e)
        if not self.ctrl:
            try:
                pygame.joystick.init()
                for i in range(pygame.joystick.get_count()):
                    j = pygame.joystick.Joystick(i)
                    j.init()
                    self.joys.append(j)
            except pygame.error:
                pass
        log.info("controles: %d gamecontroller, %d joystick", len(self.ctrl), len(self.joys))

    def close(self):
        for c in self.ctrl:
            try:
                c.quit()
            except Exception:
                pass
        for j in self.joys:
            try:
                j.quit()
            except Exception:
                pass
        self.ctrl, self.joys = [], []
        try:
            if self._c:
                self._c.quit()
            pygame.joystick.quit()
        except Exception:
            pass

    CB = {}
    JB = {3: "b", 4: "a", 5: "x", 6: "y", 7: "l1", 8: "r1", 9: "select", 10: "start", 11: "menu",
          13: "l2", 14: "r2"}
    KEYS = {pygame.K_UP: "up", pygame.K_DOWN: "down", pygame.K_LEFT: "left", pygame.K_RIGHT: "right",
            pygame.K_RETURN: "a", pygame.K_ESCAPE: "b", pygame.K_BACKSPACE: "b", pygame.K_x: "x",
            pygame.K_y: "y", pygame.K_q: "l1", pygame.K_w: "r1", pygame.K_s: "start",
            pygame.K_TAB: "select", pygame.K_PAGEUP: "l2", pygame.K_PAGEDOWN: "r2"}

    def _cb(self, b):
        if not Input.CB:
            Input.CB = {pygame.CONTROLLER_BUTTON_A: "a", pygame.CONTROLLER_BUTTON_B: "b",
                        pygame.CONTROLLER_BUTTON_X: "x", pygame.CONTROLLER_BUTTON_Y: "y",
                        pygame.CONTROLLER_BUTTON_BACK: "select", pygame.CONTROLLER_BUTTON_GUIDE: "menu",
                        pygame.CONTROLLER_BUTTON_START: "start",
                        pygame.CONTROLLER_BUTTON_LEFTSHOULDER: "l1",
                        pygame.CONTROLLER_BUTTON_RIGHTSHOULDER: "r1",
                        pygame.CONTROLLER_BUTTON_DPAD_UP: "up", pygame.CONTROLLER_BUTTON_DPAD_DOWN: "down",
                        pygame.CONTROLLER_BUTTON_DPAD_LEFT: "left",
                        pygame.CONTROLLER_BUTTON_DPAD_RIGHT: "right"}
        return Input.CB.get(b)

    def _press(self, name, out, now):
        if name is None:
            return
        if name in self.held:
            return
        self.held[name] = now + 0.38
        if name == "start" and "menu" in self.held or name == "menu" and "start" in self.held:
            out.append("quit")
            return
        if name in ("menu",):
            return
        out.append(name)

    def _release(self, name):
        self.held.pop(name, None)

    def _axis(self, key, val, neg, pos, out, now, thr=22000):
        cur = self.axes.get(key)
        new = neg if val < -thr else pos if val > thr else None
        if val is not None and abs(val) < thr * 0.6:
            new = None
        elif new is None:
            return
        if new != cur:
            if cur:
                self._release(cur)
            if new:
                self._press(new, out, now)
            self.axes[key] = new

    def poll(self, events):
        now = time.time()
        out = []
        for e in events:
            t = e.type
            if t == pygame.QUIT:
                out.append("quit")
            elif t == pygame.KEYDOWN:
                if e.key == pygame.K_F4 and (e.mod & pygame.KMOD_ALT):
                    out.append("quit")
                else:
                    self._press(self.KEYS.get(e.key), out, now)
            elif t == pygame.KEYUP:
                self._release(self.KEYS.get(e.key))
            elif t == pygame.CONTROLLERBUTTONDOWN and self.ctrl:
                self._press(self._cb(e.button), out, now)
            elif t == pygame.CONTROLLERBUTTONUP and self.ctrl:
                self._release(self._cb(e.button))
            elif t == pygame.CONTROLLERAXISMOTION and self.ctrl:
                if e.axis == pygame.CONTROLLER_AXIS_TRIGGERLEFT:
                    self._axis("lt", e.value, None, "l2", out, now, 16000)
                elif e.axis == pygame.CONTROLLER_AXIS_TRIGGERRIGHT:
                    self._axis("rt", e.value, None, "r2", out, now, 16000)
                elif e.axis == pygame.CONTROLLER_AXIS_LEFTX:
                    self._axis("lx", e.value, "left", "right", out, now)
                elif e.axis == pygame.CONTROLLER_AXIS_LEFTY:
                    self._axis("ly", e.value, "up", "down", out, now)
            elif t == pygame.JOYBUTTONDOWN and not self.ctrl:
                self._press(self.JB.get(e.button), out, now)
            elif t == pygame.JOYBUTTONUP and not self.ctrl:
                self._release(self.JB.get(e.button))
            elif t == pygame.JOYHATMOTION and not self.ctrl:
                x, y = e.value
                for n in ("up", "down", "left", "right"):
                    self._release(n)
                if x:
                    self._press("left" if x < 0 else "right", out, now)
                if y:
                    self._press("up" if y > 0 else "down", out, now)
        for n, t in list(self.held.items()):
            if n in self.REPEAT and now >= t:
                out.append(n)
                self.held[n] = now + (0.07 if n in ("up", "down", "left", "right") else 0.18)
        return out


# ======================================================================= tarefas em segundo plano

class Job:
    def __init__(self, fn):
        self.cancelled = False
        self.procs = []
        self.done = False
        self.result = None
        self.error = None
        threading.Thread(target=self._run, args=(fn,), daemon=True).start()

    def _run(self, fn):
        try:
            self.result = fn(self)
        except Cancelled:
            self.cancelled = True
        except TuboError as e:
            self.error = str(e)
        except Exception as e:
            log.error("erro na tarefa: %s", traceback.format_exc())
            self.error = "Erro inesperado: %s" % e
        self.done = True

    def cancel(self):
        self.cancelled = True
        for p in self.procs:
            try:
                p.kill()
            except Exception:
                pass


# ======================================================================= base de telas

class Screen:
    title = ""

    def __init__(self, app):
        self.app = app
        self.f = app.f

    def action(self, a):
        pass

    def update(self, dt):
        pass

    def draw(self, s):
        pass

    def hints(self):
        return [("A", "Voltar")]

    def resumed(self):
        pass

    def header(self, s, title, sub=None):
        text(s, self.f.title, title, TXT, 20, 15, maxw=420 if sub else 600)
        if sub:
            text(s, self.f.s, sub, MUTED, W - 20, 22, maxw=190, align="right")
        pygame.draw.line(s, LINE, (0, TOP - 1), (W, TOP - 1))


def draw_hints(s, f, hints):
    pygame.draw.rect(s, BG, (0, H - FOOT, W, FOOT))
    pygame.draw.line(s, LINE, (0, H - FOOT), (W, H - FOOT))
    x = 16
    for k, label in hints:
        img = render(f.s, label, MUTED)
        if k in ("A", "B", "X", "Y"):
            col = ACC if k == "B" else CARD2
            pygame.draw.circle(s, col, (x + 10, H - FOOT // 2), 10)
            text(s, f.xs, k, BG if k == "B" else TXT, x + 10, H - FOOT // 2 - 7, align="center")
            kw = 20
        elif k in ("◀▶", "▲▼"):
            kw = 30
            cy = H - FOOT // 2
            rrect(s, CARD2, (x, cy - 10, kw, 20), 6)
            if k == "◀▶":
                pygame.draw.polygon(s, TXT, [(x + 6, cy), (x + 12, cy - 5), (x + 12, cy + 5)])
                pygame.draw.polygon(s, TXT, [(x + 24, cy), (x + 18, cy - 5), (x + 18, cy + 5)])
            else:
                pygame.draw.polygon(s, TXT, [(x + 9, cy - 5), (x + 4, cy + 4), (x + 14, cy + 4)])
                pygame.draw.polygon(s, TXT, [(x + 21, cy + 5), (x + 16, cy - 4), (x + 26, cy - 4)])
        else:
            kimg = render(f.xs, k, TXT)
            kw = kimg.get_width() + 12
            rrect(s, CARD2, (x, H - FOOT // 2 - 10, kw, 20), 6)
            s.blit(kimg, (x + 6, H - FOOT // 2 - 7))
        s.blit(img, (x + kw + 6, H - FOOT // 2 - img.get_height() // 2))
        x += kw + 6 + img.get_width() + 16
        if x > W - 40:
            break


class ListView:
    """Lista vertical com rolagem suave e foco com borda de acento."""

    def __init__(self, row_h, top=TOP + 6, bottom=H - FOOT - 4):
        self.sel = 0
        self.scroll = 0.0
        self.row_h = row_h
        self.top = top
        self.bottom = bottom
        self.n = 0

    @property
    def view_h(self):
        return self.bottom - self.top

    def move(self, d, n):
        self.n = n
        if n == 0:
            self.sel = 0
            return False
        old = self.sel
        self.sel = max(0, min(n - 1, self.sel + d))
        return old != self.sel

    def update(self, dt, n):
        self.n = n
        self.sel = max(0, min(max(0, n - 1), self.sel))
        y = self.sel * self.row_h
        target = self.scroll
        margin = self.row_h * 0.6
        if y - target < 0:
            target = max(0, y - 4)
        elif y + self.row_h - target > self.view_h - (margin if self.sel < n - 1 else 0):
            target = y + self.row_h - self.view_h + (margin if self.sel < n - 1 else 4)
        maxs = max(0, n * self.row_h - self.view_h + 4)
        target = max(0, min(maxs, target))
        self.target = target
        self.scroll += (target - self.scroll) * min(1.0, dt * 14)
        if abs(target - self.scroll) < 0.5:
            self.scroll = target

    def visible(self, n):
        first = max(0, int(self.scroll // self.row_h))
        last = min(n, int((self.scroll + self.view_h) // self.row_h) + 1)
        return range(first, last)

    def row_y(self, i):
        return int(self.top + i * self.row_h - self.scroll)

    def draw_scrollbar(self, s, n):
        total = n * self.row_h
        if total <= self.view_h:
            return
        h = max(24, int(self.view_h * self.view_h / total))
        y = self.top + int((self.view_h - h) * self.scroll / max(1, total - self.view_h))
        rrect(s, CARD2, (W - 6, self.top, 3, self.view_h), 2)
        rrect(s, MUTED, (W - 6, y, 3, h), 2)


def draw_video_row(s, app, v, x, y, w, focused, h=84, extra=None):
    f = app.f
    if focused:
        rrect(s, CARD2, (x, y, w, h - 6), 10)
        rrect(s, ACC, (x, y, w, h - 6), 10, 2)
    tw, th = 128, 72
    tx, ty = x + 6, y + 3
    img = app.thumbs.get(v["id"], (tw, th))
    if img:
        s.blit(img, (tx, ty))
        # cantos arredondados simples
        for cx, cy in ((tx, ty), (tx + tw - 1, ty), (tx, ty + th - 1), (tx + tw - 1, ty + th - 1)):
            s.set_at((cx, cy), CARD2 if focused else BG)
    else:
        rrect(s, CARD, (tx, ty, tw, th), 6)
        pygame.draw.polygon(s, LINE, [(tx + 56, ty + 26), (tx + 56, ty + 46), (tx + 74, ty + 36)])
    badge = "AO VIVO" if v.get("live") else fmt_dur(v.get("duration"))
    if badge:
        bimg = render(f.xs, badge, TXT if not v.get("live") else BG)
        bw = bimg.get_width() + 8
        if v.get("live"):
            rrect(s, ORANGE, (tx + tw - bw - 4, ty + th - 19, bw, 16), 4)
        else:
            alpha_rect(s, (0, 0, 0), (tx + tw - bw - 4, ty + th - 19, bw, 16), 200, 4)
        s.blit(bimg, (tx + tw - bw, ty + th - 18))
    pos = v.get("pos") or 0
    if pos and v.get("duration"):
        frac = min(1.0, pos / v["duration"])
        pygame.draw.rect(s, (60, 60, 60), (tx, ty + th - 3, tw, 3))
        pygame.draw.rect(s, RED, (tx, ty + th - 3, int(tw * frac), 3))
    lx = tx + tw + 12
    maxw = x + w - lx - 10
    lines = wrap(f.b, v.get("title") or "", maxw, 2)
    yy = y + 6
    for ln in lines:
        text(s, f.b, ln, TXT, lx, yy)
        yy += 19
    meta = []
    if v.get("channel"):
        meta.append(v["channel"])
    line2 = []
    if v.get("views") is not None:
        line2.append(fmt_views(v["views"]))
    if v.get("published"):
        line2.append(fmt_ago(v["published"]))
    if extra:
        line2.append(extra)
    yy = max(yy + 2, y + 44)
    if meta:
        text(s, f.sr, meta[0], MUTED, lx, yy, maxw=maxw)
        yy += 16
    if line2:
        text(s, f.sr, " · ".join(line2), DIM if not focused else MUTED, lx, yy, maxw=maxw)
    if app.store.in_later(v["id"]):
        icon(s, "later", x + w - 14, y + 12, ORANGE, 0.55)


def empty_state(s, f, title, sub, ic="play"):
    cy = TOP + (H - TOP - FOOT) // 2 - 30
    pygame.draw.circle(s, CARD, (W // 2, cy), 34)
    icon(s, ic, W // 2, cy, DIM, 1.2)
    text(s, f.h, title, TXT, W // 2, cy + 48, align="center")
    for i, ln in enumerate(wrap(f.r, sub, 460, 3)):
        text(s, f.r, ln, MUTED, W // 2, cy + 74 + i * 19, align="center")


# ======================================================================= telas

class Home(Screen):
    ITEMS = [("search", "Buscar", "search"), ("subs", "Inscrições", "subs"),
             ("later", "Assistir mais tarde", "later"), ("history", "Histórico", "history"),
             ("continue", "Continuar", "play"), ("settings", "Configurações", "gear")]

    def __init__(self, app):
        super().__init__(app)
        self.sel = 0

    def cont_item(self):
        for h in self.app.store.history[:15]:
            if self.app.store.resume_pos(h["id"]):
                return h
        return None

    def action(self, a):
        if a in ("left", "right"):
            if (self.sel % 2 == 0) == (a == "right"):
                self.sel += 1 if a == "right" else -1
        elif a == "up" and self.sel >= 2:
            self.sel -= 2
        elif a == "down" and self.sel < 4:
            self.sel += 2
        elif a == "a":
            self.open(self.ITEMS[self.sel][0])
        elif a == "b":
            self.app.confirm("Sair do Tubo?", "Você pode voltar a qualquer hora pelo menu Tools.",
                             self.app.quit, yes="Sair")
        elif a == "start":
            self.open("search")

    def open(self, key):
        app = self.app
        if key == "search":
            app.push(SearchScreen(app))
        elif key == "subs":
            app.push(SubsScreen(app))
        elif key == "later":
            app.push(VideoList(app, "Assistir mais tarde", lambda: app.store.later, kind="later",
                               empty=("Nada salvo", "Na lista de vídeos, aperte Y e escolha "
                                                    "“Assistir mais tarde”.", "later")))
        elif key == "history":
            app.push(VideoList(app, "Histórico", lambda: app.store.history, kind="history",
                               empty=("Histórico vazio", "Os vídeos que você assistir aparecem aqui "
                                                         "(últimos 100).", "history")))
        elif key == "continue":
            c = self.cont_item()
            if c:
                app.play(c)
            else:
                app.toast_msg("Nenhum vídeo pela metade")
        elif key == "settings":
            app.push(SettingsScreen(app))

    def sub(self, key):
        st = self.app.store
        if key == "search":
            return "%d buscas recentes" % len(st.searches) if st.searches else "Encontre vídeos e canais"
        if key == "subs":
            return "%d canais" % len(st.subs) if st.subs else "Siga canais sem conta Google"
        if key == "later":
            return "%d vídeos" % len(st.later) if st.later else "Nenhum vídeo salvo"
        if key == "history":
            return "%d vídeos" % len(st.history) if st.history else "Nada assistido ainda"
        if key == "settings":
            return "%dp · %s" % (st.settings["height"], "só áudio" if st.settings["audio_default"] else "vídeo")
        return ""

    def draw(self, s):
        f = self.f
        logo(s, 20, 14, f)
        stat = self.app.update_status_text()
        if stat:
            w = f.s.size(stat)[0] + 36
            rrect(s, CARD, (W - 20 - w, 16, w, 26), 13)
            pygame.draw.circle(s, ORANGE, (W - 20 - w + 13, 29), 4)
            text(s, f.s, stat, MUTED, W - 32, 21, align="right")
        else:
            text(s, f.sr, "yt-dlp " + self.app.yt.version(), DIM, W - 20, 22, align="right")
        pygame.draw.line(s, LINE, (0, TOP - 1), (W, TOP - 1))
        cw, ch = 292, 112
        for i, (key, label, ic) in enumerate(self.ITEMS):
            x = 20 + (i % 2) * (cw + 16)
            y = TOP + 16 + (i // 2) * (ch + 14)
            foc = i == self.sel
            rrect(s, CARD2 if foc else CARD, (x, y, cw, ch), 14)
            if foc:
                rrect(s, ACC, (x, y, cw, ch), 14, 2)
            if key == "continue":
                c = self.cont_item()
                if c:
                    img = self.app.thumbs.get(c["id"], (112, 63))
                    if img:
                        s.blit(img, (x + 14, y + 14))
                    else:
                        rrect(s, CARD2 if not foc else CARD, (x + 14, y + 14, 112, 63), 6)
                    if c.get("duration"):
                        fr = min(1, c.get("pos", 0) / c["duration"])
                        pygame.draw.rect(s, (60, 60, 60), (x + 14, y + 74, 112, 3))
                        pygame.draw.rect(s, RED, (x + 14, y + 74, int(112 * fr), 3))
                    text(s, f.h, label, TXT, x + 138, y + 14)
                    for j, ln in enumerate(wrap(f.sr, c.get("title", ""), cw - 150, 2)):
                        text(s, f.sr, ln, MUTED, x + 138, y + 38 + j * 16)
                    text(s, f.s, "de %s" % fmt_dur(c.get("pos")), ACC if foc else DIM, x + 14, y + 86)
                    continue
            rrect(s, BG if not foc else CARD, (x + 16, y + 16, 46, 46), 12)
            icon(s, ic, x + 39, y + 39, ACC if foc else MUTED)
            text(s, f.h, label, TXT, x + 16, y + 70)
            sub = self.sub(key) if key != "continue" else "Nenhum vídeo pela metade"
            text(s, f.sr, sub, MUTED, x + 16, y + 90, maxw=cw - 30)

    def hints(self):
        return [("B", "Abrir"), ("A", "Sair"), ("Start", "Buscar"), ("Menu+Start", "Fechar")]


class SearchScreen(Screen):
    ROWS = ["1234567890", "qwertyuiop", "asdfghjkl-", "zxcvbnm,.'"]
    SPECIAL = [("Espaço", 4, " "), ("Apagar", 2, "del"), ("Limpar", 2, "clr"), ("Buscar", 2, "go")]

    def __init__(self, app, query=""):
        super().__init__(app)
        self.q = query
        self.r, self.c = 1, 0
        self.hsel = 0
        self.blink = 0

    # posicao: r 0..3 teclas, r 4 especiais, r 5 historico
    def key_at(self):
        if self.r < 4:
            return self.ROWS[self.r][self.c]
        if self.r == 4:
            col = 0
            for label, span, k in self.SPECIAL:
                if self.c < col + span:
                    return k
                col += span
        return None

    def action(self, a):
        hist = self.app.store.searches[:8]
        if a == "up":
            if self.r == 5:
                self.r = 4
                self.c = 0
            elif self.r > 0:
                self.r -= 1
        elif a == "down":
            if self.r < 4:
                self.r += 1
            elif self.r == 4 and hist:
                self.r = 5
                self.hsel = min(self.hsel, len(hist) - 1)
        elif a in ("left", "right"):
            d = -1 if a == "left" else 1
            if self.r == 5:
                self.hsel = (self.hsel + d) % len(hist)
            elif self.r == 4:
                spans, col, idx = self.SPECIAL, 0, 0
                starts = []
                for _, sp, _k in spans:
                    starts.append(col)
                    col += sp
                cur = max(i for i, st in enumerate(starts) if st <= self.c)
                cur = (cur + d) % len(spans)
                self.c = starts[cur]
            else:
                self.c = (self.c + d) % 10
        elif a == "a":
            if self.r == 5:
                if hist:
                    self.q = hist[self.hsel]
                    self.go()
                return
            k = self.key_at()
            if k == " ":
                self.add(" ")
            elif k == "del":
                self.q = self.q[:-1]
            elif k == "clr":
                self.q = ""
            elif k == "go":
                self.go()
            elif k:
                self.add(k)
        elif a == "y":                   # X fisico
            if self.r == 5 and hist:
                q = hist[self.hsel]
                self.app.store.searches = [x for x in self.app.store.searches if x != q]
                self.app.store.save("searches")
                if not self.app.store.searches:
                    self.r = 4
                self.hsel = max(0, min(self.hsel, len(self.app.store.searches[:8]) - 1))
            else:
                self.q = self.q[:-1]
        elif a == "x":                   # Y fisico
            self.add(" ")
        elif a == "start":
            self.go()
        elif a == "b":
            self.app.pop()

    def add(self, ch):
        if len(self.q) < 80 and not (ch == " " and (not self.q or self.q.endswith(" "))):
            self.q += ch

    def go(self):
        q = self.q.strip()
        if not q:
            self.app.toast_msg("Digite algo para buscar")
            return
        app = self.app

        def work(job):
            if not internet_ok():
                raise TuboError("Sem internet. Conecte o Wi-Fi e tente de novo.")
            return app.yt.search(q, job)

        def done(res):
            app.store.add_search(q)
            app.push(VideoList(app, "“%s”" % q, res, kind="results", sub="%d vídeos" % len(res),
                               empty=("Nada encontrado", "Tente outras palavras.", "search")))
        app.run_job(work, "Buscando “%s”…" % q, done)

    def update(self, dt):
        self.blink = (self.blink + dt) % 1.0

    def draw(self, s):
        f = self.f
        self.header(s, "Buscar")
        # campo
        rrect(s, CARD, (20, TOP + 12, W - 40, 44), 12)
        rrect(s, LINE, (20, TOP + 12, W - 40, 44), 12, 1)
        icon(s, "search", 44, TOP + 34, MUTED, 0.7)
        shown = self.q if self.q else ""
        if shown:
            t = shown
            while f.big.size(t)[0] > W - 120:
                t = t[1:]
            wq = text(s, f.big, t, TXT, 62, TOP + 22)
        else:
            text(s, f.big, "O que você quer assistir?", DIM, 62, TOP + 22)
            wq = 0
        if self.blink < 0.55:
            pygame.draw.rect(s, ACC, (62 + wq + 2, TOP + 22, 2, 24))
        # teclado
        kx0, ky0, kw, kh, gap = 20, TOP + 70, 56, 40, 4
        for r, row in enumerate(self.ROWS):
            for c, ch in enumerate(row):
                x, y = kx0 + c * (kw + gap), ky0 + r * (kh + gap)
                foc = self.r == r and self.c == c
                rrect(s, ACC if foc else CARD2, (x, y, kw, kh), 9)
                text(s, f.key, ch, BG if foc else TXT, x + kw // 2, y + 9, align="center")
        y = ky0 + 4 * (kh + gap)
        col = 0
        for label, span, k in self.SPECIAL:
            x = kx0 + col * (kw + gap)
            w = span * kw + (span - 1) * gap
            foc = self.r == 4 and col <= self.c < col + span
            base = ACC if k == "go" else CARD
            if foc:
                rrect(s, ACC, (x, y, w, kh), 9)
                if k == "go":
                    rrect(s, TXT, (x, y, w, kh), 9, 2)
            else:
                rrect(s, (52, 66, 36) if k == "go" else CARD, (x, y, w, kh), 9)
            text(s, f.b, label, BG if foc else (ACC if k == "go" else TXT), x + w // 2, y + 10, align="center")
            col += span
        # historico
        hy = y + kh + 12
        hist = self.app.store.searches[:8]
        if hist:
            text(s, f.xs, "BUSCAS RECENTES", DIM, 22, hy)
            x = 20
            hy += 18
            for i, q in enumerate(hist):
                t = ellipsize(f.s, q, 180)
                w = f.s.size(t)[0] + 24
                if x + w > W - 20:
                    break
                foc = self.r == 5 and self.hsel == i
                rrect(s, CARD2 if foc else CARD, (x, hy, w, 28), 14)
                if foc:
                    rrect(s, ACC, (x, hy, w, 28), 14, 2)
                text(s, f.s, t, TXT if foc else MUTED, x + 12, hy + 6)
                x += w + 8
        else:
            text(s, f.sr, "Suas buscas recentes vão aparecer aqui.", DIM, 22, hy + 6)

    def hints(self):
        if self.r == 5:
            return [("B", "Buscar"), ("X", "Remover"), ("A", "Voltar"), ("Start", "Buscar")]
        return [("B", "Tecla"), ("X", "Apagar"), ("Y", "Espaço"), ("Start", "Buscar"), ("A", "Voltar")]


class VideoList(Screen):
    """Lista de videos (resultados, canal, mais tarde, historico). items pode ser funcao (lista viva)."""

    def __init__(self, app, title, items, kind="results", sub=None, empty=None):
        super().__init__(app)
        self.title = title
        self._items = items
        self.kind = kind
        self.sub = sub
        self.empty = empty or ("Nada aqui", "", "play")
        self.lv = ListView(84)

    @property
    def items(self):
        return self._items() if callable(self._items) else self._items

    def cur(self):
        it = self.items
        return it[self.lv.sel] if it and self.lv.sel < len(it) else None

    def action(self, a):
        it = self.items
        if a == "up":
            self.lv.move(-1, len(it))
        elif a == "down":
            self.lv.move(1, len(it))
        elif a in ("l1", "l2"):
            self.lv.move(-4, len(it))
        elif a in ("r1", "r2"):
            self.lv.move(4, len(it))
        elif a == "b":
            self.app.pop()
        elif a == "a" and self.cur():
            self.app.play(self.cur(), it, self.lv.sel)
        elif a == "x" and self.cur():            # Y fisico
            self.app.video_menu(self.cur(), self)
        elif a == "y" and self.cur():            # X fisico
            if self.kind in ("later", "history"):
                self.remove(self.cur())
            else:
                self.app.play(self.cur(), it, self.lv.sel, audio=True)
        else:
            self.extra_action(a)

    def extra_action(self, a):
        pass

    def remove(self, v):
        st = self.app.store
        if self.kind == "later":
            st.later = [x for x in st.later if x["id"] != v["id"]]
            st.save("later")
            self.app.toast_msg("Removido de Assistir mais tarde")
        elif self.kind == "history":
            st.history = [x for x in st.history if x["id"] != v["id"]]
            st.save("history")
            self.app.toast_msg("Removido do histórico")

    def update(self, dt):
        it = self.items
        self.lv.update(dt, len(it))
        vis = [it[i]["id"] for i in self.lv.visible(len(it))]
        ahead = [it[i]["id"] for i in range(self.lv.sel, min(len(it), self.lv.sel + 8))]
        for vid in vis + ahead:
            self.app.thumbs.request(vid)
        self.app.thumbs.prioritize(vis)

    def draw_header(self, s):
        it = self.items
        self.header(s, self.title, self.sub or ("%d vídeos" % len(it) if it else None))

    def draw(self, s):
        self.draw_header(s)
        self.draw_list(s)

    def draw_list(self, s):
        it = self.items
        if not it:
            empty_state(s, self.f, *self.empty)
            return
        clip = s.get_clip()
        s.set_clip((0, self.lv.top, W, self.lv.view_h))
        for i in self.lv.visible(len(it)):
            v = it[i]
            extra = None
            if self.kind == "history" and v.get("at"):
                extra = "visto " + fmt_ago(v["at"])
            draw_video_row(s, self.app, v, 12, self.lv.row_y(i), W - 30, i == self.lv.sel, extra=extra)
        s.set_clip(clip)
        self.lv.draw_scrollbar(s, len(it))

    def hints(self):
        if not self.items:
            return [("A", "Voltar")]
        alt = ("X", "Remover") if self.kind in ("later", "history") else ("X", "Só áudio")
        return [("B", "Assistir"), alt, ("Y", "Opções"), ("A", "Voltar")]


class ChannelScreen(VideoList):
    def __init__(self, app, cid, name, vids):
        super().__init__(app, name or "Canal", vids, kind="channel",
                         empty=("Sem vídeos", "Este canal não tem vídeos públicos recentes.", "user"))
        self.cid = cid
        self.lv.top = TOP + 50

    def extra_action(self, a):
        if a == "start":
            r = self.app.store.toggle_sub(self.cid, self.title)
            self.app.toast_msg("Inscrito em %s" % self.title if r else "Inscrição cancelada")

    def draw_header(self, s):
        f = self.f
        pygame.draw.circle(s, CARD2, (38, 29), 19)
        text(s, f.h, (self.title[:1] or "?").upper(), ACC, 38, 18, align="center")
        text(s, f.title, self.title, TXT, 66, 15, maxw=380)
        subd = self.app.store.subscribed(self.cid)
        lab = "Inscrito" if subd else "Inscrever-se"
        w = f.s.size(lab)[0] + 28
        rrect(s, CARD2 if subd else ACC, (W - 20 - w, 15, w, 28), 14)
        text(s, f.s, lab, TXT if subd else BG, W - 20 - w // 2, 21, align="center")
        pygame.draw.line(s, LINE, (0, TOP - 1), (W, TOP - 1))
        text(s, f.xs, "VÍDEOS RECENTES · %d" % len(self.items), DIM, 22, TOP + 16)
        text(s, f.sr, "Start: %s" % ("cancelar inscrição" if subd else "inscrever-se"), DIM, W - 22,
             TOP + 15, align="right")

    def hints(self):
        h = super().hints()
        return h[:3] + [("Start", "Inscrição"), ("A", "Voltar")]


class SubsScreen(VideoList):
    """Abas: Novidades (videos novos dos canais inscritos, via RSS) e Canais."""

    def __init__(self, app):
        super().__init__(app, "Inscrições", self.feed_items, kind="feed")
        self.tab = 0
        self.feed = core.load_json("feed_cache.json", {"at": 0, "videos": [], "subs": []})
        self.clv = ListView(58, top=TOP + 44)
        self.lv.top = TOP + 44
        self.loaded = False
        self.maybe_refresh()

    def feed_items(self):
        ids = {s["id"] for s in self.app.store.subs}
        return [v for v in self.feed.get("videos", []) if v.get("channel_id") in ids]

    def maybe_refresh(self, force=False):
        subs = list(self.app.store.subs)
        if not subs:
            return
        same = sorted(self.feed.get("subs", [])) == sorted(s["id"] for s in subs)
        if not force and same and time.time() - self.feed.get("at", 0) < 15 * 60:
            return
        app = self.app

        def work(job):
            return core.fetch_feed(subs, job)

        def done(res):
            vids, fails = res
            self.feed = {"at": int(time.time()), "videos": vids, "subs": [s["id"] for s in subs]}
            core.save_json("feed_cache.json", self.feed)
            self.lv.sel = 0
            if fails:
                app.toast_msg("%d canal(is) não responderam" % fails)
        app.run_job(work, "Buscando vídeos novos de %d canais…" % len(subs), done)

    def resumed(self):
        if self.tab == 0:
            self.maybe_refresh()

    def action(self, a):
        if a in ("left", "right"):
            self.tab = 1 - self.tab
            if self.tab == 0:
                self.maybe_refresh()
            return
        if self.tab == 0:
            if a == "start":
                self.maybe_refresh(force=True)
                return
            return super().action(a)
        subs = self.app.store.subs
        if a == "up":
            self.clv.move(-1, len(subs))
        elif a == "down":
            self.clv.move(1, len(subs))
        elif a in ("l1", "l2"):
            self.clv.move(-5, len(subs))
        elif a in ("r1", "r2"):
            self.clv.move(5, len(subs))
        elif a == "b":
            self.app.pop()
        elif a == "a" and subs:
            sc = subs[self.clv.sel]
            self.app.open_channel(sc["id"], sc["name"])
        elif a == "y" and subs:
            sc = subs[self.clv.sel]
            self.app.confirm("Cancelar inscrição?", sc["name"],
                             lambda: (self.app.store.toggle_sub(sc["id"], sc["name"]),
                                      self.app.toast_msg("Inscrição cancelada")), yes="Cancelar inscrição")

    def update(self, dt):
        if self.tab == 0:
            super().update(dt)
        else:
            self.clv.update(dt, len(self.app.store.subs))

    def draw(self, s):
        f = self.f
        self.header(s, "Inscrições", "%d canais" % len(self.app.store.subs))
        x = 20
        for i, lab in enumerate(("Novidades", "Canais")):
            w = f.b.size(lab)[0] + 30
            foc = self.tab == i
            rrect(s, ACC if foc else CARD, (x, TOP + 8, w, 30), 15)
            text(s, f.b, lab, BG if foc else MUTED, x + w // 2, TOP + 14, align="center")
            x += w + 8
        if self.tab == 0 and self.feed.get("at"):
            text(s, f.sr, "atualizado " + fmt_ago(self.feed["at"]), DIM, W - 20, TOP + 16, align="right")
        if not self.app.store.subs:
            empty_state(s, f, "Nenhuma inscrição",
                        "Abra um canal (Y numa lista de vídeos → Abrir canal) e aperte Start para "
                        "se inscrever. Fica salvo só no console.", "subs")
            return
        if self.tab == 0:
            self.empty = ("Sem vídeos novos", "Aperte Start para atualizar.", "subs")
            self.draw_list(s)
            return
        subs = self.app.store.subs
        clip = s.get_clip()
        s.set_clip((0, self.clv.top, W, self.clv.view_h))
        for i in self.clv.visible(len(subs)):
            sc = subs[i]
            y = self.clv.row_y(i)
            foc = i == self.clv.sel
            if foc:
                rrect(s, CARD2, (12, y, W - 30, 52), 10)
                rrect(s, ACC, (12, y, W - 30, 52), 10, 2)
            pygame.draw.circle(s, CARD2 if not foc else CARD, (42, y + 26), 18)
            text(s, f.h, sc["name"][:1].upper(), ACC, 42, y + 15, align="center")
            text(s, f.b, sc["name"], TXT, 72, y + 8, maxw=W - 130)
            n = sum(1 for v in self.feed.get("videos", []) if v.get("channel_id") == sc["id"])
            text(s, f.sr, "inscrito %s%s" % (fmt_ago(sc.get("added")), " · %d vídeos recentes" % n if n else ""),
                 MUTED, 72, y + 29, maxw=W - 130)
        s.set_clip(clip)
        self.clv.draw_scrollbar(s, len(subs))

    def hints(self):
        if not self.app.store.subs:
            return [("A", "Voltar")]
        if self.tab == 0:
            return [("B", "Assistir"), ("X", "Só áudio"), ("Y", "Opções"), ("Start", "Atualizar"),
                    ("◀▶", "Aba")]
        return [("B", "Abrir canal"), ("X", "Cancelar inscrição"), ("◀▶", "Aba"), ("A", "Voltar")]


class SettingsScreen(Screen):
    def __init__(self, app):
        super().__init__(app)
        self.lv = ListView(50)
        self.cache_size = core.dir_size(core.THUMBS)

    def rows(self):
        st = self.app.store.settings
        sl = {"off": "Desligadas", "pt": "Português", "en": "Inglês"}
        onoff = lambda b: "Ligado" if b else "Desligado"
        u = self.app.update_status()
        stv = self.app.store.state
        chk = core.load_json("state.json", {}).get("last_check")
        return [
            ("height", "Resolução do vídeo", "%dp" % st["height"], "Menor = menos dados e menos CPU"),
            ("autoplay", "Próximo vídeo automático", onoff(st["autoplay"]), "Ao terminar, toca o próximo da lista"),
            ("audio_default", "Abrir em só áudio", onoff(st["audio_default"]), "B passa a abrir só o áudio"),
            ("sub_lang", "Legendas", sl.get(st["sub_lang"], "Desligadas"), "Select liga/desliga no vídeo"),
            ("resume", "Continuar de onde parou", onoff(st["resume"]), "Retoma vídeos pela metade"),
            ("fill", "Preencher a tela", onoff(st["fill"]), "Corta as laterais do 16:9 (Y no vídeo)"),
            ("clear_thumbs", "Limpar miniaturas", fmt_size(self.cache_size), "Limite automático de 30 MB"),
            ("clear_hist", "Limpar histórico", "%d vídeos" % len(self.app.store.history), ""),
            ("clear_search", "Limpar buscas recentes", "%d" % len(self.app.store.searches), ""),
            ("ytdlp", "Versão do yt-dlp", self.app.yt.version(),
             "verificado " + fmt_ago(chk) if chk else "ainda não verificado"),
            ("update", "Atualizar yt-dlp agora", "…" if u.get("state") == "running" else "",
             u.get("msg", "Automático a cada 3 dias")),
            ("about", "Sobre o Tubo", "v" + VERSION, "Fonte Inter (SIL OFL) · usa yt-dlp e mpv"),
        ]

    def action(self, a):
        rows = self.rows()
        key = rows[self.lv.sel][0]
        st = self.app.store.settings
        if a == "up":
            self.lv.move(-1, len(rows))
        elif a == "down":
            self.lv.move(1, len(rows))
        elif a == "b":
            self.app.pop()
        elif a in ("left", "right", "a"):
            d = -1 if a == "left" else 1
            if key == "height":
                opts = [240, 360, 480]
                st["height"] = opts[(opts.index(st["height"]) + d) % 3 if st["height"] in opts else 1]
            elif key == "sub_lang":
                opts = ["off", "pt", "en"]
                st["sub_lang"] = opts[(opts.index(st["sub_lang"]) + d) % 3]
            elif key in ("autoplay", "audio_default", "resume", "fill"):
                st[key] = not st[key]
            elif a != "a":
                return
            elif key == "clear_thumbs":
                def do():
                    for n in os.listdir(core.THUMBS):
                        try:
                            os.remove(os.path.join(core.THUMBS, n))
                        except OSError:
                            pass
                    self.app.thumbs.clear()
                    self.cache_size = core.dir_size(core.THUMBS)
                    self.app.toast_msg("Miniaturas apagadas")
                self.app.confirm("Limpar miniaturas?", "Elas são baixadas de novo quando precisar.", do,
                                 yes="Limpar")
            elif key == "clear_hist":
                def do():
                    self.app.store.history = []
                    self.app.store.save("history")
                    self.app.toast_msg("Histórico apagado")
                self.app.confirm("Limpar histórico?", "Também apaga as posições de “continuar”.", do,
                                 yes="Limpar")
            elif key == "clear_search":
                self.app.store.searches = []
                self.app.store.save("searches")
                self.app.toast_msg("Buscas recentes apagadas")
            elif key in ("update", "ytdlp"):
                self.app.start_update(force=True)
            if key in st:
                self.app.store.save("settings")

    def update(self, dt):
        self.lv.update(dt, len(self.rows()))

    def draw(self, s):
        f = self.f
        self.header(s, "Configurações")
        rows = self.rows()
        clip = s.get_clip()
        s.set_clip((0, self.lv.top, W, self.lv.view_h))
        for i in self.lv.visible(len(rows)):
            key, label, val, hint = rows[i]
            y = self.lv.row_y(i)
            foc = i == self.lv.sel
            if foc:
                rrect(s, CARD2, (12, y, W - 30, 44), 10)
                rrect(s, ACC, (12, y, W - 30, 44), 10, 2)
            text(s, f.b, label, TXT, 28, y + 5)
            if hint:
                text(s, f.sr, hint, MUTED if foc else DIM, 28, y + 24, maxw=380)
            if val:
                choice = key in ("height", "sub_lang", "autoplay", "audio_default", "resume", "fill")
                col = ACC if (choice and val not in ("Desligado", "Desligadas")) else MUTED
                vx = W - 34
                cy = y + 22
                if choice and foc:
                    pygame.draw.polygon(s, ACC, [(vx, cy), (vx - 7, cy - 6), (vx - 7, cy + 6)])
                    vx -= 16
                w = text(s, f.b, val, col, vx, y + 12, align="right")
                if choice and foc:
                    lx = vx - w - 10
                    pygame.draw.polygon(s, ACC, [(lx - 7, cy), (lx, cy - 6), (lx, cy + 6)])
        s.set_clip(clip)
        self.lv.draw_scrollbar(s, len(rows))

    def hints(self):
        return [("◀▶", "Alterar"), ("B", "Selecionar"), ("A", "Voltar")]


class AudioScreen(Screen):
    """So audio: mpv sem video controlado pela IPC; Y apaga a tela."""

    def __init__(self, app, r, v, playlist, idx, start):
        super().__init__(app)
        self.r, self.v, self.playlist, self.idx = r, v, playlist, idx
        self.screen_off = False
        self.ended = False
        self.t0 = time.time()
        app.store.add_history(v, start, r.get("duration"))
        self.m = player.Mpv(player.audio_cmd(r, app.store.settings, start))
        self.m.dur = r.get("duration")
        self.m.pos = start or 0
        app.thumbs.request(v["id"])

    def set_screen(self, on):
        if on == (not self.screen_off):
            return
        self.screen_off = not on
        player.screen(on)

    def action(self, a):
        if self.screen_off:
            self.set_screen(True)
            return
        m = self.m
        if a in ("a", "start"):
            m.command("cycle", "pause")
            m.paused = not m.paused
        elif a == "left":
            m.command("seek", -10)
        elif a == "right":
            m.command("seek", 10)
        elif a in ("l1", "l2"):
            m.command("seek", -60)
        elif a in ("r1", "r2"):
            m.command("seek", 60)
        elif a == "up":
            m.command("add", "volume", 5)
            m.volume = min(130, m.volume + 5)
        elif a == "down":
            m.command("add", "volume", -5)
            m.volume = max(0, m.volume - 5)
        elif a == "x":
            self.set_screen(False)
        elif a == "y":
            self.app.video_menu(self.v, None, in_player=True)
        elif a == "b":
            self.leave()

    def leave(self, eof=False):
        if self.ended:
            return
        self.ended = True
        pos = self.m.pos
        if self.m.running():
            self.m.stop()
        else:
            self.m.finish()
        self.set_screen(True)
        self.app.store.add_history(self.v, 0 if eof else pos, self.m.dur)
        self.app.pop()

    def close(self):
        if not self.ended:
            self.ended = True
            self.app.store.add_history(self.v, self.m.pos, self.m.dur)
            self.m.stop()
            self.set_screen(True)

    def update(self, dt):
        if self.ended or self.m.running():
            return
        rc = self.m.finish()
        dur = self.m.dur or 0
        eof = rc == 0 and (not dur or self.m.pos >= dur - 15)
        self.ended = True
        self.set_screen(True)
        self.app.store.add_history(self.v, 0 if eof else self.m.pos, self.m.dur)
        self.app.pop()
        if eof:
            self.app.after_playback(self.playlist, self.idx, audio=True)
        elif rc == 5:
            self.app.quit()
        else:
            self.app.message("A reprodução parou", player_error_text(rc, time.time() - self.t0))

    def draw(self, s):
        if self.screen_off:
            s.fill((0, 0, 0))
            return
        f, m, v = self.f, self.m, self.v
        self.header(s, "Só áudio", "Y apaga a tela")
        cw, ch = 352, 198
        cx, cy = (W - cw) // 2, TOP + 18
        img = self.app.thumbs.get(v["id"], (cw, ch))
        if img:
            s.blit(img, (cx, cy))
        else:
            rrect(s, CARD, (cx, cy, cw, ch), 12)
            icon(s, "note", W // 2, cy + ch // 2, DIM, 2.0)
        rrect(s, BG, (cx - 2, cy - 2, cw + 4, ch + 4), 14, 3)
        y = cy + ch + 14
        for ln in wrap(f.h, v.get("title", ""), 560, 2):
            text(s, f.h, ln, TXT, W // 2, y, align="center")
            y += 22
        text(s, f.r, v.get("channel", ""), MUTED, W // 2, y + 2, maxw=520, align="center")
        # barra
        by = H - FOOT - 50
        dur = m.dur or 0
        pos = min(m.pos, dur) if dur else m.pos
        rrect(s, CARD2, (40, by, W - 80, 6), 3)
        if dur:
            rrect(s, ACC, (40, by, max(6, int((W - 80) * pos / dur)), 6), 3)
            pygame.draw.circle(s, TXT, (40 + int((W - 80) * pos / dur), by + 3), 7)
        text(s, f.s, fmt_dur(pos) or "0:00", MUTED, 40, by + 14)
        text(s, f.s, fmt_dur(dur) if dur else ("AO VIVO" if v.get("live") else "--:--"), MUTED, W - 40, by + 14,
             align="right")
        st = "Carregando…" if m.buffering and not m.paused else ("Pausado" if m.paused else "Tocando")
        text(s, f.s, "%s · volume %d%%" % (st, m.volume), ACC if st == "Tocando" else ORANGE, W // 2, by + 14,
             align="center")

    def hints(self):
        return [("B", "Pausar"), ("◀▶", "±10s"), ("L1/R1", "±1min"), ("▲▼", "Vol"), ("Y", "Apagar tela"),
                ("A", "Sair")]


def player_error_text(rc, elapsed):
    tail = ""
    try:
        with open(player.MPV_LOG, encoding="utf-8", errors="replace") as fh:
            ls = [l.strip() for l in fh.read().splitlines() if l.strip()]
        if ls:
            tail = ls[-1][:140]
    except OSError:
        pass
    if rc == 2:
        msg = "O mpv não conseguiu abrir o vídeo."
    elif rc == 0:
        msg = "O vídeo parou antes do fim (rede instável?). A posição foi salva."
    else:
        msg = "O mpv saiu com código %s." % rc
    if tail:
        msg += " Detalhe: " + tail
    return msg


# ======================================================================= modais

class Modal:
    def action(self, a):
        pass

    def update(self, dt):
        pass


class Dialog(Modal):
    def __init__(self, app, title, body, buttons):
        self.app, self.title, self.body, self.buttons = app, title, body, buttons
        self.sel = 0

    def action(self, a):
        if a in ("left", "right") and len(self.buttons) > 1:
            self.sel = 1 - self.sel
        elif a == "a":
            self.app.modals.remove(self)
            fn = self.buttons[self.sel][1]
            if fn:
                fn()
        elif a == "b":
            self.app.modals.remove(self)

    def draw(self, s):
        f = self.app.f
        alpha_rect(s, (0, 0, 0), (0, 0, W, H), 170)
        lines = wrap(f.r, self.body, 400, 6)
        h = 120 + len(lines) * 19
        x, y = (W - 460) // 2, (H - h) // 2
        rrect(s, CARD, (x, y, 460, h), 16)
        rrect(s, LINE, (x, y, 460, h), 16, 1)
        text(s, f.h, self.title, TXT, x + 28, y + 22, maxw=404)
        for i, ln in enumerate(lines):
            text(s, f.r, ln, MUTED, x + 28, y + 52 + i * 19)
        bx = x + 460 - 24
        for i in range(len(self.buttons) - 1, -1, -1):
            lab = self.buttons[i][0]
            w = f.b.size(lab)[0] + 32
            bx -= w
            foc = i == self.sel
            rrect(s, ACC if foc else CARD2, (bx, y + h - 54, w, 34), 17)
            text(s, f.b, lab, BG if foc else TXT, bx + w // 2, y + h - 46, align="center")
            bx -= 10


class Menu(Modal):
    def __init__(self, app, title, options):
        self.app, self.title, self.options = app, title, options
        self.sel = 0

    def action(self, a):
        if a == "up":
            self.sel = (self.sel - 1) % len(self.options)
        elif a == "down":
            self.sel = (self.sel + 1) % len(self.options)
        elif a == "a":
            self.app.modals.remove(self)
            self.options[self.sel][1]()
        elif a in ("b", "x"):
            self.app.modals.remove(self)

    def draw(self, s):
        f = self.app.f
        alpha_rect(s, (0, 0, 0), (0, 0, W, H), 160)
        h = 66 + len(self.options) * 44
        x, y = (W - 440) // 2, max(20, (H - h) // 2)
        rrect(s, CARD, (x, y, 440, h), 16)
        rrect(s, LINE, (x, y, 440, h), 16, 1)
        text(s, f.s, self.title, MUTED, x + 24, y + 18, maxw=392)
        for i, (lab, _fn) in enumerate(self.options):
            yy = y + 48 + i * 44
            foc = i == self.sel
            if foc:
                rrect(s, ACC, (x + 12, yy, 416, 38), 10)
            text(s, f.b, lab, BG if foc else TXT, x + 26, yy + 9, maxw=390)


class Loading(Modal):
    def __init__(self, app, job, msg, cancellable=True):
        self.app, self.job, self.msg, self.cancellable = app, job, msg, cancellable
        self.t = 0.0

    def action(self, a):
        if a == "b" and self.cancellable:
            self.job.cancel()
            self.app.finish_job(cancelled=True)

    def update(self, dt):
        self.t += dt

    def draw(self, s):
        f = self.app.f
        alpha_rect(s, (0, 0, 0), (0, 0, W, H), 150)
        w, h = 420, 118
        x, y = (W - w) // 2, (H - h) // 2
        rrect(s, CARD, (x, y, w, h), 16)
        rrect(s, LINE, (x, y, w, h), 16, 1)
        cx, cy = x + 46, y + h // 2
        pygame.draw.circle(s, CARD2, (cx, cy), 18, 4)
        a0 = self.t * 5.5
        pygame.draw.arc(s, ACC, (cx - 18, cy - 18, 36, 36), a0, a0 + 1.9, 4)
        lines = wrap(f.b, self.msg, w - 110, 2)
        for i, ln in enumerate(lines):
            text(s, f.b, ln, TXT, x + 82, y + 30 + i * 20 - (10 if len(lines) == 1 else 0) + 6)
        sub = "A cancela" if self.cancellable else "aguarde"
        if self.t > 12:
            sub = "Está demorando… " + sub
        text(s, f.sr, sub, MUTED, x + 82, y + h - 36)


class Countdown(Modal):
    def __init__(self, app, v, go):
        self.app, self.v, self.go = app, v, go
        self.left = 6.0

    def action(self, a):
        if a == "a":
            self.app.modals.remove(self)
            self.go()
        elif a == "b":
            self.app.modals.remove(self)

    def update(self, dt):
        self.left -= dt
        if self.left <= 0 and self in self.app.modals:
            self.app.modals.remove(self)
            self.go()

    def draw(self, s):
        f = self.app.f
        alpha_rect(s, (0, 0, 0), (0, 0, W, H), 170)
        w, h = 480, 190
        x, y = (W - w) // 2, (H - h) // 2
        rrect(s, CARD, (x, y, w, h), 16)
        text(s, f.s, "PRÓXIMO EM %d s" % max(0, math.ceil(self.left)), ACC, x + 24, y + 20)
        img = self.app.thumbs.get(self.v["id"], (160, 90))
        if img:
            s.blit(img, (x + 24, y + 46))
        else:
            rrect(s, CARD2, (x + 24, y + 46, 160, 90), 8)
        for i, ln in enumerate(wrap(f.b, self.v.get("title", ""), w - 220, 3)):
            text(s, f.b, ln, TXT, x + 198, y + 48 + i * 20)
        text(s, f.sr, self.v.get("channel", ""), MUTED, x + 198, y + 116, maxw=w - 220)
        frac = max(0, self.left / 6.0)
        rrect(s, CARD2, (x + 24, y + h - 34, w - 48, 6), 3)
        rrect(s, ACC, (x + 24, y + h - 34, int((w - 48) * (1 - frac)) + 2, 6), 3)
        text(s, f.sr, "B assistir agora · A cancelar", MUTED, x + w - 24, y + 20, align="right")


# ======================================================================= app

def init_display():
    pygame.font.init()
    if os.environ.get("SDL_VIDEODRIVER") in ("dummy", "offscreen"):
        try:
            pygame.display.init()
            return pygame.display.set_mode((W, H)), False
        except pygame.error:
            return pygame.Surface((W, H)), False      # SDL do Knulli nao tem dummy: desenha so em memoria
    pygame.display.init()
    scr = pygame.display.set_mode((W, H), pygame.FULLSCREEN)
    pygame.mouse.set_visible(False)
    return scr, True


class App:
    def __init__(self):
        core.setup_log()
        log.info("Tubo %s iniciando (python %s, pygame %s)", VERSION, sys.version.split()[0], pygame.version.ver)
        self.store = Store()
        self.yt = YtDlp()
        self.thumbs = Thumbs()
        self.surf, self.real = init_display()
        self.f = Fonts()
        self.inp = Input()
        self.stack = [Home(self)]
        self.modals = []
        self.job = None
        self.job_cb = None
        self.toast = None
        self.running = True
        self.upd_proc = None
        self.upd_cache = (0, {})
        threading.Thread(target=core.prune_thumbs, daemon=True).start()
        threading.Thread(target=self._auto_update, daemon=True).start()
        threading.Thread(target=self.yt.warm, daemon=True).start()

    # --------------------------------------------------------------- pilha
    @property
    def top(self):
        return self.stack[-1]

    def push(self, sc):
        self.stack.append(sc)

    def pop(self):
        if len(self.stack) > 1:
            self.stack.pop()
            self.top.resumed()

    def quit(self):
        self.running = False

    # --------------------------------------------------------------- avisos
    def toast_msg(self, t):
        self.toast = (t, time.time() + 2.6)

    def message(self, title, body):
        self.modals.append(Dialog(self, title, body, [("OK", None)]))

    def confirm(self, title, body, on_yes, yes="Sim"):
        self.modals.append(Dialog(self, title, body, [("Cancelar", None), (yes, on_yes)]))
        self.modals[-1].sel = 1

    # --------------------------------------------------------------- tarefas
    def run_job(self, fn, msg, done, cancellable=True, on_error=None):
        if self.job:
            return
        self.job = Job(fn)
        self.job_cb = (done, on_error)
        self.modals.append(Loading(self, self.job, msg, cancellable))

    def finish_job(self, cancelled=False):
        job, (done, on_err) = self.job, self.job_cb
        self.job = None
        self.modals = [m for m in self.modals if not isinstance(m, Loading)]
        if cancelled or job.cancelled:
            self.toast_msg("Cancelado")
            return
        if job.error:
            log.info("erro mostrado: %s", job.error)
            if on_err:
                on_err(job.error)
            else:
                self.message("Não deu certo", job.error)
            return
        done(job.result)

    # --------------------------------------------------------------- atualizacao do yt-dlp
    def _auto_update(self):
        time.sleep(1.5)
        st = core.load_json("state.json", {})
        if not os.path.exists(core.YTDLP_ZIP):
            # sem o yt-dlp (instalado sem internet na hora): baixa agora
            self.start_update(mode="--force")
            return
        need_build = not os.path.exists(core.YTDLP_PYZ) or st.get("pyz_python") != sys.version.split()[0]
        if need_build:
            self.start_update(mode="--build")
            return
        if time.time() - st.get("last_check", 0) < 3 * 86400:
            return
        if internet_ok():
            self.start_update(mode="--auto")

    def start_update(self, force=False, mode=None):
        if self.upd_proc and self.upd_proc.poll() is None:
            self.toast_msg("Atualização já em andamento")
            return
        mode = mode or ("--force" if force else "--auto")
        self.upd_proc = subprocess.Popen([sys.executable, os.path.join(core.HERE, "updater.py"), mode],
                                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL)
        self.upd_mode = mode
        self.upd_cache = (0, {})

    def update_status(self):
        t, st = self.upd_cache
        if time.time() - t > 1.0:
            st = core.load_json("update.json", {})
            self.upd_cache = (time.time(), st)
        return st

    def update_status_text(self):
        if self.upd_proc and self.upd_proc.poll() is None:
            return "Atualizando yt-dlp…" if self.upd_mode != "--build" else "Preparando yt-dlp…"
        return ""

    def _check_update_done(self):
        if self.upd_proc and self.upd_proc.poll() is not None:
            rc = self.upd_proc.returncode
            self.yt.restart()        # reabre o worker com o yt-dlp novo
            self.upd_proc = None
            self.upd_cache = (0, {})
            st = self.update_status()
            if self.upd_mode == "--force" or (st.get("state") == "ok" and self.upd_mode == "--auto"):
                self.toast_msg(st.get("msg", "Pronto") if rc == 0 or st else "Falha ao atualizar")

    # --------------------------------------------------------------- videos
    def video_menu(self, v, screen, in_player=False):
        st = self.store
        opts = []
        if not in_player:
            opts.append(("Assistir", lambda: self.play(v, screen.items if screen else None,
                                                         screen.lv.sel if screen else None)))
            opts.append(("Ouvir só o áudio", lambda: self.play(v, screen.items if screen else None,
                                                                 screen.lv.sel if screen else None, audio=True)))
        later = st.in_later(v["id"])

        def tl():
            r = st.toggle_later(v)
            self.toast_msg("Salvo em Assistir mais tarde" if r else "Removido de Assistir mais tarde")
        opts.append(("Remover de Assistir mais tarde" if later else "Assistir mais tarde", tl))
        cid, cname = v.get("channel_id"), v.get("channel") or "canal"
        if cid:
            if not (isinstance(screen, ChannelScreen) and screen.cid == cid) and not in_player:
                opts.append(("Abrir canal: %s" % cname, lambda: self.open_channel(cid, cname)))

            def ts():
                r = st.toggle_sub(cid, cname)
                self.toast_msg("Inscrito em %s" % cname if r else "Inscrição cancelada")
            opts.append(("Cancelar inscrição" if st.subscribed(cid) else "Inscrever-se em %s" % cname, ts))
        if screen is not None and getattr(screen, "kind", "") == "history":
            opts.append(("Remover do histórico", lambda: screen.remove(v)))
        self.modals.append(Menu(self, v.get("title", ""), opts))

    def open_channel(self, cid, name):
        def work(job):
            if not internet_ok():
                raise TuboError("Sem internet. Conecte o Wi-Fi e tente de novo.")
            return self.yt.channel(cid, job)

        def done(res):
            nm, vids = res
            nm = nm or name
            for s in self.store.subs:          # mantem o nome do canal inscrito atualizado
                if s["id"] == cid and nm and s["name"] != nm:
                    s["name"] = nm
                    self.store.save("subs")
            self.push(ChannelScreen(self, cid, nm, vids))
        self.run_job(work, "Abrindo canal %s…" % name, done)

    def play(self, v, playlist=None, idx=None, audio=None):
        st = self.store.settings
        if audio is None:
            audio = st["audio_default"]
        height = st["height"]

        def work(job):
            if not internet_ok():
                raise TuboError("Sem internet. Conecte o Wi-Fi e tente de novo.")
            return self.yt.resolve(v["id"], height, audio, st["sub_lang"], job)

        def done(r):
            vv = dict(v)
            for k in ("title", "channel", "channel_id", "duration", "live"):
                if r.get(k):
                    vv[k] = r[k]
            start = self.store.resume_pos(v["id"]) if st["resume"] and not r.get("live") else 0
            if audio:
                self.push(AudioScreen(self, r, vv, playlist, idx, start))
            else:
                self.play_video(r, vv, playlist, idx, start)
        self.run_job(work, ("Abrindo áudio: " if audio else "Abrindo: ") + (v.get("title") or v["id"]), done)

    def release_display(self):
        self.inp.close()
        if self.real and not os.environ.get("TUBO_MPV_EXTRA"):
            pygame.display.quit()

    def restore_display(self):
        if self.real and not os.environ.get("TUBO_MPV_EXTRA"):
            pygame.display.init()
            self.surf = pygame.display.set_mode((W, H), pygame.FULLSCREEN)
            pygame.mouse.set_visible(False)
        self.inp = Input()
        try:
            pygame.event.clear()     # descarta os botoes apertados dentro do mpv
        except pygame.error:
            pass

    def play_video(self, r, v, playlist, idx, start):
        self.store.add_history(v, start, r.get("duration"))
        cmd = player.video_cmd(r, self.store.settings, start)
        self.release_display()
        t0 = time.time()
        m = player.Mpv(cmd)
        m.dur = r.get("duration")
        try:
            while m.running():
                time.sleep(0.1)
        finally:
            rc = m.finish()
            self.restore_display()
        dur = m.dur or 0
        eof = rc == 0 and (not dur or m.pos >= dur - 15)
        self.store.add_history(v, 0 if eof else m.pos, m.dur)
        log.info("video %s terminou rc=%s eof=%s em %.0fs", v["id"], rc, eof, time.time() - t0)
        if rc == 5:
            self.quit()
        elif eof:
            self.after_playback(playlist, idx, audio=False)
        elif rc not in (4,):
            self.message("A reprodução parou", player_error_text(rc, time.time() - t0))

    def after_playback(self, playlist, idx, audio):
        if not self.store.settings["autoplay"] or playlist is None or idx is None:
            return
        if idx + 1 >= len(playlist):
            self.toast_msg("Fim da lista")
            return
        nxt = playlist[idx + 1]
        self.thumbs.request(nxt["id"])
        self.modals.append(Countdown(self, nxt, lambda: self.play(nxt, playlist, idx + 1, audio=audio)))

    # --------------------------------------------------------------- laco
    def step(self, actions, dt):
        if self.job and self.job.done:
            self.finish_job()
        self._check_update_done()
        for a in actions:
            if a == "quit":
                self.quit()
                continue
            if self.modals:
                self.modals[-1].action(a)
            else:
                self.top.action(a)
        self.top.update(dt)
        for m in list(self.modals):
            m.update(dt)

    def draw(self, s=None):
        s = s or self.surf
        s.fill(BG)
        self.top.draw(s)
        if not (isinstance(self.top, AudioScreen) and self.top.screen_off):
            draw_hints(s, self.f, self.top.hints() if not self.modals else self.modal_hints())
        for m in self.modals:
            m.draw(s)
        if self.toast and time.time() < self.toast[1]:
            t = self.toast[0]
            w = self.f.s.size(t)[0] + 32
            rrect(s, TXT, ((W - w) // 2, H - FOOT - 46, w, 34), 17)
            text(s, self.f.s, t, BG, W // 2, H - FOOT - 37, align="center")

    def modal_hints(self):
        m = self.modals[-1]
        if isinstance(m, Loading):
            return [("A", "Cancelar")] if m.cancellable else []
        if isinstance(m, Countdown):
            return [("B", "Assistir agora"), ("A", "Cancelar")]
        return [("B", "Confirmar"), ("A", "Fechar")]

    def loop(self):
        clock = pygame.time.Clock()
        last = time.time()
        while self.running:
            now = time.time()
            dt = min(0.1, now - last)
            last = now
            try:
                acts = self.inp.poll(pygame.event.get())
            except pygame.error:
                acts = []
            self.step(acts, dt)
            if not self.running:
                break
            self.draw()
            pygame.display.flip()
            idle = isinstance(self.top, AudioScreen) and self.top.screen_off
            clock.tick(6 if idle else 30)

    def shutdown(self):
        for sc in self.stack:
            if isinstance(sc, AudioScreen):
                sc.close()
        if self.job:
            self.job.cancel()
        self.store.save("settings")
        self.yt.stop()
        log.info("Tubo saiu")


def main():
    app = None
    try:
        app = App()
        app.loop()
    except Exception:
        log.error("falha: %s", traceback.format_exc())
        raise
    finally:
        if app:
            app.shutdown()
        pygame.quit()


if __name__ == "__main__":
    main()
