-- =============================================================================
--  Tema Premium: listas de ports (tela "store": Meus Ports, Favoritos, areas e
--  categorias) em grade de capas. Os dados, as abas e as acoes continuam os da
--  tela original; aqui so o desenho e o direcional da grade.
-- =============================================================================
local L = require("lib.i18n").L
local PS = require("ui.premium.style")
local PG = require("ui.premium.grid")

local PL = {}

local TABS_Y = 40
local GRID_Y = 40 + 44

local function metrics() return PG.metrics(20, GRID_Y, 600, PS.FOOT_Y - 6) end

function PL.update(self, dt)
  PG.update(self, #self.items, self.sel, metrics(), dt)
end

local function draw_tabs(self)
  local c = PS.c()
  local fa, fi = PS.font("b", 12, true), PS.font("m", 12, true)
  -- rolagem horizontal das abas (categorias podem passar da largura)
  local xs, x = {}, 0
  for i, t in ipairs(self.tabs) do
    local f = i == self.tab and fa or fi
    local w = f:getWidth(PS.tr(t.label)) + 28
    xs[i] = { x, w }
    x = x + w + 8
  end
  local view = 600
  local cur = xs[self.tab]
  self.ptab_scroll = self.ptab_scroll or 0
  if cur[1] - self.ptab_scroll < 0 then self.ptab_scroll = cur[1] end
  if cur[1] + cur[2] - self.ptab_scroll > view then self.ptab_scroll = cur[1] + cur[2] - view end
  local G = require("ui.gfx")
  G.clip(20, TABS_Y + 4, view, 36)
  for i, t in ipairs(self.tabs) do
    local on = i == self.tab
    local f = on and fa or fi
    local tx = 20 + xs[i][1] - self.ptab_scroll
    PS.rect(tx, TABS_Y + 8, xs[i][2], 28, on and c.accent or c.surf, 14)
    PS.text(f, t.label, tx + 14, TABS_Y + 22 - f:getHeight() / 2, on and c.bg or c.dim2)
  end
  G.unclip()
end

local function empty_text(self)
  if self.filter == "favs" then return L("Nenhum favorito aqui. Na Central, aperte SELECT sobre um port para marcar.") end
  if self.filter == "installed" then return L("Nenhum port instalado nesta área.") end
  if self.filter:sub(1, 4) == "cat:" then return L("Não existem ports disponíveis nesta categoria.") end
  return L("Nenhum port ainda. Eles aparecem aqui quando o catálogo for atualizado.")
end

function PL.draw(self)
  local c = PS.c()
  local right = string.format(PS.tr(L("%d de %d")), #self.items > 0 and self.sel or 0, #self.items)
  PS.header(self:title(), right)
  draw_tabs(self)
  if #self.items == 0 then
    local f = PS.font("r", 13)
    local ls = PS.lines(f, empty_text(self), 480, 3)
    for i, l in ipairs(ls) do PS.fit(f, l, 80, 200 + (i - 1) * 20, 480, c.dim, "center") end
  else
    PG.draw(self, metrics(), { items = self.items, sel = self.sel, focus = true, key = "pl" .. tostring(self.filter) .. tostring(self.section) })
  end
  local hints = { { "a", L("Detalhes") }, { "b", L("Voltar") }, { { "l1", "r1" }, L("Abas") }, { "select", L("Favorito") } }
  if self.filter == "installed" then
    hints[#hints + 1] = { "x", L("Desinstalar") }
  elseif not self.favs then
    local SX = require("ui.settings_extra")
    hints[#hints + 1] = { "x", SX.sort_short(require("core.prefs").get("list_sort") or "catalog") }
  end
  PS.footer(hints)
end

--- direcional da grade; devolve true se tratou a acao
function PL.action(self, act)
  if act ~= "up" and act ~= "down" and act ~= "left" and act ~= "right" then return false end
  local n = #self.items
  if n == 0 then return true end
  self.sel = PG.move(self.sel, n, act)
  return true
end

return PL
