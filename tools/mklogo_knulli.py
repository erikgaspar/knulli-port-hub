#!/usr/bin/env python3
# Logo do Knulli Port Hub (estilo pixel, cores proprias) + capa, marquee e fanart.
import os, math, random
from PIL import Image, ImageDraw, ImageFont, ImageFilter

FD = "/tmp/klogo/fonts"; OUT = "/tmp/klogo/out"; os.makedirs(OUT, exist_ok=True)
PIX = os.path.join(FD, "PressStart2P-Regular.ttf")
INTER = os.path.join(FD, "ChakraPetch-SemiBold.ttf")

INK = (10, 9, 20, 255)          # contorno escuro
LIME_T, LIME_B = (196, 255, 98), (46, 214, 128)
CYAN = (56, 214, 255, 255)
PINK = (255, 79, 139, 255)
PLATE = (24, 36, 70, 255)
BADGE_T, BADGE_B = (58, 30, 98), (20, 26, 58)

def grad(size, top, bot):
    w, h = size; g = Image.new("RGBA", size)
    d = ImageDraw.Draw(g)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line((0, y, w, y), fill=tuple(round(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
    return g

def text_layer(size, txt, font, fill_top, fill_bot, stroke, shadow):
    # texto com degrade, contorno e sombra (tudo em pixels inteiros)
    W, H = size
    mask = Image.new("L", size, 0); ImageDraw.Draw(mask).text((W // 2, H // 2), txt, font=font, fill=255, anchor="mm")
    out = Image.new("RGBA", size, (0, 0, 0, 0))
    # contorno: dilata a mascara
    ol = mask.filter(ImageFilter.MaxFilter(stroke * 2 + 1))
    sh = Image.new("RGBA", size, (0, 0, 0, 0)); sh.paste(INK, (shadow, shadow), ol)
    out = Image.alpha_composite(out, sh)
    o2 = Image.new("RGBA", size, (0, 0, 0, 0)); o2.paste(INK, (0, 0), ol)
    out = Image.alpha_composite(out, o2)
    g = grad(size, fill_top, fill_bot); g.putalpha(mask)
    # brilho: faixa clara no topo das letras
    hi = Image.new("L", size, 0); bb = mask.getbbox()
    if bb:
        ImageDraw.Draw(hi).rectangle((0, bb[1], W, bb[1] + max(2, (bb[3] - bb[1]) // 6)), fill=90)
        hi = Image.composite(hi, Image.new("L", size, 0), mask)
        white = Image.new("RGBA", size, (255, 255, 255, 255)); white.putalpha(hi)
        g = Image.alpha_composite(g, white)
    return Image.alpha_composite(out, g)

def sparkle(d, x, y, s, col):
    d.rectangle((x - s, y - s * 3, x + s, y + s * 3), fill=col)
    d.rectangle((x - s * 3, y - s, x + s * 3, y + s), fill=col)

def badge(W=504, H=340):
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    # escudo octogonal (cantos chanfrados em degraus de pixel)
    c = 36; m = 14
    poly = [(m + c, m), (W - m - c, m), (W - m, m + c), (W - m, H - m - c - 30), (W // 2 + 40, H - m),
            (W // 2 - 40, H - m), (m, H - m - c - 30), (m, m + c)]
    d.polygon(poly, fill=INK)
    inner = [(x + (6 if x < W / 2 else -6), y + (6 if y < H / 2 else -6)) for x, y in poly]
    mask = Image.new("L", (W, H), 0); ImageDraw.Draw(mask).polygon(inner, fill=255)
    g = grad((W, H), BADGE_T, BADGE_B); im.paste(g, (0, 0), mask)
    d.line(inner + [inner[0]], fill=CYAN, width=6, joint="curve")
    # grade pixel discreta no fundo do escudo
    gl = Image.new("RGBA", (W, H), (0, 0, 0, 0)); gd = ImageDraw.Draw(gl)
    for x in range(0, W, 16): gd.line((x, 0, x, H), fill=(120, 200, 255, 18))
    for y in range(0, H, 16): gd.line((0, y, W, y), fill=(120, 200, 255, 18))
    gl.putalpha(Image.composite(gl.getchannel("A"), Image.new("L", (W, H), 0), mask))
    im = Image.alpha_composite(im, gl); d = ImageDraw.Draw(im)
    # KNULLI
    k = text_layer((W, 130), "KNULLI", ImageFont.truetype(PIX, 64), LIME_T, LIME_B, 6, 6)
    im.alpha_composite(k, (0, 46))
    # placa PORT HUB
    px0, py0, px1, py1 = 70, 186, W - 70, 262
    d.rectangle((px0 - 6, py0 - 6, px1 + 6, py1 + 6), fill=INK)
    d.rectangle((px0, py0, px1, py1), fill=PLATE)
    d.rectangle((px0, py0, px1, py0 + 5), fill=PINK)
    d.rectangle((px0, py1 - 5, px1, py1), fill=PINK)
    p = text_layer((px1 - px0, py1 - py0), "PORT HUB", ImageFont.truetype(PIX, 32), (235, 252, 255), (120, 220, 255), 4, 3)
    im.alpha_composite(p, (px0, py0 + 1))
    # pontinhos de brilho
    sparkle(d, 50, 66, 3, CYAN); sparkle(d, W - 52, 70, 3, (255, 255, 255, 255))
    sparkle(d, W - 40, 168, 2, PINK); sparkle(d, 40, 176, 2, (196, 255, 98, 255))
    # seta de download (ports chegando) na ponta do escudo
    ax = W // 2; ay = 284
    d.rectangle((ax - 10, ay - 14, ax + 10, ay + 4), fill=INK)
    d.polygon([(ax - 24, ay), (ax + 24, ay), (ax, ay + 24)], fill=INK)
    d.rectangle((ax - 6, ay - 10, ax + 6, ay + 4), fill=(196, 255, 98, 255))
    d.polygon([(ax - 16, ay + 3), (ax + 16, ay + 3), (ax, ay + 19)], fill=(196, 255, 98, 255))
    return im

def scene(W, H, horizon):
    # ceu noturno + grade em perspectiva (verde/ciano) + "sol" pixelado
    im = grad((W, H), (12, 10, 34), (40, 18, 70)); d = ImageDraw.Draw(im)
    rnd = random.Random(7)
    for _ in range(W * H // 2600):
        x, y = rnd.randrange(W), rnd.randrange(horizon)
        s = rnd.choice((1, 1, 1, 2)); d.rectangle((x, y, x + s - 1, y + s - 1), fill=(220, 230, 255, rnd.randrange(120, 255)))
    cx, r = W // 2, int(H * 0.3)
    for i in range(r):
        yy = horizon - i
        if yy < 0: break
        if (i // 6) % 4 == 3 and i < r * 0.6: continue          # faixas do sol
        t = i / r; col = (round(255 - 40 * t), round(120 + 110 * t), round(160 - 60 * t), 255)
        half = int(math.sqrt(max(0, r * r - i * i)))
        d.line((cx - half, yy, cx + half, yy), fill=col)
    d.rectangle((0, horizon, W, H), fill=(8, 14, 30, 255))
    for k in range(1, 18):
        y = horizon + int((H - horizon) * (k / 18) ** 2.0)
        d.line((0, y, W, y), fill=(56, 214, 255, 110))
    for k in range(-12, 13):
        d.line((cx + k * W // 24, horizon, cx + k * W // 3, H), fill=(61, 220, 132, 110))
    d.line((0, horizon, W, horizon), fill=(196, 255, 98, 255), width=2)
    return im

master = badge()
master.save(os.path.join(OUT, "logo_master.png"))
for name, (w, h) in {"logo_splash": (252, 170), "logo_menu": (110, 74), "logo_about": (92, 62), "logo_header": (47, 32)}.items():
    master.resize((w, h), Image.LANCZOS).save(os.path.join(OUT, name + ".png"))
# marquee do EmulationStation (467x250, transparente)
mq = Image.new("RGBA", (467, 250), (0, 0, 0, 0)); lg = master.resize((370, 250), Image.LANCZOS); mq.alpha_composite(lg, ((467 - 370) // 2, 0))
mq.save(os.path.join(OUT, "logo.png"))
# capa 640x480
cv = scene(640, 480, 300); lg = master.resize((378, 255), Image.LANCZOS); cv.alpha_composite(lg, ((640 - 378) // 2, 34))
band = Image.new("RGBA", (640, 120), (8, 10, 24, 200)); cv.alpha_composite(band, (0, 352)); d = ImageDraw.Draw(cv)
d.text((320, 382), "PORTS, FERRAMENTAS E MAIS PARA O KNULLI", font=ImageFont.truetype(PIX, 14), fill=(196, 255, 98), anchor="mm",
       stroke_width=3, stroke_fill=(10, 9, 20))
d.text((320, 418), "Downloads • FTP • Wi-Fi • Temas • Diagnósticos", font=ImageFont.truetype(INTER, 18), fill=(235, 245, 255), anchor="mm",
       stroke_width=2, stroke_fill=(10, 9, 20))
d.text((320, 452), "0.5.4 BETA · KNULLI", font=ImageFont.truetype(PIX, 8), fill=(255, 212, 71), anchor="mm")
cv.convert("RGB").save(os.path.join(OUT, "cover.png"))
# fanart 1280x720
fa = scene(1280, 720, 470); lg = master.resize((560, 378), Image.LANCZOS); fa.alpha_composite(lg, ((1280 - 560) // 2, 60))
fa.convert("RGB").save(os.path.join(OUT, "fanart.png"))
# previa lado a lado
pv = Image.new("RGBA", (1300, 500), (40, 40, 40, 255)); pv.alpha_composite(cv.convert("RGBA"), (0, 10))
pv.alpha_composite(master, (660, 10)); x = 660
for n in ("logo_splash", "logo_menu", "logo_about", "logo_header"):
    im = Image.open(os.path.join(OUT, n + ".png")); pv.alpha_composite(im, (x, 370)); x += im.width + 20
pv.convert("RGB").save("/tmp/klogo/preview.png")
print("ok")
