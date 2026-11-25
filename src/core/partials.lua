-- =============================================================================
--  Downloads incompletos (retomada de downloads de ports)
--
--  A thread de instalacao (threads/install_thread.lua) deixa o arquivo parcial
--  em <tmp>/job_<slug>/download.zip.part com resume.json quando a conexao cai
--  de vez, o download e cancelado depois de avancar, ou o app e fechado no
--  meio. No proximo pedido do MESMO download (mesma URL, ETag/Last-Modified e
--  tamanho iguais) ela continua do ponto; senao apaga e baixa do zero.
--
--  Aqui (lado da interface): lista os parciais, mostra "Pausado em X%" na fila
--  e nos detalhes, conta "Downloads incompletos: N (X GB)" em Configuracoes >
--  Downloads e limpa:
--    - parciais com mais de 7 dias sem avancar;
--    - parciais de itens que sairam do catalogo (ou cujo link mudou).
--  O job em andamento nunca e tocado.
-- =============================================================================
local L = require("lib.i18n").L
local C = require("config")
local U = require("lib.util")
local json = require("lib.json")

local P = { cache = nil, pruned = false }
P.MAX_AGE = 7 * 24 * 3600

local function active_dir()
  local I = package.loaded["core.installer"]
  local j = I and I.job
  if j and not j.finished and j.port and j.port.slug then
    return C.TMP_DIR .. "/job_" .. j.port.slug
  end
end

--- varre a pasta temporaria: { {dir, slug, id, name, url, total, done, mtime, legacy}, ... }
function P.scan()
  local out = U.capture("cd " .. U.shq(C.TMP_DIR) .. " 2>/dev/null && for d in job_*; do "
    .. "f=\"$d/download.zip.part\"; [ -f \"$f\" ] || continue; "
    .. "echo \"$(wc -c < \"$f\" | tr -d ' ') $(date -r \"$f\" +%s 2>/dev/null || echo 0) $d\"; done") or ""
  local list = {}
  for line in out:gmatch("[^\n]+") do
    local size, mt, d = line:match("^(%d+)%s+(%d+)%s+(job_.+)$")
    if d then
      local dir = C.TMP_DIR .. "/" .. d
      local m = nil
      local t = U.read_file(dir .. "/resume.json")
      if t then
        local ok, v = pcall(json.decode, t)
        if ok and type(v) == "table" then m = v end
      end
      local e = { dir = dir, slug = d:sub(5), done = tonumber(size) or 0, mtime = tonumber(mt) or 0,
        legacy = m == nil }
      if m then
        e.id, e.name, e.url = m.id, m.name, m.url
        e.total = tonumber(m.total)
        e.created, e.updated, e.state = tonumber(m.created), tonumber(m.updated), m.state
      end
      list[#list + 1] = e
    end
  end
  return list
end

function P.list()
  if not P.cache then P.cache = P.scan() end
  return P.cache
end

function P.invalidate() P.cache = nil end

--- port do catalogo dono do parcial (pelo id; parcial antigo sem metadados: pelo slug)
local function port_of(e)
  local Catalog = package.loaded["core.catalog"]
  if not Catalog then return nil end
  if e.id and Catalog.by_id and Catalog.by_id[e.id] then return Catalog.by_id[e.id] end
  for _, p in ipairs(Catalog.hidden or {}) do
    local pp = p.port or p
    if pp.id == e.id or (e.legacy and pp.slug == e.slug) then return pp end
  end
  if e.legacy then
    for _, p in ipairs(Catalog.ports or {}) do if p.slug == e.slug then return p end end
  end
  return nil
end
P.port_of = port_of

--- parcial que vale para este port (mesma URL do catalogo) ou nil
function P.for_port(p)
  if not (p and p.slug) then return nil end
  local ad = active_dir()
  for _, e in ipairs(P.list()) do
    if e.slug == p.slug and e.dir ~= ad then
      if e.legacy or not e.url or e.url == p.download_url then return e end
    end
  end
  return nil
end

--- porcentagem (nil quando o total nao e conhecido)
function P.pct(e)
  if e and e.total and e.total > 0 then
    return math.floor(U.clamp(e.done / e.total, 0, 1) * 100)
  end
  return nil
end

function P.summary()
  local n, bytes = 0, 0
  local ad = active_dir()
  for _, e in ipairs(P.list()) do
    if e.dir ~= ad then n = n + 1; bytes = bytes + (e.done or 0) end
  end
  return n, bytes
end

function P.remove(e)
  if not e or not e.dir or e.dir == active_dir() then return false end
  -- so pastas de job dentro da pasta temporaria do hub
  if not e.dir:find("^" .. C.TMP_DIR:gsub("%p", "%%%0") .. "/job_[^/]+$") then return false end
  U.exec_ok("rm -rf " .. U.shq(e.dir))
  U.log("download incompleto apagado:", e.slug, e.done, "bytes")
  P.invalidate()
  return true
end

function P.clear_all()
  local n, bytes = 0, 0
  for _, e in ipairs(P.list()) do
    local sz = e.done or 0
    if P.remove(e) then n = n + 1; bytes = bytes + sz end
  end
  P.invalidate()
  return n, bytes
end

--- motivo para apagar sozinho (ou nil). catalog_ok = catalogo carregado
function P.stale(e, now, catalog_ok)
  local last = math.max(e.mtime or 0, e.updated or 0)
  if last > 0 and now - last > P.MAX_AGE then return "mais de 7 dias" end
  -- port do PortMaster com o catalogo dele ainda nao carregado: nao da para saber
  local PMC = package.loaded["core.pmcatalog"]
  if catalog_ok and tostring(e.id or e.slug or ""):find("^pm%-") and not (PMC and PMC.data) then catalog_ok = false end
  if catalog_ok then
    local p = port_of(e)
    if not p then return "saiu do catalogo" end
    if e.url and p.download_url and e.url ~= p.download_url then return "o link mudou" end
  end
  return nil
end

--- textos da queda de conexao durante o download (janela de progresso e
--- fila): titulo, detalhe; nil quando a conexao esta normal
function P.retry_text(j)
  local r = j and j.net_retry
  if not r then return nil end
  local I18N = require("lib.i18n")
  local tot = r.total or j.total
  local pct = (tot and tot > 0) and math.floor(U.clamp((r.done or j.done or 0) / tot, 0, 1) * 100) or nil
  local title = pct and string.format(I18N.tr(L("Conexão caiu — continuando de %d%%")), pct)
    or I18N.tr(L("Conexão caiu — continuando de onde parou"))
  local detail
  if r.resuming then
    detail = string.format(I18N.tr(L("Tentativa %d de %d: reconectando...")), r.attempt or 1, r.max or 5)
  else
    local left = math.max(0, math.ceil((r.wait or 0) - (love.timer.getTime() - (r.t or 0))))
    detail = string.format(I18N.tr(L("Nova tentativa em %d s (%d de %d)")), left, r.attempt or 1, r.max or 5)
  end
  return title, detail
end

--- "Pausado em X% — continuar"
function P.paused_label(e)
  local I18N = require("lib.i18n")
  local pct = P.pct(e)
  if pct then return string.format(I18N.tr(L("Pausado em %d%% — continuar")), pct) end
  return string.format(I18N.tr(L("Pausado (%s baixados) — continuar")), U.format_bytes(e.done or 0))
end

--- limpeza automatica (1x por sessao, depois do catalogo carregado)
function P.prune()
  local Catalog = package.loaded["core.catalog"]
  local catalog_ok = Catalog and #(Catalog.ports or {}) > 20
  local now = os.time()
  local n = 0
  P.invalidate()
  for _, e in ipairs(P.list()) do
    local why = P.stale(e, now, catalog_ok)
    if why then
      U.log("download incompleto de " .. tostring(e.name or e.slug) .. " apagado: " .. why)
      if P.remove(e) then n = n + 1 end
    end
  end
  P.invalidate()
  return n
end

return P
