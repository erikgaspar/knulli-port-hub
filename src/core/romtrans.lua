-- =============================================================================
--  Traducoes de ROMs (so Knulli) - logica
--
--  1. procurar : baixa o indice (knulli-translations.json; cache + copia
--                embutida), calcula os hashes das ROMs dos sistemas do indice
--                (bin/romtrans_patch.py scan; cache por caminho+tamanho+mtime)
--                e cruza: sha1 > md5 > crc32+tamanho. ROM .zip: CRC32 e tamanho
--                do diretorio central; sha1/md5 so quando o tamanho bate.
--  2. traduzir : baixa o patch, extrai (zip/7z), confere o hash de novo, tira o
--                header SMC se o patch pede a ROM sem header, aplica (IPS, BPS,
--                UPS, PPF, APS N64, xdelta), confere o resultado, recompacta o
--                .zip (mesmo nome), move a original para o backup e grava a
--                traduzida no lugar (mesmo nome: saves e imagens continuam).
--                O <name> no gamelist ganha " (PT-BR)" e o registro fica em
--                <APP_DIR>/conf/romtrans.json.
--  3. desfazer : devolve a original do backup e tira o " (PT-BR)".
--
--  As operacoes demoradas rodam em threads/romtrans_thread.lua (M.run). As
--  funcoes M.op_* tambem podem ser chamadas direto (testes).
--  Este modulo nao depende de love.* nem de config na carga (roda na thread).
-- =============================================================================
local U = require("lib.util")
local json = require("lib.json")
local LT = require("core.libtools")   -- so parse/get/set/serialize do gamelist

local M = {}

M.DEFAULT_URL = "https://raw.githubusercontent.com/erikgaspar/knulli-port-hub/main/knulli-translations.json"
M.SUFFIX = " (PT-BR)"
M.MAX_PATCH = 256 * 1024 * 1024
M.MAXFULL = 64 * 1024 * 1024       -- acima disto, so hash se o tamanho bater com o indice

M.cfg = {
  root = "/userdata/roms",
  backup_dir = "/userdata/backups/knulli-port-hub/roms-originais",
  gl_backup_dir = "/tmp/porthub-backups/gamelists",
  cache_dir = "/tmp/porthub-cache",
  conf_dir = "/tmp/porthub-conf",
  tmp_dir = "/tmp",
  py = "romtrans_patch.py",
  python = "python3",
  sevenz = "7zzs",
  index_url = M.DEFAULT_URL,
  embedded = nil,                   -- texto da copia embutida (lido pelo app)
}
function M.setup(cfg)
  for k, v in pairs(cfg or {}) do M.cfg[k] = v end
end

-- ganchos de progresso/cancelamento (a thread troca)
M.progress = function(done, total, text) end
M.cancelled = function() return false end

-------------------------------------------------------------------------------
-- utilitarios
-------------------------------------------------------------------------------
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end
local function base_of(p) return (p:match("([^/]+)$") or p) end
local function dir_of(p) return p:match("^(.*)/[^/]*$") or "." end
local function stem(p) return (base_of(p):gsub("%.[^.]+$", "")) end
local function lower(s) return (s or ""):lower() end

local function fsize(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:seek("end")
  f:close()
  return s
end
M.fsize = fsize

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close(); return true end
  return false
end

local function sh_ok(cmd)
  local r = os.execute(cmd .. " >/dev/null 2>&1")
  return r == 0 or r == true
end
local function mkdir_p(d) return sh_ok("mkdir -p " .. U.shq(d)) end

--- roda um comando; devolve saida (stdout+stderr) e codigo
local function run(cmd)
  local out = U.capture(cmd .. " 2>&1; echo \"__rc=$?\"") or ""
  local rc = tonumber(out:match("__rc=(%d+)%s*$")) or -1
  return (out:gsub("__rc=%d+%s*$", "")), rc
end
M.run_cmd = run

local function py_cmd(args)
  return M.cfg.python .. " -I " .. U.shq(M.cfg.py) .. " " .. args
end

local function py(args)
  local out, rc = run(py_cmd(args))
  if rc ~= 0 then
    local e = out:match("ERRO: ([^\n]+)") or trim(out):sub(-300)
    if rc == 127 or out:find("not found", 1, true) and not out:find("ERRO", 1, true) then
      e = "python3 não encontrado (" .. trim(out):sub(1, 120) .. ")"
    end
    return nil, e ~= "" and e or ("código " .. rc)
  end
  return out
end

local function q(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = U.shq(select(i, ...)) end
  return table.concat(t, " ")
end

--- hashes de um arquivo { size, crc32, md5, sha1, h512 = {...} }
function M.hash(path)
  local out, err = py("hash " .. U.shq(path))
  if not out then return nil, err end
  local line = out:match("(%b{})")
  local ok, h = pcall(json.decode, line or "")
  if not ok or type(h) ~= "table" then return nil, "hash: resposta inválida" end
  if h.error then return nil, h.error end
  return h
end

--- espaco livre (KB) na particao de `path` (sobe ate achar uma pasta que existe)
function M.free_kb(path)
  local p = path
  for _ = 1, 12 do
    if exists(p) or sh_ok("test -d " .. U.shq(p)) then break end
    p = dir_of(p)
  end
  local out = U.capture("df -Pk " .. U.shq(p) .. " 2>/dev/null | tail -1") or ""
  return tonumber(out:match("^%S+%s+%d+%s+%d+%s+(%d+)"))
end

local function need_space(path, bytes, what)
  local free = M.free_kb(path)
  local want = math.ceil(bytes / 1024) + 2048
  if free and free < want then
    error(string.format("espaço insuficiente em %s para %s: precisa de %s, há %s", path, what,
      U.format_bytes(want * 1024), U.format_bytes(free * 1024)), 0)
  end
end

--- move (rename; se for outra particao: confere espaco, copia, confere, apaga)
function M.move(src, dst)
  local ok = os.rename(src, dst)
  if ok then return true end
  local sz = fsize(src)
  if not sz then return nil, "não encontrado: " .. src end
  local free = M.free_kb(dir_of(dst))
  if free and free < math.ceil(sz / 1024) + 2048 then
    return nil, "espaço insuficiente em " .. dir_of(dst)
  end
  if not sh_ok("cp -p " .. q(src, dst)) or fsize(dst) ~= sz then
    os.remove(dst)
    return nil, "não foi possível copiar para " .. dst
  end
  os.remove(src)
  return true
end

-------------------------------------------------------------------------------
-- download (http/https pelo curl; file:// ou caminho local por copia)
-------------------------------------------------------------------------------
function M.download(url, out, timeout, max_bytes)
  url = trim(url)
  local loc = url:match("^file://(.+)$") or (url:sub(1, 1) == "/" and url) or nil
  if loc then
    if not exists(loc) then return nil, "arquivo não encontrado: " .. loc end
    if not sh_ok("cp " .. q(loc, out)) then return nil, "não foi possível copiar " .. loc end
  else
    if not url:match("^https?://") then return nil, "endereço inválido: " .. url end
    local cmd = "curl -sSL --connect-timeout 15 -m " .. (timeout or 120) .. " -A 'KnulliPortHub'"
      .. (max_bytes and (" --max-filesize " .. max_bytes) or "")
      .. " -o " .. U.shq(out) .. " -w 'HTTP=%{http_code}' " .. U.shq(url)
    local s, rc = run(cmd)
    local code = tonumber(s:match("HTTP=(%d+)")) or 0
    if rc ~= 0 or code ~= 200 then
      os.remove(out)
      if code ~= 0 and code ~= 200 then return nil, "o servidor respondeu HTTP " .. code end
      if rc == 63 then return nil, "arquivo maior que o limite" end
      return nil, "falha no download (curl " .. rc .. "): " .. trim(s:gsub("HTTP=%d+", "")):sub(1, 160)
    end
  end
  local sz = fsize(out)
  if not sz or sz == 0 then os.remove(out); return nil, "download vazio" end
  if max_bytes and sz > max_bytes then os.remove(out); return nil, "arquivo maior que o limite" end
  return true, sz
end

-------------------------------------------------------------------------------
-- indice
-------------------------------------------------------------------------------
local HASH_KEYS = { "crc32", "md5", "sha1" }

local function norm_hashes(h)
  if type(h) ~= "table" then return nil end
  local r = {}
  for _, k in ipairs(HASH_KEYS) do
    local v = h[k]
    if type(v) == "number" then v = string.format("%08x", v) end
    if type(v) == "string" and v ~= "" then
      v = lower(trim(v)):gsub("^0x", "")
      if k == "crc32" then v = string.rep("0", 8 - #v) .. v end
      r[k] = v
    end
  end
  r.size = tonumber(h.size)
  r.name = h.name
  r.header = lower(h.header or "none")
  if not (r.crc32 or r.md5 or r.sha1) then return nil end
  return r
end
M.norm_hashes = norm_hashes

local FORMATS = { ips = true, bps = true, ups = true, ppf = true, aps = true, xdelta = true }

function M.parse_index(text)
  if type(text) ~= "string" or text == "" then return nil, "índice vazio" end
  local ok, d = pcall(json.decode, text)
  if not ok or type(d) ~= "table" or type(d.translations) ~= "table" then
    return nil, "índice inválido"
  end
  local list, bad = {}, 0
  for _, t in ipairs(d.translations) do
    local fmt = type(t) == "table" and lower(t.patch_format or ""):gsub("^xdelta3$", "xdelta"):gsub("^vcdiff$", "xdelta")
    local rom = type(t) == "table" and norm_hashes(t.rom)
    if type(t) == "table" and t.example == true then
      -- entrada de exemplo (copia embutida): ignorada
    elseif fmt and rom and FORMATS[fmt] and type(t.id) == "string" and type(t.system) == "string"
        and type(t.patch_url) == "string" and t.patch_url ~= "" then
      local e = {}
      for k, v in pairs(t) do e[k] = v end
      e.patch_format = fmt
      e.archive = lower(t.archive or "none")
      e.rom = rom
      e.result = norm_hashes(t.result)
      e.title = (type(t.title) == "string" and t.title ~= "") and t.title or t.id
      list[#list + 1] = e
    else
      bad = bad + 1
    end
  end
  return { format = d.format, updated = d.updated, translations = list, invalid = bad }
end

function M.index_cache_path() return M.cfg.cache_dir .. "/knulli_translations.json" end

--- indice: online -> cache -> copia embutida. Devolve idx (com .source) ou nil, erro
function M.load_index(online)
  local cache = M.index_cache_path()
  local why
  if online and M.cfg.index_url and M.cfg.index_url ~= "" then
    mkdir_p(M.cfg.cache_dir)
    local tmp = cache .. ".download"
    local ok, err = M.download(M.cfg.index_url, tmp, 40, 16 * 1024 * 1024)
    if ok then
      local idx, perr = M.parse_index(U.read_file(tmp))
      if idx then
        os.remove(cache)
        os.rename(tmp, cache)
        idx.source = "online"
        return idx
      end
      why = perr
    else
      why = err
    end
    os.remove(tmp)
  end
  local idx = M.parse_index(U.read_file(cache))
  if idx then idx.source = "cache"; idx.warn = why; return idx end
  idx = M.parse_index(M.cfg.embedded)
  if idx then idx.source = "embutido"; idx.warn = why; return idx end
  return nil, why or "índice indisponível"
end

-------------------------------------------------------------------------------
-- registro das ROMs traduzidas
-------------------------------------------------------------------------------
function M.reg_path() return M.cfg.conf_dir .. "/romtrans.json" end

function M.reg_load()
  local text = U.read_file(M.reg_path())
  local ok, d = pcall(json.decode, text or "")
  if not ok or type(d) ~= "table" or type(d.items) ~= "table" then d = { format = 1, items = {} } end
  return d
end

function M.reg_save(reg)
  mkdir_p(M.cfg.conf_dir)
  local p = M.reg_path()
  local text = json.encode(reg, true)
  local tmp = p .. ".tmp"
  if not U.write_file(tmp, text) or fsize(tmp) ~= #text then
    os.remove(tmp); return nil, "não foi possível gravar " .. p
  end
  local ok, err = os.rename(tmp, p)
  if not ok then os.remove(tmp); return nil, tostring(err) end
  return true
end

-------------------------------------------------------------------------------
-- gamelist: so o <name> da entrada muda (mesmas regras do libtools)
-------------------------------------------------------------------------------
local function gl_find(doc, rel)
  local want = rel:gsub("^%./", "")
  for _, e in ipairs(doc.entries) do
    if e.kind == "game" and e.path and e.path:gsub("^%./", "") == want then return e end
  end
end

--- nomes do gamelist de um sistema: rel -> name
function M.gl_names(sys)
  local t = {}
  local text = U.read_file(M.cfg.root .. "/" .. sys .. "/gamelist.xml")
  if not text or not text:find("<gameList", 1, true) then return t end
  for _, e in ipairs(LT.parse(text).entries) do
    if e.path then t[e.path:gsub("^%./", "")] = LT.get(e, "name") end
  end
  return t
end

--- troca o <name> com fn(nome) -> novo. Devolve ok, nome_antes, nome_depois | nil, erro
function M.gl_rename(sys, rel, fn)
  local file = M.cfg.root .. "/" .. sys .. "/gamelist.xml"
  for _ = 1, 2 do
    local text = U.read_file(file)
    if not text or not text:find("<gameList", 1, true) then return nil, "sem gamelist.xml em " .. sys end
    local doc = LT.parse(text)
    local e = gl_find(doc, rel)
    if not e then return nil, "o jogo não está no gamelist.xml" end
    local name = LT.get(e, "name") or stem(rel)
    local nn = fn(name)
    if not nn or nn == name then return true, name, name end
    -- copia de seguranca (1a vez do dia)
    local bdir = M.cfg.gl_backup_dir .. "/" .. os.date("%Y-%m-%d")
    local bfile = bdir .. "/" .. sys .. ".xml"
    if not exists(bfile) then
      if not mkdir_p(bdir) or not U.write_file(bfile, text) or fsize(bfile) ~= #text then
        return nil, "não foi possível gravar a cópia de segurança do gamelist"
      end
    end
    LT.set(doc, e, "name", nn)
    local out = LT.serialize(doc)
    -- mudou no disco desde a leitura (o EmulationStation gravou)? le de novo
    if U.read_file(file) == text then
      local tmp = file .. ".porthub.tmp"
      if not U.write_file(tmp, out) or fsize(tmp) ~= #out then
        os.remove(tmp); return nil, "gravação incompleta do gamelist (cartão cheio?)"
      end
      local ok, err = os.rename(tmp, file)
      if not ok then os.remove(tmp); return nil, tostring(err) end
      return true, name, nn
    end
  end
  return nil, "o gamelist mudou durante a operação"
end

local function add_suffix(name)
  if lower(name):find("pt%-br") then return nil end
  return name .. M.SUFFIX
end
local function del_suffix(name)
  local s = name:gsub("%s*%(PT%-BR%)%s*$", "")
  return s
end

-------------------------------------------------------------------------------
-- comparacao de hashes
-------------------------------------------------------------------------------
--- r = hashes do indice; h = hashes calculados. "sha1"/"md5"/"crc32" ou nil
function M.hash_match(r, h)
  if not r or not h then return nil end
  if r.sha1 and h.sha1 then return r.sha1 == lower(h.sha1) and "sha1" or nil end
  if r.md5 and h.md5 then return r.md5 == lower(h.md5) and "md5" or nil end
  if r.crc32 and h.crc32 then
    if r.size and h.size and r.size ~= h.size then return nil end
    return r.crc32 == lower(h.crc32) and "crc32" or nil
  end
  return nil
end

local PTBR_PATS = { "pt%-br", "pt_br", "ptbr", "%(pt%)", "%[pt%]", "tradu[cz]", "%[t%-?%+?por", "portugu" }
function M.is_ptbr(s)
  s = lower(s)
  for _, p in ipairs(PTBR_PATS) do if s:find(p) then return true end end
  return false
end

local function norm_title(s)
  s = lower(s or ""):gsub("%b()", ""):gsub("%b[]", ""):gsub("%.[%w]+$", "")
  s = s:gsub("^the%s+", ""):gsub(",%s*the%s*$", "")
  return (s:gsub("[^%w]", ""))
end
M.norm_title = norm_title

local STATUS = { complete = "completa", completa = "completa", full = "completa", ["100%"] = "completa",
  partial = "parcial", parcial = "parcial", beta = "parcial", wip = "parcial" }
function M.status_label(t)
  local s = lower(t.status or "")
  return STATUS[s] or (s ~= "" and s or "completa")
end

-------------------------------------------------------------------------------
-- 1. PROCURAR
-------------------------------------------------------------------------------
--- pedido de varredura a partir do indice
local function scan_request(idx)
  local per = {}
  for _, t in ipairs(idx.translations) do
    local s = per[t.system]
    if not s then s = { sys = t.system, sizes = {}, any_size = false, seen = {} }; per[t.system] = s end
    if t.rom.size then
      if not s.seen[t.rom.size] then s.seen[t.rom.size] = true; s.sizes[#s.sizes + 1] = t.rom.size end
    else
      s.any_size = true
    end
  end
  local systems = {}
  for _, s in pairs(per) do s.seen = nil; systems[#systems + 1] = s end
  table.sort(systems, function(a, b) return a.sys < b.sys end)
  return systems
end

--- roda o scan do python (progresso linha a linha; cancelamento por arquivo-flag)
function M.scan_files(idx)
  mkdir_p(M.cfg.cache_dir)
  mkdir_p(M.cfg.tmp_dir)
  local systems = scan_request(idx)
  local req = M.cfg.tmp_dir .. "/romtrans-scan-req.json"
  local out = M.cfg.tmp_dir .. "/romtrans-scan-out.json"
  local flag = M.cfg.tmp_dir .. "/romtrans-scan.cancel"
  os.remove(flag); os.remove(out)
  U.write_file(req, json.encode({ root = M.cfg.root, systems = systems, maxfull = M.MAXFULL,
    cache = M.cfg.cache_dir .. "/romtrans_hashes.json", cancel = flag }))
  local h = io.popen(py_cmd("scan " .. q(req, out)) .. " 2>&1")
  if not h then error("não foi possível rodar o python3", 0) end
  local other = {}
  for line in h:lines() do
    local i, n, name = line:match("^P\t(%d+)\t(%d+)\t(.*)$")
    if i then
      M.progress(tonumber(i), tonumber(n), name)
      if M.cancelled() then U.write_file(flag, "1") end
    elseif not line:match("^R\t") then
      other[#other + 1] = line
    end
  end
  h:close()
  os.remove(req)
  local ok, d = pcall(json.decode, U.read_file(out) or "")
  os.remove(out); os.remove(flag)
  if not ok or type(d) ~= "table" or type(d.files) ~= "table" then
    local msg = table.concat(other, "\n")
    error("a varredura falhou: " .. ((msg:match("ERRO: ([^\n]+)") or msg):sub(-300)), 0)
  end
  return d
end

--- candidatos de hash de cada arquivo: { h, file, inzip, header }
local function candidates(f)
  local c = {}
  local function add(h, inzip)
    if h.crc32 or h.sha1 or h.md5 then c[#c + 1] = { h = h, file = f, inzip = inzip } end
    if h.h512 then
      local hh = h.h512
      c[#c + 1] = { h = hh, file = f, inzip = inzip, header = true }
    end
  end
  if f.kind == "zip" then
    for _, e in ipairs(f.entries or {}) do add(e, e.name) end
  elseif f.kind == "file" then
    add(f)
  end
  return c
end

--- cruza o indice com os arquivos. Devolve { matches, translated, others, skipped }
function M.match(idx, scan, reg)
  reg = reg or M.reg_load()
  local by_sys = {}
  local names = {}
  local skipped = 0
  local ptbr_files = {}
  for _, f in ipairs(scan.files or {}) do
    local s = by_sys[f.sys]
    if not s then s = { files = {}, sha1 = {}, md5 = {}, crc32 = {} }; by_sys[f.sys] = s end
    names[f.sys] = names[f.sys] or M.gl_names(f.sys)
    f.name = names[f.sys][f.rel]
    local key = f.sys .. "/" .. f.rel
    if reg.items[key] then
      -- ja traduzido pelo app: fora das sugestoes
    elseif M.is_ptbr(f.rel) or (f.name and M.is_ptbr(f.name)) then
      skipped = skipped + 1
      ptbr_files[key] = true
      s.files[#s.files + 1] = f
    else
      s.files[#s.files + 1] = f
      for _, c in ipairs(candidates(f)) do
        for _, k in ipairs(HASH_KEYS) do
          local v = c.h[k] and lower(c.h[k])
          if v then
            s[k][v] = s[k][v] or {}
            table.insert(s[k][v], c)
          end
        end
      end
    end
  end

  local function lookup(s, r)
    local seen, list = {}, {}
    for _, k in ipairs(HASH_KEYS) do
      if r[k] then
        for _, c in ipairs(s[k][r[k]] or {}) do
          if not seen[c] then seen[c] = true; list[#list + 1] = c end
        end
      end
    end
    return list
  end

  local matches, translated, others = {}, {}, {}
  local ext_seen = {}
  for _, t in ipairs(idx.translations) do
    local s = by_sys[t.system]
    local found = false
    if s then
      for _, c in ipairs(lookup(s, t.rom)) do
        local how = M.hash_match(t.rom, c.h)
        if how and (not c.header or t.rom.header ~= "smc512") then
          found = true
          local f = c.file
          matches[#matches + 1] = { key = f.sys .. "/" .. f.rel .. "#" .. t.id, sys = f.sys, rel = f.rel,
            path = f.path, size = f.size, mtime = f.mtime, inzip = c.inzip, header = c.header or false,
            how = how, name = f.name or stem(f.rel), t = t, before = c.h }
        end
      end
      -- arquivo que ja e o resultado da traducao (traduzido fora do app)
      if t.result then
        for _, c in ipairs(lookup(s, t.result)) do
          local f = c.file
          local k = f.sys .. "/" .. f.rel
          if not c.header and M.hash_match(t.result, c.h) and not ext_seen[k] then
            ext_seen[k] = true
            found = true
            translated[#translated + 1] = { key = k, sys = f.sys, rel = f.rel, path = f.path, external = true,
              name = f.name or stem(f.rel), t = t }
          end
        end
      end
    end
    if not found then
      local state, similar = s and "missing" or "no_system", nil
      if s then
        local want = { norm_title(t.title), t.rom.name and norm_title(t.rom.name) or nil }
        for _, f in ipairs(s.files) do
          local n1, n2 = norm_title(f.rel:match("([^/]+)$")), f.name and norm_title(f.name) or ""
          for _, w in ipairs(want) do
            if w and #w >= 4 and (n1 == w or n2 == w or n1:find(w, 1, true) == 1 or n2:find(w, 1, true) == 1) then
              state, similar = "other_version", f.rel
              if ptbr_files[f.sys .. "/" .. f.rel] then state = "ptbr_name" end
              break
            end
          end
          if similar then break end
        end
      end
      others[#others + 1] = { key = t.system .. "#" .. t.id, t = t, state = state, similar = similar, sys = t.system }
    end
  end
  for key, rec in pairs(reg.items) do
    translated[#translated + 1] = { key = key, sys = rec.sys, rel = rec.rel, path = rec.path, rec = rec,
      name = rec.gl_name_before or stem(rec.rel or key), missing = not exists(rec.path or ""),
      backup_missing = not exists(rec.backup or "") }
  end
  local function by_name(a, b)
    local x, y = lower(a.name or a.t and a.t.title or ""), lower(b.name or b.t and b.t.title or "")
    if x ~= y then return x < y end
    return (a.key or "") < (b.key or "")
  end
  table.sort(matches, by_name)
  table.sort(translated, by_name)
  table.sort(others, function(a, b)
    local order = { other_version = 1, ptbr_name = 2, missing = 3, no_system = 4 }
    if a.state ~= b.state then return order[a.state] < order[b.state] end
    return lower(a.t.title) < lower(b.t.title)
  end)
  return { matches = matches, translated = translated, others = others, skipped = skipped }
end

function M.op_scan(p)
  M.progress(0, 0, "índice de traduções")
  local idx, err = M.load_index(p.online ~= false)
  if not idx then error(err, 0) end
  local scan = M.scan_files(idx)
  local r = M.match(idx, scan, M.reg_load())
  r.index_source = idx.source
  r.index_warn = idx.warn
  r.index_count = #idx.translations
  r.index_updated = idx.updated
  r.files = #(scan.files or {})
  r.errors = scan.errors
  r.cancelled = scan.cancelled or M.cancelled()
  return r
end

-------------------------------------------------------------------------------
-- 2. TRADUZIR
-------------------------------------------------------------------------------
local function new_workdir()
  local d = M.cfg.tmp_dir .. "/romtrans-" .. os.time() .. "-" .. math.random(100000, 999999)
  if not mkdir_p(d) then error("não foi possível criar " .. d, 0) end
  return d
end

local function inside_root(path)
  local r = M.cfg.root .. "/"
  return path and path:sub(1, #r) == r and not path:find("/%.%./") and not path:find("/%.%.$")
end

--- baixa e prepara o patch (extrai de zip/7z). Devolve o caminho do patch
function M.get_patch(t, work)
  local dl = work .. "/patch.download"
  local ok, err = M.download(t.patch_url, dl, 300, M.MAX_PATCH)
  if not ok then error("não foi possível baixar o patch: " .. tostring(err), 0) end
  local size = fsize(dl)
  if t.patch_size and tonumber(t.patch_size) and tonumber(t.patch_size) ~= size then
    error(string.format("o patch baixado tem %d bytes; o índice diz %d", size, tonumber(t.patch_size)), 0)
  end
  if t.patch_sha1 or t.patch_crc32 or t.patch_md5 then
    local ph = M.hash(dl)
    local want = norm_hashes({ sha1 = t.patch_sha1, md5 = t.patch_md5, crc32 = t.patch_crc32 })
    if not ph or not M.hash_match(want, ph) then error("o arquivo baixado não confere com o índice (hash do patch)", 0) end
  end
  if M.cancelled() then error("cancelado", 0) end
  local patch = work .. "/patch.bin"
  local arch = t.archive or "none"
  if arch == "zip" then
    local out, perr = py("pick " .. q(dl, t.patch_file or "", t.patch_format, patch))
    if not out then error("não foi possível abrir o zip do patch: " .. perr, 0) end
  elseif arch == "7z" then
    local x = work .. "/x"
    mkdir_p(x)
    local out, rc = run(U.shq(M.cfg.sevenz) .. " x -y -bd " .. U.shq("-o" .. x) .. " " .. U.shq(dl))
    if rc ~= 0 then error("não foi possível extrair o 7z do patch: " .. trim(out):sub(-160), 0) end
    local o2, perr = py("pick " .. q(x, t.patch_file or "", t.patch_format, patch))
    if not o2 then error(perr, 0) end
  elseif arch == "none" or arch == "" then
    os.rename(dl, patch)
  else
    error("tipo de arquivo do patch não suportado: " .. arch, 0)
  end
  return patch
end

function M.op_translate(p)
  local m = p.match
  local t = m and m.t
  if not t then error("nada para traduzir", 0) end
  if not inside_root(m.path) then error("caminho fora da pasta de ROMs: " .. tostring(m.path), 0) end
  local reg = M.reg_load()
  local rkey = m.sys .. "/" .. m.rel
  if reg.items[rkey] then error("este jogo já foi traduzido pelo app; desfaça antes", 0) end
  local steps = 7
  local function step(i, text) M.progress(i, steps, text) end
  local cur = fsize(m.path)
  if not cur then error("a ROM não está mais em " .. m.path, 0) end
  if cur ~= m.size then error("a ROM mudou desde a busca; procure de novo", 0) end
  local data_size = (m.before and m.before.size) or cur
  need_space(M.cfg.tmp_dir, data_size * 3 + cur, "os arquivos temporários")

  local work = new_workdir()
  local ok, res = pcall(function()
    step(1, "Baixando o patch")
    local patch = M.get_patch(t, work)
    if M.cancelled() then error("cancelado", 0) end

    step(2, "Conferindo a ROM")
    local input = m.path
    if m.inzip then
      input = work .. "/rom.in"
      local o, e = py("zipget " .. q(m.path, m.inzip, input))
      if not o then error("não foi possível ler a ROM dentro do zip: " .. e, 0) end
    end
    local h, herr = M.hash(input)
    if not h then error(herr, 0) end
    local strip = false
    if M.hash_match(t.rom, h) then
      strip = false
    elseif t.rom.header ~= "smc512" and h.h512 and M.hash_match(t.rom, h.h512) then
      strip = true
    else
      error("a ROM não confere com a versão exigida pela tradução (hash diferente)", 0)
    end
    local before = strip and h.h512 or h
    if strip then
      local noh = work .. "/rom.noh"
      local o, e = py("strip512 " .. q(input, noh))
      if not o then error(e, 0) end
      input = noh
    end
    if M.cancelled() then error("cancelado", 0) end

    step(3, "Aplicando a tradução")
    local outp = work .. "/rom.out"
    local o, e = py("apply " .. q(t.patch_format, input, patch, outp))
    if not o then error("o patch não pôde ser aplicado: " .. e, 0) end

    step(4, "Conferindo o resultado")
    local ah, aerr = M.hash(outp)
    if not ah then error(aerr, 0) end
    local verified = false
    if t.result then
      if not M.hash_match(t.result, ah) then
        error("o resultado não confere com o hash esperado pelo índice; nada foi trocado", 0)
      end
      verified = true
    end
    if M.cancelled() then error("cancelado", 0) end

    step(5, "Preparando o arquivo")
    local final = outp
    if m.inzip then
      final = work .. "/final.zip"
      local o2, e2 = py("zipput " .. q(m.path, m.inzip, outp, final))
      if not o2 then error("não foi possível recompactar o zip: " .. e2, 0) end
    end
    local fh = (final == outp) and ah or M.hash(final)
    local fb = m.inzip and M.hash(m.path) or h
    if not fh or not fb then error("não foi possível conferir os arquivos", 0) end

    step(6, "Guardando a original e gravando a traduzida")
    local bpath = M.cfg.backup_dir .. "/" .. m.sys .. "/" .. m.rel
    if exists(bpath) then bpath = bpath .. "." .. os.date("%Y%m%d-%H%M%S") end
    if not mkdir_p(dir_of(bpath)) then error("não foi possível criar " .. dir_of(bpath), 0) end
    local newp = dir_of(m.path) .. "/." .. base_of(m.path) .. ".porthub-new"
    os.remove(newp)
    local mok, merr = M.move(final, newp)
    if not mok then error(merr, 0) end
    local bok, berr = M.move(m.path, bpath)
    if not bok then os.remove(newp); error("não foi possível guardar a original: " .. tostring(berr), 0) end
    local rok, rerr = os.rename(newp, m.path)
    if not rok then
      M.move(bpath, m.path)
      os.remove(newp)
      error("não foi possível gravar a ROM traduzida: " .. tostring(rerr), 0)
    end

    step(7, "Atualizando a lista de jogos")
    local glok, gname, gnew = M.gl_rename(m.sys, m.rel, add_suffix)
    local rec = { key = rkey, sys = m.sys, rel = m.rel, path = m.path, file = base_of(m.path), id = t.id,
      title = t.title, group = t.group, version = t.version, lang = t.lang, format = t.patch_format,
      inzip = m.inzip, header_removed = strip, verified = verified,
      before = { size = before.size, crc32 = before.crc32, md5 = before.md5, sha1 = before.sha1 },
      after = { size = ah.size, crc32 = ah.crc32, md5 = ah.md5, sha1 = ah.sha1 },
      file_before = { size = fb.size, sha1 = fb.sha1 }, file_after = { size = fh.size, sha1 = fh.sha1 },
      backup = bpath, date = os.date("%Y-%m-%d %H:%M"),
      gl_name_before = glok and gname or nil, gl_name_after = glok and gnew or nil,
      gl_note = not glok and gname or nil }
    reg = M.reg_load()
    reg.items[rkey] = rec
    local sok, serr = M.reg_save(reg)
    return { ok = true, rec = rec, gl_note = not glok and gname or nil, reg_err = not sok and serr or nil }
  end)
  sh_ok("rm -rf " .. U.shq(work))
  if not ok then error(res, 0) end
  return res
end

-------------------------------------------------------------------------------
-- 3. DESFAZER
-------------------------------------------------------------------------------
function M.op_undo(p)
  local reg = M.reg_load()
  local rec = reg.items[p.key or ""]
  if not rec then error("este jogo não está no registro de traduções", 0) end
  if not inside_root(rec.path) then error("caminho fora da pasta de ROMs: " .. tostring(rec.path), 0) end
  M.progress(1, 4, "Conferindo os arquivos")
  if not exists(rec.backup or "") then error("a cópia da ROM original não está mais em " .. tostring(rec.backup), 0) end
  local bsz = fsize(rec.backup)
  if rec.file_before and rec.file_before.size and bsz ~= rec.file_before.size then
    error("a cópia da original está com tamanho diferente do registrado; nada foi mexido", 0)
  end
  local present = exists(rec.path)
  if present and not p.force then
    local h = M.hash(rec.path)
    if not h or (rec.file_after and rec.file_after.sha1 and h.sha1 ~= rec.file_after.sha1) then
      return { need_force = true, reason = "a ROM atual não é a que o app gravou (foi trocada ou o jogo gravou nela)" }
    end
  end
  M.progress(2, 4, "Devolvendo a ROM original")
  local origp = dir_of(rec.path) .. "/." .. base_of(rec.path) .. ".porthub-orig"
  local oldp = dir_of(rec.path) .. "/." .. base_of(rec.path) .. ".porthub-old"
  os.remove(origp); os.remove(oldp)
  local ok, err = M.move(rec.backup, origp)
  if not ok then error("não foi possível trazer a original de volta: " .. tostring(err), 0) end
  if present then
    local r1, e1 = os.rename(rec.path, oldp)
    if not r1 then M.move(origp, rec.backup); error(tostring(e1), 0) end
  end
  local r2, e2 = os.rename(origp, rec.path)
  if not r2 then
    if present then os.rename(oldp, rec.path) end
    M.move(origp, rec.backup)
    error(tostring(e2), 0)
  end
  os.remove(oldp)
  M.progress(3, 4, "Atualizando a lista de jogos")
  local glok, gerr = M.gl_rename(rec.sys, rec.rel, function(name)
    local s = del_suffix(name)
    return s ~= "" and s or nil
  end)
  reg = M.reg_load()
  reg.items[rec.key] = nil
  if next(reg.items) == nil then reg.items = {} end
  local sok, serr = M.reg_save(reg)
  M.progress(4, 4, "")
  return { ok = true, gl_note = not glok and gerr or nil, reg_err = not sok and serr or nil }
end

--- tira do registro um item cujo arquivo/backup sumiu (sem mexer em arquivos)
function M.forget(key)
  local reg = M.reg_load()
  reg.items[key] = nil
  return M.reg_save(reg)
end

-------------------------------------------------------------------------------
-- configuracao no app e execucao em segundo plano (so no app: love.thread)
-------------------------------------------------------------------------------
--- monta a configuracao a partir do config do app (variaveis de ambiente para testes)
function M.app_setup()
  local C = require("config")
  local root = os.getenv("PORTHUB_ROMTRANS_ROOT") or require("core.spacemgr").roms_root()
  local url = os.getenv("PORTHUB_ROMTRANS_INDEX")
  if not url or url == "" then
    url = trim(U.read_file(C.APP_DIR .. "/translations_url.txt") or "")
    if url == "" then url = M.DEFAULT_URL end
  end
  local embedded
  if love and love.filesystem then embedded = love.filesystem.read("catalog/knulli_translations.json") end
  M.setup({
    root = root,
    backup_dir = os.getenv("PORTHUB_ROMTRANS_BACKUP") or "/userdata/backups/knulli-port-hub/roms-originais",
    gl_backup_dir = C.APP_DIR .. "/backups/gamelists",
    cache_dir = C.APP_DIR .. "/cache",
    conf_dir = C.APP_DIR .. "/conf",
    tmp_dir = C.TMP_DIR,
    py = os.getenv("PORTHUB_ROMTRANS_PY") or (C.APP_DIR .. "/bin/romtrans_patch.py"),
    sevenz = C.APP_DIR .. "/bin/7zzs",
    index_url = url,
    embedded = embedded,
  })
end

M.job = nil   -- { op, status = {done,total,text}, cancel() }

function M.busy() return M.job ~= nil end

--- roda M.op_<op>(params) na thread. on_done(ok, res_ou_erro)
function M.run(op, params, on_done)
  if M.job then return nil, "ocupado" end
  local Sh = require("core.shjob")
  Sh.seq = Sh.seq + 1
  local base = "hub_romtrans_" .. Sh.seq
  local out = love.thread.getChannel(base)
  local st = love.thread.getChannel(base .. "_st")
  local ctl = love.thread.getChannel(base .. "_ctl")
  out:clear(); st:clear(); ctl:clear()
  local th = love.thread.newThread("threads/romtrans_thread.lua")
  local job = { op = op, status = { done = 0, total = 0, text = "" }, st = st, ctl = ctl }
  function job.cancel() ctl:push("cancel"); job.cancelling = true end
  function job.poll()
    local m = st:pop()
    while m do job.status = m; m = st:pop() end
    return job.status
  end
  M.job = job
  Sh.jobs[#Sh.jobs + 1] = { thread = th, ch = out, total = 1, done = 0, running = true,
    on_done = function(results, err)
      M.job = nil
      if not results then on_done(false, err or "erro interno"); return end
      on_done(results.ok, results.res)
    end }
  th:start({ out = base, st = base .. "_st", ctl = base .. "_ctl", op = op, cfg = M.cfg, params = params or {} })
  return job
end

return M
