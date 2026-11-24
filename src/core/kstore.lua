-- =============================================================================
--  Apps do Knulli (Knulli App Store integrada ao Knulli Port Hub)
--  Le a lista assinada que a Knulli App Store ja baixou (catalog-index.json) e o
--  estado dos apps instalados (/userdata/system/knulli-app-store/installed).
--  Instalar/atualizar/reparar/remover sao feitos pelo instalador da propria
--  loja (knulli-app), que confere hashes e desfaz em caso de erro. O hub so
--  mostra a lista e o andamento.
-- =============================================================================
local L = require("lib.i18n").L
local U = require("lib.util")
local C = require("config")
local json = require("lib.json")

local K = {}

K.SCRIPT = "Knulli App Store.sh"
K.STATE = "/userdata/system/knulli-app-store"
K.REPO = "https://github.com/jellydn/knulli-app-store"

function K.dir() return C.PORTS_DIR .. "/knulli-app-store" end
function K.available()
  return U.file_size(K.dir() .. "/knulli-app") ~= nil and U.file_size(K.dir() .. "/catalog-index.json") ~= nil
end

local function read_json(path)
  local t = U.read_file(path)
  if not t then return nil end
  local ok, d = pcall(json.decode, t)
  return ok and d or nil
end

--- compara versoes "5.4.1.0" / "2.3.0-alpha1" (numeros em ordem; o resto desempata como texto)
function K.vcmp(a, b)
  local ta, tb = {}, {}
  for n in tostring(a or ""):gmatch("%d+") do ta[#ta + 1] = tonumber(n) end
  for n in tostring(b or ""):gmatch("%d+") do tb[#tb + 1] = tonumber(n) end
  for i = 1, math.max(#ta, #tb) do
    local x, y = ta[i] or 0, tb[i] or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  if a == b then return 0 end
  return tostring(a) < tostring(b) and -1 or 1
end

local TYPE = { game = L("JOGO"), utility = L("UTILITÁRIO"), integration = L("INTEGRAÇÃO") }
K.TYPE = TYPE

--- lista de apps: { id, name, version, type, summary, notes, license, repository,
---                  installed_version, status = "none"|"installed"|"update", pkg }
local cache, cache_t = nil, -100
function K.invalidate() cache = nil end
function K.list(force)
  local now = love and love.timer and love.timer.getTime() or os.time()
  if cache and not force and now - cache_t < 5 then return cache end
  local res, err = K.list_raw()
  cache, cache_t = res, now
  return res, err
end

function K.list_raw()
  local cat = read_json(K.dir() .. "/catalog-index.json")
  if type(cat) ~= "table" or type(cat.packages) ~= "table" then return nil, L("Lista de apps da Knulli App Store não encontrada.") end
  local out = {}
  for _, e in ipairs(cat.packages) do
    local p = type(e) == "table" and e.package
    if type(p) == "table" and p.id then
      local st = read_json(K.STATE .. "/installed/" .. p.id .. ".json")
      local iv = st and st.manifest and st.manifest.version
      local status = "none"
      if iv then status = K.vcmp(iv, p.version) < 0 and "update" or "installed" end
      out[#out + 1] = { id = p.id, name = p.name or p.id, version = p.version or "?", type = p.type,
        summary = p.summary or "", notes = (p.review and p.review.notes) or {},
        review = p.review and p.review.status or "", license = p.license or "", repository = p.repository or "",
        installed_version = iv, status = status, pkg = p }
    end
  end
  table.sort(out, function(a, b)
    if (a.status == "none") ~= (b.status == "none") then return a.status ~= "none" end
    return a.name:lower() < b.name:lower()
  end)
  return out
end

--- comando do instalador para uma acao ("install"|"update"|"repair"|"uninstall")
--- O manifesto do app vai para um arquivo temporario (o knulli-app le de arquivo).
function K.command(app, action)
  local d = U.shq(K.dir())
  local log = U.shq(K.STATE .. "/hub-" .. action .. ".log")
  if action == "uninstall" then
    return "mkdir -p " .. U.shq(K.STATE) .. " && cd " .. d .. " && ./knulli-app uninstall " .. U.shq(app.id) .. " > " .. log .. " 2>&1; rc=$?; tail -n 15 " .. log .. "; exit $rc"
  end
  local mf = C.APP_DIR .. "/tmp/kstore-" .. app.id:gsub("[^%w%._%-]", "_") .. ".json"
  U.exec_ok("mkdir -p " .. U.shq(C.APP_DIR .. "/tmp"))
  if not U.write_file(mf, json.encode(app.pkg)) then return nil, L("não foi possível gravar o manifesto temporário") end
  return "mkdir -p " .. U.shq(K.STATE) .. " && cd " .. d .. " && ./knulli-app validate " .. U.shq(mf) .. " > " .. log .. " 2>&1 && ./knulli-app "
    .. action .. " " .. U.shq(mf) .. " >> " .. log .. " 2>&1; rc=$?; rm -f " .. U.shq(mf) .. "; tail -n 15 " .. log .. "; exit $rc"
end

return K
