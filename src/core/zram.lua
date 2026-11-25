-- =============================================================================
--  Knulli Port Hub: memoria extra (zram) do Knulli
--  Servico do proprio Knulli: /usr/share/knulli/services/zramswap (modprobe
--  zram, disksize = metade da RAM, mkswap, swapon prio 1000). Ligar/desligar
--  de forma persistente = knulli-services enable|disable zramswap (grava
--  system.services no knulli.conf) + start|stop.
--
--  ATENCAO (bug do Knulli): o script le `free -b | grep "^Mem:"`; com o sistema
--  em portugues o free escreve "Mem.:" -> disksize 0 -> falha. No boot funciona
--  porque o S99userservices usa LC_ALL=C. Por isso TODO comando aqui roda com
--  LC_ALL=C, e o resultado e conferido por /proc/swaps (nao pelo codigo de saida).
--
--  Ports que fecharam por falta de memoria (codigo 137 / "Killed" / dmesg
--  "Killed process", detectado pelo launcher em conf/.port_exit): Prefs
--  "oom_ports" (ids separados por virgula). Perguntar antes de abrir port
--  pesado: Prefs "zram_ask" ("0" = nao perguntar mais). Ligar junto com o modo
--  desempenho: arquivo conf/perf_zram_off desliga (padrao: liga), lido pelo
--  bin/perf_run.sh.
-- =============================================================================
local C = require("config")
local U = require("lib.util")
local Prefs = require("core.prefs")

local M = {}

M.SERVICE = "/usr/share/knulli/services/zramswap"
M.CONF = "/userdata/system/knulli.conf"
M.PERF_OFF = C.APP_DIR .. "/conf/perf_zram_off"
M.EXIT_FILE = C.APP_DIR .. "/conf/.port_exit"

--- so no Knulli e com o servico do sistema presente
function M.available()
  return (C.KNULLI and U.exists(M.SERVICE)) and true or false
end

local function meminfo()
  local t = {}
  for k, v in (U.read_file("/proc/meminfo") or ""):gmatch("(%w+):%s+(%d+)") do t[k] = tonumber(v) * 1024 end
  return t
end

--- zramswap em system.services do knulli.conf (liga sozinho no boot)?
function M.enabled()
  local s = U.read_file(M.CONF) or ""
  for line in s:gmatch("[^\n]+") do
    local v = line:match("^%s*system%.services%s*=%s*(.-)%s*$")
    if v then
      for w in v:gmatch("%S+") do if w == "zramswap" then return true end end
      return false
    end
  end
  return false
end

--- estado atual (leituras leves de /proc e /sys)
--- -> { active, enabled, size, used, orig, compr, mem_used, ram_total, ram_free }  (bytes)
function M.status()
  local st = { active = false, enabled = M.enabled() }
  for line in (U.read_file("/proc/swaps") or ""):gmatch("[^\n]+") do
    local dev, size, used = line:match("^(%S*zram%d+)%s+%S+%s+(%d+)%s+(%d+)")
    if dev then
      st.active = true
      st.size = (st.size or 0) + tonumber(size) * 1024
      st.used = (st.used or 0) + tonumber(used) * 1024
    end
  end
  -- mm_stat: orig_data_size compr_data_size mem_used_total ...
  local mm = U.read_file("/sys/block/zram0/mm_stat")
  if st.active and mm then
    local o, c, u = mm:match("(%d+)%s+(%d+)%s+(%d+)")
    st.orig, st.compr, st.mem_used = tonumber(o), tonumber(c), tonumber(u)
  end
  local mi = meminfo()
  st.ram_total = mi.MemTotal
  st.ram_free = mi.MemAvailable or mi.MemFree
  return st
end

--- comando de shell para ligar/desligar (persistente; persist=false so agora)
function M.command(on, persist)
  local svc = "LC_ALL=C LANG=C /usr/bin/knulli-services "
  if on then
    return (persist ~= false and (svc .. "enable zramswap; ") or "")
      .. "grep -q zram /proc/swaps || " .. svc .. "start zramswap; "
      .. "grep -q zram /proc/swaps && echo ZRAM_ON || echo ZRAM_OFF"
  end
  return (persist ~= false and (svc .. "disable zramswap; ") or "")
    .. "if grep -q zram /proc/swaps; then " .. svc .. "stop zramswap; fi; "
    .. "grep -q zram /proc/swaps && echo ZRAM_ON || echo ZRAM_OFF"
end

--- liga/desliga em segundo plano; on_done(ok, status)
--- (desligar pode demorar: o swapoff traz de volta para a RAM o que estava no zram)
function M.set(on, on_done, persist)
  local function finish(res)
    local st = M.status()
    local ok = st.active == (on and true or false)
    if not ok then U.log("zram:", on and "ligar" or "desligar", "falhou:", res and res[1] and res[1].out or "?") end
    if on_done then on_done(ok, st) end
  end
  local okj = pcall(function()
    require("core.shjob").start({ M.command(on, persist) .. " 2>&1" }, finish)
  end)
  if not okj then
    os.execute(M.command(on, persist) .. " >/dev/null 2>&1")
    finish(nil)
  end
end

-- ---------------------------------------------------------------------------
-- ligar junto com o modo desempenho (padrao: sim)
-- ---------------------------------------------------------------------------
function M.with_perf() return not U.exists(M.PERF_OFF) end

function M.set_with_perf(on)
  if on then os.remove(M.PERF_OFF)
  else
    os.execute("mkdir -p " .. U.shq(C.APP_DIR .. "/conf") .. " 2>/dev/null")
    U.write_file(M.PERF_OFF, "1\n")
  end
end

-- ---------------------------------------------------------------------------
-- ports que fecharam por falta de memoria
-- ---------------------------------------------------------------------------
local function sid(id) return (tostring(id or ""):gsub("[^%w_%-]", "")) end

local function oom_set()
  local s = {}
  for id in (Prefs.get("oom_ports") or ""):gmatch("[^,]+") do s[id] = true end
  return s
end

function M.oom(id) return oom_set()[sid(id)] == true end

function M.set_oom(id, on)
  local k = sid(id)
  if k == "" then return end
  local s = oom_set()
  s[k] = on and true or nil
  local list = {}
  for x in pairs(s) do list[#list + 1] = x end
  table.sort(list)
  Prefs.set("oom_ports", #list > 0 and table.concat(list, ",") or nil)
end

--- le (e apaga) conf/.port_exit gravado pelo launcher: "id|codigo|oom 0/1"
--- marca o port se fechou por falta de memoria -> { id, rc, oom } ou nil
function M.take_exit(id)
  local raw = U.read_file(M.EXIT_FILE)
  if not raw then return nil end
  os.remove(M.EXIT_FILE)
  local eid, rc, oom = raw:match("^([%w_%-]*)|(%d*)|([01])")
  if not eid or eid == "" then return nil end
  if id and sid(id) ~= eid then return nil end
  local r = { id = eid, rc = tonumber(rc), oom = oom == "1" or tonumber(rc) == 137 }
  if r.oom then
    M.set_oom(eid, true)
    U.log("port fechou por falta de memoria:", eid, "codigo", rc)
  end
  return r
end

-- ---------------------------------------------------------------------------
-- perguntar antes de abrir port pesado
-- ---------------------------------------------------------------------------
function M.ask_enabled() return Prefs.get("zram_ask") ~= "0" end
function M.set_ask_enabled(on) Prefs.set("zram_ask", on and nil or "0") end

--- port marcado como pesado no catalogo?
function M.heavy(p)
  local hs = p and p.h700 and p.h700.status
  return hs == "pesado" or hs == "nao_funciona"
end

-- ---------------------------------------------------------------------------
-- textos
-- ---------------------------------------------------------------------------
local function mb(n)
  if not n then return "?" end
  return string.format("%d MB", math.floor(n / 1048576 + 0.5))
end
M.mb = mb

return M
