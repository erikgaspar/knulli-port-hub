-- =============================================================================
--  Knulli: Monitor do console (core/monitor.lua)
--  Ao vivo, 1 leitura por segundo e so enquanto a tela esta aberta: temperatura
--  da CPU/GPU (amarelo >= 60 °C, vermelho >= 70 °C: throttling passivo do H700),
--  grafico dos ultimos 60 s, frequencia/governor e uso da CPU, GPU, RAM,
--  swap/zram, bateria, espaco livre do cartao e tempo ligado.
--  Abrir: require("ui.screens.monitor").open()  (registra a tela se preciso)
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local T = require("ui.theme")
local G = require("ui.gfx")
local U = require("lib.util")
local Mon = require("core.monitor")

local S = {}
S.fixed_text = true
local INTERVAL = 1

function S.open()
  App.screens.monitor = App.screens.monitor or S
  App.push("monitor")
end

function S:enter()
  self.t = 0
  self.paused = false
  Mon.sample()                    -- 1a leitura do /proc/stat (o uso sai na 2a)
  self.s = Mon.sample()
end

function S:update(dt)
  if self.paused then return end
  self.t = self.t + dt
  if self.t >= INTERVAL then
    self.t = self.t - INTERVAL
    if self.t > INTERVAL then self.t = 0 end
    self.s = Mon.sample()
  end
end

local function dec(s) return I18N.lang == "en" and s or (s:gsub("%.", ",")) end
local function temp_txt(c) return c and dec(string.format("%.1f °C", c)) or "—" end
local function temp_col(c)
  local l = Mon.level(c)
  if l == "hot" then return T.c.red elseif l == "warm" then return T.c.yellow end
  return T.c.green
end
local function mhz(khz) return khz and string.format("%d MHz", math.floor(khz / 1000 + 0.5)) or "—" end
local function kb(n) return n and U.format_bytes(n * 1024) or "—" end

local function uptime_txt(sec)
  if not sec then return "—" end
  sec = math.floor(sec)
  local d = math.floor(sec / 86400)
  local h = math.floor((sec % 86400) / 3600)
  local m = math.floor((sec % 3600) / 60)
  if d > 0 then return string.format("%dd %02dh%02dmin", d, h, m) end
  if h > 0 then return string.format("%dh%02dmin", h, m) end
  return string.format("%dmin %02ds", m, sec % 60)
end

local STATUS = { Charging = L("Carregando"), Discharging = L("Descarregando"), Full = L("Completa"),
  ["Not charging"] = L("Não está carregando"), Unknown = L("Desconhecido") }

--- barra horizontal com fracao 0..1
local function bar(x, y, w, h, frac, c)
  G.rect(x, y, w, h, T.c.bg3, h / 2)
  frac = math.max(0, math.min(1, frac or 0))
  if frac > 0 then G.rect(x, y, math.max(h, w * frac), h, c, h / 2) end
end

function S:draw_temp(x, y, w, h)
  local s = self.s
  G.panel(x, y, w, h, { bg = T.c.bg1 })
  G.text(T.f.pix8, L("TEMPERATURA"), x + 12, y + 12, T.c.accent2)
  local c = s.cpu_c
  local col = temp_col(c)
  G.text(T.f.small, "CPU", x + 12, y + 30, T.c.faint)
  G.text(T.f.pix24, temp_txt(c), x + 12, y + 46, col)
  local lvl = Mon.level(c)
  local note = lvl == "hot" and L("Muito quente: o sistema reduz a velocidade") or (lvl == "warm" and L("Quente: pode reduzir a velocidade") or L("Normal"))
  G.text_fit(T.f.small, note, x + 12, y + 80, w - 24, lvl and col or T.c.dim)
  -- GPU e demais zonas
  local yy = y + 100
  if s.gpu_c then
    G.text(T.f.small, "GPU", x + 12, yy, T.c.faint)
    G.text(T.f.bodyb, temp_txt(s.gpu_c), x + 60, yy - 2, temp_col(s.gpu_c))
    yy = yy + 20
  end
  local extra = {}
  for _, z in ipairs(s.zones or {}) do
    local t = z.type:lower()
    if not t:match("^cpu") and not t:match("^gpu") then
      local name = t:gsub("_thermal_zone", ""):gsub("%-battery$", " bat"):upper()
      extra[#extra + 1] = name .. " " .. dec(string.format("%.0f°", z.c))
    end
  end
  if #extra > 0 then G.text_fit(T.f.small, table.concat(extra, "   "), x + 12, yy, w - 24, T.c.dim) end
  -- grafico dos ultimos 60 s
  self:draw_graph(x + 12, y + h - 118, w - 24, 104)
end

function S:draw_graph(x, y, w, h)
  G.rect(x, y, w, h, T.c.bg0, 4)
  local hist = Mon.hist
  local lo, hi = 35, 80
  for _, v in ipairs(hist) do lo = math.min(lo, math.floor(v / 5) * 5); hi = math.max(hi, math.ceil(v / 5) * 5) end
  local function py(v) return y + h - 4 - (v - lo) / (hi - lo) * (h - 8) end
  -- linhas de 60 e 70 °C
  for _, ref in ipairs({ { Mon.WARN_C, T.c.yellow }, { Mon.HOT_C, T.c.red } }) do
    if ref[1] > lo and ref[1] < hi then
      G.rect(x + 2, py(ref[1]), w - 4, 1, ref[2], 0, 0.45)
      G.text(T.f.small, ref[1] .. "°", x + w - 26, py(ref[1]) - 14, ref[2])
    end
  end
  if #hist >= 2 then
    local pts = {}
    local step = (w - 8) / (Mon.HIST - 1)
    local x0 = x + 4 + (Mon.HIST - #hist) * step
    for i, v in ipairs(hist) do
      pts[#pts + 1] = x0 + (i - 1) * step
      pts[#pts + 1] = py(v)
    end
    G.color(temp_col(hist[#hist]))
    love.graphics.setLineWidth(2)
    love.graphics.line(pts)
    love.graphics.setLineWidth(1)
  end
  G.text(T.f.small, L("últimos 60 s"), x + 6, y + 3, T.c.faint)
end

function S:draw_info(x, y, w, h)
  local s = self.s
  G.panel(x, y, w, h, { bg = T.c.bg1 })
  local yy = y + 10
  local kx, vx = x + 12, x + 96
  local vw = w - (vx - x) - 12
  local function row(k, v, c)
    G.text_fit(T.f.small, k, kx, yy + 2, vx - kx - 6, T.c.faint)
    G.text_fit(T.f.bodyb, v or "—", vx, yy, vw, c or T.c.text)
    yy = yy + 20
  end
  -- CPU
  local f = mhz(s.freq)
  if s.freq_max and s.freq_hw and s.freq_max < s.freq_hw then f = f .. "  (" .. L("máx. ") .. mhz(s.freq_max) .. ")" end
  row(L("CPU"), f .. (s.gov and ("  •  " .. s.gov) or ""))
  local pct = s.cpu_pct
  G.text_fit(T.f.small, L("Uso"), kx, yy + 2, vx - kx - 6, T.c.faint)
  bar(vx, yy + 4, vw - 56, 10, (pct or 0) / 100, pct and pct >= 85 and T.c.orange or T.c.accent2)
  G.text(T.f.bodyb, pct and string.format("%d%%", math.floor(pct + 0.5)) or "…", x + w - 60, yy, T.c.text, "right", 48)
  yy = yy + 20
  if s.gpu_freq then row(L("GPU"), string.format("%d MHz", math.floor(s.gpu_freq / 1e6 + 0.5)) .. (s.gpu_gov and ("  •  " .. s.gpu_gov) or "")) end
  -- memoria
  yy = yy + 4
  if s.mem_total and s.mem_avail then
    local used = s.mem_total - s.mem_avail
    local fr = used / s.mem_total
    G.text_fit(T.f.small, L("RAM"), kx, yy + 2, vx - kx - 6, T.c.faint)
    bar(vx, yy + 4, vw - 56, 10, fr, fr >= 0.9 and T.c.red or (fr >= 0.75 and T.c.yellow or T.c.green))
    G.text(T.f.bodyb, string.format("%d%%", math.floor(fr * 100 + 0.5)), x + w - 60, yy, T.c.text, "right", 48)
    yy = yy + 18
    G.text_fit(T.f.small, kb(used) .. L(" em uso de ") .. kb(s.mem_total), vx, yy, vw, T.c.dim)
    yy = yy + 18
  end
  local sw
  if s.swap_total and s.swap_total > 0 then sw = kb(s.swap_used) .. " / " .. kb(s.swap_total) else sw = L("sem swap") end
  if s.zram_orig and s.zram_orig > 0 then
    sw = sw .. "  •  zram " .. U.format_bytes(s.zram_orig) .. " → " .. U.format_bytes(s.zram_compr)
  end
  row(L("Swap"), sw, (s.swap_total or 0) > 0 and T.c.text or T.c.dim)
  -- bateria
  yy = yy + 4
  if s.bat_pct then
    local b = string.format("%d%%", s.bat_pct) .. "  •  " .. I18N.tr(STATUS[s.bat_status or "Unknown"] or s.bat_status or "")
    local bc = s.bat_pct >= 40 and T.c.green or (s.bat_pct >= 15 and T.c.yellow or T.c.red)
    row(L("Bateria"), b, bc)
    local parts = {}
    if s.bat_v then parts[#parts + 1] = dec(string.format("%.2f V", s.bat_v)) end
    if s.bat_ma then parts[#parts + 1] = string.format("%d mA", math.floor(s.bat_ma + 0.5)) end
    if s.bat_w then parts[#parts + 1] = dec(string.format("%.2f W", s.bat_w)) end
    if s.bat_c then parts[#parts + 1] = dec(string.format("%.1f °C", s.bat_c)) end
    if #parts > 0 then G.text_fit(T.f.small, table.concat(parts, "  •  "), vx, yy - 2, vw, T.c.dim); yy = yy + 16 end
  else
    row(L("Bateria"), L("não informado"), T.c.faint)
  end
  -- cartao
  yy = yy + 4
  if s.disk then
    local fr = s.disk.total and s.disk.total > 0 and (1 - s.disk.free / s.disk.total) or 0
    local low = s.disk.free < 1024 * 1024 * 1024
    G.text_fit(T.f.small, L("Cartão"), kx, yy + 2, vx - kx - 6, T.c.faint)
    bar(vx, yy + 4, vw - 56, 10, fr, low and T.c.red or (fr >= 0.9 and T.c.yellow or T.c.accent2))
    G.text(T.f.bodyb, string.format("%d%%", math.floor(fr * 100 + 0.5)), x + w - 60, yy, T.c.text, "right", 48)
    yy = yy + 18
    G.text_fit(T.f.small, U.format_bytes(s.disk.free) .. L(" livres de ") .. U.format_bytes(s.disk.total) .. "  (" .. Mon.DISK .. ")",
      vx, yy, vw, low and T.c.orange or T.c.dim)
    yy = yy + 18
  else
    row(L("Cartão"), L("não informado"), T.c.faint)
  end
  yy = yy + 4
  row(L("Ligado há"), uptime_txt(s.uptime))
end

function S:draw()
  G.header(L("Monitor do console"), self.paused and L("PAUSADO") or L("ao vivo"))
  local lw = 236
  self:draw_temp(12, 48, lw, 388)
  self:draw_info(12 + lw + 10, 48, T.W - lw - 34, 388)
  G.hints({ { "y", self.paused and L("Continuar") or L("Pausar") }, { "b", L("Voltar") } })
end

function S:action(act)
  if act == "b" then App.pop()
  elseif act == "y" then self.paused = not self.paused end
end

return S
