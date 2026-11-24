-- =============================================================================
--  Apps do Knulli (Knulli App Store integrada ao Knulli Port Hub)
--  Le a lista assinada de apps (catalog-index.json) e o estado dos apps
--  instalados (/userdata/system/knulli-app-store/installed, o mesmo da loja).
--  Instalar/atualizar/reparar/remover sao feitos pelo instalador da propria
--  loja (knulli-app), que confere hashes e desfaz em caso de erro. O hub so
--  mostra a lista e o andamento.
--
--  De onde vem o instalador + lista (sempre os dois da mesma pasta/build):
--   a) copia mantida pelo hub em /userdata/system/knulli-port-hub/tools/knulli-app
--      (bin/kapp_fetch.py: release oficial do GitHub, so knulli-app, lista,
--      assinatura, README e licenca; fora de ports, nao aparece no menu)
--   b) a Knulli App Store instalada em ports, se existir e for mais nova
--  Sem nenhuma das duas, a aba oferece "Preparar os Apps do Knulli".
--  Testes: PORTHUB_KAPP_DIR troca a pasta da copia; PORTHUB_KAPP_NO_STORE=1
--  ignora a loja em ports.
-- =============================================================================
local L = require("lib.i18n").L
local U = require("lib.util")
local C = require("config")
local json = require("lib.json")

local K = {}

K.SCRIPT = "Knulli App Store.sh"
K.STATE = "/userdata/system/knulli-app-store"
K.REPO = "https://github.com/jellydn/knulli-app-store"
K.HUB_DIR = os.getenv("PORTHUB_KAPP_DIR") or "/userdata/system/knulli-port-hub/tools/knulli-app"
K.NO_STORE = os.getenv("PORTHUB_KAPP_NO_STORE") == "1"
K.CHECK_EVERY = 12 * 3600           -- procura release nova no maximo a cada 12 h
K.SIZE_HINT = 18 * 1024 * 1024      -- tamanho aproximado do pacote (antes de consultar)

local function complete(d)
  return U.file_size(d .. "/knulli-app") ~= nil and U.file_size(d .. "/catalog-index.json") ~= nil
    and U.file_size(d .. "/catalog-index.json.sig") ~= nil
end

function K.store_dir() return C.PORTS_DIR .. "/knulli-app-store" end
--- a Knulli App Store completa esta instalada em ports (instalador, lista e atalho)
function K.store_installed()
  return not K.NO_STORE and complete(K.store_dir()) and U.file_size(C.PORTS_DIR .. "/" .. K.SCRIPT) ~= nil
end
function K.hub_ok() return complete(K.HUB_DIR) end

local function read_json(path)
  local t = U.read_file(path)
  if not t then return nil end
  local ok, d = pcall(json.decode, t)
  return ok and d or nil
end

--- dados da copia do hub (installed.json: tag, published_at, size, sha256...)
function K.hub_info() return read_json(K.HUB_DIR .. "/installed.json") end

local function mtime(path)
  local s = U.capture("stat -c %Y " .. U.shq(path) .. " 2>/dev/null")
  return tonumber(s and s:match("%d+")) or 0
end

--- origem usada agora: "hub" | "store" | nil, e a pasta. A loja so ganha da
--- copia do hub quando a lista dela e mais nova (data do catalog-index.json,
--- que vem do zip da release nas duas).
local src_cache, src_t = nil, -100
function K.source()
  local now = love and love.timer and love.timer.getTime() or os.time()
  if src_cache and now - src_t < 5 then return src_cache[1], src_cache[2] end
  local hub = K.hub_ok()
  local store = not K.NO_STORE and complete(K.store_dir())
  local s, d = nil, nil
  if hub and store then
    if mtime(K.store_dir() .. "/catalog-index.json") > mtime(K.HUB_DIR .. "/catalog-index.json") + 60 then
      s, d = "store", K.store_dir()
    else
      s, d = "hub", K.HUB_DIR
    end
  elseif hub then s, d = "hub", K.HUB_DIR
  elseif store then s, d = "store", K.store_dir() end
  src_cache, src_t = { s, d }, now
  return s, d
end

--- pasta do instalador + lista em uso (nil sem nenhuma)
function K.dir() local _, d = K.source(); return d end
function K.available() return K.source() ~= nil end

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
function K.invalidate() cache = nil; src_cache = nil end
function K.list(force)
  local now = love and love.timer and love.timer.getTime() or os.time()
  if cache and not force and now - cache_t < 5 then return cache end
  local res, err = K.list_raw()
  cache, cache_t = res, now
  return res, err
end

function K.list_raw()
  local d = K.dir()
  local cat = d and read_json(d .. "/catalog-index.json")
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

--- acoes do instalador em andamento (a copia do hub nao e trocada no meio)
K.running = 0

--- comando do instalador para uma acao ("install"|"update"|"repair"|"uninstall")
--- O manifesto do app vai para um arquivo temporario (o knulli-app le de arquivo).
function K.command(app, action)
  local dir = K.dir()
  if not dir then return nil, L("Os Apps do Knulli ainda não foram preparados.") end
  local d = U.shq(dir)
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

-- ---------------------------------------------------------------------------
-- copia do hub: baixar / atualizar (bin/kapp_fetch.py numa thread)

K.job = nil        -- { mode = "update"|"check", progress = arquivo }
K.latest = nil     -- { tag, size, published } da ultima consulta

function K.progress_file() return K.HUB_DIR .. ".progress" end

--- comando do baixador (mode "update" baixa se houver tag nova; "check" so consulta)
function K.fetch_command(mode)
  local py = os.getenv("PORTHUB_KAPP_FETCH") or (C.APP_DIR .. "/bin/kapp_fetch.py")
  local cmd = "python3 -I " .. U.shq(py) .. " --dest " .. U.shq(K.HUB_DIR)
  if mode == "check" then cmd = cmd .. " --check"
  else cmd = cmd .. " --progress " .. U.shq(K.progress_file()) end
  return cmd .. " 2>&1"
end

--- le a saida do baixador: ok, { tag, size, published, updated, current }, erro
function K.parse_fetch(out)
  local info, ok, err, last = {}, false, nil, nil
  for l in tostring(out or ""):gmatch("[^\n]+") do
    local tag, size, pub = l:match("^LATEST (%S+) (%d+) ?(%S*)")
    if tag then info.tag, info.size, info.published = tag, tonumber(size), pub end
    if l:match("^CURRENT ") then info.current = true end
    local otag, how = l:match("^OK (%S+) (%S+)")
    if otag then ok = true; info.tag = otag; info.updated = how == "updated"; info.current = how == "current" end
    if l:match("^ERRO ") then err = l:sub(6) end
    if not l:match("^STEP ") then last = l end
  end
  if not ok and not err and info.tag and not info.current then ok = true end   -- --check com versao nova
  if not ok and not err then err = last or L("o baixador não respondeu") end
  return ok, info, err
end

--- roda o baixador em segundo plano. cb(ok, info, err)
--- K.job = download/atualizacao (um por vez); K.check_job = so consulta
function K.fetch(mode, cb)
  local slot = mode == "check" and "check_job" or "job"
  if K[slot] then if cb then cb(false, {}, L("Já existe uma atualização dos Apps do Knulli em andamento.")) end; return nil end
  local job = { mode = mode, progress = mode ~= "check" and K.progress_file() or nil, t0 = os.time() }
  K[slot] = job
  require("core.shjob").start({ K.fetch_command(mode) }, function(res, terr)
    K[slot] = nil
    local r = res and res[1]
    local ok, info, err = K.parse_fetch(r and r.out or "")
    if not r then ok, err = false, tostring(terr or "?") end
    if info.tag and info.size then
      K.latest = { tag = info.tag, size = info.size, published = info.published }
      pcall(function() require("core.prefs").set("kapp_size", tostring(info.size)) end)
    end
    if ok and mode ~= "check" then
      pcall(function() require("core.prefs").set("kapp_last", tostring(os.time())) end)
    end
    if info.updated then K.invalidate() end
    if not ok then U.log("Apps do Knulli (copia do hub):", tostring(err)) end
    if cb then cb(ok, info, err) end
  end)
  return job
end

--- bytes baixados / total do download em andamento (ou nil)
function K.progress()
  local j = K.job
  if not j or not j.progress then return nil end
  local s = U.read_file(j.progress)
  local d, t = tostring(s or ""):match("^(%d+) (%d+)")
  if not d then return nil end
  return tonumber(d), tonumber(t)
end

--- tamanho do pacote para mostrar antes de baixar (consulta feita ou estimativa)
function K.download_size()
  if K.latest and K.latest.size then return K.latest.size, true end
  local n = tonumber(require("core.prefs").get("kapp_size") or "")
  if n and n > 0 then return n, true end
  return K.SIZE_HINT, false
end

--- consulta a release mais nova uma vez (para mostrar o tamanho certo)
function K.peek()
  if K.latest or K.job or K.check_job or K.peeked then return end
  K.peeked = true
  K.fetch("check")
end

--- junto com os catalogos: no maximo 1x a cada 12 h (ou quando o usuario pede)
--- procura tag nova e atualiza a copia do hub. So quando a copia ja existe.
function K.auto_check(user_initiated)
  if not C.KNULLI or K.job or K.running > 0 or not K.hub_ok() then return false end
  local Prefs = require("core.prefs")
  local last = tonumber(Prefs.get("kapp_last") or "") or 0
  if not user_initiated and os.time() - last < K.CHECK_EVERY and os.time() >= last then return false end
  local before = (K.hub_info() or {}).tag
  K.fetch("update", function(ok, info)
    if ok and info.updated then
      U.log("Apps do Knulli: lista atualizada", tostring(before), "->", tostring(info.tag))
      if App and App.toast then
        App.toast(string.format(L("Apps do Knulli: lista atualizada (%s)"), tostring(info.tag)), "ok")
      end
      if App and App.on_catalog_changed then App.on_catalog_changed() end
    end
  end)
  return true
end

return K
