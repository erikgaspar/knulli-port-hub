-- =============================================================================
--  Tema Premium: Ferramentas do Knulli em grade (tela "ptools")
--  Grade 3x2 de cartoes (arte de fundo escurecida + o numero principal) e dois
--  cartoes largos embaixo. As ferramentas sao as mesmas de ui/ktools_ui.lua
--  (que continua com a lista nos outros temas). So dados reais e leves.
--    direcional: navegar | B (acao "a"): abrir | A (acao "b"): voltar
-- =============================================================================
local L = require("lib.i18n").L
local C = require("config")
local U = require("lib.util")
local Catalog = require("core.catalog")
local Covers = require("core.covers")
local PS = require("ui.premium.style")

local S = {}
local lg = love.graphics

local GX, GY, GW, GH, GG = 20, 54, 192, 124, 12
local WY, WH = 480 - 34 - 12 - 40, 40

local GRID = { "space", "romtrans", "chd", "library", "backup", "monitor" }
local WIDE = { "zram", "bluetooth", "reports" }
local TITLE = {
  space = L("Liberar espaço"), romtrans = L("Traduzir jogos"), chd = L("Converter para CHD"),
  library = L("Organizar biblioteca"), backup = L("Backup dos saves"), monitor = L("Monitor"),
  bluetooth = L("Bluetooth"), reports = L("Relatórios"), zram = L("Memória extra"),
}
local ICON = { bluetooth = "bt", reports = "report", zram = "ram" }
-- cartoes com arte de fundo (arte larga dos ports do console)
local ART = { space = 1, romtrans = 2, chd = 3, backup = 4 }

function S:enter()
  local by_id = {}
  for _, e in ipairs(require("ui.ktools_ui").entries()) do by_id[e.id or ""] = e end
  self.grid, self.wide = {}, {}
  for _, id in ipairs(GRID) do if by_id[id] then self.grid[#self.grid + 1] = { id = id, e = by_id[id] } end end
  for _, id in ipairs(WIDE) do if by_id[id] then self.wide[#self.wide + 1] = { id = id, e = by_id[id] } end end
  self.sel = self.sel or 1
  self.temps = {}
  self.temp_t = -10
  self:load_info()
end

function S:resume() self:load_info() end

--- numeros dos cartoes (leituras leves, uma vez ao abrir/voltar)
function S:load_info()
  App.update_free_space()
  local info = {}
  local ok, n = pcall(function()
    local t = U.read_file(C.APP_DIR .. "/conf/romtrans.json")
    local d = t and require("lib.json").decode(t)
    local c = 0
    for _ in pairs(type(d) == "table" and type(d.items) == "table" and d.items or {}) do c = c + 1 end
    return c
  end)
  info.trans = ok and n or 0
  local okr, list = pcall(function() return require("core.h700reports").list() end)
  info.reports = okr and #list or nil
  self.info = info
  self:load_zram()
  -- arte: ports do console (abertos recentemente / instalados) e destaques
  local arts, seen = {}, {}
  local function add(p) if p and not p.builtin and not seen[p] then seen[p] = true; arts[#arts + 1] = p end end
  for id in (require("core.prefs").get("recent_ports") or ""):gmatch("[^,]+") do add(Catalog.by_id[id]) end
  for _, p in ipairs(Catalog.ports) do if App.status(p) ~= "none" then add(p) end end
  for _, p in ipairs(Catalog.ports) do if p.featured then add(p) end end
  info.arts = arts
  self.info = info
end

--- estado da memoria extra (leituras de /proc e /sys)
function S:load_zram()
  local okz, Z = pcall(require, "core.zram")
  if okz and Z.available() then
    local ok, st = pcall(Z.status)
    self.zram = ok and st or nil
  end
end

function S:update(dt)
  if (App.t or 0) - self.temp_t > 2 then
    self.temp_t = App.t or 0
    if self.zram then self:load_zram() end
    local okm, Mon = pcall(require, "core.monitor")
    local t = okm and Mon.cpu_temp and select(2, pcall(Mon.cpu_temp)) or nil
    self.temp = type(t) == "number" and t or nil
    self.temp_warn = okm and self.temp and Mon.level(self.temp) or nil
    if self.temp then
      self.temps[#self.temps + 1] = self.temp
      while #self.temps > 10 do table.remove(self.temps, 1) end
    end
  end
end

-- ---------------------------------------------------------------------------

local function value_of(self, id)
  local c = PS.c()
  local info = self.info or {}
  if id == "space" then
    local free, total = App.free, App.total
    if not free then return L("Espaço livre: desconhecido"), PS.font("m", 13), c.light end
    local low = total and total > 0 and free / total < 0.10
    return U.format_bytes(free) .. PS.tr(L(" livres")), PS.font("x", 18), low and c.warn or c.text
  elseif id == "romtrans" then
    local n = info.trans or 0
    if n > 0 then return string.format(PS.tr(L("%d com tradução PT-BR")), n), PS.font("m", 13), c.light end
    return L("Patches PT-BR"), PS.font("m", 13), c.light
  elseif id == "chd" then return L("Jogos de CD menores"), PS.font("m", 13), c.light
  elseif id == "library" then return L("Listas, imagens e vídeos"), PS.font("m", 13), c.dim2
  elseif id == "backup" then return L("Saves num arquivo só"), PS.font("m", 13), c.light
  elseif id == "monitor" then
    if self.temp then return string.format("%d °C", math.floor(self.temp + 0.5)), PS.font("x", 20), self.temp_warn and c.warn or c.text end
    return L("CPU, RAM e bateria"), PS.font("m", 13), c.dim2
  elseif id == "zram" then
    local z = self.zram
    if not z then return "", PS.font("r", 12), c.dim end
    if z.active then return string.format(PS.tr(L("Ligada  •  %s")), require("core.zram").mb(z.size)), PS.font("m", 12), c.accent end
    return L("Desligada"), PS.font("r", 12), c.dim
  elseif id == "bluetooth" then return L("Controles"), PS.font("r", 12), c.dim
  elseif id == "reports" then
    local n = info.reports
    if n then return string.format(PS.tr(n == 1 and L("%d avaliado") or L("%d avaliados")), n), PS.font("r", 12), c.dim end
    return "", PS.font("r", 12), c.dim
  end
  return "", PS.font("r", 12), c.dim
end

local function fan_covers(self, x, y, w, h)
  local arts = (self.info and self.info.arts) or {}
  local G = require("ui.gfx")
  G.clip(x, y, w, h)
  lg.push()
  lg.translate(x + w + 10, y + 14)
  lg.rotate(-8 * math.pi / 180)
  for i = 1, 3 do
    local p = arts[i] or Catalog.ports[i]
    local cx = -(4 - i) * (46 + 6)
    local img = p and Covers.get(p)
    if img then
      local iw, ih = img:getDimensions()
      local s = math.max(46 / iw, 69 / ih)
      lg.setColor(1, 1, 1, 0.55)
      -- (corte simples: a capa 3:4 fica um pouco mais larga que 46 px)
      lg.draw(img, cx + (46 - iw * s) / 2, 0, 0, s, s)
    else
      PS.rect(cx, 0, 46, 69, PS.c().surf2, 6, 0.8)
    end
  end
  lg.pop()
  G.unclip()
end

local function bars(self, x, y, w, h)
  local c = PS.c()
  local n = 10
  local g = 3
  local bw = (w - g * (n - 1)) / n
  for i = 1, n do
    local t = self.temps[#self.temps - n + i]
    local frac = t and U.clamp((t - 30) / 50, 0.12, 1) or 0.12
    local col = (t and t >= 65) and c.warn or c.accent
    PS.rect(x + (i - 1) * (bw + g), y + h - h * frac, bw, h * frac, col, 2, t and 0.5 or 0.15)
  end
end

local function draw_grid_card(self, i, it)
  local c = PS.c()
  local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
  local on = self.sel == i
  local k = PS.fk("pt" .. i, on)
  local x, y, w, h = PS.grow(GX + col * (GW + GG), GY + row * (GH + GG), GW, GH, k)
  PS.rect(x, y, w, h, c.surf, 14)
  local art = ART[it.id] and self.info and self.info.arts[ART[it.id]]
  local img = art and require("core.heroart").get(art)
  if img then
    PS.draw_cover_fit(img, x, y, w, h, 0.5, 0.4)
    PS.veil(x, y, w, h, it.id == "backup" and 0.7 or 0.66)
    PS.fillet(x, y, w, h, 14, c.bg)
  elseif it.id == "library" then
    fan_covers(self, x, y, w, h)
    PS.fillet(x, y, w, h, 14, c.bg)
  elseif it.id == "monitor" then
    bars(self, x + 14, y + h - 16 - 34, w - 28, 34)
  end
  if k > 0 then PS.focus(x, y, w, h, 14, k) end
  local tf = PS.font("b", 14)
  PS.fit(tf, TITLE[it.id] or it.e.text, x + 14, y + 12, w - 28, c.text)
  local v, vf, vc = value_of(self, it.id)
  if it.id == "monitor" then
    PS.fit(vf, v, x + 14, y + 12 + tf:getHeight() + 4, w - 28, vc)
  else
    PS.fit(vf, v, x + 14, y + h - 12 - vf:getHeight(), w - 28, vc)
  end
end

local function draw_wide(self, j, it)
  local c = PS.c()
  local i = #self.grid + j
  local on = self.sel == i
  local k = PS.fk("pt" .. i, on)
  local nw = math.max(1, #self.wide)
  local gap = nw >= 3 and GG or 10
  local w = (600 - gap * (nw - 1)) / nw
  -- 3 cartoes: mais altos, com o titulo em cima e o valor embaixo
  local tall = nw >= 3
  local wh = tall and 60 or WH
  local x, y, ww, hh = PS.grow(GX + (j - 1) * (w + gap), WY + WH - wh, w, wh, k)
  PS.rect(x, y, ww, hh, c.surf, 12)
  if k > 0 then PS.focus(x, y, ww, hh, 12, k) end
  PS.icon(ICON[it.id] or "gear", x + 14, y + hh / 2 - 9, 18, c.dim2)
  local f = PS.font("m", 13)
  local v, vf, vc = value_of(self, it.id)
  if tall then
    local th = f:getHeight() + 3 + vf:getHeight()
    local ty = y + hh / 2 - th / 2
    PS.fit(f, TITLE[it.id] or it.e.text, x + 42, ty, ww - 42 - 12, c.text)
    PS.fit(vf, v, x + 42, ty + f:getHeight() + 3, ww - 42 - 12, vc)
    return
  end
  local vw = vf:getWidth(PS.tr(v))
  PS.fit(f, TITLE[it.id] or it.e.text, x + 42, y + hh / 2 - f:getHeight() / 2, ww - 42 - 14 - vw - 10, c.text)
  PS.text(vf, v, x + ww - 14 - vw, y + hh / 2 - vf:getHeight() / 2, vc)
end

function S:draw()
  local c = PS.c()
  PS.header(L("Ferramentas"))
  if #self.grid + #self.wide == 0 then
    PS.fit(PS.font("r", 13), L("Nenhuma ferramenta disponível."), 20, 200, 600, c.dim, "center")
  end
  for i, it in ipairs(self.grid) do draw_grid_card(self, i, it) end
  for j, it in ipairs(self.wide) do draw_wide(self, j, it) end
  PS.footer({ { "a", L("Abrir") }, { "b", L("Voltar") } })
end

function S:action(act)
  if act == "b" then App.pop(); return end
  local ng, nw = #self.grid, #self.wide
  local n = ng + nw
  if n == 0 then return end
  local i = U.clamp(self.sel, 1, n)
  if i <= ng then
    local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
    if act == "left" and col > 0 then i = i - 1
    elseif act == "right" and col < 2 and i < ng then i = i + 1
    elseif act == "up" and row > 0 then i = i - 3
    elseif act == "down" then
      if i + 3 <= ng then i = i + 3
      elseif nw > 0 then
        if nw >= 3 then i = ng + math.min(col + 1, nw) else i = ng + (col < 2 and 1 or math.min(2, nw)) end
      end
    end
  else
    local j = i - ng
    if act == "left" and j > 1 then i = i - 1
    elseif act == "right" and j < nw then i = i + 1
    elseif act == "up" and ng > 0 then
      local last_row = math.floor((ng - 1) / 3)
      local col = nw >= 3 and math.min(j - 1, 2) or (j == 1 and 0 or 2)
      i = math.min(ng, last_row * 3 + col + 1)
    end
  end
  self.sel = i
  if act == "a" then
    local it = i <= ng and self.grid[i] or self.wide[i - ng]
    if it and it.e.on_a then it.e.on_a() end
  end
end

return S
