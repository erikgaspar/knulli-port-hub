-- =============================================================================
--  Pacote de musicas de games (OverClocked ReMix) - lado do app
--  O repositorio guarda so o indice (knulli-music.json: jogo, remix, artistas,
--  pagina no ocremix.org, links dos espelhos oficiais, duracao, tamanho). O
--  bin/musicpack.py baixa no console, uma faixa por vez, confere (ffprobe),
--  converte para OGG 96 kbps (ffmpeg) e poe em <musica>/ocremix. Remover apaga
--  so o que o pacote instalou (registro em <musica>/ocremix/.knulli-port-hub.json).
--  Indice: cache baixado (APP_DIR/cache/knulli_music.json) ou a copia embutida.
--  Testes: PORTHUB_MUSIC_DIR troca /userdata/music; PORTHUB_MUSICPACK_PY o script.
-- =============================================================================
local L = require("lib.i18n").L
local U = require("lib.util")
local C = require("config")
local json = require("lib.json")

local M = {}

M.URL = "https://raw.githubusercontent.com/erikgaspar/knulli-port-hub/main/knulli-music.json"
M.DEST = os.getenv("PORTHUB_MUSIC_DIR") or "/userdata/music"
M.FOLDER = "ocremix"
M.job = nil        -- { action, progress, cancel, t0 }

local function cache_path() return C.APP_DIR .. "/cache/knulli_music.json" end
local function tmp(n) return C.APP_DIR .. "/tmp/" .. n end

local function parse(text)
  local ok, d = pcall(json.decode, text or "")
  if not ok or type(d) ~= "table" or type(d.tracks) ~= "table" then return nil end
  local list = {}
  for _, t in ipairs(d.tracks) do
    if type(t) == "table" and type(t.id) == "string" and type(t.file) == "string" then list[#list + 1] = t end
  end
  d.tracks = list
  return d
end

--- indice atual (cache baixado ou copia embutida)
function M.index()
  if M._idx then return M._idx end
  local d = parse(U.read_file(cache_path()))
  if not d and love and love.filesystem then d = parse(love.filesystem.read("catalog/knulli_music.json")) end
  M._idx = d
  return d
end

--- baixa o indice novo em segundo plano (uma vez por abertura da tela)
function M.refresh(cb)
  if M.refreshing then return end
  M.refreshing = true
  local out = cache_path()
  local cmd = "mkdir -p " .. U.shq(C.APP_DIR .. "/cache") .. " && curl -sfL --max-time 30 -o " .. U.shq(out .. ".new")
    .. " " .. U.shq(M.URL) .. " && mv -f " .. U.shq(out .. ".new") .. " " .. U.shq(out)
  require("core.shjob").start({ cmd }, function(res)
    M.refreshing = false
    local ok = res and res[1] and res[1].rc == 0
    if ok then
      local d = parse(U.read_file(out))
      if d then M._idx = d else os.remove(out) end
    end
    if cb then cb(ok) end
  end)
end

--- totais do indice: n, tamanho estimado (OGG), download (MP3), duracao (s)
function M.totals(idx)
  local n, size, dl, dur = 0, 0, 0, 0
  for _, t in ipairs((idx or {}).tracks or {}) do
    n = n + 1
    size = size + (tonumber(t.size) or 0)
    dl = dl + (tonumber(t.mp3_size) or 0)
    dur = dur + (tonumber(t.duration) or 0)
  end
  return n, size, dl, dur
end

--- estado instalado: { tracks = {id = arquivo}, mode = "only"|"knulli", knulli = {...} }
function M.state()
  local t = U.read_file(M.DEST .. "/" .. M.FOLDER .. "/.knulli-port-hub.json")
  local ok, d = pcall(json.decode, t or "")
  d = ok and type(d) == "table" and d or {}
  d.tracks = type(d.tracks) == "table" and d.tracks or {}
  d.knulli = type(d.knulli) == "table" and d.knulli or {}
  d.count = 0
  for id, f in pairs(d.tracks) do
    if U.file_size(M.DEST .. "/" .. M.FOLDER .. "/" .. tostring(f)) then d.count = d.count + 1 else d.tracks[id] = nil end
  end
  return d
end

local function script() return os.getenv("PORTHUB_MUSICPACK_PY") or (C.APP_DIR .. "/bin/musicpack.py") end

--- arquivo do indice para o script (o cache ou a copia embutida gravada em tmp)
local function index_file()
  if U.file_size(cache_path()) then return cache_path() end
  local p = tmp("knulli_music.json")
  U.exec_ok("mkdir -p " .. U.shq(C.APP_DIR .. "/tmp"))
  local t = love.filesystem.read("catalog/knulli_music.json")
  if t and U.write_file(p, t) then return p end
  return nil
end

function M.log_path(action) return tmp("musicpack-" .. action .. ".log") end

--- comeca instalar (mode "only"|"knulli") ou remover. cb(ok, saida, rc)
function M.start(action, mode, cb)
  if M.job then return false, L("Já existe uma operação do pacote de músicas em andamento.") end
  U.exec_ok("mkdir -p " .. U.shq(C.APP_DIR .. "/tmp"))
  local j = { action = action, mode = mode, progress = tmp("musicpack.progress"), cancel = tmp("musicpack.cancel"),
    t0 = os.time() }
  os.remove(j.progress); os.remove(j.cancel)
  local log = M.log_path(action)
  local cmd = "python3 -I " .. U.shq(script()) .. " " .. action .. " --dest " .. U.shq(M.DEST)
  if action == "install" then
    local idx = index_file()
    if not idx then return false, L("Índice do pacote de músicas não encontrado.") end
    cmd = cmd .. " --index " .. U.shq(idx) .. " --mode " .. (mode == "knulli" and "knulli" or "only")
      .. " --progress " .. U.shq(j.progress) .. " --cancel " .. U.shq(j.cancel)
  end
  cmd = cmd .. " > " .. U.shq(log) .. " 2>&1; rc=$?; grep -v '^STEP\\|^TRACK' " .. U.shq(log) .. " | tail -n 8; exit $rc"
  M.job = j
  require("core.shjob").start({ cmd }, function(res, err)
    M.job = nil
    local r = res and res[1]
    if cb then cb(r and r.rc == 0, r and r.out or tostring(err or "?"), r and r.rc) end
  end)
  return true
end

--- pede para parar (o script para no meio do download ou entre faixas)
function M.cancel()
  if M.job and M.job.cancel then U.write_file(M.job.cancel, "1"); M.job.cancelling = true end
end

--- andamento: { i, n, title, phase = download|convert|knulli|done, got, size, ok, fail, skip }
function M.progress()
  local j = M.job
  if not j or not j.progress then return nil end
  local ok, d = pcall(json.decode, U.read_file(j.progress) or "")
  return ok and type(d) == "table" and d or nil
end

--- quantas musicas do proprio Knulli existem (para a opcao "junto")
function M.knulli_count()
  local s = U.capture("ls /usr/share/knulli/music 2>/dev/null | grep -ci '\\.\\(ogg\\|mp3\\)$'")
  return tonumber(s and s:match("%d+")) or 0
end

--- texto dos creditos (para mostrar no app)
function M.credits_text(idx)
  local t = { L("Músicas: OverClocked ReMix (ocremix.org) — arranjos de fãs distribuídos gratuitamente. Os arranjos pertencem aos seus artistas; as composições originais, aos seus donos."), "" }
  for i, tr in ipairs((idx or {}).tracks or {}) do
    t[#t + 1] = string.format("%02d. %s — \"%s\"", i, tostring(tr.game or ""), tostring(tr.title or ""))
    t[#t + 1] = "    " .. table.concat(type(tr.artists) == "table" and tr.artists or {}, ", ") .. "  •  " .. tostring(tr.page or "")
  end
  return table.concat(t, "\n")
end

return M
