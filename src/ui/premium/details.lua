-- =============================================================================
--  Tema Premium: pagina do port (tela "details")
--  Fundo = capa desfocada e escurecida (Canvas pre-calculado), capa 168x236
--  com sombra, titulo grande, selos, descricao, cartao "Modo desempenho" e os
--  botoes Jogar (acento) e Opcoes. As acoes reaproveitam as da tela original
--  (instalar, atualizar, aviso do RG35XXH, espaco, remover, favoritos...).
--    direcional: escolher (cima/baixo entre o cartao de desempenho e os botoes)
--    B (acao "a"): confirmar | Y (acao "x"): opcoes | A (acao "b"): voltar
--    L1/R1: rolar a descricao | SELECT: favoritar
-- =============================================================================
local L = require("lib.i18n").L
local C = require("config")
local U = require("lib.util")
local Catalog = require("core.catalog")
local Covers = require("core.covers")
local Manifest = require("core.manifest")
local Favorites = require("core.favorites")
local Downloads = require("core.downloads")
local Compat = require("core.compat")
local PS = require("ui.premium.style")
local PM = require("ui.premium.model")
local PI = require("ui.premium.images")

local PD = {}
local lg = love.graphics

local COVER_X, COVER_Y, COVER_W, COVER_H = 20, 58, 168, 236
local RX, RW = 208, 412                 -- coluna da direita
local BTN_H = 46

local function perf_ok(p)
  if not C.KNULLI or p.builtin then return false end
  local ok, avail = pcall(function() return require("core.perf").available() end)
  return ok and avail
end

--- o port pode ser aberto pelo hub agora?
local function playable(p)
  return App.status(p) ~= "none" and App.port_script(p) ~= nil
end

--- rotulo do botao principal: Jogar (instalado) ou o do fluxo de instalacao
function PD.main_label(self)
  local p = self.port
  if playable(p) then return L("Jogar"), true end
  local label, enabled = self:primary()
  local nice = { [L("INSTALAR")] = L("Instalar"), [L("ATUALIZAR")] = L("Atualizar"), [L("REINSTALAR")] = L("Reinstalar"),
    [L("NA FILA")] = L("Na fila"), [L("BAIXANDO")] = L("Baixando"), [L("EM BREVE")] = L("Em breve"), [L("INSTALADO")] = L("Instalado") }
  return nice[label] or label, enabled
end

local function focus_list(self)
  local list = {}
  if perf_ok(self.port) then list[#list + 1] = "perf" end
  list[#list + 1] = "play"
  list[#list + 1] = "opts"
  return list
end

local function st(self)
  if not self.pd then self.pd = { focus = "play", desc_scroll = 0 } end
  return self.pd
end

-- ---------------------------------------------------------------------------

local function draw_backdrop(p)
  local c = PS.c()
  PS.rect(0, 0, 640, 480, c.bg)
  local img = Covers.get(p)
  if img then
    local cv = PI.backdrop(img, p.slug or tostring(p.id))
    if cv then lg.setColor(1, 1, 1, 1); lg.draw(cv, 0, 0) end
  end
end

local function draw_crumbs(self)
  local c = PS.c()
  local p = self.port
  PS.rect(0, 39, 640, 1, c.text, 0.08)
  local f, fb = PS.font("r", 13, true), PS.font("m", 13, true)
  local parts = { L("Central"), p.section == "tools" and L("Utilitários") or L("Jogos") }
  local x, y = 20, 20 - f:getHeight() / 2
  for _, s in ipairs(parts) do
    x = x + PS.text(f, s, x, y, c.dim2) + 8
    PS.text(f, "›", x, y, c.dim)
    x = x + f:getWidth("›") + 8
  end
  local clock = require("core.clock").time()
  local cw = fb:getWidth(clock)
  PS.text(fb, clock, 620 - cw, y, c.text)
  PS.fit(fb, p.name, x, y, 620 - cw - 16 - x, c.text)
end

local function info_rows(self)
  local p = self.port
  local rows = {}
  local st_ = App.status(p)
  if st_ ~= "none" and self.disk then rows[#rows + 1] = { L("No cartão"), U.format_bytes(self.disk.bytes) }
  elseif p.size_label and p.size_label ~= "?" then rows[#rows + 1] = { L("Tamanho"), p.size_label } end
  local v = (st_ ~= "none" and Manifest.installed_version(p)) or p.version
  if (v or "") ~= "" then rows[#rows + 1] = { L("Versão"), v } end
  rows[#rows + 1] = { L("Categoria"), p.category or "" }
  if (p.platform or "") ~= "" then rows[#rows + 1] = { L("Plataforma"), p.platform } end
  return rows
end

local function badges(self)
  local p = self.port
  local c = PS.c()
  local out = {}
  local b, k = PM.h700_badge(p, true)
  if b then
    out[#out + 1] = { b, k == "ok" and { c.accent[1], c.accent[2], c.accent[3], 0.16 } or (k == "warn" and PS.WARNBG or { c.red[1], c.red[2], c.red[3], 0.18 }),
      k == "ok" and c.accent or (k == "warn" and c.warn or c.red), "b" }
  end
  local st_ = App.status(p)
  if st_ == "update" then out[#out + 1] = { L("ATUALIZAÇÃO DISPONÍVEL"), PS.WARNBG, c.warn, "b" } end
  -- compatibilidade: so quando diz algo (experimental/incompativel); o resto fica em Opcoes
  if self.compat and (self.compat.status == "experimental" or self.compat.status == "incompatible") then
    local bad = self.compat.status == "incompatible"
    out[#out + 1] = { Compat.LABEL[self.compat.status], bad and { c.red[1], c.red[2], c.red[3], 0.18 } or PS.WARNBG, bad and c.red or c.warn, "b" }
  end
  if not p.builtin then
    local last = require("core.perf").last(p.id)
    if last and last.temp_max and last.temp_max > 0 then
      out[#out + 1] = { PS.tr(L("máx. ")) .. string.format("%d", math.floor(last.temp_max + 0.5)) .. " °C", c.surf2, c.dim2, "m" }
    end
  end
  if p.requires_files then out[#out + 1] = { L("REQUER ARQUIVOS DO JOGO"), PS.WARNBG, c.warn, "b" } end
  if Favorites.is(p) then out[#out + 1] = { L("FAVORITO"), c.surf2, c.dim2, "m" } end
  return out
end

local function draw_left(self)
  local c = PS.c()
  local p = self.port
  PS.shadow(COVER_X, COVER_Y, COVER_W, COVER_H, 14, 10, 0.6)
  -- fundo atras da capa: o Canvas desfocado; os cantos usam a cor media dele
  PS.cover(p, COVER_X, COVER_Y, COVER_W, COVER_H, 14, PD.corner_c)
  local f, fv = PS.font("r", 12), PS.font("m", 12)
  local y = COVER_Y + COVER_H + 12
  for _, r in ipairs(info_rows(self)) do
    if y + f:getHeight() > PS.FOOT_Y - 6 then break end
    PS.text(f, r[1], COVER_X, y, c.dim)
    local vw = math.min(fv:getWidth(PS.tr(r[2])), COVER_W - f:getWidth(PS.tr(r[1])) - 8)
    PS.fit(fv, r[2], COVER_X + COVER_W - vw, y, vw, c.text)
    y = y + f:getHeight() + 6
  end
end

local function draw_right(self)
  local c = PS.c()
  local p = self.port
  local s = st(self)
  local y = 58
  -- titulo (ate 2 linhas)
  local tf = PS.font("b", 24)
  local lines = PS.lines(tf, p.name, RW, 2)
  local lh = math.floor(tf:getHeight() * 1.12)
  for i, l in ipairs(lines) do PS.text(tf, l, RX, y + (i - 1) * lh, c.text) end
  y = y + #lines * lh + 10
  -- selos
  local x = RX
  local list = badges(self)
  local bh = 0
  for _, b in ipairs(list) do
    local f = PS.font(b[4], 11, true)
    local w = f:getWidth(PS.tr(b[1])) + 18
    if x + w > RX + RW then x = RX; y = y + 28 end
    PS.pill(b[1], x, y, { font = f, bg = b[2], fg = b[3], px = 9, h = 22 })
    x = x + w + 6
    bh = 22
  end
  if bh > 0 then y = y + bh + 12 end
  -- botoes (fixos no pe) e cartao de desempenho logo acima
  local by = PS.FOOT_Y - 16 - BTN_H
  local perf = perf_ok(p)
  local py = by - 12 - 62
  -- descricao: area entre os selos e o cartao (rola com L1/R1)
  local desc_bottom = (perf and py or by) - 12
  local df = PS.font("r", 13)
  local dlh = math.floor(df:getHeight() * 1.45)
  local text = Catalog.text(p, "description")
  if text == "" then text = Catalog.text(p, "short") end
  if text == "" then text = PS.tr(L("Sem descrição.")) end
  local _, dl = df:getWrap(PS.tr(text), RW)
  local vis = math.max(1, math.floor((desc_bottom - y) / dlh))
  s.desc_max = math.max(0, #dl - vis)
  s.desc_scroll = U.clamp(s.desc_scroll or 0, 0, s.desc_max)
  s.desc_vis = vis
  if desc_bottom - y >= dlh then
    for i = 1, vis do
      local l = dl[i + s.desc_scroll]
      if not l then break end
      if i == vis and i + s.desc_scroll < #dl then l = U.ellipsize(df, l .. " …", RW) end
      PS.text(df, l, RX, y + (i - 1) * dlh, c.dim2)
    end
  end
  -- cartao "Modo desempenho"
  if perf then
    local Perf = require("core.perf")
    local on = s.focus == "perf"
    local k = PS.fk("pd_perf", on)
    local cx, cy, cw, ch = PS.grow(RX, py, RW, 62, k, 0.015)
    PS.rect(cx, cy, cw, ch, c.surf, 12, 0.85)
    if k > 0 then PS.focus(cx, cy, cw, ch, 12, k) end
    local f1, f2 = PS.font("m", 13), PS.font("r", 12)
    PS.fit(f1, L("Modo desempenho"), cx + 14, cy + 12, cw - 80, c.text)
    local last = Perf.last(p.id)
    local sub = last and (PS.tr(L("Última sessão: ")) .. Perf.summary_text(last)) or PS.tr(L("CPU no máximo e GPU a 696 MHz enquanto joga."))
    PS.fit(f2, sub, cx + 14, cy + 14 + f1:getHeight() + 2, cw - 80, c.dim)
    local always = Perf.always(p.id)
    local tx, ty = cx + cw - 14 - 38, cy + ch / 2 - 11
    PS.rect(tx, ty, 38, 22, always and c.accent or c.line, 11)
    PS.color(always and c.bg or c.dim)
    lg.circle("fill", always and (tx + 38 - 3 - 8) or (tx + 3 + 8), ty + 11, 8, 16)
  end
  -- botoes
  local label, enabled = PD.main_label(self)
  local ow = 120
  local mw = RW - 10 - ow
  local on1, on2 = s.focus == "play", s.focus == "opts"
  local k1, k2 = PS.fk("pd_play", on1), PS.fk("pd_opts", on2)
  local x1, y1, w1, h1 = PS.grow(RX, by, mw, BTN_H, k1, 0.02)
  PS.rect(x1, y1, w1, h1, enabled and c.accent or c.surf2, 12)
  if k1 > 0 then PS.frame(x1 - 3, y1 - 3, w1 + 6, h1 + 6, c.accent, 15, 2, k1 * (enabled and 0.55 or 1)) end
  local bf = PS.font("b", 15, true)
  local lbl = PS.tr(label)
  local pend = Downloads.pending(p.id)
  if pend and pend.state ~= "waiting" then
    local pc = Downloads.percent and Downloads.percent(pend)
    if pc then lbl = lbl .. " " .. pc .. "%" end
  end
  local gw = 20 + 10 + bf:getWidth(lbl)
  local gx = x1 + (w1 - gw) / 2
  PS.glyph("a", gx, y1 + h1 / 2 - 10, 20, enabled)
  PS.text(bf, lbl, gx + 30, y1 + h1 / 2 - bf:getHeight() / 2, enabled and c.bg or c.dim)
  local x2, y2, w2, h2 = PS.grow(RX + mw + 10, by, ow, BTN_H, k2, 0.02)
  PS.rect(x2, y2, w2, h2, c.surf2, 12)
  if k2 > 0 then PS.focus(x2, y2, w2, h2, 12, k2) end
  local of = PS.font("m", 14, true)
  local ol = PS.tr(L("Opções"))
  local ogw = 20 + 8 + of:getWidth(ol)
  local ogx = x2 + (w2 - ogw) / 2
  PS.glyph("x", ogx, y2 + h2 / 2 - 10, 20)
  PS.text(of, ol, ogx + 28, y2 + h2 / 2 - of:getHeight() / 2, c.text)
end

function PD.draw(self)
  local p = self.port
  local s = st(self)
  if s.primary_pending and not App.dialog then s.primary_pending = nil end
  draw_backdrop(p)
  -- cor media do fundo atras da capa (cantos arredondados): o veu domina
  PD.corner_c = PS.c().bg
  draw_crumbs(self)
  draw_left(self)
  draw_right(self)
  local c = PS.c()
  local st_ = App.status(p)
  local stxt, scol
  local pend = Downloads.pending(p.id)
  if pend then stxt, scol = (pend.state == "waiting" and L("Na fila") or L("Baixando")), c.warn
  elseif p.builtin then stxt, scol = L("Ferramenta do hub"), c.accent
  elseif st_ == "installed" then stxt, scol = L("Instalado"), c.accent
  elseif st_ == "update" then stxt, scol = L("Atualização disponível"), c.warn
  else stxt, scol = L("Não instalado"), c.dim end
  local x = PS.footer({ { "b", L("Voltar") }, { "select", Favorites.is(p) and L("Desfavoritar") or L("Favoritar") },
    { { "l1", "r1" }, L("Rolar") } }, nil, { alpha = 0.7, line = { 1, 1, 1, 0.08 }, fg = PS.DIM2 })
  local f = PS.font("r", 12)
  local tw = f:getWidth(PS.tr(stxt))
  PS.color(scol)
  lg.circle("fill", 620 - tw - 11, PS.FOOT_Y + 17, 3.5, 12)
  PS.text(f, stxt, 620 - tw, PS.FOOT_Y + 17 - f:getHeight() / 2, PS.DIM2)
end

-- ---------------------------------------------------------------------------
-- acoes

--- dialogo "Opcoes": instalar/atualizar, desempenho, compatibilidade, remover, favorito
function PD.options(self)
  local p = self.port
  local btns = {}
  local label, enabled = self:primary()
  if enabled and (playable(p) or App.status(p) ~= "none") then
    btns[#btns + 1] = { label = PS.tr(label), sub = App.status(p) == "update" and string.format(PS.tr(L("Versão do catálogo: v%s")), p.version) or nil,
      fn = function() PD.run_primary(self) end }
  end
  if perf_ok(p) then
    btns[#btns + 1] = { label = L("Desempenho"), sub = L("Iniciar em modo desempenho, preferência e avaliação"),
      fn = function() require("ui.perf_ui").port_menu(p) end }
  end
  if self.compat then
    btns[#btns + 1] = { label = L("Compatibilidade"), sub = PS.tr(Compat.LABEL[self.compat.status]),
      fn = function() App.push("compat", { port = p }) end }
  end
  if not p.builtin then
    btns[#btns + 1] = { label = Favorites.is(p) and L("Desfavoritar") or L("Favoritar"),
      fn = function() self:action("select") end }
  end
  if App.status(p) ~= "none" and not p.builtin then
    btns[#btns + 1] = { label = L("Remover do console"), danger = true, fn = function() App.ask_uninstall(p) end }
  end
  btns[#btns + 1] = { label = L("Voltar") }
  App.show_dialog({ title = p.name, kind = "info", list = true, body = L("O que você quer fazer?"), buttons = btns })
end

--- segue o fluxo original do botao principal (instalar / atualizar / reinstalar)
function PD.run_primary(self)
  local s = st(self)
  s.primary_pending = true
  self.btn = 1
  self:action("a")
end

--- devolve true se tratou a acao (senao a tela segue o fluxo original)
function PD.action(self, act)
  local s = st(self)
  local p = self.port
  -- fluxo do botao principal em andamento (ex.: confirmacao do RG35XXH chama "a" de novo)
  if s.primary_pending and act == "a" then self.btn = 1; return false end
  if act == "b" then App.pop(); return true end
  if act == "select" then return false end
  if act == "x" then PD.options(self); return true end
  if act == "y" then
    if self.compat then App.push("compat", { port = p }) end
    return true
  end
  if act == "l1" or act == "r1" then
    local d = (act == "l1" and -1 or 1) * math.max(1, (s.desc_vis or 3) - 1)
    s.desc_scroll = U.clamp((s.desc_scroll or 0) + d, 0, s.desc_max or 0)
    return true
  end
  local list = focus_list(self)
  local idx = 1
  for i, f in ipairs(list) do if f == s.focus then idx = i end end
  if not list[idx] or list[idx] ~= s.focus then s.focus = "play"; idx = #list - 1 end
  if act == "left" then
    if s.focus == "opts" then s.focus = "play" end
    return true
  elseif act == "right" then
    if s.focus == "play" then s.focus = "opts" end
    return true
  elseif act == "up" then
    if s.focus ~= "perf" and list[1] == "perf" then s.focus = "perf"
    else s.desc_scroll = math.max(0, (s.desc_scroll or 0) - 1) end
    return true
  elseif act == "down" then
    if s.focus == "perf" then s.focus = "play"
    else s.desc_scroll = math.min(s.desc_max or 0, (s.desc_scroll or 0) + 1) end
    return true
  elseif act == "a" then
    if s.focus == "perf" then
      local Perf = require("core.perf")
      local on = not Perf.always(p.id)
      Perf.set_always(p.id, on)
      App.toast(on and L("Este port vai abrir sempre em modo desempenho.") or L("Modo desempenho automático desligado para este port."), "info")
      return true
    end
    if s.focus == "opts" then PD.options(self); return true end
    if playable(p) then App.launch_port(p); return true end
    -- nao instalado: fluxo original de instalacao
    s.primary_pending = true
    self.btn = 1
    return false
  end
  return true
end

return PD
