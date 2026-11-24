-- =============================================================================
--  Arte "hero" (faixas largas: CONTINUAR, EM DESTAQUE, fundos do tema Premium)
--  Ordem de busca para cada port:
--    1. campo "hero" do catalogo (p.hero: link da imagem)
--    2. Steam: busca pelo nome (storesearch) -> appid -> library_hero.jpg
--       (reserva: capsule_616x353.jpg)
--    3. nada: quem desenha usa a capa com veu (H.get devolve nil)
--  Tudo em segundo plano: os downloads vao pela fila do core/fetcher.lua (um
--  por vez) e a reducao da imagem (3840 px -> 640 px) roda numa thread
--  (threads/hero_thread.lua). A interface nunca espera: H.get devolve nil ate
--  a imagem ficar pronta.
--  Cache: <APP_DIR>/cache/hero/ (PNG de 640 px + index.json), limite H.MAX_BYTES
--  (apaga as menos usadas). Busca sem resultado fica anotada por MISS_DAYS dias.
--  Chame H.update() a cada quadro (main.lua faz isso quando o modulo foi carregado).
-- =============================================================================
local C = require("config")
local U = require("lib.util")
local json = require("lib.json")

local H = {
  dir = C.APP_DIR .. "/cache/hero",
  MAX_BYTES = 40 * 1024 * 1024,
  MEM_MAX = 6,              -- imagens na memoria
  MISS_DAYS = 7,            -- sem resultado: tenta de novo depois de N dias
  RETRY_S = 90,             -- falha de rede: tenta de novo depois de N segundos
  WIDTH = 640,              -- largura maxima guardada
  mem = {}, order = {}, state = {}, fail_t = {},
  queue = {}, cur = nil, idx = nil, seq = 0,
}

H.SEARCH_URL = "https://store.steampowered.com/api/storesearch/?term=%s&cc=us&l=en"
H.IMG_URL = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/%s/%s"
H.IMG_FILES = { "library_hero.jpg", "capsule_616x353.jpg" }

local function now() return os.time() end
local function clock() return (love and love.timer and love.timer.getTime()) or os.clock() end

-- ---------------------------------------------------------------------------
-- nomes e busca (funcoes puras: testaveis sem graficos)

--- termo de busca a partir do nome do port: sem parenteses/colchetes e sufixos
function H.search_term(p)
  local name = tostring((p and (p.hero_term or p.name)) or "")
  name = name:gsub("%b()", " "):gsub("%b[]", " ")
  name = name:gsub("[™®©]", " "):gsub("%s+", " ")
  return U.trim(name)
end

--- nome normalizado para comparar (minusculas, so letras e numeros)
function H.norm(s)
  s = tostring(s or ""):lower()
  s = s:gsub("[™®©]", ""):gsub("&", " and ")
  s = s:gsub("[^%w]", "")
  return s
end

local BAD = { "soundtrack", "demo", "dlc", "artbook", "ost", "playtest", "season pass", "bundle", "upgrade",
  "expansion", "costume", "dedicated server", "sdk", "editor" }
local function is_extra(name)
  local l = tostring(name or ""):lower()
  for _, b in ipairs(BAD) do
    if l:find(b, 1, true) then return true end
  end
  return false
end

--- escolhe o appid na resposta da busca da Steam (tabela ja decodificada)
--- ou nil se nenhum item parece ser o mesmo jogo
function H.pick_app(data, name)
  if type(data) ~= "table" or type(data.items) ~= "table" then return nil end
  local want = H.norm(name)
  if want == "" then return nil end
  local best, best_score
  for i, it in ipairs(data.items) do
    if type(it) == "table" and (it.type == nil or it.type == "app") and it.id then
      local n = H.norm(it.name)
      local score = 0
      if n == want then score = 100
      elseif not is_extra(it.name) and #want >= 4 and #n >= 4 then
        if n:sub(1, #want) == want then score = 70          -- "celeste" -> "celeste64"? so se nao for extra
        elseif want:sub(1, #n) == n then score = 60         -- nome do port maior ("dust an elysian tail")
        elseif n:find(want, 1, true) then score = 50 end
      end
      score = score - (i - 1)        -- empate: o primeiro da busca
      if score >= 45 and (not best_score or score > best_score) then best, best_score = it.id, score end
    end
  end
  return best and tostring(best):match("^%d+$") and tostring(best) or nil
end

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(ch) return string.format("%%%02X", ch:byte()) end))
end
H.urlencode = urlencode

function H.search_url(p) return string.format(H.SEARCH_URL, urlencode(H.search_term(p))) end
function H.image_url(appid, file) return string.format(H.IMG_URL, appid, file) end

-- ---------------------------------------------------------------------------
-- indice do cache

local function idx_path() return H.dir .. "/index.json" end

function H.load_index()
  if H.idx then return H.idx end
  local t = U.read_file(idx_path())
  local ok, d = pcall(json.decode, t or "")
  if not ok or type(d) ~= "table" or type(d.items) ~= "table" then d = { v = 1, items = {} } end
  H.idx = d
  return d
end

local function ensure_dir()
  if H.dir_ok then return true end
  os.execute("mkdir -p " .. U.shq(H.dir) .. " 2>/dev/null")
  H.dir_ok = U.is_dir and U.is_dir(H.dir) or true
  return H.dir_ok
end

function H.save_index()
  ensure_dir()
  local ok, text = pcall(json.encode, H.load_index())
  if ok and text then U.write_file(idx_path() .. ".tmp", text); os.rename(idx_path() .. ".tmp", idx_path()) end
end

--- apaga as imagens menos usadas ate o cache caber em MAX_BYTES
function H.prune(max)
  max = max or H.MAX_BYTES
  local d = H.load_index()
  local list, total = {}, 0
  for k, it in pairs(d.items) do
    if it.f then list[#list + 1] = { k = k, it = it }; total = total + (tonumber(it.b) or 0) end
  end
  table.sort(list, function(a, b) return (tonumber(a.it.t) or 0) < (tonumber(b.it.t) or 0) end)
  local removed = 0
  for _, e in ipairs(list) do
    if total <= max then break end
    os.remove(H.dir .. "/" .. e.it.f)
    total = total - (tonumber(e.it.b) or 0)
    d.items[e.k] = nil
    removed = removed + 1
    H.forget_mem(e.k)
  end
  return removed, total
end

--- bytes usados pelo cache (pelo indice)
function H.used()
  local total = 0
  for _, it in pairs(H.load_index().items) do total = total + (tonumber(it.b) or 0) end
  return total
end

-- ---------------------------------------------------------------------------
-- memoria

function H.forget_mem(key)
  local img = H.mem[key]
  if img and img.release then img:release() end
  H.mem[key] = nil
  for i, k in ipairs(H.order) do if k == key then table.remove(H.order, i); break end end
end

local function touch(key)
  for i, k in ipairs(H.order) do if k == key then table.remove(H.order, i); break end end
  H.order[#H.order + 1] = key
  while #H.order > H.MEM_MAX do H.forget_mem(H.order[1]) end
end

local function load_img(key, file)
  local data = U.read_file(H.dir .. "/" .. file)
  if not data then return nil end
  local ok, img = pcall(function()
    local fd = love.filesystem.newFileData(data, file)
    return love.graphics.newImage(love.image.newImageData(fd))
  end)
  if not ok or not img then
    U.log("hero: imagem invalida", file, tostring(img))
    return nil
  end
  img:setFilter("linear", "linear")
  H.mem[key] = img
  touch(key)
  return img
end

-- ---------------------------------------------------------------------------
-- fila (um port por vez)

local function key_of(p) return p and (p.slug or U.slug(tostring(p.id or p.name or ""))) or nil end
H.key_of = key_of

local function enqueue(p)
  local key = key_of(p)
  for i, q in ipairs(H.queue) do
    if key_of(q) == key then table.remove(H.queue, i); break end
  end
  -- o pedido mais recente (o que esta na tela) passa na frente
  table.insert(H.queue, 1, p)
  while #H.queue > 12 do table.remove(H.queue) end
end

local function finish(key, ok, info)
  H.cur = nil
  local d = H.load_index()
  if ok then
    d.items[key] = { f = info.f, b = info.b, t = now(), src = info.src, appid = info.appid }
    H.state[key] = nil
    H.prune()
  elseif info and info.miss then
    d.items[key] = { miss = now(), appid = info.appid }
    H.state[key] = "none"
  else
    -- falha de rede/arquivo: tenta de novo daqui a pouco (nao anota)
    H.state[key] = "failed"
    H.fail_t[key] = clock()
  end
  H.save_index()
end

-- thread que reduz a imagem baixada
local function thread_start()
  if H.thread then return end
  H.req = love.thread.getChannel("hub_hero_req")
  H.res = love.thread.getChannel("hub_hero_res")
  H.req:clear(); H.res:clear()
  H.thread = love.thread.newThread("threads/hero_thread.lua")
  H.thread:start()
end

local function resize(key, src, info)
  thread_start()
  H.seq = H.seq + 1
  local out_name = key .. ".png"
  H.cur.resize = { id = H.seq, info = info, f = out_name }
  H.req:push({ id = H.seq, src = src, out = H.dir .. "/" .. out_name, w = H.WIDTH })
end

local function fetch_image(key, urls, i, info)
  local url = urls[i]
  if not url then return finish(key, false, { miss = info.src == "steam", appid = info.appid }) end
  local tmp = H.dir .. "/" .. key .. ".src"
  require("core.fetcher").get("hero", url, tmp, function(ok)
    if ok then resize(key, tmp, info)
    else os.remove(tmp); fetch_image(key, urls, i + 1, info) end
  end)
end

local function process(p)
  local key = key_of(p)
  H.cur = { key = key, p = p }
  ensure_dir()
  local hero = tostring(p.hero or "")
  if hero:match("^https?://") then
    return fetch_image(key, { hero }, 1, { src = "catalog" })
  end
  if H.search_term(p) == "" then return finish(key, false, { miss = true }) end
  local qf = H.dir .. "/q_" .. key .. ".json"
  require("core.fetcher").get("hero_q", H.search_url(p), qf, function(ok)
    local text = ok and U.read_file(qf) or nil
    os.remove(qf)
    if not text then return finish(key, false, nil) end
    local okj, data = pcall(json.decode, text)
    if not okj or type(data) ~= "table" then return finish(key, false, nil) end
    local appid = H.pick_app(data, H.search_term(p))
    if not appid then return finish(key, false, { miss = true }) end
    local urls = {}
    for _, f in ipairs(H.IMG_FILES) do urls[#urls + 1] = H.image_url(appid, f) end
    fetch_image(key, urls, 1, { src = "steam", appid = appid })
  end)
end

function H.update()
  if H.thread then
    local err = H.thread:getError()
    if err then
      U.log("hero: erro na thread:", err)
      H.thread = nil
      if H.cur and H.cur.resize then finish(H.cur.key, false, nil) end
    end
  end
  if H.res then
    local m = H.res:pop()
    while m do
      local cur = H.cur
      if cur and cur.resize and cur.resize.id == m.id then
        os.remove(H.dir .. "/" .. cur.key .. ".src")
        if m.ok then
          local info = cur.resize.info
          info.f, info.b = cur.resize.f, tonumber(m.bytes) or 0
          finish(cur.key, true, info)
        else
          U.log("hero: falha ao reduzir", cur.key, tostring(m.err))
          finish(cur.key, false, nil)
        end
      end
      m = H.res:pop()
    end
  end
  if not H.cur and #H.queue > 0 and not H.paused then
    local p = table.remove(H.queue, 1)
    local key = key_of(p)
    if H.state[key] == "loading" then
      local ok, err = pcall(process, p)
      if not ok then U.log("hero:", tostring(err)); H.cur = nil; H.state[key] = "failed"; H.fail_t[key] = clock() end
    end
  end
end

-- ---------------------------------------------------------------------------
-- uso pelas telas

--- imagem hero do port (ou nil enquanto nao existe / nao ha). Nunca bloqueia
--- na rede; pode ler uma imagem pequena (640 px) do cartao na primeira vez.
function H.get(p)
  if not p or p.builtin then return nil end
  local key = key_of(p)
  if not key or key == "" then return nil end
  local img = H.mem[key]
  if img then touch(key); return img end
  local st = H.state[key]
  if st == "loading" or st == "none" then return nil end
  if st == "failed" then
    if clock() - (H.fail_t[key] or 0) < H.RETRY_S then return nil end
    H.state[key] = nil
  end
  local d = H.load_index()
  local it = d.items[key]
  if it and it.f then
    it.t = now()
    img = load_img(key, it.f)
    if img then return img end
    d.items[key] = nil      -- arquivo sumiu ou estragou: busca de novo
  elseif it and it.miss and (now() - (tonumber(it.miss) or 0)) < H.MISS_DAYS * 86400
    and not tostring(p.hero or ""):match("^https?://") then
    H.state[key] = "none"
    return nil
  end
  H.state[key] = "loading"
  enqueue(p)
  return nil
end

--- "ready" | "loading" | "none" (sem arte: use a capa) | nil (ainda nao pedido)
function H.status(p)
  local key = key_of(p)
  if not key then return "none" end
  if H.mem[key] then return "ready" end
  return H.state[key]
end

--- apaga o cache inteiro (Configuracoes > Armazenamento, futuro)
function H.clear()
  local d = H.load_index()
  for k, it in pairs(d.items) do if it.f then os.remove(H.dir .. "/" .. it.f) end end
  d.items = {}
  H.save_index()
  for k in pairs(H.mem) do H.forget_mem(k) end
  H.state, H.fail_t = {}, {}
end

function H.stop()
  if H.req then H.req:clear(); H.req:push({ t = "quit" }) end
end

return H
