-- =============================================================================
--  Tema Premium: Central (tela "sections")
--  Faixa EM DESTAQUE (112 px) com arte de fundo, abas em pilulas (L1/R1) e
--  grade de capas em 6 colunas. Aba "Apps do Knulli": cartoes largos com os
--  apps da Knulli App Store (ui/premium/kapp.lua abre a pagina de cada um).
--  Aba "BIOS" abre a tela propria (um cartao grande explica e abre com B).
--  Abas de grade (Jogos, Utilitarios) tem filtros e ordenacao proprios
--  (core/portfilter.lua, lembrados em Prefs por aba): com algum ativo aparece
--  uma faixa de pilulas entre as abas e a grade.
--    direcional: grade (cima: faixa de filtros, depois EM DESTAQUE)
--    B (acao "a"): abrir | A (acao "b"): voltar | L1/R1: abas | X (acao "y"): buscar
--    Y (acao "x"): painel de filtros | L2/R2: letra anterior/seguinte (A-Z;
--    nas outras ordens, pagina) | SELECT: favorito
--    na faixa EM DESTAQUE: esquerda/direita trocam o destaque
--    na faixa de filtros: B tira o filtro escolhido ("Limpar" tira todos)
-- =============================================================================
local L = require("lib.i18n").L
local C = require("config")
local U = require("lib.util")
local Catalog = require("core.catalog")
local Covers = require("core.covers")
local Favorites = require("core.favorites")
local PF = require("core.portfilter")
local PS = require("ui.premium.style")
local PG = require("ui.premium.grid")
local PI = require("ui.premium.images")

local PC = {}
local lg = love.graphics

local BAND_H, TABS_Y, TABS_H = 112, 112, 42
local GRID_Y = BAND_H + TABS_H + 2
local STRIP_H = 30
local DWELL, FADE = 6.0, 0.5
local JUMP_T = 0.6

local function tabs()
  local t = { { id = "games", label = L("Jogos"), kind = "grid" } }
  if C.KNULLI then t[#t + 1] = { id = "kstore", label = L("Apps do Knulli"), kind = "apps" } end
  t[#t + 1] = { id = "bios", label = L("BIOS"), kind = "open" }
  t[#t + 1] = { id = "tools", label = L("Utilitários"), kind = "grid" }
  return t
end

local function featured_list()
  local f = {}
  for i, p in ipairs(Catalog.ports) do if p.featured then f[#f + 1] = { p = p, i = i } end end
  table.sort(f, function(a, b)
    local oa, ob = a.p.featured_order or math.huge, b.p.featured_order or math.huge
    if oa ~= ob then return oa < ob end
    return a.i < b.i
  end)
  local out = {}
  for k, e in ipairs(f) do out[k] = e.p end
  -- sem destaques marcados: os mais novos do catalogo
  if #out == 0 then out = require("ui.premium.model").news(Catalog.ports, 5) end
  return out
end

--- filtro da aba (lido de Prefs na primeira vez)
local function filt(s, id)
  s.filters = s.filters or {}
  local f = s.filters[id]
  if not f then f = PF.load(id); s.filters[id] = f end
  return f
end

--- itens da grade: ports da aba filtrados e ordenados. Sem filtro, as
--- ferramentas integradas (aba Utilitarios) ficam na frente
local function build_items(s, section)
  local f = filt(s, section)
  local base = Catalog.filter("all", App.status, section)
  s.base = base
  local ports = PF.apply(base, f)
  local items = {}
  if PF.active_count(f) == 0 then
    for _, t in ipairs(require("core.tools").for_filter(section, "all")) do items[#items + 1] = t end
  end
  for _, p in ipairs(ports) do items[#items + 1] = p end
  return items
end

local function cat_name(id)
  local Cats = require("core.categories")
  local c = Cats.BY_ID[id]
  if c then return c.name end
  for _, x in ipairs(Catalog.categories) do if x.id == id then return x.name end end
  return id
end

local function st(self)
  local s = self.pc
  if not s then
    s = { tab = 1, sel = 1, zone = "grid", feat = 1, feat_t = 0, chip = 1 }
    self.pc = s
  end
  if not s.tabs then
    s.tabs = tabs()
    s.feats = featured_list()
    s.feat = U.clamp(s.feat, 1, math.max(1, #s.feats))
    s.tab = U.clamp(s.tab, 1, #s.tabs)
    s.items = nil
  end
  local t = s.tabs[s.tab]
  if t.kind == "grid" and not s.items then
    s.items = build_items(s, t.id)
    s.jump = nil
    s.sel = U.clamp(s.sel, 1, math.max(1, #s.items))
    s.count = 0
    for _, p in ipairs(s.items) do if not p.builtin then s.count = s.count + 1 end end
    local f = filt(s, t.id)
    s.chips = PF.is_default(f) and {} or PF.chips(f, cat_name)
    if #s.chips > 0 then s.chips[#s.chips + 1] = { key = "all", label = L("Limpar"), clear = true } end
    s.chip = U.clamp(s.chip or 1, 1, math.max(1, #s.chips))
    s.grid_y = #s.chips > 0 and (GRID_Y + STRIP_H) or GRID_Y
    if s.zone == "chips" and #s.chips == 0 then s.zone = "grid" end
  elseif t.kind == "apps" and not s.items then
    -- Apps do Knulli: cartoes da Knulli App Store (vazio = loja nao instalada)
    local items, err, inst = require("ui.premium.kapp").items()
    s.items, s.apps_err, s.apps_inst = items or {}, err, inst or 0
    s.sel = U.clamp(s.sel, 1, math.max(1, #s.items))
    s.chips, s.grid_y = {}, GRID_Y
  elseif t.kind ~= "grid" then
    s.chips, s.grid_y = {}, GRID_Y
  end
  return s
end

--- catalogo mudou (on_catalog / resume): refaz as listas
function PC.invalidate(self)
  if self.pc then self.pc.tabs = nil; self.pc.items = nil; self.pc.oinfo = nil end
end

-- abas Utilitarios e Apps do Knulli: cartoes largos (itens sem capa e com nome longo)
local function metrics(s)
  local t = s.tabs and s.tabs[s.tab]
  return PG.metrics(20, s.grid_y or GRID_Y, 600, PS.FOOT_Y - 6, t and (t.id == "tools" or t.kind == "apps"))
end

function PC.update(self, dt)
  local s = st(self)
  local t = s.tabs[s.tab]
  if t.kind == "grid" or t.kind == "apps" then
    PG.update(s, #s.items, s.sel, metrics(s), dt)
  end
  if s.sheet then require("ui.premium.filtersheet").update(s.sheet, dt) end
  if s.jump then
    s.jump.t = s.jump.t - dt
    if s.jump.t <= 0 then s.jump = nil end
  end
  -- vitrine: troca sozinha a cada DWELL s (com animacoes ligadas)
  local n = #s.feats
  if s.fade then
    s.fade = s.fade + dt
    if s.fade >= FADE then s.fade = nil end
  elseif n > 1 and App.animations() and s.zone ~= "band" and not s.sheet then
    s.feat_t = s.feat_t + dt
    if s.feat_t > DWELL then PC.feat_go(s, 1) end
  end
end

function PC.feat_go(s, d)
  local n = #s.feats
  if n < 2 then return end
  s.prev = s.feat
  s.feat = (s.feat - 1 + d) % n + 1
  s.feat_t = 0
  s.fade = App.animations() and 0 or nil
end

-- ---------------------------------------------------------------------------

--- arte da faixa (hero, ou capa desfocada) no retangulo; a = opacidade
local function band_art(p, a)
  if not p then return end
  local hero = require("core.heroart").get(p)
  if hero then
    PS.draw_cover_fit(hero, 0, 0, 640, BAND_H, 0.5, 0.3, a)
    return
  end
  local img = Covers.get(p)
  if img then
    local cv = PI.blurred(img, (p.slug or "") .. "|band", 640, BAND_H, { dark = 0.1 })
    if cv then lg.setColor(1, 1, 1, a or 1); lg.draw(cv, 0, 0) end
  end
end

local function draw_band(self, s)
  local c = PS.c()
  PS.rect(0, 0, 640, BAND_H, c.surf)
  local p = s.feats[s.feat]
  if s.fade and s.prev and s.feats[s.prev] then
    local k = s.fade / FADE
    band_art(s.feats[s.prev], 1)
    band_art(p, k)
  else
    band_art(p, 1)
  end
  PS.veil(0, 0, 640, BAND_H, 0.55)
  local on = s.zone == "band"
  local k = PS.fk("pc_band", on)
  if k > 0 then PS.focus(2, 2, 636, BAND_H - 4, 10, k) end
  -- titulo e busca
  local tf = PS.font("b", 15, true)
  PS.text(tf, L("Central"), 20, 12 + 13 - tf:getHeight() / 2, c.text)
  local bx, by, bw, bh = 640 - 20 - 190, 12, 190, 26
  PS.rect(bx, by, bw, bh, c.surf, 8, 0.85)
  PS.icon("search", bx + 10, by + 6, 14, c.dim)
  local sf = PS.font("r", 12, true)
  PS.fit(sf, L("Buscar ports"), bx + 32, by + 13 - sf:getHeight() / 2, bw - 70, c.dim)
  PS.glyph("y", bx + bw - 24, by + 4, 18)
  -- EM DESTAQUE + nome
  if p then
    local lf, nf = PS.font("b", 11, true), PS.font("x", 19)
    local ny = BAND_H - 12 - nf:getHeight()
    PS.track(lf, L("EM DESTAQUE"), 20, ny - 2 - lf:getHeight(), c.accent, 0.08)
    PS.fit(nf, p.name, 20, ny, 440, c.text)
    local n = #s.feats
    if n > 1 then
      for i = 1, math.min(n, 8) do
        PS.color(i == s.feat and c.accent or c.text, i == s.feat and 1 or 0.4)
        lg.circle("fill", 620 - (math.min(n, 8) - i) * 10, BAND_H - 18, 3, 10)
      end
    end
  end
end

local function draw_tabs(self, s)
  local c = PS.c()
  local x = 20
  local fa, fi = PS.font("b", 12, true), PS.font("m", 12, true)
  for i, t in ipairs(s.tabs) do
    local on = i == s.tab
    local f = on and fa or fi
    local w = f:getWidth(PS.tr(t.label)) + 28
    PS.rect(x, TABS_Y + 7, w, 28, on and c.accent or c.surf, 14)
    PS.text(f, t.label, x + 14, TABS_Y + 21 - f:getHeight() / 2, on and c.bg or c.dim2)
    x = x + w + 8
  end
  local t = s.tabs[s.tab]
  if t.kind == "apps" and #s.items > 0 then
    -- Apps do Knulli: "N apps • X instalados" a direita
    local cf = PS.font("r", 12, true)
    local txt = string.format(PS.tr(L("%d apps  •  %d instalados")), #s.items, s.apps_inst or 0)
    local tw = cf:getWidth(txt)
    if 620 - tw > x then PS.text(cf, txt, 620 - tw, TABS_Y + 21 - cf:getHeight() / 2, c.dim) end
  end
  if t.kind == "grid" then
    -- botao do painel de filtros (com o numero de filtros ligados)
    local rf = PS.font("m", 12, true)
    local n = PF.active_count(filt(s, t.id))
    local label = PS.tr(L("Filtros"))
    local w = 8 + 18 + 6 + rf:getWidth(label) + (n > 0 and (6 + 18) or 0) + 12
    local fx = 620 - w
    if fx > x then
      PS.rect(fx, TABS_Y + 7, w, 28, c.surf, 14)
      PS.glyph("x", fx + 6, TABS_Y + 12, 18)
      PS.text(rf, label, fx + 30, TABS_Y + 21 - rf:getHeight() / 2, c.dim2)
      if n > 0 then
        local nf = PS.font("b", 11, true)
        local nx = fx + 30 + rf:getWidth(label) + 6
        PS.rect(nx, TABS_Y + 12, 18, 18, c.accent, 9)
        local ns = tostring(n)
        PS.text(nf, ns, nx + 9 - nf:getWidth(ns) / 2, TABS_Y + 21 - nf:getHeight() / 2, c.bg)
      elseif #(s.chips or {}) == 0 then
        -- sem filtros: a contagem fica a esquerda do botao
        local cf = PS.font("r", 12, true)
        local txt = string.format(PS.tr(s.count == 1 and L("%d port") or L("%d ports")), s.count or 0)
        -- Utilitarios sem ports do catalogo: conta as ferramentas integradas
        if (s.count or 0) == 0 and s.items and #s.items > 0 then txt = string.format(PS.tr(L("%d ferramentas")), #s.items) end
        if fx - 12 - cf:getWidth(txt) > x then PS.text(cf, txt, fx - 12 - cf:getWidth(txt), TABS_Y + 21 - cf:getHeight() / 2, c.dim) end
      end
    end
  end
end

--- faixa dos filtros ativos: "N ports", pilulas com x e "Limpar"
local function draw_strip(self, s)
  local chips = s.chips or {}
  if #chips == 0 then return end
  local c = PS.c()
  local y = GRID_Y - 2
  local h = 22
  local cy = y + (STRIP_H - h) / 2 - 1
  local bf = PS.font("b", 12, true)
  local txt = string.format(PS.tr(s.count == 1 and L("%d port") or L("%d ports")), s.count or 0)
  local x = 20 + PS.text(bf, txt, 20, cy + h / 2 - bf:getHeight() / 2, s.count > 0 and c.accent or c.warn) + 12
  local f = PS.font("m", 11, true)
  local xf = PS.font("b", 11, true)
  local focus = s.zone == "chips"
  for i, ch in ipairs(chips) do
    local label = PS.tr(ch.label)
    local w = f:getWidth(label) + 20 + (ch.clear and 0 or 12)
    -- nao cabe: "+N" no lugar das que sobram (o Limpar sempre aparece)
    local rest = 0
    if not ch.clear then
      local lw = f:getWidth(PS.tr(L("Limpar"))) + 20
      if x + w + 8 + lw > 620 then rest = #chips - i end
    end
    if rest > 0 then
      local more = "+" .. rest
      local mw = f:getWidth(more) + 16
      PS.rect(x, cy, mw, h, c.surf, h / 2)
      PS.text(f, more, x + 8, cy + h / 2 - f:getHeight() / 2, c.dim2)
      if focus and s.chip >= i and s.chip < #chips then PS.frame(x - 2, cy - 2, mw + 4, h + 4, c.accent, h / 2 + 2, 2) end
      x = x + mw + 8
      ch = chips[#chips]
      label = PS.tr(ch.label)
      w = f:getWidth(label) + 20
      i = #chips
      PS.frame(x, cy, w, h, c.line, h / 2, 1)
      PS.text(f, label, x + 10, cy + h / 2 - f:getHeight() / 2, c.dim2)
      if focus and s.chip == i then PS.frame(x - 2, cy - 2, w + 4, h + 4, c.accent, h / 2 + 2, 2) end
      break
    end
    if ch.clear then
      PS.frame(x, cy, w, h, c.line, h / 2, 1)
      PS.text(f, label, x + 10, cy + h / 2 - f:getHeight() / 2, c.dim2)
    else
      PS.rect(x, cy, w, h, c.surf2, h / 2)
      PS.text(f, label, x + 10, cy + h / 2 - f:getHeight() / 2, c.text)
      PS.text(xf, "×", x + w - 16, cy + h / 2 - xf:getHeight() / 2 - 1, c.dim)
    end
    if focus and s.chip == i then PS.frame(x - 2, cy - 2, w + 4, h + 4, c.accent, h / 2 + 2, 2) end
    x = x + w + 8
  end
end

--- abas que abrem outra tela: cartao grande com o resumo real
local function open_info(id)
  if id == "kstore" then
    local KS = require("core.kstore")
    local apps = KS.available() and KS.list() or nil
    local n = 0
    for _, a in ipairs(apps or {}) do if a.status ~= "none" then n = n + 1 end end
    return L("Apps do Knulli"), L("Apps da Knulli App Store (comunidade): instalar, atualizar e remover."),
      apps and string.format(PS.tr(L("%d de %d instalados")), n, #apps) or L("Loja não instalada"), "store"
  end
  local okb, label = pcall(function() return require("ui.screens.sections").bios_label({}) end)
  return L("BIOS do Sistema"), L("Downloads, verificação e instalação de BIOS para emuladores."),
    okb and label or "", "bios"
end

local function draw_open(self, s)
  local c = PS.c()
  local t = s.tabs[s.tab]
  s.oinfo = s.oinfo or { open_info(t.id) }    -- (resumo lido uma vez por aba)
  local title, desc, status, icon = s.oinfo[1], s.oinfo[2], s.oinfo[3], s.oinfo[4]
  local k = PS.fk("pc_open", true)
  local x, y, w, h = PS.grow(20, GRID_Y + 6, 600, 200, k, 0.01)
  PS.rect(x, y, w, h, c.surf, 14)
  PS.focus(x, y, w, h, 14, k)
  PS.rect(x + 24, y + 24, 64, 64, c.surf2, 14)
  require("ui.icons").draw(icon, x + 36, y + 36, c.accent, 40 / 24)
  local tf, df, sf = PS.font("b", 18), PS.font("r", 13), PS.font("m", 12)
  PS.fit(tf, title, x + 108, y + 28, w - 132, c.text)
  local ls = PS.lines(df, desc, w - 132, 3)
  for i, l in ipairs(ls) do PS.text(df, l, x + 108, y + 58 + (i - 1) * math.floor(df:getHeight() * 1.4), c.dim2) end
  if status and status ~= "" then PS.pill(U.upper(PS.tr(status)), x + 108, y + 124, { font = PS.font("b", 11, true), bg = c.surf2, fg = c.dim2, h = 22, px = 10 }) end
  local bf = PS.font("b", 13, true)
  local label = PS.tr(L("Abrir"))
  local bw = 14 + 16 + 8 + bf:getWidth(label) + 14
  PS.rect(x + 108, y + h - 24 - 30, bw, 30, c.accent, 15)
  PS.glyph("a", x + 108 + 14, y + h - 24 - 23, 16, true)
  PS.text(bf, label, x + 108 + 38, y + h - 24 - 15 - bf:getHeight() / 2, c.bg)
end

--- grade vazia: sem ports na aba, ou nenhum com os filtros escolhidos
local function draw_empty(self, s, t)
  local c = PS.c()
  local f = filt(s, t.id)
  if PF.active_count(f) == 0 then
    local ef = PS.font("r", 13)
    PS.fit(ef, L("Nenhum port ainda. Eles aparecem aqui quando o catálogo for atualizado."), 20, GRID_Y + 80, 600, c.dim, "center")
    return
  end
  local y = s.grid_y + 34
  PS.rect(296, y, 48, 48, c.surf, 14)
  PS.icon("search", 308, y + 12, 24, c.dim)
  local tf, df = PS.font("b", 15), PS.font("r", 12)
  PS.fit(tf, L("Nenhum port com esses filtros"), 20, y + 62, 600, c.text, "center")
  PS.fit(df, L("Tire um filtro na faixa acima ou ajuste o painel."), 20, y + 86, 600, c.dim, "center")
  -- botoes: B limpa, Y abre o painel
  local bf = PS.font("b", 12, true)
  local l1, l2 = PS.tr(L("Limpar filtros")), PS.tr(L("Filtros"))
  local w1 = 12 + 16 + 8 + bf:getWidth(l1) + 14
  local w2 = 12 + 16 + 8 + bf:getWidth(l2) + 14
  local bx = 320 - (w1 + 10 + w2) / 2
  local by = y + 116
  PS.rect(bx, by, w1, 30, c.accent, 15)
  PS.glyph("a", bx + 12, by + 7, 16, true)
  PS.text(bf, l1, bx + 36, by + 15 - bf:getHeight() / 2, c.bg)
  bx = bx + w1 + 10
  PS.rect(bx, by, w2, 30, c.surf2, 15)
  PS.glyph("x", bx + 12, by + 7, 16)
  PS.text(bf, l2, bx + 36, by + 15 - bf:getHeight() / 2, c.dim2)
end

--- letra grande no centro da grade depois do pulo L2/R2
local function draw_jump(s)
  local j = s.jump
  if not j then return end
  local c = PS.c()
  local a = math.min(1, j.t / 0.18)
  local m = metrics(s)
  local cx, cy = 320, m.y + m.view / 2
  PS.shadow(cx - 50, cy - 50, 100, 100, 20, 6, 0.6 * a)
  PS.rect(cx - 50, cy - 50, 100, 100, c.surf, 20, 0.96 * a)
  PS.frame(cx - 50, cy - 50, 100, 100, c.accent, 20, 2, a)
  if j.letter == "*" then
    -- ferramentas integradas (antes dos ports, sem letra)
    PS.icon("wrench", cx - 24, cy - 24, 48, c.accent)
    return
  end
  local f = PS.font("x", 56, true)
  PS.text(f, j.letter, cx - f:getWidth(j.letter) / 2, cy - f:getHeight() / 2, c.accent, a)
end

--- aba Apps do Knulli sem apps: loja nao instalada (explica e mostra o
--- repositorio) ou lista vazia/ilegivel
local function draw_apps_empty(self, s)
  local c = PS.c()
  local K = require("core.kstore")
  local y = GRID_Y + 22
  PS.rect(292, y, 56, 56, c.surf, 16)
  require("ui.icons").draw("store", 304, y + 12, c.accent, 32 / 24)
  local tf, df, uf = PS.font("b", 15), PS.font("r", 12), PS.font("m", 13)
  y = y + 72
  if s.apps_err == "missing" then
    PS.fit(tf, L("Knulli App Store não instalada"), 20, y, 600, c.text, "center")
    local body = PS.tr(L("Os apps do Knulli vêm da Knulli App Store, uma loja da comunidade. Instale a loja pelo site do projeto e os apps aparecem aqui, com instalação e atualização pelo hub."))
    local ls = PS.lines(df, body, 480, 3)
    for i, l in ipairs(ls) do PS.fit(df, l, 80, y + 28 + (i - 1) * 18, 480, c.dim2, "center") end
    local uy = y + 28 + #ls * 18 + 14
    local url = K.REPO:gsub("^https?://", "")
    local uw = uf:getWidth(url) + 28
    PS.rect(320 - uw / 2, uy, uw, 28, c.surf, 14)
    PS.text(uf, url, 320 - uf:getWidth(url) / 2, uy + 14 - uf:getHeight() / 2, c.accent)
  else
    PS.fit(tf, L("Nenhum app na lista da Knulli App Store."), 20, y, 600, c.text, "center")
    if s.apps_err and s.apps_err ~= "" then PS.fit(df, s.apps_err, 20, y + 28, 600, c.dim, "center") end
  end
end

function PC.draw(self)
  local s = st(self)
  local c = PS.c()
  draw_band(self, s)
  draw_tabs(self, s)
  local t = s.tabs[s.tab]
  if t.kind == "grid" then
    draw_strip(self, s)
    if #s.items == 0 then
      draw_empty(self, s, t)
    else
      PG.draw(s, metrics(s), { items = s.items, sel = s.sel, focus = s.zone == "grid" and not s.sheet, key = "pc" .. t.id })
    end
    draw_jump(s)
  elseif t.kind == "apps" then
    if #s.items == 0 then
      draw_apps_empty(self, s)
    else
      PG.draw(s, metrics(s), { items = s.items, sel = s.sel, focus = s.zone == "grid", key = "pck" })
    end
  else
    draw_open(self, s)
  end
  if s.sheet then require("ui.premium.filtersheet").draw(s.sheet); return end
  local hints = { { "a", L("Abrir") }, { "b", L("Voltar") }, { { "l1", "r1" }, L("Abas") }, { "y", L("Buscar") } }
  if t.kind == "apps" then
    if #s.items == 0 then table.remove(hints, 1) else hints[1] = { "a", L("Detalhes") } end
    if require("core.kstore").available() then hints[#hints + 1] = { "x", L("Loja completa") } end
  end
  if t.kind == "grid" then
    hints[#hints + 1] = { "x", L("Filtros") }
    if s.zone == "chips" then
      hints[1] = { "a", L("Tirar filtro") }
    elseif #s.items == 0 then
      hints[1] = { "a", L("Limpar filtros") }
    else
      if filt(s, t.id).sort == "az" then hints[#hints + 1] = { { "l2", "r2" }, L("Letra") } end
      hints[#hints + 1] = { "select", L("Favorito") }
    end
  end
  PS.footer(hints)
end

function PC.switch_tab(self, d)
  local s = st(self)
  s.tab = (s.tab - 1 + d) % #s.tabs + 1
  s.items, s.sel, s.pg_scroll, s.pg_target, s.oinfo, s.jump = nil, 1, 0, 0, nil, nil
  if s.zone == "grid" or s.zone == "open" or s.zone == "chips" then s.zone = "grid" end
  Covers.reset_pending()
end

--- o filtro da aba mudou: grava, refaz a grade e volta ao comeco
local function refilter(s, keep_zone)
  local t = s.tabs[s.tab]
  PF.save(t.id, filt(s, t.id))
  s.items, s.sel, s.pg_scroll, s.pg_target = nil, 1, 0, 0
  s.jump = nil
  if not keep_zone then s.zone = "grid" end
  Covers.reset_pending()
end

--- L2/R2: primeira capa da letra anterior/seguinte (ordem A-Z); nas outras
--- ordens, pula 3 linhas
local function jump(s, d)
  local items = s.items
  local n = #items
  if n == 0 then return end
  local f = filt(s, s.tabs[s.tab].id)
  s.zone = "grid"
  if f.sort ~= "az" then
    s.sel = U.clamp(s.sel + d * metrics(s).cols * 3, 1, n)
    return
  end
  local letter = PF.letter
  local function block_start(i)
    local l = letter(items[i])
    while i > 1 and letter(items[i - 1]) == l do i = i - 1 end
    return i
  end
  local i
  if d > 0 then
    local l = letter(items[s.sel])
    i = s.sel
    while i <= n and letter(items[i]) == l do i = i + 1 end
    if i > n then i = 1 end                -- depois da ultima letra: volta ao comeco
  else
    local b = block_start(s.sel)
    if b > 1 then i = block_start(b - 1) else i = block_start(n) end
  end
  s.sel = i
  -- a primeira linha da letra vai para o topo da grade
  local m = metrics(s)
  local row = math.floor((i - 1) / m.cols)
  local rows = math.ceil(n / m.cols)
  local maxs = math.max(0, rows * (m.rh + PG.GAP) - PG.GAP - (m.view - 4))
  s.pg_target = math.min(row * (m.rh + PG.GAP), maxs)
  local l = letter(items[i])
  s.jump = { letter = l, t = JUMP_T }
end

function PC.action(self, act)
  local s = st(self)
  local t = s.tabs[s.tab]
  -- painel de filtros aberto: ele recebe tudo
  if s.sheet then
    local r = require("ui.premium.filtersheet").action(s.sheet, act)
    if r == "close" then s.sheet = nil; refilter(s) end
    return
  end
  if act == "b" then App.pop(); return end
  if act == "l1" then PC.switch_tab(self, -1); return end
  if act == "r1" then PC.switch_tab(self, 1); return end
  if act == "y" then App.push("search"); return end
  if act == "x" and t.kind == "grid" then
    s.sheet = require("ui.premium.filtersheet").open(t.id, s.base or Catalog.filter("all", App.status, t.id), filt(s, t.id))
    return
  end
  local has_chips = t.kind == "grid" and #(s.chips or {}) > 0
  if s.zone == "band" then
    local p = s.feats[s.feat]
    if act == "down" then s.zone = has_chips and "chips" or "grid"
    elseif act == "left" then PC.feat_go(s, -1)
    elseif act == "right" then PC.feat_go(s, 1)
    elseif act == "a" then if p then App.push("details", { port = p }) end
    end
    return
  end
  if t.kind == "apps" then
    local n = #s.items
    if act == "x" then
      if require("core.kstore").available() then require("ui.kstore_ui").open_store() end
    elseif act == "up" or act == "down" or act == "left" or act == "right" then
      local sel, out = PG.move(s.sel, n, act, metrics(s).cols)
      s.sel = sel
      if out == "up" or (n == 0 and act == "up") then s.zone = "band" end
    elseif act == "a" then
      local it = s.items[s.sel]
      if it and it.app then require("ui.premium.kapp").open(it.app) end
    end
    return
  end
  if t.kind == "open" then
    if act == "up" then s.zone = "band"
    elseif act == "a" then
      if t.id == "kstore" then require("ui.kstore_ui").open() else App.push("bios") end
    end
    return
  end
  if s.zone == "chips" then
    local n = #s.chips
    if act == "left" then s.chip = math.max(1, s.chip - 1)
    elseif act == "right" then s.chip = math.min(n, s.chip + 1)
    elseif act == "up" then s.zone = "band"
    elseif act == "down" then s.zone = "grid"
    elseif act == "a" then
      local ch = s.chips[s.chip]
      local f = filt(s, t.id)
      if ch.clear then PF.clear(f) else PF.clear_key(f, ch.key) end
      refilter(s, true)
      st(self)
      if #s.chips == 0 then s.zone = "grid" end
    end
    return
  end
  if act == "l2" then jump(s, -1); return end
  if act == "r2" then jump(s, 1); return end
  local n = #s.items
  if act == "up" or act == "down" or act == "left" or act == "right" then
    local sel, out = PG.move(s.sel, n, act, metrics(s).cols)
    s.sel = sel
    if out == "up" or (n == 0 and act == "up") then s.zone = has_chips and "chips" or "band" end
    return
  end
  local p = s.items[s.sel]
  if not p then
    -- grade vazia por causa dos filtros: B limpa tudo
    if act == "a" and PF.active_count(filt(s, t.id)) > 0 then
      PF.clear(filt(s, t.id), true)
      refilter(s)
    end
    return
  end
  if act == "a" then
    if p.builtin then App.push(p.screen, { from = "store" }) else App.push("details", { port = p }) end
  elseif act == "select" then
    if p.builtin then App.toast(L("Ferramentas integradas já ficam sempre aqui, em Manutenção."), "info"); return end
    local on = Favorites.toggle(p)
    App.toast(on and (p.name .. L(" adicionado aos favoritos")) or (p.name .. L(" removido dos favoritos")), "info")
  end
end

return PC
