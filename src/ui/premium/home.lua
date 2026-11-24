-- =============================================================================
--  Tema Premium: tela inicial (layout "premium" do menu principal)
--  Barra superior (marca, Wi-Fi, bateria, hora), barra lateral fixa com foco
--  proprio, cartao CONTINUAR (arte larga do ultimo port jogado), NOVIDADES NO
--  CATALOGO (capas) e atalhos com o estado do console. Rodape com os botoes.
--    direcional: navegar (esquerda na primeira coluna vai para a barra lateral)
--    B (acao "a"): abrir/jogar | Y (acao "x"): detalhes do port | X (acao "y"): buscar
--    A (acao "b"): sair/energia | L1/R1: trocar o destaque | SELECT: atualizar o hub
-- =============================================================================
local L = require("lib.i18n").L
local C = require("config")
local U = require("lib.util")
local Catalog = require("core.catalog")
local Covers = require("core.covers")
local Prefs = require("core.prefs")
local PS = require("ui.premium.style")
local PM = require("ui.premium.model")
local PI = require("ui.premium.images")

local PH = {}
local lg = love.graphics

-- medidas do prototipo (640x480)
local SIDE_W = 148
local CX, CW = 164, 460              -- coluna de conteudo
local CARD_Y, CARD_H = 54, 168       -- CONTINUAR
local NEWS_HY = 232                  -- titulo NOVIDADES
local NEWS_Y, NEWS_W, NEWS_H, NEWS_G = 257, 74, 111, 10
local CHIP_Y, CHIP_H, CHIP_G = 397, 34, 8

local function side_items()
  local list = {
    { id = "home", label = L("Início"), icon = "home" },
    { id = "store", label = L("Central"), icon = "grid" },
    { id = "installed", label = L("Meus Ports"), icon = "pad" },
    { id = "library", label = L("Biblioteca"), icon = "library" },
  }
  if C.KNULLI then list[#list + 1] = { id = "ktools", label = L("Ferramentas"), icon = "wrench" } end
  list[#list + 1] = { id = "settings", label = L("Ajustes"), icon = "gear" }
  return list
end

local function st(self)
  local s = self.ph
  if not s then
    s = { zone = "cont", side = 1, news = 1, chip = 1, news_x = 0, temp_t = -10 }
    self.ph = s
  end
  return s
end

--- recalcula os dados (abertura, volta de outra tela, catalogo novo)
local function refresh(S, self)
  local s = st(self)
  s.items = s.items or side_items()
  s.news_list = PM.news(Catalog.ports, 12)
  s.new_n = PM.new_count(Catalog.ports, Catalog.is_new)
  s.news = U.clamp(s.news, 1, math.max(1, #s.news_list))
  -- traducoes aplicadas pelo app (registro em conf/romtrans.json; leitura leve)
  local ok, n = pcall(function()
    local t = U.read_file(C.APP_DIR .. "/conf/romtrans.json")
    local d = t and require("lib.json").decode(t)
    local c = 0
    for _ in pairs(type(d) == "table" and type(d.items) == "table" and d.items or {}) do c = c + 1 end
    return c
  end)
  s.trans_n = ok and n or 0
end

--- port do cartao (continuar ou destaque) e o tipo
local function card_port(S, self)
  local ids = PM.recent_ids(Prefs.get("recent_ports"))
  return PM.pick_continue(ids, Catalog.by_id, App.status, self.featured, Catalog.ports, self.feat_i)
end

function PH.update(S, self, dt)
  self.feat_t = 0   -- sem troca automatica do destaque no cartao (so L1/R1)
  local s = st(self)
  if self.dash_dirty or not s.news_list then
    refresh(S, self)
    self.dash_dirty = false
  end
  -- temperatura da CPU: leitura de um arquivo do sistema a cada 3 s
  if (App.t or 0) - s.temp_t > 3 then
    s.temp_t = App.t or 0
    local okm, Mon = pcall(require, "core.monitor")
    if okm and Mon.cpu_temp then
      local okt, tc = pcall(Mon.cpu_temp)
      s.temp = okt and tc or nil
      s.temp_lv = s.temp and Mon.level(s.temp) or nil
    end
  end
  -- rolagem suave da faixa de novidades
  local step = NEWS_W + NEWS_G
  local left = (s.news - 1) * step
  local target = s.news_x_t or 0
  if left < target then target = left end
  if left + NEWS_W > target + CW then target = left + NEWS_W - CW end
  local maxx = math.max(0, #(s.news_list or {}) * step - NEWS_G - CW)
  target = U.clamp(target, 0, maxx)
  s.news_x_t = target
  s.news_x = PS.approach(s.news_x, target, dt, 14)
end

-- ---------------------------------------------------------------------------
-- desenho

local function draw_top(S, self)
  local c = PS.c()
  PS.rect(0, 39, 640, 1, c.surf2)
  PS.rect(20, 11, 18, 18, c.accent, 5)
  local bf = PS.font("b", 13, true)
  PS.track(bf, "KNULLI PORT HUB", 48, 20 - bf:getHeight() / 2, c.text, 0.04)
  -- direita: Wi-Fi, bateria e hora
  local clock = require("core.clock").time()
  local tf = PS.font("m", 13, true)
  local x = 620 - tf:getWidth(clock)
  PS.text(tf, clock, x, 20 - tf:getHeight() / 2, c.text)
  local b = require("core.battery").get()
  local sf = PS.font("r", 12, true)
  local btxt = b.ok and (b.pct .. "%") or "--"
  local bc = c.dim
  if b.ok and not b.charging and require("core.battery").level(b.pct) == "critical" then bc = c.red end
  x = x - 10 - sf:getWidth(btxt)
  PS.text(sf, btxt, x, 20 - sf:getHeight() / 2, bc)
  if b.ok and b.charging then
    x = x - 12
    PS.color(c.accent)
    lg.polygon("fill", x + 5, 13, x + 1, 21, x + 4.5, 21, x + 3, 27, x + 8, 18.5, x + 4.5, 18.5, x + 6.5, 13)
  end
  local _, wc, off = S.wifi_state()
  x = x - 10 - 16
  local col = off and c.red or ((wc == require("ui.theme").c.yellow) and c.warn or c.dim)
  PS.icon("wifi", x, 12, 16, col)
  if off then PS.color(c.red); lg.setLineWidth(2); lg.line(x + 1, 13, x + 15, 27); lg.setLineWidth(1) end
  -- versao nova do hub: aviso discreto ao lado da marca
  if require("core.updnotice").pending() then
    local f = PS.font("m", 11, true)
    local lx = 48 + PS.track_width(bf, "KNULLI PORT HUB", 0.04) + 14
    PS.pill(L("Atualização disponível"), lx, 11, { font = f, bg = { c.accent[1], c.accent[2], c.accent[3], 0.16 }, fg = c.accent, h = 18 })
  end
end

local function draw_side(S, self)
  local c = PS.c()
  local s = st(self)
  PS.rect(SIDE_W - 1, 40, 1, PS.FOOT_Y - 40, c.surf2)
  local f_on, f_off = PS.font("m", 14), PS.font("r", 14)
  for i, it in ipairs(s.items) do
    local y = 52 + (i - 1) * 42
    local focus = s.zone == "side" and s.side == i
    local current = it.id == "home"
    local k = PS.fk("ph_side" .. i, focus)
    if current or k > 0 then PS.rect(10, y, 128, 38, c.surf2, 10) end
    if k > 0 then PS.focus(10, y, 128, 38, 10, k) end
    local ic = (current or focus) and c.accent or c.dim
    PS.icon(it.icon, 22, y + 10, 18, ic)
    local f = (current or focus) and f_on or f_off
    PS.fit(f, it.label, 50, y + 19 - f:getHeight() / 2, 84, (current or focus) and c.text or c.dim)
  end
  -- espaco livre do cartao
  local by = PS.FOOT_Y - 12 - 66
  PS.rect(10, by, 128, 66, c.surf, 10)
  local lf, vf = PS.font("r", 11, true), PS.font("b", 14, true)
  PS.text(lf, L("Cartão"), 20, by + 10, c.dim)
  local free, total = App.free, App.total
  PS.fit(vf, free and (U.format_bytes(free) .. PS.tr(L(" livres"))) or L("Espaço livre: desconhecido"), 20, by + 10 + lf:getHeight() + 6, 108, c.text)
  local frac = (free and total and total > 0) and (1 - free / total) or 0
  local bary = by + 66 - 10 - 4
  PS.rect(20, bary, 108, 4, c.line, 2)
  local low = free and total and total > 0 and free / total < 0.10
  if frac > 0 then PS.rect(20, bary, math.max(4, 108 * frac), 4, low and c.warn or c.accent, 2) end
end

local function cont_button_label(p, kind)
  if App.status(p) ~= "none" and App.port_script(p) then return L("Jogar") end
  return L("Ver detalhes")
end

local function draw_card(S, self)
  local c = PS.c()
  local s = st(self)
  local p, kind = card_port(S, self)
  s.card_p, s.card_kind = p, kind
  local focus = s.zone == "cont"
  local k = PS.fk("ph_cont", focus)
  local x, y, w, h = PS.grow(CX, CARD_Y, CW, CARD_H, k, 0.012)
  PS.rect(x, y, w, h, c.surf, 16)
  if not p then
    local f = PS.font("b", 16)
    PS.fit(f, L("Nenhum port ainda"), x + 16, y + 40, w - 32, c.text)
    PS.fit(PS.font("r", 12), L("Abra a Central para instalar o primeiro."), x + 16, y + 66, w - 32, c.dim)
    if k > 0 then PS.focus(x, y, w, h, 16, k) end
    return
  end
  -- arte: hero (catalogo/Steam) ou a capa desfocada com a capa nitida a direita
  local hero = require("core.heroart").get(p)
  local cimg = Covers.get(p)
  if hero then
    PS.draw_cover_fit(hero, x, y, w, h, 0.72, 0.35)
  elseif cimg then
    local cv = PI.blurred(cimg, (p.slug or "") .. "|cont", CW, CARD_H, { dark = 0.25 })
    if cv then lg.setColor(1, 1, 1, 1); lg.draw(cv, x, y, 0, w / CW, h / CARD_H) end
    local ch = h - 28
    local cw = math.floor(ch * 0.75)
    local cx = x + w - 18 - cw
    PS.shadow(cx, y + 14, cw, ch, 8, 6, 0.6)
    PS.draw_cover_fit(cimg, cx, y + 14, cw, ch)
    PS.fillet(cx, y + 14, cw, ch, 8, c.surf)
  end
  -- veu solido a esquerda (texto legivel sobre qualquer arte)
  PS.veil(x, y, w * 0.62, h, 0.78)
  PS.fillet(x, y, w, h, 16, c.bg)
  if k > 0 then PS.focus(x, y, w, h, 16, k) end
  -- textos
  local tx, ty, tw = x + 16, y + 14, math.floor(w * 0.54)
  local lf = PS.font("b", 11, true)
  PS.track(lf, kind == "continue" and L("CONTINUAR") or L("EM DESTAQUE"), tx, ty, c.accent, 0.08, tw)
  ty = ty + lf:getHeight() + 6
  local nf = PS.font("x", 20)
  local lines = PS.lines(nf, p.name, tw, 2)
  local lh = math.floor(nf:getHeight() * 1.05)
  for i, l in ipairs(lines) do PS.text(nf, l, tx, ty + (i - 1) * lh, c.text) end
  ty = ty + #lines * lh + 6
  local meta
  if kind == "continue" then
    local Perf = require("core.perf")
    meta = PM.play_meta(Perf.last_play(p.id), Perf.last(p.id))
    if meta == "" then meta = PS.tr(p.category or "") end
  else
    local parts = { PS.tr(p.category or "") }
    if p.size_label and p.size_label ~= "?" then parts[#parts + 1] = p.size_label end
    meta = table.concat(parts, " • ")
  end
  local mf = PS.font("r", 12)
  if ty + mf:getHeight() <= y + h - 14 - 30 - 4 then PS.fit(mf, meta, tx, ty, tw, c.dim2) end
  -- botao Jogar + selo
  local by = y + h - 14 - 30
  local bf = PS.font("b", 13, true)
  local label = PS.tr(cont_button_label(p, kind))
  local bw = 14 + 16 + 8 + bf:getWidth(label) + 14
  PS.rect(tx, by, bw, 30, c.accent, 15)
  PS.glyph("a", tx + 14, by + 7, 16, true)
  PS.text(bf, label, tx + 14 + 16 + 8, by + 15 - bf:getHeight() / 2, c.bg)
  local badge, kindb = PM.h700_badge(p)
  if not badge and kind == "featured" and Catalog.is_new(p) then badge, kindb = L("NOVO"), "ok" end
  if badge then
    local col = kindb == "ok" and c.accent or (kindb == "warn" and c.warn or c.red)
    PS.pill(badge, tx + bw + 8, by + 6, { font = PS.font("b", 11, true), bg = { col[1], col[2], col[3], 0.16 }, fg = col, h = 18 })
  end
  -- destaques (L1/R1): pontinhos quando o cartao mostra a vitrine
  local n = self.featured and #self.featured or 0
  if kind == "featured" and n > 1 then
    for i = 1, math.min(n, 8) do
      PS.color(i == self.feat_i and c.accent or c.text, i == self.feat_i and 1 or 0.35)
      lg.circle("fill", x + w - 16 - (math.min(n, 8) - i) * 10, y + h - 14, 3)
    end
  end
end

local function draw_news(S, self)
  local c = PS.c()
  local s = st(self)
  local hf = PS.font("b", 12, true)
  PS.track(hf, L("NOVIDADES NO CATÁLOGO"), CX, NEWS_HY, c.dim, 0.06, CW - 120)
  if (s.new_n or 0) > 0 then
    local rf = PS.font("m", 12, true)
    local txt = string.format(PS.tr(L("+%d esta semana")), s.new_n)
    PS.text(rf, txt, CX + CW - rf:getWidth(txt), NEWS_HY, c.accent)
  end
  local list = s.news_list or {}
  if #list == 0 then
    PS.fit(PS.font("r", 12), L("Nenhum port no catálogo ainda."), CX, NEWS_Y + 40, CW, c.dim)
    return
  end
  local G = require("ui.gfx")
  G.clip(CX - 4, NEWS_Y - 4, CW + 8, NEWS_H + 30)
  local nf = PS.font("r", 11)
  local sx = math.floor(s.news_x + 0.5)
  for i, p in ipairs(list) do
    local x = CX + (i - 1) * (NEWS_W + NEWS_G) - sx
    if x + NEWS_W >= CX - 10 and x <= CX + CW + 10 then
      local on = s.zone == "news" and s.news == i
      local k = PS.fk("ph_news" .. i, on)
      local bx, by, bw, bh = PS.grow(x, NEWS_Y, NEWS_W, NEWS_H, k)
      PS.cover(p, bx, by, bw, bh, 8, c.bg)
      if App.status(p) ~= "none" then
        PS.color(c.accent)
        lg.circle("fill", bx + bw - 11, by + 11, 7, 16)
        PS.icon("check", bx + bw - 15.5, by + 6.5, 9, c.bg)
      end
      if k > 0 then PS.focus(bx, by, bw, bh, 8, k) end
      PS.fit(nf, p.name, x, NEWS_Y + NEWS_H + 5, NEWS_W, on and c.text or c.dim2)
    end
  end
  G.unclip()
end

local function chips(S, self)
  local s = st(self)
  local temp = s.temp and (string.format("%d", math.floor(s.temp + 0.5)) .. " °C") or PS.tr(L("Monitor"))
  local tn = s.trans_n or 0
  local trans = tn > 0 and string.format(PS.tr(tn == 1 and L("%d tradução PT-BR") or L("%d traduções PT-BR")), tn)
    or PS.tr(L("Traduzir jogos"))
  return {
    { id = "monitor", label = temp, dot = true },
    { id = "romtrans", label = trans },
    { id = "chdconv", label = PS.tr(L("Converter para CHD")) },
  }
end

local function draw_chips(S, self)
  local c = PS.c()
  local s = st(self)
  local list = chips(S, self)
  local w = (CW - CHIP_G * (#list - 1)) / #list
  local f = PS.font("m", 12)
  for i, it in ipairs(list) do
    local on = s.zone == "chips" and s.chip == i
    local k = PS.fk("ph_chip" .. i, on)
    local x, y, ww, hh = PS.grow(CX + (i - 1) * (w + CHIP_G), CHIP_Y, w, CHIP_H, k)
    PS.rect(x, y, ww, hh, c.surf, 10)
    if k > 0 then PS.focus(x, y, ww, hh, 10, k) end
    local tw = math.min(f:getWidth(it.label), ww - 24 - (it.dot and 15 or 0))
    local total = tw + (it.dot and 15 or 0)
    local tx = x + (ww - total) / 2
    if it.dot then
      local dc = s.temp_lv == "hot" and c.red or (s.temp_lv == "warm" and c.warn or c.accent)
      if not s.temp then dc = c.dim end
      PS.color(dc)
      lg.circle("fill", tx + 3.5, y + hh / 2, 3.5, 12)
      tx = tx + 15
    end
    PS.fit(f, it.label, tx, y + hh / 2 - f:getHeight() / 2, tw, c.text)
  end
end

function PH.draw(S, self)
  local s = st(self)
  if not s.news_list then refresh(S, self) end
  draw_top(S, self)
  draw_side(S, self)
  draw_card(S, self)
  draw_news(S, self)
  draw_chips(S, self)
  local hints = { { "a", L("Selecionar") }, { "b", C.OS_MODE and L("Energia") or L("Sair") }, { "start", L("Downloads") }, { "y", L("Buscar") } }
  if require("core.updnotice").pending() then hints[#hints + 1] = { "select", L("Atualizar") } end
  PS.footer(hints, "v" .. (C.VERSION_NUM or ""))
end

-- ---------------------------------------------------------------------------
-- acoes

local function open_chip(id)
  if id == "monitor" then
    if App.screens.monitor then App.push("monitor") else App.toast(L("Esta ferramenta não está disponível nesta versão."), "warn") end
    return
  end
  local mod = id == "romtrans" and "ui.romtrans_ui" or "ui.chdconv_ui"
  local ok, m = pcall(require, mod)
  if ok and type(m) == "table" and m.open then m.open()
  else App.toast(L("Esta ferramenta não está disponível nesta versão."), "warn") end
end

local function open_port(p, play)
  if not p then return end
  if play and App.status(p) ~= "none" and App.port_script(p) then App.launch_port(p)
  else App.push("details", { port = p }) end
end

function PH.action(S, self, act)
  local s = st(self)
  if not s.items then refresh(S, self) end
  if act == "b" then
    if Prefs.get("exit_mode") == "quit" and not C.OS_MODE then App.quit() else S.exit_dialog() end
    return
  elseif act == "y" then App.push("search"); return
  elseif act == "select" then
    if require("core.updnotice").pending() then App.push("update") end
    return
  elseif act == "l1" or act == "r1" then
    if s.card_kind == "featured" then S.feat_go(self, act == "r1" and 1 or -1, true) end
    return
  end
  local z = s.zone
  local nnews = #(s.news_list or {})
  if z == "side" then
    local n = #s.items
    if act == "up" then s.side = math.max(1, s.side - 1)
    elseif act == "down" then s.side = math.min(n, s.side + 1)
    elseif act == "right" then s.zone = s.last or "cont"
    elseif act == "a" then
      local id = s.items[s.side].id
      if id == "home" then s.zone = "cont" else S.open(id) end
    end
    return
  end
  if act == "left" and (z == "cont" or (z == "news" and s.news == 1) or (z == "chips" and s.chip == 1)) then
    s.last = z
    s.zone = "side"
    return
  end
  if z == "cont" then
    if act == "down" then s.zone = nnews > 0 and "news" or "chips"
    elseif act == "a" then open_port(s.card_p, true)
    elseif act == "x" then if s.card_p then App.push("details", { port = s.card_p }) end
    end
  elseif z == "news" then
    if act == "up" then s.zone = "cont"
    elseif act == "down" then s.zone = "chips"; s.chip = U.clamp(math.floor((s.news - 1) * 3 / math.max(1, math.min(nnews, 5))) + 1, 1, 3)
    elseif act == "left" then s.news = math.max(1, s.news - 1)
    elseif act == "right" then s.news = math.min(nnews, s.news + 1)
    elseif act == "a" or act == "x" then open_port((s.news_list or {})[s.news], false)
    end
  elseif z == "chips" then
    if act == "up" then s.zone = nnews > 0 and "news" or "cont"
    elseif act == "left" then s.chip = math.max(1, s.chip - 1)
    elseif act == "right" then s.chip = math.min(3, s.chip + 1)
    elseif act == "a" then open_chip(chips(S, self)[s.chip].id)
    end
  end
end

return PH
