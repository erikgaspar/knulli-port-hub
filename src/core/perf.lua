-- =============================================================================
--  Knulli Port Hub: modo desempenho por port (RG35XXH / H700)
--  O jogo roda por bin/perf_run.sh (chamado pelo launcher quando .run_port
--  traz "script|id|perf"), que grava o resumo da sessao em
--  <APP_DIR>/conf/perf/<id>.json:
--    { id, script, start, end, start_iso, end_iso, seconds, minutes,
--      temp_max_c, temp_avg_c, samples, exit_code }
--  Preferencia "sempre em modo desempenho" por port: Prefs "perf_always" (ids
--  separados por virgula). Ultimo port aberto pelo hub: Prefs "last_port_launch"
--  ("id|os.time|perf 0/1"), usado pelo "Como rodou?" ao voltar do jogo.
-- =============================================================================
local C = require("config")
local U = require("lib.util")
local json = require("lib.json")
local Prefs = require("core.prefs")
local I18N = require("lib.i18n")

local M = {}

M.SCRIPT = C.APP_DIR .. "/bin/perf_run.sh"
M.DIR = C.APP_DIR .. "/conf/perf"

--- id seguro para nome de arquivo (mesmo filtro do perf_run.sh e do launcher)
function M.safe_id(id) return (tostring(id or ""):gsub("[^%w_%-]", "")) end

--- modo desempenho disponivel? (so no Knulli e com o script presente)
function M.available()
  return C.KNULLI and U.exists(M.SCRIPT) or false
end

--- ultimo resumo de desempenho do port (tabela) ou nil
function M.last(id)
  local sid = M.safe_id(id)
  if sid == "" then return nil end
  local t = U.read_file(M.DIR .. "/" .. sid .. ".json")
  if not t then return nil end
  local ok, d = pcall(json.decode, t)
  if not ok or type(d) ~= "table" then return nil end
  local function num(v) v = tonumber(v); return v end
  return {
    id = sid,
    start = num(d.start), ["end"] = num(d["end"]),
    start_iso = type(d.start_iso) == "string" and d.start_iso or "",
    minutes = num(d.minutes), seconds = num(d.seconds),
    temp_max = num(d.temp_max_c), temp_avg = num(d.temp_avg_c),
    exit_code = num(d.exit_code),
  }
end

-- ---------------------------------------------------------------------------
-- "sempre em modo desempenho" (por port)
-- ---------------------------------------------------------------------------
local function always_set()
  local s = {}
  for id in (Prefs.get("perf_always") or ""):gmatch("[^,]+") do s[id] = true end
  return s
end

function M.always(id)
  if not C.KNULLI then return false end
  return always_set()[M.safe_id(id)] == true
end

function M.set_always(id, on)
  local sid = M.safe_id(id)
  if sid == "" then return end
  local s = always_set()
  s[sid] = on and true or nil
  local list = {}
  for k in pairs(s) do list[#list + 1] = k end
  table.sort(list)
  Prefs.set("perf_always", #list > 0 and table.concat(list, ",") or nil)
end

-- ---------------------------------------------------------------------------
-- ultima sessao iniciada pelo hub (para o "Como rodou?")
-- ---------------------------------------------------------------------------
function M.mark_launch(id, perf)
  Prefs.set("last_port_launch", M.safe_id(id) .. "|" .. os.time() .. "|" .. (perf and "1" or "0"))
end

--- dados da sessao que acabou de terminar (e limpa o registro: uma vez so)
--- -> { id, minutes, perf = bool, summary = M.last(...) se for desta sessao } ou nil
function M.take_session(id)
  local raw = Prefs.get("last_port_launch")
  if not raw then return nil end
  Prefs.set("last_port_launch", nil)
  local sid, t0, pf = raw:match("^([%w_%-]+)|(%d+)|([01])$")
  if not sid or sid ~= M.safe_id(id) then return nil end
  t0 = tonumber(t0)
  local s = { id = sid, perf = pf == "1", started = t0 }
  local now = os.time()
  if t0 and now >= t0 then s.minutes = math.floor((now - t0) / 6 + 0.5) / 10 end
  if s.perf then
    local last = M.last(sid)
    -- so vale o resumo gravado depois deste inicio (nao um antigo)
    if last and last.start and t0 and last.start >= t0 - 5 then
      s.summary = last
      if last.minutes then s.minutes = last.minutes end
    end
  end
  -- ultima sessao de jogo (cartao CONTINUAR do tema Premium): "id|inicio|minutos|temp. max."
  Prefs.set("last_play", sid .. "|" .. (t0 or now) .. "|" .. (s.minutes and string.format("%.1f", s.minutes) or "")
    .. "|" .. ((s.summary and s.summary.temp_max) and string.format("%.1f", s.summary.temp_max) or ""))
  return s
end

--- ultima sessao registrada do port: { start, minutes, temp_max } ou nil
function M.last_play(id)
  local raw = Prefs.get("last_play")
  if not raw then return nil end
  local sid, t0, mins, tmax = raw:match("^([%w_%-]+)|(%d+)|([%d%.]*)|([%d%.]*)$")
  if not sid or sid ~= M.safe_id(id) then return nil end
  return { start = tonumber(t0), minutes = tonumber(mins), temp_max = tonumber(tmax) }
end

-- ---------------------------------------------------------------------------
-- textos
-- ---------------------------------------------------------------------------
local function dec(v, n)
  local s = string.format("%." .. (n or 1) .. "f", v)
  if I18N.lang == "pt-BR" then s = s:gsub("%.", ",") end
  return s
end
M.dec = dec

--- "12 min  •  máx. 58,3 °C  •  média 52,1 °C" (partes que existirem)
function M.summary_text(s)
  if not s then return "" end
  local parts = {}
  if s.minutes then
    parts[#parts + 1] = (s.minutes >= 10 and string.format("%d", math.floor(s.minutes + 0.5)) or dec(s.minutes)) .. " min"
  end
  if s.temp_max and s.temp_max > 0 then parts[#parts + 1] = I18N.tr(I18N.L("máx. ")) .. dec(s.temp_max) .. " °C" end
  if s.temp_avg and s.temp_avg > 0 then parts[#parts + 1] = I18N.tr(I18N.L("média ")) .. dec(s.temp_avg) .. " °C" end
  return table.concat(parts, "  •  ")
end

return M
