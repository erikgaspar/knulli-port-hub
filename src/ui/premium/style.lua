-- =============================================================================
--  Tema Premium (Knulli Port Hub): tokens, fontes Inter e primitivas de desenho
--  Usado so quando o tema ativo pede style.layout = "premium" (ver PS.active).
--  Tudo leve para o H700: nada de shader, so retangulos, textos e imagens.
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local T = require("ui.theme")
local U = require("lib.util")
local utf8 = require("utf8")

local PS = {}

function PS.active() return T.style.layout == "premium" end

local function hex(h, a) return T.hex(h, a) end

-- cores fixas do prototipo que nao existem na paleta do tema
PS.DIM2 = hex("#C5CBD3")      -- texto secundario claro
PS.LIGHT = hex("#E3E7EC")     -- valores sobre imagem
PS.WARNBG = hex("#3A2D12")    -- fundo do selo de aviso
PS.VEIL = { 10 / 255, 11 / 255, 14 / 255 }

--- cores do tema (lidas na hora: o tema pode ser trocado sem reiniciar)
function PS.c()
  local c = T.c
  return { bg = c.bg0, surf = c.bg1, surf2 = c.bg2, line = c.line, text = c.text, dim = c.dim,
    faint = c.faint, accent = c.accent, warn = c.yellow, red = c.red, dim2 = PS.DIM2, light = PS.LIGHT }
end

-- ---------------------------------------------------------------------------
-- fontes (Inter estatica). w: "r" regular, "m" semibold, "b" bold, "x" extrabold
local FILES = {
  r = "assets/fonts/Inter-Regular.ttf", m = "assets/fonts/Inter-SemiBold.ttf",
  b = "assets/fonts/Inter-Bold.ttf", x = "assets/fonts/Inter-ExtraBold.ttf",
}
local FCACHE = {}

--- diferenca do tamanho de texto escolhido (Configuracoes > Tamanho do texto)
function PS.delta()
  for _, l in ipairs(T.FONT_LEVELS) do if l.id == T.font_level then return l.delta end end
  return 0
end

--- fonte Inter no peso `w` e tamanho `size` (px do prototipo). fixed = ignora o
--- tamanho de texto do usuario (rotulos dentro de pilulas de altura fixa)
function PS.font(w, size, fixed)
  local s = size + (fixed and 0 or PS.delta())
  local k = (w or "r") .. s
  local f = FCACHE[k]
  if f then return f end
  local ok, nf = pcall(love.graphics.newFont, FILES[w] or FILES.r, s)
  if not ok then nf = T.f.body end
  if ok then nf:setFilter("linear", "linear") end
  FCACHE[k] = nf
  return nf
end

-- ---------------------------------------------------------------------------
-- texto

local function tr(s) return U.safe_utf8(I18N.tr(s or "")) end
PS.tr = tr

function PS.color(c, a)
  love.graphics.setColor(c[1], c[2], c[3], (c[4] or 1) * (a or 1))
end

--- texto simples (uma linha); devolve a largura
function PS.text(font, s, x, y, c, a)
  s = tr(s)
  love.graphics.setFont(font)
  PS.color(c, a)
  love.graphics.print(s, math.floor(x + 0.5), math.floor(y + 0.5))
  return font:getWidth(s)
end

--- texto cortado com "…" em `w` px; align "left" | "center" | "right"
function PS.fit(font, s, x, y, w, c, align, a)
  s = U.ellipsize(font, tr(s), math.max(4, w))
  local tw = font:getWidth(s)
  if align == "center" then x = x + (w - tw) / 2 elseif align == "right" then x = x + w - tw end
  love.graphics.setFont(font)
  PS.color(c, a)
  love.graphics.print(s, math.floor(x + 0.5), math.floor(y + 0.5))
  return tw
end

--- texto com espacamento entre letras (rotulos em caixa alta: CONTINUAR...)
function PS.track(font, s, x, y, c, em, maxw)
  s = tr(s)
  local sp = font:getHeight() * (em or 0.06)
  love.graphics.setFont(font)
  PS.color(c)
  local cx = x
  for _, cp in utf8.codes(s) do
    local ch = utf8.char(cp)
    local cw = font:getWidth(ch)
    if maxw and cx + cw - x > maxw then break end
    love.graphics.print(ch, math.floor(cx + 0.5), math.floor(y + 0.5))
    cx = cx + cw + sp
  end
  return cx - sp - x
end

function PS.track_width(font, s, em)
  s = tr(s)
  local n = utf8.len(s) or #s
  return font:getWidth(s) + font:getHeight() * (em or 0.06) * math.max(0, n - 1)
end

--- linhas quebradas em `w` (no maximo `maxl`, a ultima com "…")
function PS.lines(font, s, w, maxl)
  local _, ls = font:getWrap(tr(s), w)
  if maxl and #ls > maxl then
    local out = {}
    for i = 1, maxl do out[i] = ls[i] end
    out[maxl] = U.ellipsize(font, out[maxl] .. " …", w)
    return out, true
  end
  return ls, false
end

-- ---------------------------------------------------------------------------
-- formas

function PS.rect(x, y, w, h, c, r, a)
  PS.color(c, a)
  love.graphics.rectangle("fill", x, y, w, h, r or 0, r or 0, (r or 0) > 0 and 8 or nil)
end

function PS.frame(x, y, w, h, c, r, lw, a)
  lw = lw or 1
  PS.color(c, a)
  love.graphics.setLineWidth(lw)
  local i = lw / 2
  local rr = math.max(0, (r or 0) - i)
  love.graphics.rectangle("line", x + i, y + i, w - lw, h - lw, rr, rr, rr > 0 and 8 or nil)
  love.graphics.setLineWidth(1)
end

--- "cantos" na cor do fundo por cima de uma imagem retangular: deixa a imagem
--- com cantos arredondados sem stencil (o fundo atras e de cor solida)
local FILLETS = {}
--- canto (leque de triangulos do vertice ate o arco), criado uma vez por raio
local function fillet_mesh(r)
  local m = FILLETS[r]
  if m then return m end
  local v = { { 0, 0 } }
  local n = 8
  for i = 0, n do
    local a = math.pi + (math.pi / 2) * (i / n)
    v[#v + 1] = { r + math.cos(a) * r, r + math.sin(a) * r }
  end
  m = love.graphics.newMesh(v, "fan", "static")
  FILLETS[r] = m
  return m
end

function PS.fillet(x, y, w, h, r, c)
  if not r or r <= 0 then return end
  r = math.floor(r + 0.5)
  local m = fillet_mesh(r)
  local lg = love.graphics
  PS.color(c)
  lg.draw(m, x, y)                          -- superior esquerdo
  lg.draw(m, x + w, y, math.pi / 2)         -- superior direito
  lg.draw(m, x + w, y + h, math.pi)         -- inferior direito
  lg.draw(m, x, y + h, -math.pi / 2)        -- inferior esquerdo
end

--- sombra suave (camadas transparentes; sem blur)
function PS.shadow(x, y, w, h, r, dy, a)
  dy, a = dy or 8, a or 0.5
  for i = 4, 1, -1 do
    local g = i * 3
    PS.rect(x - g + 2, y + dy - g + 4, w + 2 * g - 4, h + 2 * g - 4, { 0, 0, 0 }, r + g, a * 0.09)
  end
end

--- veu escuro solido (texto sobre imagem)
function PS.veil(x, y, w, h, a, r)
  PS.rect(x, y, w, h, PS.VEIL, r or 0, a or 0.7)
end

--- foco: borda de 2 px na cor do acento (k = 0..1 da animacao)
function PS.focus(x, y, w, h, r, k)
  if (k or 0) <= 0 then return end
  PS.frame(x, y, w, h, T.style.focus or T.c.accent, r, 2, k)
end

--- retangulo aumentado pela animacao do foco (escala 1.0 -> 1.03, sem
--- transformar o texto): devolve x, y, w, h ja aumentados
function PS.grow(x, y, w, h, k, scale)
  local s = (scale or 0.03) * (k or 0)
  local gx, gy = w * s / 2, h * s / 2
  return x - gx, y - gy, w + 2 * gx, h + 2 * gy
end

--- animacao do foco (0..1) por chave, mesma regra do resto do hub
function PS.fk(key, on) return require("ui.gfx").focus_k(key, on) end

--- aproxima `cur` de `target` (rolagem suave); sem animacoes, pula direto
function PS.approach(cur, target, dt, speed)
  if not (App and App.animations and App.animations()) or cur == nil then return target end
  local v = cur + (target - cur) * math.min(1, (dt or 0) * (speed or 14))
  if math.abs(v - target) < 0.5 then v = target end
  return v
end

--- pilula com texto; devolve a largura. o = { font, bg, fg, px, h, a }
function PS.pill(s, x, y, o)
  o = o or {}
  local f = o.font or PS.font("b", 11, true)
  local px = o.px or 8
  local h = o.h or (f:getHeight() + 8)
  s = tr(s)
  local w = f:getWidth(s) + 2 * px
  if o.bg then PS.rect(x, y, w, h, o.bg, h / 2, o.a) end
  PS.text(f, s, x + px, y + math.floor((h - f:getHeight()) / 2), o.fg or T.c.text)
  return w, h
end

-- ---------------------------------------------------------------------------
-- botoes do controle (letra fisica: no Knulli B confirma)

local LBL = { l1 = "L1", r1 = "R1", l2 = "L2", r2 = "R2", start = "START", select = "SELECT" }

--- largura do icone do botao `btn`
function PS.glyph_w(btn, size)
  size = size or 18
  if btn == "a" or btn == "b" or btn == "x" or btn == "y" or btn == "dpad" then return size end
  local f = PS.font("b", 10, true)
  return f:getWidth(LBL[btn] or tostring(btn)) + 12
end

--- icone do botao. inv = invertido (sobre o botao de acento: fundo escuro, letra acento)
function PS.glyph(btn, x, y, size, inv)
  size = size or 18
  local lg = love.graphics
  local c = PS.c()
  if btn == "dpad" then
    PS.color(c.dim)
    local m = size / 2
    lg.rectangle("fill", x + m - 3, y + 1, 6, size - 2, 1.5, 1.5)
    lg.rectangle("fill", x + 1, y + m - 3, size - 2, 6, 1.5, 1.5)
    return size
  end
  if btn == "a" or btn == "b" or btn == "x" or btn == "y" then
    local bg, fg
    if inv then bg, fg = c.bg, c.accent
    elseif btn == "a" then bg, fg = c.accent, c.bg
    else bg, fg = c.line, c.text end
    PS.color(bg)
    lg.circle("fill", x + size / 2, y + size / 2, size / 2, 24)
    local f = PS.font("b", size >= 18 and 11 or 10, true)
    local s = require("ui.gfx").btn_letter(btn)
    PS.text(f, s, x + (size - f:getWidth(s)) / 2, y + (size - f:getHeight()) / 2, fg)
    return size
  end
  local f = PS.font("b", 10, true)
  local s = LBL[btn] or tostring(btn)
  local w = f:getWidth(s) + 12
  PS.rect(x, y, w, size, c.line, size / 2)
  PS.text(f, s, x + 6, y + (size - f:getHeight()) / 2, c.text)
  return w
end

-- ---------------------------------------------------------------------------
-- barras fixas: topo (40 px) e rodape (34 px)
PS.TOP_H, PS.FOOT_H = 40, 34
PS.FOOT_Y = 480 - 34

--- rodape com dicas de botoes. hints = { {btn, texto}, ... } (btn pode ser
--- uma lista: { {"l1","r1"}, "Abas" } vira uma pilula "L1 R1"). right = texto a direita
function PS.footer(hints, right, opts)
  opts = opts or {}
  local c = PS.c()
  local y = PS.FOOT_Y
  if opts.bg ~= false then PS.rect(0, y, 640, 34, c.bg, 0, opts.alpha or 1) end
  PS.rect(0, y, 640, 1, opts.line or c.surf2)
  local f = PS.font("r", 12)
  local x = 20
  local rw = 0
  if right and right ~= "" then rw = f:getWidth(tr(right)) + 18 end
  local maxx = 620 - rw
  for _, h in ipairs(hints or {}) do
    local btn, label = h[1], h[2]
    local gw
    if type(btn) == "table" then
      local s = {}
      for _, b in ipairs(btn) do s[#s + 1] = LBL[b] or b end
      local pf = PS.font("b", 10, true)
      local txt = table.concat(s, " ")
      gw = pf:getWidth(txt) + 12
      if x + gw > maxx then break end
      PS.rect(x, y + 8, gw, 18, c.line, 9)
      PS.text(pf, txt, x + 6, y + 8 + (18 - pf:getHeight()) / 2, c.text)
    else
      gw = PS.glyph_w(btn)
      if x + gw > maxx then break end
      PS.glyph(btn, x, y + 8)
    end
    x = x + gw + 6
    if label and label ~= "" then
      local lw = f:getWidth(tr(label))
      if x + lw > maxx then lw = math.max(0, maxx - x) end
      PS.fit(f, label, x, y + 17 - f:getHeight() / 2, lw, opts.fg or c.dim)
      x = x + lw
    end
    x = x + 18
  end
  if rw > 0 then PS.fit(f, right, 620 - rw + 18, y + 17 - f:getHeight() / 2, rw - 18, opts.fg or c.dim) end
  return x - 18
end

--- cabecalho simples das telas (40 px): titulo a esquerda, texto e hora a direita
function PS.header(title, right, opts)
  opts = opts or {}
  local c = PS.c()
  if opts.bg ~= false then PS.rect(0, 0, 640, 40, c.bg, 0, opts.alpha or 1) end
  PS.rect(0, 39, 640, 1, c.surf2)
  local clock = require("core.clock").time()
  local cf = PS.font("m", 13, true)
  local cw = cf:getWidth(clock)
  PS.text(cf, clock, 620 - cw, 20 - cf:getHeight() / 2, c.text)
  local limit = 620 - cw - 14
  if right and right ~= "" then
    local rf = PS.font("r", 12, true)
    local rw = math.min(rf:getWidth(tr(right)), math.floor((limit - 20) * 0.45))
    PS.fit(rf, right, limit - rw, 20 - rf:getHeight() / 2, rw, c.dim)
    limit = limit - rw - 14
  end
  if title then
    local tf = PS.font("b", 15, true)
    PS.fit(tf, title, 20, 20 - tf:getHeight() / 2, limit - 20, c.text)
  end
end

-- ---------------------------------------------------------------------------
-- icones de linha (traco 2 px), desenhados num quadro de 24 unidades
local function stroke(c, w) PS.color(c); love.graphics.setLineWidth(w or 2); love.graphics.setLineJoin("bevel") end

function PS.icon(id, x, y, size, c)
  local lg = love.graphics
  local s = (size or 18) / 24
  lg.push()
  lg.translate(x, y)
  lg.scale(s, s)
  stroke(c, 2)
  if id == "home" then
    lg.line(3, 11, 12, 4, 21, 11, 21, 20, 15, 20, 15, 14, 9, 14, 9, 20, 3, 20, 3, 11)
  elseif id == "grid" then
    for _, p in ipairs({ { 3, 3 }, { 14, 3 }, { 3, 14 }, { 14, 14 } }) do lg.rectangle("line", p[1], p[2], 7, 7, 1.5, 1.5) end
  elseif id == "pad" then
    lg.rectangle("line", 2, 7, 20, 12, 4, 4)
    lg.line(7, 11, 7, 15); lg.line(5, 13, 9, 13)
    lg.circle("fill", 16, 12, 1.2); lg.circle("fill", 18, 14, 1.2)
  elseif id == "wrench" then
    lg.line(14.7, 6.3, 12, 5.5, 9.6, 7, 8.6, 9.8, 9.3, 11.7, 3, 18, 6, 21, 12.3, 14.7, 14.4, 15.4, 17.1, 14.3, 18.5, 12, 17.7, 9.3, 15.1, 11.9, 12.7, 11.3, 12.1, 8.9, 14.7, 6.3)
  elseif id == "gear" then
    lg.circle("line", 12, 12, 3)
    for i = 0, 7 do
      local a = i * math.pi / 4
      lg.line(12 + math.cos(a) * 7, 12 + math.sin(a) * 7, 12 + math.cos(a) * 10, 12 + math.sin(a) * 10)
    end
  elseif id == "library" then
    lg.rectangle("line", 3, 4, 5, 16, 1, 1); lg.rectangle("line", 10, 4, 5, 16, 1, 1)
    lg.line(17, 5.5, 21, 4.5, 21.5, 19, 17.5, 20, 17, 5.5)
  elseif id == "search" then
    lg.circle("line", 11, 11, 7); lg.line(16, 16, 21, 21)
  elseif id == "wifi" then
    lg.arc("line", "open", 12, 19, 15, -math.pi * 0.78, -math.pi * 0.22, 12)
    lg.arc("line", "open", 12, 19, 10, -math.pi * 0.76, -math.pi * 0.24, 10)
    lg.arc("line", "open", 12, 19, 5, -math.pi * 0.74, -math.pi * 0.26, 8)
    lg.circle("fill", 12, 19, 1.4)
  elseif id == "bt" then
    lg.line(7, 7, 17, 17, 12, 22, 12, 2, 17, 7, 7, 17)
  elseif id == "report" then
    lg.rectangle("line", 5, 3, 14, 18, 2, 2); lg.line(9, 8, 15, 8); lg.line(9, 12, 15, 12); lg.line(9, 16, 13, 16)
  elseif id == "check" then
    lg.setLineWidth(3.5); lg.line(5, 12, 10, 17, 19, 7)
  elseif id == "up" then
    lg.setLineWidth(3); lg.line(12, 19, 12, 6); lg.line(6, 11, 12, 5, 18, 11)
  elseif id == "star" then
    local pts = {}
    for i = 0, 9 do
      local a = -math.pi / 2 + i * math.pi / 5
      local r = (i % 2 == 0) and 9 or 4
      pts[#pts + 1] = 12 + math.cos(a) * r; pts[#pts + 1] = 12.5 + math.sin(a) * r
    end
    lg.polygon("fill", pts)
  elseif id == "download" then
    lg.line(12, 3, 12, 15); lg.line(7, 10, 12, 15, 17, 10); lg.line(4, 17, 4, 21, 20, 21, 20, 17)
  elseif id == "power" then
    lg.arc("line", "open", 12, 13, 8, -math.pi * 0.3, math.pi * 1.3, 16); lg.line(12, 3, 12, 11)
  else
    lg.rectangle("line", 4, 4, 16, 16, 3, 3)
  end
  lg.setLineWidth(1)
  lg.setLineJoin("miter")
  lg.pop()
end

-- ---------------------------------------------------------------------------
-- capas (cache de core/covers.lua): cantos arredondados, placeholder e selos

local PLACE = { "#2B3440", "#33302A", "#2A3A33", "#3A2E36", "#2E3142", "#3A3328" }

local function initials(name)
  local out = {}
  for w in U.safe_utf8(name or "?"):gmatch("[%w]+") do
    out[#out + 1] = w:sub(1, 1):upper()
    if #out >= 2 then break end
  end
  return #out > 0 and table.concat(out) or "?"
end

--- desenha a imagem em modo "cover" (preenche e corta) dentro do retangulo
function PS.draw_cover_fit(img, x, y, w, h, ax, ay, a)
  local G = require("ui.gfx")
  local iw, ih = img:getDimensions()
  local s = math.max(w / iw, h / ih)
  local dw, dh = iw * s, ih * s
  G.clip(x, y, w, h)
  love.graphics.setColor(1, 1, 1, a or 1)
  love.graphics.draw(img, x + (w - dw) * (ax or 0.5), y + (h - dh) * (ay or 0.5), 0, s, s)
  G.unclip()
end

--- capa do port (ou icone da ferramenta integrada) com cantos arredondados.
--- bgc = cor do fundo atras da capa (para os cantos)
function PS.cover(p, x, y, w, h, r, bgc, t)
  local c = PS.c()
  r = r or 10
  bgc = bgc or c.bg
  if p and p.builtin then
    PS.rect(x, y, w, h, c.surf2, r)
    local isz = math.min(w, h) * 0.42
    require("ui.icons").draw(p.icon or "generic", x + (w - isz) / 2, y + (h - isz) / 2, c.accent, isz / 24)
    return
  end
  local Covers = require("core.covers")
  local img = p and Covers.get(p)
  if img then
    PS.draw_cover_fit(img, x, y, w, h)
    PS.fillet(x, y, w, h, r, bgc)
    return
  end
  -- placeholder solido com as iniciais (e um brilho lento enquanto carrega)
  local seed = 0
  local name = p and p.name or "?"
  for i = 1, #name do seed = seed + name:byte(i) end
  PS.rect(x, y, w, h, T.hex(PLACE[seed % #PLACE + 1]), r)
  local f = PS.font("x", w >= 120 and 28 or (w >= 70 and 18 or 13), true)
  local s = initials(name)
  PS.text(f, s, x + (w - f:getWidth(s)) / 2, y + (h - f:getHeight()) / 2, c.text, 0.55)
  if p and Covers.is_loading(p) and App and App.animations and App.animations() then
    local k = 0.5 + 0.5 * math.sin((t or (App and App.t) or 0) * 3)
    PS.rect(x, y, w, h, c.text, r, 0.04 + 0.05 * k)
  end
end

--- selos da capa na grade: instalado (circulo com visto), atualizacao, h700
function PS.cover_badges(p, x, y, w, h)
  if not p or p.builtin then return end
  local c = PS.c()
  local st = App.status(p)
  if st ~= "none" then
    local bc = st == "update" and c.warn or c.accent
    PS.color(bc)
    love.graphics.circle("fill", x + w - 14, y + 14, 9, 20)
    PS.icon(st == "update" and "up" or "check", x + w - 19.5, y + 8.5, 11, c.bg)
  end
  if p.h700 then
    local hs = p.h700.status
    local label = hs == "testado" and L("TESTADO") or (hs == "pesado" and L("PESADO") or L("NÃO RODA"))
    local bg = hs == "testado" and c.accent or (hs == "pesado" and c.warn or c.red)
    local f = PS.font("x", 9, true)
    local lw = f:getWidth(tr(label)) + 12
    if lw <= w - 10 then PS.pill(label, x + 5, y + h - 5 - 15, { font = f, bg = bg, fg = c.bg, px = 6, h = 15 }) end
  end
end

return PS
