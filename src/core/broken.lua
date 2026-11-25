-- =============================================================================
--  Knulli Port Hub: itens do catalogo com download quebrado
--
--  Duas origens de marca, o mesmo tratamento:
--   - local: o download de um item falhou por resposta do SERVIDOR ou do PACOTE
--       link    = HTTP 403/404/410 ou pagina HTML no lugar do arquivo
--       package = nao e ZIP/RAR/7z/TAR, ou sem .sh na raiz depois de extrair
--     Falha de rede do proprio aparelho (sem internet, timeout, DNS, conexao)
--     nunca marca nada.
--   - catalogo: campo "broken" no knulli-catalog.json (vale para todos)
--       "broken": { "reason": "link"|"package", "note": "...", "url": "<url que falhou>",
--                   "size": 123, "etag": "...", "last_modified": "...", "since": "AAAA-MM-DD" }
--
--  Itens marcados ficam fora das listas, da busca e da Central (Configuracoes >
--  Downloads > "Mostrar itens com download quebrado" mostra de novo). A marca some
--  sozinha quando:
--   - a URL do item no catalogo muda (link corrigido na origem);
--   - a reverificacao (1x por dia por item, em segundo plano, fetch.sh probe:
--     so 1 KB pedido com Range) mostra que voltou:
--       link    -> responde 200/206 com algo que nao e pagina HTML (assinatura
--                  ZIP/RAR/7z/gzip/xz/bz2/tar ou Content-Type de arquivo)
--       package -> o arquivo mudou: tamanho (ou ETag / Last-Modified, quando o
--                  tamanho nao da para comparar) diferente do que falhou
--   - o usuario reativa na lista "Itens escondidos".
--  Arquivo: broken_items.json (pasta de dados do LOVE)
--    { items = { [id] = { id, name, kind, code, http, detail, url, date, t, size,
--                         etag, last_modified, checked, last } },
--      ok = { [id] = { url, since, t, by = "check"|"user" } } }  -- marca do catalogo desfeita aqui
-- =============================================================================
local L = require("lib.i18n").L
local json = require("lib.json")
local U = require("lib.util")
local C = require("config")
local Prefs = require("core.prefs")

local B = { data = nil, checking = false, restored = {}, session_checked = false }
B.FILE = "broken_items.json"
B.CHECK_EVERY = 24 * 3600

local function str(v) return type(v) == "string" and v or (type(v) == "number" and tostring(v) or nil) end

function B.load()
  local ok, t = pcall(love.filesystem.read, B.FILE)
  local d = ok and t and json.decode(t)
  if type(d) ~= "table" then d = {} end
  if type(d.items) ~= "table" then d.items = {} end
  if type(d.ok) ~= "table" then d.ok = {} end
  B.data = d
  return d
end

local function D() return B.data or B.load() end

function B.save()
  pcall(love.filesystem.write, B.FILE, json.encode(D()))
end

--- mostrar itens com download quebrado (Configuracoes > Downloads)
function B.show_all() return Prefs.get("show_broken") == "1" end
function B.set_show_all(v) Prefs.set("show_broken", v and "1" or "0") end

-- ---------------------------------------------------------------------------
-- Classificacao da falha (installer.lua, mensagem "error" da thread)
local LINK_HTTP = { [403] = true, [404] = true, [410] = true }

--- devolve kind ("link"|"package"), http ou nil (nao marca)
function B.classify(code, detail)
  detail = tostring(detail or "")
  if code == "http_error" then
    -- curl -f: "The requested URL returned error: 403"
    local http = tonumber(detail:match("(%d%d%d)%s*$") or detail:match("error:?%s*(%d%d%d)") or "")
    if http and LINK_HTTP[http] then return "link", http end
    return nil
  elseif code == "not_zip" then
    -- pagina HTML no lugar do arquivo (site de compartilhamento, aviso de remocao...)
    local low = detail:lower()
    if detail == "desconhecido" or low:find("json") then return "package" end
    return "link"
  elseif code == "no_script" or code == "empty_pkg" then
    return "package"
  end
  return nil
end

local function reason_text(m)
  if m.kind == "link" then
    if m.http then return string.format(require("lib.i18n").tr(L("Link quebrado (o servidor respondeu %d)")), m.http) end
    return L("Link quebrado (o servidor mandou uma página no lugar do arquivo)")
  end
  if m.code == "no_script" then return L("Pacote inválido (sem script .sh na raiz)") end
  if m.code == "empty_pkg" then return L("Pacote inválido (sem arquivos de port)") end
  return L("Pacote inválido (não é ZIP, RAR, 7z ou TAR)")
end
B.reason_text = reason_text

--- marca local depois da falha. p = port, j = job do instalador. true se marcou
function B.on_install_error(p, code, detail, info)
  if not (C.KNULLI and p and p.id and p.download_url and p.download_url ~= "") then return false end
  if p.is_local or p.builtin then return false end
  local kind, http = B.classify(code, detail)
  if not kind then return false end
  local d = D()
  info = info or {}
  d.items[p.id] = { id = p.id, name = p.name, kind = kind, code = code, http = http,
    detail = U.safe_utf8(tostring(detail or "")):sub(1, 120), url = p.download_url,
    date = os.date("%Y-%m-%d"), t = os.time(), size = tonumber(info.size), checked = os.time() }
  d.ok[p.id] = nil
  B.save()
  U.log("download quebrado: " .. p.id .. " escondido (" .. kind .. ", " .. tostring(code) .. " " .. tostring(detail) .. ")")
  -- pacote invalido: guarda ETag/Last-Modified/tamanho do servidor para saber,
  -- na reverificacao, se o arquivo mudou (sem baixar tudo de novo)
  if kind == "package" then
    B.probe_list({ { id = p.id, url = p.download_url } }, function(res)
      local r, m = res[1], D().items[p.id]
      if not (r and m and m.url == p.download_url) then return end
      if r.status == 200 or r.status == 206 then
        m.etag = r.etag; m.last_modified = r.lastmod
        m.size = r.total or m.size
        B.save()
      end
    end)
  end
  return true
end

--- texto que vai junto da mensagem de erro logo apos a falha
function B.hidden_note()
  return L("\n\nEste item foi escondido da Central porque o download não funciona. Para ver ou reativar: Configurações > Downloads > Itens escondidos. Se o link voltar a funcionar, ele reaparece sozinho.")
end

-- ---------------------------------------------------------------------------
-- Estado efetivo de um port (depois de normalizado pelo catalogo)
--- marca do catalogo (p.broken) que ainda vale para a URL atual
local function catalog_mark(p)
  local b = p.broken
  if type(b) ~= "table" then return nil end
  if b.url and b.url ~= "" and b.url ~= p.download_url then return nil end   -- link trocado na origem
  local ok = D().ok[p.id]
  if ok and ok.url == p.download_url and (ok.since or "") == (b.since or "") then return nil end
  return { id = p.id, name = p.name, kind = b.reason == "package" and "package" or "link",
    code = b.code or (b.reason == "package" and "package" or nil), http = tonumber(b.http), note = b.note,
    url = p.download_url, date = b.since, size = tonumber(b.size), etag = b.etag,
    last_modified = b.last_modified, catalog = true }
end

--- marca efetiva (local ou do catalogo) ou nil. Limpa a local se a URL mudou.
function B.mark(p)
  if not (C.KNULLI and p and p.id) then return nil end
  local d = D()
  local m = d.items[p.id]
  if m and m.url ~= p.download_url then
    d.items[p.id] = nil
    B.dirty = true
    U.log("download quebrado: " .. p.id .. " voltou (URL do catálogo mudou)")
    m = nil
  end
  return m or catalog_mark(p)
end

--- separa a lista do catalogo: visiveis + escondidos { {port=, mark=} }
--- installed(p) -> true: ports instalados pelo hub nunca somem
function B.split(ports, installed)
  if not C.KNULLI then return ports, {} end
  local show = B.show_all()
  local vis, hid = {}, {}
  for _, p in ipairs(ports) do
    local m = B.mark(p)
    if m then
      p.broken_mark = m
      hid[#hid + 1] = { port = p, mark = m }
      if show or (installed and installed(p)) then vis[#vis + 1] = p end
    else
      p.broken_mark = nil
      vis[#vis + 1] = p
    end
  end
  if B.dirty then B.dirty = nil; B.save() end
  return vis, hid
end

--- reativar (usuario ou reverificacao). by = "user" | "check"
function B.clear(p, by)
  local d = D()
  local m = p.broken_mark or B.mark(p)
  d.items[p.id] = nil
  d.items["@" .. p.id] = nil
  if type(p.broken) == "table" and m and m.catalog then
    d.ok[p.id] = { url = p.download_url, since = p.broken.since or "", t = os.time(), by = by or "user" }
  end
  B.save()
  p.broken_mark = nil
end

-- ---------------------------------------------------------------------------
-- Reverificacao
--- interpreta a saida do "fetch.sh probe"
function B.parse_probe(out)
  local r = {}
  for line in tostring(out or ""):gmatch("[^\n]+") do
    local k, v = line:match("^(%u+)=(.*)$")
    if k then r[k] = v end
  end
  local res = { rc = tonumber(r.RC), status = tonumber(r.STATUS), ctype = (r.CTYPE or ""):lower(),
    len = tonumber(r.LEN), etag = (r.ETAG or "") ~= "" and r.ETAG or nil,
    lastmod = (r.LASTMOD or "") ~= "" and r.LASTMOD or nil, sig = (r.SIG or ""):lower(), html = r.HTML == "1" }
  local tot = (r.RANGE or ""):match("/(%d+)%s*$")
  res.total = tonumber(tot or "") or ((res.status == 200) and res.len or nil)
  return res
end

local ARCH_SIG = { "^504b0304", "^504b0506", "^504b0708", "^526172211a07", "^377abcaf271c", "^1f8b", "^fd377a585a00", "^425a68" }
local ARCH_CT = { "zip", "rar", "7z", "x%-tar", "gzip", "x%-xz", "bzip", "octet%-stream", "x%-compressed", "binary" }

local function is_html(r)
  return r.html or r.ctype:find("text/html", 1, true) ~= nil
end
local function looks_archive(r)
  for _, s in ipairs(ARCH_SIG) do if r.sig:find(s) then return true end end
  for _, s in ipairs(ARCH_CT) do if r.ctype:find(s) then return true end end
  return false
end

--- decide com a resposta da reverificacao: "ok" (voltou) | "broken" | "net" (sem resposta)
function B.judge(m, r)
  if not r or not r.status or r.status == 0 then return "net" end
  -- 63 = --max-filesize cortou (servidor ignorou o Range); os cabecalhos valem
  if r.rc and r.rc ~= 0 and r.rc ~= 63 and r.rc ~= 23 then return "net" end
  if r.status ~= 200 and r.status ~= 206 then return "broken" end
  if is_html(r) then return "broken" end
  if m.kind == "link" then
    return looks_archive(r) and "ok" or "broken"
  end
  -- pacote invalido: so volta se o arquivo mudou
  if m.size and r.total then return (m.size ~= r.total) and "ok" or "broken" end
  if m.etag and r.etag then return (m.etag ~= r.etag) and "ok" or "broken" end
  if m.last_modified and r.lastmod then return (m.last_modified ~= r.lastmod) and "ok" or "broken" end
  return "broken"
end

--- roda o probe para { {id=, url=} } em segundo plano; cb(results) na mesma ordem
function B.probe_list(list, cb)
  local cmds = {}
  local tmp = C.TMP_DIR
  for _, it in ipairs(list) do
    cmds[#cmds + 1] = "sh " .. U.shq(C.FETCH_SH) .. " probe " .. U.shq(it.url) .. " " .. U.shq(tmp) .. " 2>/dev/null"
  end
  if #cmds == 0 then if cb then cb({}) end; return end
  require("core.shjob").start(cmds, function(results)
    local out = {}
    for i = 1, #list do
      local rr = results and results[i]
      out[i] = rr and B.parse_probe(rr.out) or nil
    end
    if cb then cb(out) end
  end)
end

local function last_checked(m)
  if m.catalog then
    local s = D().items["@" .. m.id]
    return s and s.checked
  end
  return m.checked
end
B.last_checked = last_checked

local function set_checked(m, res, verdict)
  local d = D()
  local rec
  if m.catalog then
    rec = d.items["@" .. m.id] or { id = m.id, shadow = true }
    d.items["@" .. m.id] = rec
  else
    rec = d.items[m.id]
  end
  if not rec then return end
  rec.checked = os.time()
  rec.last = verdict == "broken" and (res and res.status and ("HTTP " .. res.status) or "?") or verdict
end

--- reverifica os itens escondidos. hidden = { {port=, mark=} }; force = ignora o limite de 1x/dia
--- on_done(restored = { port, ... }, checked_n, net_n)
function B.recheck(hidden, force, on_done)
  if B.checking then return false end
  local todo = {}
  local now = os.time()
  for _, h in ipairs(hidden or {}) do
    local lc = last_checked(h.mark)
    if force or not lc or now - lc >= B.CHECK_EVERY then
      todo[#todo + 1] = h
    end
  end
  if #todo == 0 then if on_done then on_done({}, 0, 0) end; return true end
  B.checking = true
  local list = {}
  for _, h in ipairs(todo) do list[#list + 1] = { id = h.port.id, url = h.port.download_url } end
  B.probe_list(list, function(res)
    B.checking = false
    local restored, nchk, nnet = {}, 0, 0
    for i, h in ipairs(todo) do
      local r = res[i]
      local v = B.judge(h.mark, r)
      U.log("download quebrado: reverificação " .. h.port.id .. " -> " .. v
        .. (r and r.status and (" (HTTP " .. r.status .. ", " .. (r.ctype or "") .. ")") or ""))
      if v == "net" then
        nnet = nnet + 1
      else
        nchk = nchk + 1
        if v == "ok" then
          B.clear(h.port, "check")
          restored[#restored + 1] = h.port
          B.restored[#B.restored + 1] = h.port.name
        else
          set_checked(h.mark, r, v)
        end
      end
    end
    B.save()
    if on_done then on_done(restored, nchk, nnet) end
  end)
  return true
end

return B
