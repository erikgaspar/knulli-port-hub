-- =============================================================================
--  Tema Premium: Central (tela "sections")
--  Faixa EM DESTAQUE (112 px) com arte de fundo, abas em pilulas (L1/R1) e
--  grade de capas em 6 colunas. Abas "Apps do Knulli" e "BIOS" abrem as telas
--  proprias (um cartao grande explica e abre com B).
--    direcional: grade (cima na primeira linha vai para a faixa EM DESTAQUE)
--    B (acao "a"): abrir | A (acao "b"): voltar | L1/R1: abas | X (acao "y"): buscar
--    SELECT: favorito | na faixa: esquerda/direita trocam o destaque
-- =============================================================================
local L = require("lib.i18n").L
local C = require("config")
local U = require("lib.util")
local Catalog = require("core.catalog")
local Covers = require("core.covers")
local Favorites = require("core.favorites")
local PS = require("ui.premium.style")
local PG = require("ui.premium.grid")
local PI = require("ui.premium.images")

local PC = {}
local lg = love.graphics

local BAND_H, TABS_Y, TABS_H = 112, 112, 42
local GRID_Y = BAND_H + TABS_H + 2
local DWELL, FADE = 6.0, 0.5

local function tabs()
  local t = { { id = "games", label = L("Jogos"), kind = "grid" } }
  if C.KNULLI then t[#t + 1] = { id = "kstore", label = L("Apps do Knulli"), kind = "open" } end
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

local function build_items(section)
  local items = {}
  for _, t in ipairs(require("core.tools").for_filter(section, "all")) do items[#items + 1] = t end
  local ports = Catalog.filter("all", App.status, section)
  ports = require("ui.settings_extra").sort_ports(ports, "list_sort")
  for _, p in ipairs(ports) do items[#items + 1] = p end
  return items
end

local function st(self)
  local s = self.pc
  if not s then
    s = { tab = 1, sel = 1, zone = "grid", feat = 1, feat_t = 0 }
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
    s.items = build_items(t.id)
    s.sel = U.clamp(s.sel, 1, math.max(1, #s.items))
    s.count = 0
    for _, p in ipairs(s.items) do if not p.builtin then s.count = s.count + 1 end end
  end
  return s
end

--- catalogo mudou (on_catalog / resume): refaz as listas
function PC.invalidate(self)
  if self.pc then self.pc.tabs = nil; self.pc.items = nil; self.pc.oinfo = nil end
end

function PC.update(self, dt)
  local s = st(self)
  local t = s.tabs[s.tab]
  if t.kind == "grid" then
    PG.update(s, #s.items, s.sel, PG.metrics(20, GRID_Y, 600, PS.FOOT_Y - 6), dt)
  end
  -- vitrine: troca sozinha a cada DWELL s (com animacoes ligadas)
  local n = #s.feats
  if s.fade then
    s.fade = s.fade + dt
    if s.fade >= FADE then s.fade = nil end
  elseif n > 1 and App.animations() and s.zone ~= "band" then
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
  if t.kind == "grid" then
    local rf = PS.font("r", 12, true)
    local txt = string.format(PS.tr(s.count == 1 and L("%d port") or L("%d ports")), s.count or 0)
    if 620 - rf:getWidth(txt) > x then PS.text(rf, txt, 620 - rf:getWidth(txt), TABS_Y + 21 - rf:getHeight() / 2, c.dim) end
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

function PC.draw(self)
  local s = st(self)
  local c = PS.c()
  draw_band(self, s)
  draw_tabs(self, s)
  local t = s.tabs[s.tab]
  if t.kind == "grid" then
    if #s.items == 0 then
      local f = PS.font("r", 13)
      PS.fit(f, L("Nenhum port ainda. Eles aparecem aqui quando o catálogo for atualizado."), 20, GRID_Y + 80, 600, c.dim, "center")
    else
      PG.draw(s, PG.metrics(20, GRID_Y, 600, PS.FOOT_Y - 6), { items = s.items, sel = s.sel, focus = s.zone == "grid", key = "pc" .. t.id })
    end
  else
    draw_open(self, s)
  end
  PS.footer({ { "a", L("Abrir") }, { "b", L("Voltar") }, { { "l1", "r1" }, L("Abas") }, { "y", L("Buscar") }, { "select", L("Favorito") } })
end

function PC.switch_tab(self, d)
  local s = st(self)
  s.tab = (s.tab - 1 + d) % #s.tabs + 1
  s.items, s.sel, s.pg_scroll, s.pg_target, s.oinfo = nil, 1, 0, 0, nil
  if s.zone == "grid" or s.zone == "open" then s.zone = "grid" end
  Covers.reset_pending()
end

function PC.action(self, act)
  local s = st(self)
  local t = s.tabs[s.tab]
  if act == "b" then App.pop(); return end
  if act == "l1" then PC.switch_tab(self, -1); return end
  if act == "r1" then PC.switch_tab(self, 1); return end
  if act == "y" then App.push("search"); return end
  if s.zone == "band" then
    local p = s.feats[s.feat]
    if act == "down" then s.zone = "grid"
    elseif act == "left" then PC.feat_go(s, -1)
    elseif act == "right" then PC.feat_go(s, 1)
    elseif act == "a" or act == "x" then if p then App.push("details", { port = p }) end
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
  local n = #s.items
  if act == "up" or act == "down" or act == "left" or act == "right" then
    local sel, out = PG.move(s.sel, n, act)
    s.sel = sel
    if out == "up" then s.zone = "band" end
    return
  end
  local p = s.items[s.sel]
  if not p then return end
  if act == "a" then
    if p.builtin then App.push(p.screen, { from = "store" }) else App.push("details", { port = p }) end
  elseif act == "select" then
    if p.builtin then App.toast(L("Ferramentas integradas já ficam sempre aqui, em Manutenção."), "info"); return end
    local on = Favorites.toggle(p)
    App.toast(on and (p.name .. L(" adicionado aos favoritos")) or (p.name .. L(" removido dos favoritos")), "info")
  end
end

return PC
