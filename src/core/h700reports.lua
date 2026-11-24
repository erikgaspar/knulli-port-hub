-- =============================================================================
--  Knulli Port Hub: meus relatorios de compatibilidade no RG35XXH (H700)
--  Arquivo: <APP_DIR>/conf/h700_reports.json
--    { "version": 1, "reports": [ { id, name, status, note, date, time,
--        minutes, temp_max_c, temp_avg_c, perf, tested_on } ] }
--  status: testado | pesado | nao_funciona  (mesmos valores do catalogo extra)
--  Exportacao: <APP_DIR>/h700-relatorios.json no formato do knulli-catalog.json
--    { "ports": [ { "id": ..., "name": ..., "h700": { status, tested_on, note } } ] }
--  Perguntar depois de jogar: Prefs "h700_ask" ("0" desliga tudo) e
--  "h700_mute" (ids separados por virgula que nao perguntam mais).
-- =============================================================================
local C = require("config")
local U = require("lib.util")
local json = require("lib.json")
local Prefs = require("core.prefs")
local Perf = require("core.perf")

local M = {}

M.FILE = C.APP_DIR .. "/conf/h700_reports.json"
M.EXPORT = C.APP_DIR .. "/h700-relatorios.json"
M.STATUS = { testado = true, pesado = true, nao_funciona = true }

local data = nil

function M.load()
  data = { version = 1, reports = {} }
  local t = U.read_file(M.FILE)
  if t then
    local ok, d = pcall(json.decode, t)
    if ok and type(d) == "table" and type(d.reports) == "table" then
      for _, r in ipairs(d.reports) do
        if type(r) == "table" and type(r.id) == "string" and r.id ~= "" and M.STATUS[r.status] then
          data.reports[#data.reports + 1] = r
        end
      end
    end
  end
  return data
end

local function D() return data or M.load() end

function M.save()
  local d = D()
  os.execute("mkdir -p " .. U.shq(C.APP_DIR .. "/conf") .. " 2>/dev/null")
  local tmp = M.FILE .. ".tmp"
  if not U.write_file(tmp, json.encode(d, true)) then return false end
  if not os.rename(tmp, M.FILE) then return U.write_file(M.FILE, json.encode(d, true)) end
  return true
end

--- relatorios, mais recente primeiro
function M.list()
  local out = {}
  for _, r in ipairs(D().reports) do out[#out + 1] = r end
  table.sort(out, function(a, b)
    local ka, kb = tostring(a.date or "") .. tostring(a.time or ""), tostring(b.date or "") .. tostring(b.time or "")
    if ka ~= kb then return ka > kb end
    return tostring(a.name or a.id) < tostring(b.name or b.id)
  end)
  return out
end

function M.get(id)
  for _, r in ipairs(D().reports) do if r.id == id then return r end end
  return nil
end

function M.remove(id)
  local d = D()
  for i = #d.reports, 1, -1 do if d.reports[i].id == id then table.remove(d.reports, i) end end
  return M.save()
end

-- "RG35XXH / Knulli Scarab 2026-05" (como no knulli-catalog.json)
local tested_on_cache
function M.tested_on()
  if tested_on_cache then return tested_on_cache end
  local v = U.read_file("/usr/share/knulli/knulli.version") or ""
  local name, y, m = v:match("^%s*(%a+)%s+(%d%d%d%d)[/%-](%d%d)")
  if name then
    tested_on_cache = "RG35XXH / Knulli " .. name:sub(1, 1):upper() .. name:sub(2):lower() .. " " .. y .. "-" .. m
  else
    tested_on_cache = "RG35XXH / Knulli"
  end
  return tested_on_cache
end

--- grava/atualiza o relatorio de um port
--- e = { id, name, status, note, minutes, temp_max, temp_avg, perf }
function M.set(e)
  if not (e and e.id and M.STATUS[e.status]) then return false end
  local d = D()
  local r = M.get(e.id)
  if not r then r = { id = tostring(e.id) }; d.reports[#d.reports + 1] = r end
  r.name = tostring(e.name or r.name or e.id)
  r.status = e.status
  r.note = U.trim(tostring(e.note or ""))
  r.date = os.date("%Y-%m-%d")
  r.time = os.date("%H:%M")
  -- medidas: so substitui quando vierem novas (editar a avaliacao mantem as antigas)
  if e.minutes then r.minutes = e.minutes end
  if e.temp_max then r.temp_max_c = e.temp_max end
  if e.temp_avg then r.temp_avg_c = e.temp_avg end
  if e.perf ~= nil then r.perf = e.perf and true or false end
  r.tested_on = M.tested_on()
  return M.save()
end

-- ---------------------------------------------------------------------------
-- perguntar depois de jogar
-- ---------------------------------------------------------------------------
local function mute_set()
  local s = {}
  for id in (Prefs.get("h700_mute") or ""):gmatch("[^,]+") do s[id] = true end
  return s
end

function M.ask_enabled() return Prefs.get("h700_ask") ~= "0" end
function M.set_ask_enabled(on) Prefs.set("h700_ask", on and "1" or "0") end

function M.muted(id) return mute_set()[Perf.safe_id(id)] == true end
function M.set_muted(id, on)
  local s = mute_set()
  s[Perf.safe_id(id)] = on and true or nil
  local list = {}
  for k in pairs(s) do list[#list + 1] = k end
  table.sort(list)
  Prefs.set("h700_mute", #list > 0 and table.concat(list, ",") or nil)
end

--- deve perguntar "Como rodou?" para este port?
function M.should_ask(id)
  return C.KNULLI and M.ask_enabled() and not M.muted(id) and M.get(tostring(id)) == nil
end

-- ---------------------------------------------------------------------------
-- exportar no formato do knulli-catalog.json
-- ---------------------------------------------------------------------------
local function measured_note(r)
  local parts = {}
  if r.perf then parts[#parts + 1] = "modo desempenho" end
  if tonumber(r.minutes) then parts[#parts + 1] = string.format("%d min", math.floor(tonumber(r.minutes) + 0.5)) end
  if tonumber(r.temp_max_c) and tonumber(r.temp_max_c) > 0 then
    parts[#parts + 1] = string.format("máx. %d °C", math.floor(tonumber(r.temp_max_c) + 0.5))
  end
  if #parts == 0 then return "" end
  return "Sessão de teste: " .. table.concat(parts, ", ") .. "."
end

--- -> caminho, quantidade | nil, erro
function M.export()
  local list = M.list()
  if #list == 0 then return nil, "nenhum relatório para exportar" end
  table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
  local ports = {}
  for _, r in ipairs(list) do
    local note = r.note or ""
    if note == "" then note = measured_note(r) end
    local h = { status = r.status, tested_on = r.tested_on or M.tested_on(), note = note }
    -- medidas extras (o leitor do catalogo ignora campos desconhecidos)
    if tonumber(r.minutes) or tonumber(r.temp_max_c) then
      h.perf = { minutes = tonumber(r.minutes), temp_max_c = tonumber(r.temp_max_c),
        temp_avg_c = tonumber(r.temp_avg_c), mode = r.perf and "desempenho" or "normal" }
    end
    ports[#ports + 1] = { id = r.id, name = r.name, h700 = h }
  end
  local out = {
    catalog_version = 1,
    title = "Knulli Port Hub - relatórios do RG35XXH",
    updated = os.date("%Y-%m-%d"),
    about = "Gerado pelo Knulli Port Hub (Meus relatórios de compatibilidade). Mesmo formato do knulli-catalog.json: copie os itens de \"ports\" para lá.",
    ports = ports,
  }
  local tmp = M.EXPORT .. ".tmp"
  if not U.write_file(tmp, json.encode(out, true)) then return nil, "não foi possível gravar " .. M.EXPORT end
  if not os.rename(tmp, M.EXPORT) then
    if not U.write_file(M.EXPORT, json.encode(out, true)) then return nil, "não foi possível gravar " .. M.EXPORT end
  end
  return M.EXPORT, #ports
end

return M
