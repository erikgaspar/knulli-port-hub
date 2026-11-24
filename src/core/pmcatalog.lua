-- =============================================================================
--  Knulli Port Hub: catalogo oficial do PortMaster (so ports "Ready to Run")
--
--  Fonte: ports.json da release mais recente do PortsMaster/PortMaster-New
--    https://github.com/PortsMaster/PortMaster-New/releases/latest/download/ports.json
--  Formato (o mesmo que o harbourmaster le):
--    { "ports": { "<zip>": { name, items, items_opt, attr = { title, porter[], desc,
--        genres[], image = { screenshot, covers[] }, rtr, exp, runtime[], reqs[],
--        arch[], min_glibc, availability, store[] },
--        source = { date_added, date_updated, md5, size, url, release_id } } },
--      "utils": { "<runtime>.squashfs": { name, runtime_name, runtime_arch, md5, size, url }, ... } }
--  Imagens: pasta do port no repositorio (ports/<zip sem .zip>/<arquivo>)
--
--  Entram SO os ports que o harbourmaster mostraria neste console E que nao
--  pedem arquivos do jogo:
--    attr.rtr == true, attr.exp ~= true (experimentais ficam de fora, como no
--    PortMaster), runtimes existentes em aarch64 (ou attr.arch com aarch64; sem
--    arch e sem runtime = universal, regra do harbourmaster), attr.reqs
--    atendidos pelas capacidades do RG35XXH/Knulli e min_glibc <= glibc do console.
--
--  O ports.json inteiro (2,6 MB) so e lido na hora do download; o app guarda
--  uma versao compacta (pm_catalog_cache.json) para abrir rapido e sem internet.
-- =============================================================================
local json = require("lib.json")
local U = require("lib.util")
local C = require("config")

local PMC = {
  data = nil,         -- { fetched, release, ports = { entradas no formato do app }, runtimes = {}, stats = {} }
  runtimes = {},      -- "<nome>.squashfs" -> { md5, size, url, title }
}

PMC.URL = "https://github.com/PortsMaster/PortMaster-New/releases/latest/download/ports.json"
PMC.IMG_BASE = "https://raw.githubusercontent.com/PortsMaster/PortMaster-New/main/ports/"
PMC.ARCH = "aarch64"
PMC.CACHE = "pm_catalog_cache.json"
-- intervalo minimo entre downloads automaticos (o arquivo tem 2,6 MB)
PMC.MAX_AGE = 6 * 3600
PMC.ID_PREFIX = "pm-"

-- Capacidades do RG35XXH com Knulli, exatamente como o harbourmaster do console
-- informa (harbourmaster.hardware.device_info(): device rg35xx-h, cpu h700).
-- armhf fica de fora de proposito: so entram ports aarch64.
PMC.CAPS = { "power", "aarch64", "restore", "4:3", "640x480", "knulli", "rg35xx-h",
  "analog_0", "analog_1", "analog_2", "1gb" }
PMC.GLIBC = "2.40"

-- genero do PortMaster -> categoria do app (core/categories.lua). Ordem = prioridade
-- (o primeiro genero da lista que o port tiver decide a categoria).
PMC.GENRES = {
  { "fps", "tiro" }, { "racing", "corrida" }, { "sports", "esportes" }, { "rpg", "rpg" },
  { "platformer", "plataforma" }, { "puzzle", "puzzle" }, { "strategy", "estrategia" },
  { "simulation", "estrategia" }, { "visual novel", "aventura" }, { "casino/card", "puzzle" },
  { "rhythm", "arcade" }, { "adventure", "aventura" }, { "arcade", "arcade" }, { "action", "acao" },
  { "other", "outros" },
}

local function s(v) return type(v) == "string" and v or "" end
local function list(v)
  if type(v) == "table" then return v end
  if type(v) == "string" and v ~= "" then return { v } end
  return {}
end

--- chave para achar o mesmo jogo em catalogos diferentes (sem acento, so letras/numeros)
function PMC.key(v)
  v = U.slug(s(v)):gsub("%.zip$", ""):gsub("[^%w]", "")
  return v
end

--- nome do runtime como fica em PortMaster/libs (alguns ports omitem ".squashfs")
function PMC.rt_name(r)
  r = s(r)
  if r == "" then return nil end
  if not r:match("%.squashfs$") then r = r .. ".squashfs" end
  return r
end

local function vparts(v)
  local t = {}
  for n in s(v):gmatch("%d+") do t[#t + 1] = tonumber(n) end
  return t
end
local function vle(a, b) -- a <= b ?
  local x, y = vparts(a), vparts(b)
  for i = 1, math.max(#x, #y) do
    local p, q = x[i] or 0, y[i] or 0
    if p ~= q then return p < q end
  end
  return true
end

--- mesma regra do harbourmaster (util.match_requirements): "!x" = nao pode ter,
--- "a|b" = qualquer um dos dois
function PMC.match_reqs(reqs, caps)
  local have = {}
  for _, c in ipairs(caps or PMC.CAPS) do have[c] = true end
  for _, r in ipairs(reqs or {}) do
    r = s(r)
    if r ~= "" then
      local want = true
      if r:sub(1, 1) == "!" then want, r = false, r:sub(2) end
      local any = false
      for part in r:gmatch("[^|]+") do if have[part] then any = true end end
      if any ~= want then return false end
    end
  end
  return true
end

--- Motivo de um port ficar de fora (nil = entra)
function PMC.reject(e, runtimes)
  local a = type(e) == "table" and e.attr
  if type(a) ~= "table" then return "sem_attr" end
  if a.rtr ~= true then return "nao_rtr" end
  if a.exp == true then return "experimental" end
  local src = type(e.source) == "table" and e.source or {}
  if s(src.url) == "" or not tonumber(src.size) then return "sem_download" end
  local rts = list(a.runtime)
  local has_rt = false
  for _, r in ipairs(rts) do
    local n = PMC.rt_name(r)
    if n then
      has_rt = true
      if not runtimes[n] then return "runtime_sem_aarch64" end
    end
  end
  if not has_rt then
    local arch = list(a.arch)
    if #arch > 0 then
      local okA = false
      for _, x in ipairs(arch) do if x == PMC.ARCH then okA = true end end
      if not okA then return "sem_aarch64" end
    end
  end
  if not PMC.match_reqs(list(a.reqs)) then return "requisitos" end
  local g = s(a.min_glibc)
  if g ~= "" and not vle(g, PMC.GLIBC) then return "glibc" end
  return nil
end

local function category_of(genres)
  local have = {}
  for _, g in ipairs(list(genres)) do have[s(g):lower()] = true end
  for _, m in ipairs(PMC.GENRES) do if have[m[1]] then return m[2] end end
  return "outros"
end

local function short_of(desc)
  local d = desc:gsub("%s+", " ")
  local first = d:match("^(.-[%.!?])%s") or d
  if #first > 120 then first = first:sub(1, 117):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "..." end
  return first
end

--- entrada do PortMaster -> port no formato do catalogo do app (docs/CATALOGO.md)
function PMC.to_port(zip, e)
  local a, src = e.attr, e.source
  local base = zip:gsub("%.zip$", "")
  local title = s(a.title) ~= "" and s(a.title) or base
  local img = type(a.image) == "table" and a.image or {}
  local pic = list(img.covers)[1] or img.screenshot
  local cover = ""
  if type(pic) == "string" and pic ~= "" and not pic:find("%.%.") then
    cover = PMC.IMG_BASE .. base .. "/" .. pic
  end
  local porters = {}
  for _, p in ipairs(list(a.porter)) do if s(p) ~= "" then porters[#porters + 1] = s(p) end end
  local rts = {}
  for _, r in ipairs(list(a.runtime)) do rts[#rts + 1] = PMC.rt_name(r) end
  local desc = s(a.desc)
  return {
    id = PMC.ID_PREFIX .. base,
    name = title,
    description = desc,
    short = short_of(desc),
    category = category_of(a.genres),
    section = "games",
    version = s(src.date_updated) ~= "" and s(src.date_updated) or s(src.release_id),
    author = table.concat(porters, ", "),
    size_bytes = tonumber(src.size),
    download_url = s(src.url),
    md5 = s(src.md5):lower(),
    cover = cover,
    pm_name = zip,
    added = s(src.date_added),
    -- sem "updated": as ~650 atualizacoes do PortMaster lotariam Novidades (a versao ja e a data)
    pm = true,
    pm_items = list(e.items),
    -- requisitos no formato do port.json (core/compat.lua le "attr")
    -- (listas vazias viram nil: "arch": [] significa "qualquer uma" no PortMaster)
    attr = { rtr = true, runtime = rts, arch = #list(a.arch) > 0 and list(a.arch) or nil,
      reqs = #list(a.reqs) > 0 and list(a.reqs) or nil, min_glibc = s(a.min_glibc) ~= "" and s(a.min_glibc) or nil,
      genres = list(a.genres), availability = s(a.availability) },
  }
end

--- Le o ports.json completo e devolve a versao compacta (ou nil, erro)
function PMC.convert(text)
  local ok, d = pcall(json.decode, text or "")
  if not ok or type(d) ~= "table" or type(d.ports) ~= "table" then return nil, "ports.json invalido" end
  local rts = {}
  for k, u in pairs(type(d.utils) == "table" and d.utils or {}) do
    if type(u) == "table" and s(u.runtime_arch) == PMC.ARCH and s(u.url) ~= "" then
      local n = s(u.runtime_name) ~= "" and s(u.runtime_name) or k
      rts[n] = { md5 = s(u.md5):lower(), size = tonumber(u.size), url = s(u.url), title = s(u.name) }
    end
  end
  local out, stats = {}, { total = 0, rtr = 0, ok = 0, why = {}, genres = {} }
  local zips = {}
  for zip in pairs(d.ports) do zips[#zips + 1] = zip end
  table.sort(zips)
  local release = ""
  for _, zip in ipairs(zips) do
    local e = d.ports[zip]
    stats.total = stats.total + 1
    if type(e) == "table" and type(e.attr) == "table" and e.attr.rtr == true then stats.rtr = stats.rtr + 1 end
    local why = PMC.reject(e, rts)
    if why then
      stats.why[why] = (stats.why[why] or 0) + 1
    elseif type(zip) == "string" and zip:match("^[%w%._%-]+%.zip$") then
      local p = PMC.to_port(zip, e)
      out[#out + 1] = p
      stats.ok = stats.ok + 1
      stats.genres[p.category] = (stats.genres[p.category] or 0) + 1
      local r = s(e.source.release_id)
      if r > release then release = r end
    else
      stats.why.nome_invalido = (stats.why.nome_invalido or 0) + 1
    end
  end
  table.sort(out, function(x, y) return x.name:lower() < y.name:lower() end)
  return { fetched = os.time(), release = release, ports = out, runtimes = rts, stats = stats }
end

function PMC.set(data)
  if type(data) ~= "table" or type(data.ports) ~= "table" then return false end
  PMC.data = data
  PMC.runtimes = type(data.runtimes) == "table" and data.runtimes or {}
  return true
end

--- cache compacto guardado (sem rede)
function PMC.load_local()
  if not C.KNULLI then return false end
  local okr, t = pcall(love.filesystem.read, PMC.CACHE)
  if not (okr and t) then return false end
  local ok, d = pcall(json.decode, t)
  return ok and PMC.set(d) or false
end

--- precisa baixar de novo? (cache ausente ou com mais de MAX_AGE)
function PMC.stale()
  local d = PMC.data
  return not d or not tonumber(d.fetched) or os.time() - d.fetched > PMC.MAX_AGE or os.time() < d.fetched
end

--- resultado do download: a thread de downloads ja entrega a versao compacta
--- (threads/fetch_thread.lua); um ports.json completo tambem e aceito
function PMC.on_download(ok, path)
  if not ok then return false end
  local text = U.read_file(path)
  os.remove(path)
  local okd, d = pcall(json.decode, text or "")
  local data, err
  if okd and type(d) == "table" and type(d.ports) == "table" and type(d.stats) == "table" then
    data = d
  else
    data, err = PMC.convert(text)
  end
  if not (data and PMC.set(data)) then U.log("catalogo PortMaster:", err or "invalido"); return false end
  if data == d then pcall(love.filesystem.write, PMC.CACHE, text) else pcall(love.filesystem.write, PMC.CACHE, json.encode(data)) end
  text = nil
  local st = data.stats
  U.log(string.format("catalogo PortMaster %s: %d ports, %d RTR, %d entram", data.release, st.total, st.rtr, st.ok))
  return true
end

-- ---------------------------------------------------------------------------
-- Mescla com o catalogo do autor (Catalog.parse, antes do catalogo extra)
--
-- Duplicados (mesmo jogo nos dois catalogos, pelo nome do zip/pm_name, id ou
-- titulo normalizados): fica UM so.
--   * o do autor fica se tiver selo h700 "testado" (dele ou do catalogo extra);
--   * senao fica o do PortMaster (sempre RTR aqui). Ele herda o id do autor em
--     "alt_id" (registro de instalados e selo h700 do catalogo extra continuam
--     valendo) e o selo h700 do autor, se houver.
-- ---------------------------------------------------------------------------
local function copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end

function PMC.merge(list_, extra)
  local d = PMC.data
  if not (C.KNULLI and d and type(d.ports) == "table" and #d.ports > 0) then return list_ end
  local tested = {}  -- ids do autor com selo h700 "testado" no catalogo extra
  local ex_h700 = {}
  for _, e in ipairs(type(extra) == "table" and type(extra.ports) == "table" and extra.ports or {}) do
    if type(e) == "table" and e.id and type(e.h700) == "table" then
      ex_h700[tostring(e.id)] = e.h700
      if e.h700.status == "testado" or e.h700.status == nil then tested[tostring(e.id)] = true end
    end
  end
  local idx = {}
  for i, raw in ipairs(list_) do
    if type(raw) == "table" then
      local keys = { raw.pm_name, raw.portmaster_name, raw.id, raw.name or raw.nome or raw.title }
      for j = 1, 4 do
        local k = PMC.key(keys[j])
        if k ~= "" and not idx[k] then idx[k] = i end
      end
    end
  end
  local drop, add = {}, {}
  for _, pm in ipairs(d.ports) do
    local i = idx[PMC.key(pm.pm_name)] or idx[PMC.key(pm.name)]
    local au = i and not drop[i] and list_[i]
    if au then
      local aid = tostring(au.id or "")
      local h = (type(au.h700) == "table" and au.h700) or ex_h700[aid]
      local au_tested = (type(au.h700) == "table" and (au.h700.status or "testado") == "testado") or tested[aid]
      if au_tested then
        -- fica o do autor; o nome do zip ajuda a reconhecer o port instalado pelo PortMaster
        if not au.pm_name or au.pm_name == "" then au.pm_name = pm.pm_name end
      else
        drop[i] = true
        local p = copy(pm)
        p.alt_id = aid ~= "" and aid or nil
        if h then p.h700 = h end
        add[#add + 1] = p
      end
    else
      add[#add + 1] = copy(pm)
    end
  end
  local out = {}
  for i, raw in ipairs(list_) do if not drop[i] then out[#out + 1] = raw end end
  for _, p in ipairs(add) do out[#out + 1] = p end
  return out
end

-- ---------------------------------------------------------------------------
-- Runtimes exigidos por um port
-- ---------------------------------------------------------------------------
--- pasta libs do PortMaster (onde ficam os .squashfs)
function PMC.libs_dir()
  local okr, R = pcall(require, "core.runtimes")
  local pm = okr and R.detect_pm() or nil
  return pm and (pm .. "/libs") or nil
end

--- Runtimes que faltam para o port: lista de { name, title, url, md5, size } e o
--- total em bytes. Runtime desconhecido no indice vem com url = nil.
function PMC.missing_runtimes(p, libs)
  local need = p and p.attr and p.attr.runtime
  if type(need) ~= "table" or #need == 0 then return {}, 0 end
  libs = libs or PMC.libs_dir()
  local out, total = {}, 0
  for _, n in ipairs(need) do
    local name = PMC.rt_name(n)
    local present = libs and (U.exists(libs .. "/" .. name))
    if name and not present then
      local r = PMC.runtimes[name] or {}
      out[#out + 1] = { name = name, title = r.title ~= "" and r.title or name, url = r.url, md5 = r.md5, size = r.size }
      total = total + (r.size or 0)
    end
  end
  return out, total
end

return PMC
