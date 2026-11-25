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
-- "sempre em modo desempenho" tambem pelo EmulationStation: bloco guardado
-- logo apos o shebang do <Port>.sh (raiz de ports) que reexecuta o script
-- pelo perf_run.sh. Guardas: PORTHUB_PERF_WRAP (o perf_run e o launcher do
-- hub exportam) e /tmp/porthub-perf.state (sessao de desempenho ja ativa).
-- Desmarcar tira o bloco (o arquivo volta exatamente ao que era).
-- ---------------------------------------------------------------------------
M.WRAP_MARK = "# Knulli Port Hub: sempre em modo desempenho"

local function script_ok(script)
  script = tostring(script or "")
  return script ~= "" and not script:find("/") and not script:find("%.%.") and script:lower():match("%.sh$") ~= nil
end

function M.wrap_block(script, id)
  local q = tostring(script):gsub('[\\"$`]', "\\%0")
  return table.concat({
    M.WRAP_MARK .. " (CPU/GPU no maximo, zram); desmarque no hub para tirar",
    "PORTHUB_PERF=" .. M.SCRIPT,
    'if [ -z "$PORTHUB_PERF_WRAP" ] && [ ! -f /tmp/porthub-perf.state ] && [ -f "$PORTHUB_PERF" ]; then',
    '  PORTHUB_PERF_WRAP=1 exec bash "$PORTHUB_PERF" "' .. q .. '" ' .. M.safe_id(id) .. ' "$@"',
    "fi",
  }, "\n") .. "\n"
end

--- tira o bloco (qualquer versao: do marcador ate o "fi" depois do exec)
local function strip_wrap(text)
  local out, skip, removed = {}, false, false
  for line in (text .. (text:sub(-1) == "\n" and "" or "\n")):gmatch("([^\n]*)\n") do
    if not skip and line:find(M.WRAP_MARK, 1, true) == 1 then skip = true; removed = true
    elseif skip then
      if line:match("^fi%s*$") then skip = false end
    else
      out[#out + 1] = line
    end
  end
  if not removed or skip then return text, false end   -- bloco incompleto: nao mexe
  local s = table.concat(out, "\n")
  if text:sub(-1) == "\n" then s = s .. "\n" end
  return s, true
end
M.strip_wrap = strip_wrap

--- o script do port tem o bloco? -> true, id do exec (ou nil)
function M.has_wrap(script)
  if not script_ok(script) then return false end
  local t = U.read_file(C.PORTS_DIR .. "/" .. script) or ""
  local line = t:match("[^\n]*PORTHUB_PERF_WRAP=1 exec[^\n]*")
  if not line then return false end
  return true, line:match('exec bash "[^"]*" ".-" ([%w_%-]+)')
end

--- poe (on) ou tira o bloco do <script> (nome na raiz de ports). -> ok, erro
function M.set_wrap(script, id, on)
  if not C.KNULLI or not script_ok(script) then return nil, "script inválido" end
  local path = C.PORTS_DIR .. "/" .. script
  local text = U.read_file(path)
  if not text then return nil, "script não encontrado" end
  local base = strip_wrap(text)
  local new = base
  if on then
    local first, rest = base:match("^(#![^\n]*\n)(.*)$")
    if first then new = first .. M.wrap_block(script, id) .. rest
    else new = "#!/bin/bash\n" .. M.wrap_block(script, id) .. base end
  end
  if new == text then return true end
  -- grava no mesmo arquivo (mantem dono e permissao de execucao)
  local f = io.open(path, "wb")
  if not f then return nil, "não foi possível gravar " .. path end
  f:write(new)
  f:close()
  return true
end

--- liga/desliga "sempre em modo desempenho" (preferencia + bloco no script)
function M.set_always_port(p, script, on)
  M.set_always(p.id, on)
  if script then
    local ok, err = M.set_wrap(script, p.id, on)
    if not ok then U.log("perf: bloco do script", script, err) end
    return ok, err
  end
  return true
end

--- ao iniciar o app / depois de instalar: adota blocos feitos a mao e
--- reaplica o bloco nos ports marcados (atualizar/reinstalar troca o .sh)
--- script_of(id) -> nome do script na raiz de ports (ou nil); id_of_script(script) -> id do port
function M.sync_wraps(script_of, id_of_script)
  if not C.KNULLI then return end
  local set = always_set()
  local changed = false
  -- blocos que ja existem (ex.: colocados a mao) viram preferencia
  local out = U.capture("grep -l 'PORTHUB_PERF_WRAP=1 exec' " .. U.shq(C.PORTS_DIR) .. "/*.sh 2>/dev/null") or ""
  for path in out:gmatch("[^\n]+") do
    local script = path:match("([^/]+)$")
    local has, id = M.has_wrap(script)
    -- id do port no catalogo do hub (o bloco feito a mao pode usar outro, ex.: castleofillusion)
    local cid = id_of_script and id_of_script(script)
    if cid then id = M.safe_id(cid) end
    if has and id and id ~= "" and not set[id] then set[id] = true; changed = true end
  end
  if changed then
    local list = {}
    for k in pairs(set) do list[#list + 1] = k end
    table.sort(list)
    Prefs.set("perf_always", table.concat(list, ","))
  end
  -- marcados sem o bloco (port atualizado/reinstalado): poe de novo
  if script_of then
    for id in pairs(set) do
      local script = script_of(id)
      if script and not M.has_wrap(script) then
        local ok, err = M.set_wrap(script, id, true)
        U.log("perf: bloco reaplicado em", script, ok and "ok" or tostring(err))
      end
    end
  end
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
