-- =============================================================================
--  Knulli: monitor do console (leitura leve de /sys e /proc, sem processos)
--   * temperatura: /sys/class/thermal (no H700: cpu_thermal_zone, gpu_thermal_zone,
--     ve_thermal_zone, ddr_thermal_zone; trip points 60/70/115 °C = throttling
--     passivo em 60 e 70)
--   * CPU: cpufreq do cpu0 (frequencia/governor) + uso a partir de /proc/stat
--   * GPU: /sys/class/devfreq/gpu/cur_freq (se houver)
--   * RAM/swap/zram: /proc/meminfo + /sys/block/zram*/mm_stat
--   * bateria: /sys/class/power_supply (capacity, status, voltage/current/power)
--   * cartao: df de /userdata (a cada 10 s, unico comando externo)
--   * uptime: /proc/uptime
--  M.sample() le tudo (a tela chama ~1x/s). M.tick(dt) e o aviso de
--  temperatura: chame do love.update do main (le UM arquivo a cada 5 s).
-- =============================================================================
local U = require("lib.util")

local M = {}

M.WARN_C = 60          -- amarelo (1o trip point passivo do H700)
M.HOT_C = 70           -- vermelho + aviso (2o trip point)
M.HIST = 60            -- segundos de historico da temperatura
M.DISK = "/userdata"

local function rd(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end
local function num(p) return tonumber((rd(p) or ""):match("%-?%d+")) end
local function str(p) local s = rd(p); return s and U.trim(s) or nil end

-- ---------------------------------------------------------------------------
-- descoberta (uma vez)

local ZONES                  -- { cpu = path, gpu = path, list = {{type, path}} }
local function zones()
  if ZONES then return ZONES end
  ZONES = { list = {} }
  for i = 0, 15 do
    local base = "/sys/class/thermal/thermal_zone" .. i
    local ty = str(base .. "/type")
    if not ty then break end
    ZONES.list[#ZONES.list + 1] = { type = ty, path = base .. "/temp" }
    local l = ty:lower()
    if not ZONES.cpu and (l:match("cpu") or l:match("soc")) then ZONES.cpu = base .. "/temp" end
    if not ZONES.gpu and l:match("gpu") then ZONES.gpu = base .. "/temp" end
  end
  if not ZONES.cpu and ZONES.list[1] then ZONES.cpu = ZONES.list[1].path end
  -- trip points da zona da CPU (passivos), para mostrar
  if ZONES.cpu then
    local dir = ZONES.cpu:gsub("/temp$", "")
    ZONES.trips = {}
    for i = 0, 5 do
      local t = num(dir .. "/trip_point_" .. i .. "_temp")
      if not t then break end
      ZONES.trips[#ZONES.trips + 1] = { c = t / 1000, type = str(dir .. "/trip_point_" .. i .. "_type") }
    end
  end
  return ZONES
end

local BAT
local function battery_dir()
  if BAT ~= nil then return BAT or nil end
  BAT = false
  local out = U.capture("ls -1 /sys/class/power_supply 2>/dev/null") or ""
  for n in out:gmatch("[^\n]+") do
    local d = "/sys/class/power_supply/" .. n
    if (str(d .. "/type") or ""):lower() == "battery" and rd(d .. "/capacity") then BAT = d; break end
  end
  return BAT or nil
end

local ZRAM
local function zram_list()
  if ZRAM then return ZRAM end
  ZRAM = {}
  for i = 0, 7 do
    if rd("/sys/block/zram" .. i .. "/mm_stat") then ZRAM[#ZRAM + 1] = "/sys/block/zram" .. i end
  end
  return ZRAM
end

-- ---------------------------------------------------------------------------
-- leituras

--- temperatura da CPU em °C (um arquivo); nil se nao houver zona
function M.cpu_temp()
  local z = zones()
  local v = z.cpu and num(z.cpu)
  if not v then return nil end
  return v > 1000 and v / 1000 or v        -- milli-°C (quase sempre) ou °C
end

local prev_cpu
local function cpu_usage()
  local s = rd("/proc/stat")
  if not s then return nil end
  local l = s:match("^cpu%s+([^\n]+)")
  if not l then return nil end
  local v = {}
  for n in l:gmatch("%d+") do v[#v + 1] = tonumber(n) end
  local idle = (v[4] or 0) + (v[5] or 0)
  local total = 0
  for i = 1, math.min(#v, 8) do total = total + v[i] end   -- sem guest (ja contado em user)
  local pct
  if prev_cpu and total > prev_cpu.total then
    pct = 100 * (1 - (idle - prev_cpu.idle) / (total - prev_cpu.total))
    pct = math.max(0, math.min(100, pct))
  end
  prev_cpu = { idle = idle, total = total }
  return pct
end

local function meminfo()
  local s = rd("/proc/meminfo") or ""
  local function k(name) return tonumber(s:match(name .. ":%s*(%d+)")) end
  return { total = k("MemTotal"), avail = k("MemAvailable"), swap_total = k("SwapTotal"), swap_free = k("SwapFree") }
end

local disk_t, disk_cache = -100, nil
local function disk()
  local now = love and love.timer and love.timer.getTime() or os.time()
  if now - disk_t >= 10 then
    disk_t = now
    local free, total = U.free_space(M.DISK)
    disk_cache = free and { free = free, total = total } or nil
  end
  return disk_cache
end

M.hist = {}

--- leitura completa (para a tela; ~1x/s)
function M.sample()
  local z = zones()
  local s = {}
  s.cpu_c = M.cpu_temp()
  if z.gpu then local g = num(z.gpu); s.gpu_c = g and (g > 1000 and g / 1000 or g) end
  s.zones = {}
  for _, zz in ipairs(z.list) do
    local v = num(zz.path)
    if v then s.zones[#s.zones + 1] = { type = zz.type, c = v > 1000 and v / 1000 or v } end
  end
  s.trips = z.trips
  -- CPU
  local cf = "/sys/devices/system/cpu/cpu0/cpufreq/"
  s.freq = num(cf .. "scaling_cur_freq")
  s.freq_max = num(cf .. "scaling_max_freq")
  s.freq_hw = num(cf .. "cpuinfo_max_freq")
  s.gov = str(cf .. "scaling_governor")
  s.online = str("/sys/devices/system/cpu/online")
  s.cpu_pct = cpu_usage()
  s.gpu_freq = num("/sys/class/devfreq/gpu/cur_freq")
  s.gpu_gov = str("/sys/class/devfreq/gpu/governor")
  -- memoria
  local m = meminfo()
  s.mem_total, s.mem_avail = m.total, m.avail
  s.swap_total, s.swap_used = m.swap_total, (m.swap_total and m.swap_free) and (m.swap_total - m.swap_free) or nil
  local zr = zram_list()
  if #zr > 0 then
    local orig, compr = 0, 0
    for _, d in ipairs(zr) do
      local a, b = (rd(d .. "/mm_stat") or ""):match("(%d+)%s+(%d+)")
      orig, compr = orig + (tonumber(a) or 0), compr + (tonumber(b) or 0)
    end
    s.zram_orig, s.zram_compr = orig, compr
  end
  -- bateria
  local bd = battery_dir()
  if bd then
    s.bat_pct = num(bd .. "/capacity")
    s.bat_status = str(bd .. "/status")
    local uv = num(bd .. "/voltage_now")
    s.bat_v = uv and uv / 1e6
    local ua = num(bd .. "/current_now")
    local uw = num(bd .. "/power_now")
    s.bat_ma = ua and ua / 1000
    if uw then s.bat_w = math.abs(uw) / 1e6 elseif ua and uv then s.bat_w = math.abs(ua * uv) / 1e12 end
    local bt = num(bd .. "/temp")
    s.bat_c = bt and bt / 10
  end
  s.disk = disk()
  s.uptime = tonumber((rd("/proc/uptime") or ""):match("^([%d%.]+)"))
  -- historico (um ponto por chamada)
  if s.cpu_c then
    M.hist[#M.hist + 1] = s.cpu_c
    while #M.hist > M.HIST do table.remove(M.hist, 1) end
  end
  return s
end

--- cor da temperatura (nil = normal)
function M.level(c)
  if not c then return nil end
  if c >= M.HOT_C then return "hot" end
  if c >= M.WARN_C then return "warm" end
  return nil
end

-- ---------------------------------------------------------------------------
-- aviso de temperatura enquanto o hub esta aberto

local tick_t, warned, armed = 0, -1e9, true
M.TICK_EVERY = 5
M.WARN_AGAIN = 120     -- no maximo um aviso a cada 2 min

--- chame do love.update: require("core.monitor").tick(dt)
function M.tick(dt)
  tick_t = tick_t + (dt or 0)
  if tick_t < M.TICK_EVERY then return end
  tick_t = 0
  local c = M.cpu_temp()
  if not c then return end
  if c < M.HOT_C - 5 then armed = true; return end       -- histerese: rearma abaixo de 65 °C
  if c >= M.HOT_C and armed then
    local now = love and love.timer and love.timer.getTime() or os.time()
    if now - warned >= M.WARN_AGAIN then
      warned = now
      armed = false
      local L = require("lib.i18n").L
      if App and App.toast then
        App.toast(string.format(L("Console quente: CPU a %d °C. O sistema reduz a velocidade para esfriar."), math.floor(c + 0.5)), "warn")
      end
    end
  end
end

return M
