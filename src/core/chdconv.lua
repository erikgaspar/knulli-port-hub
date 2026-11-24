-- =============================================================================
--  Converter para CHD (so Knulli) - logica
--
--  1. chdman  : o Knulli nao traz o chdman. bin/chdman_install.py baixa os .deb
--               oficiais do Debian 12 (mame-tools + libutf8proc2, lista e SHA256
--               em bin/chdman_debs.json) e instala em
--               /userdata/system/knulli-port-hub/tools/chdman (chdman.sh).
--  2. procurar: sistemas cujo es_systems aceita .chd (es_systems.cfg + overrides
--               es_systems_*.cfg); candidatos .cue (+ .bin que ele cita), .gdi
--               (+ trilhas) e .iso; .pbp/.cso e .iso do PSP: "nao suportado".
--  3. converter (um por vez, cancelavel): confere o espaco (75% do original +
--               64 MB), "nice -n 10 chdman createcd" para um temporario
--               <Jogo>.porthub-tmp.chd, "chdman verify", troca o nome para
--               <Jogo>.chd, atualiza os .m3u que citavam o original e o <path>
--               do gamelist (so essa tag; mesmo padrao do libtools: .tmp + rename,
--               copia do dia, nao grava se o arquivo mudou no disco) e SO ENTAO
--               apaga o original e os arquivos que ele cita (nada mais).
--               Qualquer falha: apaga o .chd e devolve os .m3u; originais intactos.
--               Registro: <APP_DIR>/conf/chdconv.json.
--
--  PSP: o PPSSPP 1.19 do Knulli le .chd, mas so no formato DVD (createdvd), que
--  o chdman 0.251 do Debian 12 nao tem; por isso .iso do PSP fica "nao suportado".
--
--  As operacoes demoradas rodam em threads/chdconv_thread.lua (M.run). As
--  funcoes M.op_* tambem podem ser chamadas direto (testes).
--  Este modulo nao depende de love.* nem de config na carga (roda na thread).
-- =============================================================================
local U = require("lib.util")
local json = require("lib.json")
local LT = require("core.libtools")   -- gamelist (parse/find/set/save) e es_systems

local M = {}

M.TOOL_DIR = "/userdata/system/knulli-port-hub/tools/chdman"

M.cfg = {
  root = "/userdata/roms",
  tool_dir = M.TOOL_DIR,
  installer = "chdman_install.py",
  manifest = "chdman_debs.json",
  python = "python3",
  conf_dir = "/tmp/porthub-conf",
  gl_backup_dir = "/tmp/porthub-backups/gamelists",
  es_systems = { "/usr/share/emulationstation/es_systems.cfg" },
  es_systems_glob = "/userdata/system/configs/emulationstation/es_systems_*.cfg",
  fake_free_kb = nil,     -- testes: espaco livre simulado (KB)
  nice = 10,
}
function M.setup(cfg)
  for k, v in pairs(cfg or {}) do M.cfg[k] = v end
end

-- ganchos de progresso/cancelamento (a thread troca). progress recebe uma tabela:
-- { phase=, index=, count=, name=, pct= (0-100 do jogo), done=, total= (bytes ponderados) }
M.progress = function(info) end
M.cancelled = function() return false end

-- estimativas (o resultado real depende do jogo: trilhas de audio comprimem menos)
M.EST_RATIO = { cue = 0.60, gdi = 0.55, iso = 0.70 }   -- tamanho do .chd / original
M.SPACE_RATIO = 0.75                                    -- espaco exigido: 75% + 64 MB
M.SPACE_EXTRA_KB = 64 * 1024
M.TMP_SUFFIX = ".porthub-tmp.chd"

-------------------------------------------------------------------------------
-- utilitarios
-------------------------------------------------------------------------------
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end
local function lower(s) return (s or ""):lower() end
local function ext_of(p) return lower(p:match("%.([^./]+)$") or "") end
local function base_of(p) return (p:match("([^/]+)$") or p) end
local function dir_of(p) return p:match("^(.*)/[^/]*$") or "." end
local function stem(p) return (base_of(p):gsub("%.[^.]+$", "")) end

local function fsize(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:seek("end")
  f:close()
  return s
end

local function lines(cmd)
  local t = {}
  local h = io.popen(cmd .. " 2>/dev/null")
  if not h then return t end
  for l in h:lines() do if l ~= "" then t[#t + 1] = l end end
  h:close()
  return t
end

--- normaliza "a/./b/../c" -> "a/c" (sem tocar no disco)
local function normpath(p)
  local abs = p:sub(1, 1) == "/"
  local out = {}
  for part in p:gmatch("[^/]+") do
    if part == ".." then
      if #out > 0 and out[#out] ~= ".." then out[#out] = nil elseif not abs then out[#out + 1] = ".." end
    elseif part ~= "." then out[#out + 1] = part end
  end
  return (abs and "/" or "") .. table.concat(out, "/")
end
M.normpath = normpath

local function inside(dir, abs)
  local d = normpath(dir) .. "/"
  local a = normpath(abs)
  return a:sub(1, #d) == d and not a:find("/%.%./") and not a:find("/%.%.$")
end

function M.sys_dir(sys) return M.cfg.root .. "/" .. sys end
function M.chdman() return M.cfg.tool_dir .. "/chdman.sh" end

--- o chdman esta instalado? devolve info (installed.json) ou nil
function M.installed()
  local sh = M.chdman()
  if not fsize(sh) or not fsize(M.cfg.tool_dir .. "/bin/chdman") then return nil end
  local ok, info = pcall(json.decode, U.read_file(M.cfg.tool_dir .. "/installed.json") or "")
  return (ok and type(info) == "table") and info or { version = "?" }
end

--- manifesto dos pacotes (para mostrar tamanho e origem antes de instalar)
function M.manifest()
  local ok, m = pcall(json.decode, U.read_file(M.cfg.manifest) or "")
  if not ok or type(m) ~= "table" then return nil end
  m.total = 0
  for _, d in ipairs(m.debs or {}) do m.total = m.total + (tonumber(d.size) or 0) end
  return m
end

--- espaco livre (KB) na pasta (ou o simulado dos testes)
function M.free_kb(path)
  if M.cfg.fake_free_kb then return M.cfg.fake_free_kb end
  return LT.free_kb(path)
end

--- espaco exigido (KB) para converter um jogo de "bytes"
function M.need_kb(bytes)
  return math.ceil(bytes * M.SPACE_RATIO / 1024) + M.SPACE_EXTRA_KB
end

local function lt_setup()
  LT.setup({ root = M.cfg.root, backup_dir = M.cfg.gl_backup_dir,
    es_systems = M.cfg.es_systems, es_systems_glob = M.cfg.es_systems_glob })
  LT.reset()
end

-------------------------------------------------------------------------------
-- leitura de .cue / .gdi / .m3u
-------------------------------------------------------------------------------
--- arquivos citados por um .cue (na ordem; sem repetir)
function M.cue_files(text)
  local t, seen = {}, {}
  text = (text or ""):gsub("^\239\187\191", "")
  for line in text:gmatch("[^\r\n]+") do
    local rest = line:match("^%s*[Ff][Ii][Ll][Ee]%s+(.+)$")
    if rest then
      local name = rest:match('^"(.-)"') or rest:match("^(%S+)")
      if name and name ~= "" then
        name = name:gsub("\\", "/")
        if not seen[name] then seen[name] = true; t[#t + 1] = name end
      end
    end
  end
  return t
end

--- arquivos das trilhas de um .gdi
function M.gdi_files(text)
  local t, seen = {}, {}
  local first = true
  for line in (text or ""):gmatch("[^\r\n]+") do
    if first then first = false
    else
      local rest = line:match("^%s*%d+%s+%d+%s+%d+%s+%d+%s+(.-)%s*$")
      if rest then
        local name = rest:match('^"(.-)"') or rest:match("^(.-)%s+%-?%d+$") or rest
        name = trim(name):gsub("\\", "/")
        if name ~= "" and not seen[name] then seen[name] = true; t[#t + 1] = name end
      end
    end
  end
  return t
end

--- acha o arquivo citado (exato ou ignorando maiusculas/minusculas na pasta)
local DIRCACHE = {}
local function resolve(dir, name)
  local p = normpath(dir .. "/" .. name)
  if fsize(p) then return p end
  local d, b = dir_of(p), base_of(p)
  local list = DIRCACHE[d]
  if not list then
    list = lines("ls -1A " .. U.shq(d))
    DIRCACHE[d] = list
  end
  for _, f in ipairs(list) do
    if lower(f) == lower(b) then return d .. "/" .. f end
  end
  return nil
end

-------------------------------------------------------------------------------
-- 1. PROCURAR
-------------------------------------------------------------------------------
--- sistemas (pastas) que aceitam .chd, com as extensoes de cada um
function M.chd_systems()
  local exts = LT.system_exts()
  local t = {}
  for sys, set in pairs(exts) do if set.chd then t[sys] = set end end
  return t
end

local KINDS = { cue = true, gdi = true, iso = true, pbp = true, cso = true }

--- monta o item de um arquivo principal (cue/gdi/iso/pbp/cso)
local function make_item(sys, rel, doc)
  local sdir = M.sys_dir(sys)
  local abs = sdir .. "/" .. rel
  local kind = ext_of(rel)
  local it = { sys = sys, rel = rel, abs = abs, kind = kind, files = { abs }, missing = {},
    bytes = fsize(abs) or 0, status = "ok", m3u = {} }
  it.out_rel = rel:gsub("%.[^./]+$", "") .. ".chd"
  it.out_abs = sdir .. "/" .. it.out_rel
  local e = doc and LT.find(doc, rel)
  it.name = (e and LT.get(e, "name")) or stem(rel)
  it.hidden = e and LT.is_hidden(e) or false
  if kind == "pbp" or kind == "cso" then
    it.status = "unsupported"
    it.why = kind == "pbp" and "pbp" or "cso"
  elseif kind == "iso" and sys == "psp" then
    it.status = "unsupported"; it.why = "psp"
  elseif kind == "cue" or kind == "gdi" then
    local text = U.read_file(abs) or ""
    local names = kind == "cue" and M.cue_files(text) or M.gdi_files(text)
    if #names == 0 then it.status = "empty" end
    for _, n in ipairs(names) do
      local p = resolve(dir_of(abs), n)
      if not p then
        it.missing[#it.missing + 1] = n
        it.status = "missing"
      elseif not inside(sdir, p) then
        it.missing[#it.missing + 1] = n
        it.status = "outside"
      else
        it.files[#it.files + 1] = p
        it.bytes = it.bytes + (fsize(p) or 0)
      end
    end
  end
  if it.status == "ok" and fsize(it.out_abs) then it.status = "exists" end
  it.est_chd = math.floor(it.bytes * (M.EST_RATIO[kind] or 0.7))
  it.est_saved = it.bytes - it.est_chd
  return it
end

--- .m3u do sistema: caminho absoluto citado -> lista de .m3u (rel) que o citam
local function m3u_refs(sys, files)
  local sdir = M.sys_dir(sys)
  local refs = {}
  for _, rel in ipairs(files) do
    if ext_of(rel) == "m3u" then
      local abs = sdir .. "/" .. rel
      for line in (U.read_file(abs) or ""):gmatch("[^\r\n]+") do
        local l = trim(line):gsub("\\", "/")
        if l ~= "" and not l:find("^#") then
          local target = l:sub(1, 1) == "/" and normpath(l) or normpath(dir_of(abs) .. "/" .. l)
          refs[target] = refs[target] or {}
          local list = refs[target]
          if list[#list] ~= rel then list[#list + 1] = rel end
        end
      end
    end
  end
  return refs
end

--- lista os candidatos. res = { items = {...}, systems = n, chdman = info|nil }
function M.op_scan()
  lt_setup()
  DIRCACHE = {}
  local systems = M.chd_systems()
  local names = {}
  for sys in pairs(systems) do
    if U.exec_ok("test -d " .. U.shq(M.sys_dir(sys))) then names[#names + 1] = sys end
  end
  table.sort(names)
  local res = { items = {}, systems = #names, chdman = M.installed() }
  for si, sys in ipairs(names) do
    M.progress({ phase = "scan", index = si, count = #names, name = sys })
    local sdir = M.sys_dir(sys)
    local files = lines("cd " .. U.shq(sdir) .. " && find . -mindepth 1 -maxdepth 3 -type f "
      .. "\\( -iname '*.cue' -o -iname '*.gdi' -o -iname '*.iso' -o -iname '*.pbp' -o -iname '*.cso' -o -iname '*.m3u' \\)"
      .. " -not -path './images/*' -not -path './videos/*' -not -path './media/*'")
    for i, f in ipairs(files) do files[i] = f:gsub("^%./", "") end
    table.sort(files)
    local doc = LT.load(sys)
    local refs = m3u_refs(sys, files)
    local items, used = {}, {}
    for _, rel in ipairs(files) do
      local k = ext_of(rel)
      if KINDS[k] and not rel:find(M.TMP_SUFFIX, 1, true) then
        local it = make_item(sys, rel, doc)
        items[#items + 1] = it
        if k == "cue" or k == "gdi" then
          for i = 2, #it.files do
            local f = it.files[i]
            used[f] = (used[f] or 0) + 1
          end
        end
      end
    end
    for _, it in ipairs(items) do
      -- .iso citado por um .cue: faz parte dele, nao e um jogo separado
      if not (it.kind == "iso" and used[it.abs]) then
        -- trilha usada por mais de um .cue: apagar quebraria o outro
        if it.status == "ok" then
          for i = 2, #it.files do
            if (used[it.files[i]] or 0) > 1 then it.status = "shared" end
          end
        end
        it.m3u = refs[normpath(it.abs)] or {}
        res.items[#res.items + 1] = it
      end
    end
  end
  return res
end

-------------------------------------------------------------------------------
-- 2. CONVERTER
-------------------------------------------------------------------------------
--- roda um comando do chdman lendo o progresso ("xx.x% complete").
--- devolve ok, saida, cancelado
local function run_chdman(args, on_pct)
  -- o sh de dentro mostra o proprio PID e vira o chdman (exec: mesmo PID, para
  -- cancelar com kill); o de fora espera em primeiro plano e mostra o codigo.
  -- (nada de "&" + "wait": numa thread do LOVE o SIGCHLD vem bloqueado e o
  -- "wait" do sh nunca volta)
  local inner = "nice -n " .. tonumber(M.cfg.nice or 10) .. " sh -c 'echo \"PID $$\"; exec \"$0\" \"$@\"' "
    .. U.shq(M.chdman()) .. " " .. args .. " </dev/null 2>&1; echo \"RC $?\""
  local h = io.popen("sh -c " .. U.shq(inner) .. " 2>&1")
  if not h then return false, "não foi possível rodar o chdman", false end
  local pid, rc
  local buf, tail = {}, {}
  local cancelled, killed = false, false
  local function line(l)
    l = trim(l)
    if l == "" then return end
    local p = l:match("^PID (%d+)$")
    if p and not pid then pid = p; return end
    local r = l:match("^RC (%d+)$")
    if r then rc = tonumber(r); return end
    local pct = l:match("([%d%.]+)%% complete")
    if pct then on_pct(tonumber(pct) or 0)
    elseif not l:find("^chdman %- MAME") then
      tail[#tail + 1] = l
      if #tail > 8 then table.remove(tail, 1) end
    end
    if not killed and M.cancelled() then
      cancelled = true
      if pid then os.execute("kill " .. pid .. " >/dev/null 2>&1"); killed = true end
    end
  end
  while true do
    local c = h:read(1)
    if not c then break end
    if c == "\r" or c == "\n" then line(table.concat(buf)); buf = {}
    else buf[#buf + 1] = c end
  end
  if #buf > 0 then line(table.concat(buf)) end
  h:close()
  return rc == 0 and not cancelled, table.concat(tail, "\n"), cancelled
end

local function chdman_args(it, src, dst)
  -- .cue, .gdi e .iso (CD de dados) usam createcd; o -o recusa sobrescrever
  return "createcd -i " .. U.shq(src) .. " -o " .. U.shq(dst)
end

local function write_atomic(path, text)
  local tmp = path .. ".porthub.tmp"
  if not U.write_file(tmp, text) or (fsize(tmp) or -1) ~= #text then os.remove(tmp); return false end
  local ok = os.rename(tmp, path)
  if not ok then os.remove(tmp); return false end
  return true
end

--- novo texto de um .m3u: linhas que apontam para o original passam a apontar
--- para o .chd (mesmo prefixo de pasta escrito no .m3u). nil se nada mudou
function M.m3u_rewrite(text, m3u_abs, src_abs)
  local nl = text:find("\r\n", 1, true) and "\r\n" or "\n"
  local out, changed = {}, false
  local src = normpath(src_abs)
  local had_final = text:sub(-1) == "\n"
  for line in (text .. (had_final and "" or "\n")):gmatch("(.-)\r?\n") do
    local l = trim(line)
    local ln = l:gsub("\\", "/")
    if ln ~= "" and not ln:find("^#") then
      local target = ln:sub(1, 1) == "/" and normpath(ln) or normpath(dir_of(m3u_abs) .. "/" .. ln)
      if target == src then
        line = l:gsub("%.[^./\\]+$", "") .. ".chd"
        changed = true
      end
    end
    out[#out + 1] = line
  end
  if not changed then return nil end
  return table.concat(out, nl) .. (had_final and nl or "")
end

--- registro em conf/chdconv.json (lista de conversoes)
local function log_conversion(entry)
  local file = M.cfg.conf_dir .. "/chdconv.json"
  local ok, data = pcall(json.decode, U.read_file(file) or "")
  if not ok or type(data) ~= "table" then data = {} end
  data.conversions = data.conversions or {}
  table.insert(data.conversions, entry)
  while #data.conversions > 500 do table.remove(data.conversions, 1) end
  U.exec_ok("mkdir -p " .. U.shq(M.cfg.conf_dir))
  write_atomic(file, json.encode(data, true))
end

--- atualiza o gamelist: <path> do original -> .chd (so essa tag). ok, erro
local function update_gamelist(it)
  local tries = 0
  while true do
    tries = tries + 1
    local doc = LT.load(it.sys)
    local e = LT.find(doc, it.rel)
    if not e then
      for _, x in ipairs(doc.entries) do
        if x.path and x.path:sub(1, 1) == "/" and normpath(x.path) == normpath(it.abs) then e = x; break end
      end
    end
    if not e then return true, false end   -- jogo fora da lista: o ES acha o .chd sozinho
    local old = LT.get(e, "path") or ("./" .. it.rel)
    local newp = old:gsub("%.[^./]+$", "") .. ".chd"
    LT.set(doc, e, "path", newp)
    -- entrada antiga do .chd (sem arquivo ate agora): sai, para nao duplicar
    local dup = LT.find(doc, it.out_rel)
    if dup and dup ~= e then LT.remove(doc, dup) end
    local ok, err = LT.save(doc)
    if ok then return true, true end
    if tries >= 2 then return false, err end
  end
end

--- desfaz um jogo pela metade: apaga o .chd e devolve os .m3u
local function rollback(paths, m3u_backup)
  for _, p in ipairs(paths) do os.remove(p) end
  for abs, text in pairs(m3u_backup or {}) do write_atomic(abs, text) end
end

--- converte um jogo. devolve true, info | nil, erro, cancelado
function M.convert_one(it, report)
  report = report or function() end
  local sdir = M.sys_dir(it.sys)
  -- confere de novo (o cartao pode ter mudado desde a lista)
  DIRCACHE = {}
  local doc0 = LT.load(it.sys)
  local cur = make_item(it.sys, it.rel, doc0)
  local m3us = lines("cd " .. U.shq(sdir) .. " && find . -mindepth 1 -maxdepth 3 -type f -iname '*.m3u'")
  for i, f in ipairs(m3us) do m3us[i] = f:gsub("^%./", "") end
  cur.m3u = m3u_refs(it.sys, m3us)[normpath(cur.abs)] or {}
  if not fsize(cur.abs) then return nil, "arquivo não encontrado: " .. it.rel end
  if cur.status == "missing" then return nil, "faltam arquivos citados: " .. table.concat(cur.missing, ", ") end
  if cur.status == "exists" then return nil, "já existe " .. cur.out_rel end
  if cur.status ~= "ok" then return nil, "não dá para converter (" .. cur.status .. ")" end
  for _, f in ipairs(cur.files) do
    if not inside(sdir, f) then return nil, "arquivo fora da pasta do sistema: " .. f end
  end
  -- espaco
  local need = M.need_kb(cur.bytes)
  local free = M.free_kb(dir_of(cur.abs))
  if free and free < need then
    return nil, string.format("espaço insuficiente: precisa de %d MB, há %d MB livres", math.ceil(need / 1024), math.floor(free / 1024))
  end
  local tmp = cur.out_abs:gsub("%.chd$", "") .. M.TMP_SUFFIX
  os.remove(tmp)
  -- 1) comprimir
  report("compress", 0)
  local ok, out, cancelled = run_chdman(chdman_args(cur, cur.abs, tmp), function(p) report("compress", p) end)
  if not ok then
    rollback({ tmp })
    if cancelled then return nil, "cancelado", true end
    return nil, "o chdman falhou: " .. (out ~= "" and out or "?")
  end
  local chd_bytes = fsize(tmp)
  if not chd_bytes or chd_bytes == 0 then rollback({ tmp }); return nil, "o chdman não gerou o arquivo" end
  -- 2) verificar
  report("verify", 0)
  ok, out, cancelled = run_chdman("verify -i " .. U.shq(tmp), function(p) report("verify", p) end)
  if not ok then
    rollback({ tmp })
    if cancelled then return nil, "cancelado", true end
    return nil, "a verificação do .chd falhou: " .. (out ~= "" and out or "?")
  end
  report("finish", 100)
  -- 3) nome final (recusa se apareceu um .chd com o mesmo nome)
  if fsize(cur.out_abs) then rollback({ tmp }); return nil, "já existe " .. cur.out_rel end
  if not os.rename(tmp, cur.out_abs) then rollback({ tmp }); return nil, "não foi possível renomear o .chd" end
  -- 4) .m3u que citavam o original
  local m3u_backup, m3u_done = {}, {}
  for _, mrel in ipairs(cur.m3u) do
    local mabs = sdir .. "/" .. mrel
    local text = U.read_file(mabs)
    local nt = text and M.m3u_rewrite(text, mabs, cur.abs)
    if nt then
      if write_atomic(mabs, nt) then
        m3u_backup[mabs] = text; m3u_done[#m3u_done + 1] = mrel
      else
        rollback({ cur.out_abs }, m3u_backup)
        return nil, "não foi possível atualizar " .. mrel
      end
    end
  end
  -- 5) gamelist
  local gok, gres = update_gamelist(cur)
  if not gok then
    rollback({ cur.out_abs }, m3u_backup)
    return nil, "lista de jogos não atualizada (" .. tostring(gres) .. "); nada foi apagado"
  end
  -- 6) so agora apaga o original e os arquivos que ele cita
  local removed, rm_err = {}, {}
  for _, f in ipairs(cur.files) do
    if os.remove(f) then removed[#removed + 1] = f:sub(#sdir + 2) else rm_err[#rm_err + 1] = f end
  end
  local info = { date = os.date("%Y-%m-%d %H:%M:%S"), sys = cur.sys, from = cur.rel, to = cur.out_rel,
    files = removed, bytes_before = cur.bytes, bytes_after = chd_bytes, m3u = m3u_done,
    gamelist = gres and true or false, not_removed = #rm_err > 0 and rm_err or nil }
  log_conversion(info)
  return true, info
end

--- converte a fila p.items (lista de itens do op_scan). Cancelar para depois do
--- jogo em curso (o chdman em andamento e interrompido e o .chd parcial apagado).
function M.op_convert(p)
  lt_setup()
  local list = p.items or {}
  local res = { ok = {}, failed = {}, saved = 0, before = 0, after = 0, cancelled = false, secs = 0 }
  local total = 0
  for _, it in ipairs(list) do total = total + math.max(1, it.bytes or 1) end
  local done = 0
  local t0 = os.time()
  if not M.installed() then error("o chdman não está instalado") end
  for i, it in ipairs(list) do
    if M.cancelled() then res.cancelled = true; break end
    local w = math.max(1, it.bytes or 1)
    local function report(phase, pct)
      -- comprimir = 85% do tempo do jogo, verificar = 15%
      local frac = phase == "compress" and (pct / 100) * 0.85 or (phase == "verify" and 0.85 + (pct / 100) * 0.15 or 1)
      M.progress({ phase = phase, index = i, count = #list, name = it.name, pct = pct,
        done = done + w * frac, total = total })
    end
    local ok, info, cancelled = M.convert_one(it, report)
    if ok then
      res.ok[#res.ok + 1] = { name = it.name, sys = it.sys, before = info.bytes_before, after = info.bytes_after }
      res.before = res.before + info.bytes_before
      res.after = res.after + info.bytes_after
      res.saved = res.saved + (info.bytes_before - info.bytes_after)
    elseif cancelled then
      res.cancelled = true
      break
    else
      res.failed[#res.failed + 1] = { name = it.name, sys = it.sys, err = tostring(info) }
    end
    done = done + w
  end
  res.secs = os.time() - t0
  return res
end

-------------------------------------------------------------------------------
-- 3. INSTALAR / REMOVER O CHDMAN (bin/chdman_install.py)
-------------------------------------------------------------------------------
local function run_installer(extra)
  local cmd = U.shq(M.cfg.python) .. " -I " .. U.shq(M.cfg.installer) .. " --dest " .. U.shq(M.cfg.tool_dir)
    .. " --manifest " .. U.shq(M.cfg.manifest) .. (extra or "") .. " 2>&1"
  local h = io.popen(cmd)
  if not h then return nil, "não foi possível rodar o python3" end
  local okline, err, last = nil, nil, {}
  for l in h:lines() do
    local d, t, txt = l:match("^PROGRESS (%d+) (%d+) ?(.*)$")
    if d then M.progress({ phase = "download", done = tonumber(d), total = tonumber(t), name = txt })
    elseif l:match("^STEP ") then M.progress({ phase = "step", name = l:sub(6) })
    elseif l:match("^OK") then okline = l:sub(4)
    elseif l:match("^ERRO ") then err = l:sub(6)
    else last[#last + 1] = l; if #last > 5 then table.remove(last, 1) end end
  end
  h:close()
  if okline then return okline end
  return nil, err or table.concat(last, "\n") or "?"
end

function M.op_install()
  local r, err = run_installer("")
  if not r then error(err, 0) end
  return { version = r, info = M.installed() }
end

function M.op_uninstall()
  local r, err = run_installer(" --uninstall")
  if not r then error(err, 0) end
  return { removed = true }
end

-------------------------------------------------------------------------------
-- configuracao no app e execucao em segundo plano (so no app: love.thread)
-------------------------------------------------------------------------------
--- monta a configuracao a partir do config do app (variaveis de ambiente para testes)
function M.app_setup()
  local C = require("config")
  local root = os.getenv("PORTHUB_CHDCONV_ROOT") or require("core.spacemgr").roms_root()
  M.setup({
    root = root,
    tool_dir = os.getenv("PORTHUB_CHDCONV_TOOL") or M.TOOL_DIR,
    installer = C.APP_DIR .. "/bin/chdman_install.py",
    manifest = C.APP_DIR .. "/bin/chdman_debs.json",
    conf_dir = os.getenv("PORTHUB_CHDCONV_CONF") or (C.APP_DIR .. "/conf"),
    gl_backup_dir = C.APP_DIR .. "/backups/gamelists",
    es_systems = { os.getenv("PORTHUB_CHDCONV_ES") or "/usr/share/emulationstation/es_systems.cfg" },
    es_systems_glob = os.getenv("PORTHUB_CHDCONV_ES") and "/nonexistent/es_systems_*.cfg"
      or "/userdata/system/configs/emulationstation/es_systems_*.cfg",
    fake_free_kb = tonumber(os.getenv("PORTHUB_CHDCONV_FREE_KB") or ""),
  })
end

M.job = nil   -- { op, status = {...}, cancel() }

function M.busy() return M.job ~= nil end

--- roda M.op_<op>(params) na thread. on_done(ok, res_ou_erro)
function M.run(op, params, on_done)
  if M.job then return nil, "ocupado" end
  local Sh = require("core.shjob")
  Sh.seq = Sh.seq + 1
  local base = "hub_chdconv_" .. Sh.seq
  local out = love.thread.getChannel(base)
  local st = love.thread.getChannel(base .. "_st")
  local ctl = love.thread.getChannel(base .. "_ctl")
  out:clear(); st:clear(); ctl:clear()
  local th = love.thread.newThread("threads/chdconv_thread.lua")
  local job = { op = op, status = {}, st = st, ctl = ctl, t0 = love.timer.getTime() }
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
