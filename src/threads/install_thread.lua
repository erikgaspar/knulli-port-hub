-- =============================================================================
--  R36S PORT HUB - thread de instalacao
--  Roda fora da thread principal para nao travar a interface.
--  Etapas: espaco -> download -> verificacao -> extracao (pasta temporaria)
--          -> analise da estrutura -> confirmacao de sobrescrita -> instalacao
--  Comunicacao: canal de saida (mensagens para a interface) e canal de entrada
--  (cancelar / resposta da confirmacao).
-- =============================================================================
require("love.timer")

local job = ...
require("love.filesystem")
local I18N = require("lib.i18n")
I18N.set(job.lang or "pt-BR")
local L = I18N.L
local OUT = love.thread.getChannel(job.out_channel)
local IN = love.thread.getChannel(job.in_channel)

local function shq(s) return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'" end
local function ok(r) return r == 0 or r == true end
local function sh(cmd) return ok(os.execute(cmd)) end
local function capture(cmd)
  local h = io.popen(cmd)
  if not h then return "" end
  local s = h:read("*a") or ""
  h:close()
  return s
end
local function log(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
  print("[install] " .. table.concat(t, " "))
  io.stdout:flush()
end
local function send(msg) OUT:push(msg) end
local function fsize(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:seek("end")
  f:close()
  return s
end
local function read_all(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local WORK = job.tmp_dir .. "/job_" .. job.slug
local ZIP = WORK .. "/download.zip"
local PART = ZIP .. ".part"
local STAGE = WORK .. "/stage"
local PIDF = WORK .. "/dl.pid"
local RCF = WORK .. "/dl.rc"
-- Retomada de downloads: o parcial (download.zip.part) fica na pasta do job
-- com resume.json (url, total, etag, last_modified, datas). STATUSF recebe do
-- fetch.sh o estado das novas tentativas ("retry ...", "resume ...").
local META = WORK .. "/resume.json"
local STATUSF = WORK .. "/dl.status"
local MAX_AGE = 7 * 24 * 3600
-- true enquanto o parcial deve sobreviver a uma falha (servidor aceita Range)
local KEEP = false
local META_T = nil   -- metadados do download atual (gravados em META)

local cancelled = false
local extract_7z
local function check_cancel()
  local m = IN:pop()
  while m do
    if m.t == "cancel" then cancelled = true end
    m = IN:pop()
  end
  return cancelled
end

local function cleanup()
  sh("rm -rf " .. shq(WORK) .. " 2>/dev/null")
end

-- apaga tudo do job menos o parcial e seus metadados
local function cleanup_keep()
  sh("cd " .. shq(WORK) .. " 2>/dev/null && for f in * .[!.]*; do case \"$f\" in "
    .. "download.zip.part|resume.json|'*'|'.[!.]*') ;; *) rm -rf -- \"$f\" ;; esac; done")
end

local function write_meta(m)
  local okj, J = pcall(require, "lib.json")
  if not okj or type(m) ~= "table" then return end
  local f = io.open(META .. ".tmp", "wb")
  if not f then return end
  f:write(J.encode(m))
  f:close()
  os.rename(META .. ".tmp", META)
end

local function read_meta()
  local t = read_all(META)
  if not t then return nil end
  local okj, J = pcall(require, "lib.json")
  if not okj then return nil end
  local okd, m = pcall(J.decode, t)
  return (okd and type(m) == "table") and m or nil
end

--- guarda o parcial para continuar depois (falha de rede, cancelado, app fechado)
local function keep_partial(state, rc)
  local have = fsize(PART) or 0
  if not (KEEP and META_T and have > 0) then return false end
  META_T.state = state
  META_T.done = have
  META_T.rc = rc
  META_T.updated = os.time()
  write_meta(META_T)
  return true, have
end

local function fail(code, detail)
  log("ERRO", code, detail or "")
  -- tamanho do que foi baixado (Knulli: guarda na marca de "pacote invalido")
  local size = (not job.local_file) and fsize(PART) or nil
  if KEEP and not job.local_file and (fsize(PART) or 0) > 0 then
    cleanup_keep()
    log("parcial guardado para continuar depois:", size, "bytes")
  else
    cleanup()
  end
  send({ t = "error", code = code, detail = detail or "", size = size,
    partial = (KEEP and size and size > 0) and size or nil })
end

local function cancel_done()
  log("cancelado pelo usuario")
  local kept, have = false, nil
  -- download ja avancou (mais de 1 MB) num servidor que aceita continuar:
  -- vira pausa, o parcial fica para o proximo pedido (ou e limpo depois)
  if not job.local_file and (fsize(PART) or 0) > 1024 * 1024 then
    kept, have = keep_partial("paused", 143)
  end
  if kept then cleanup_keep() else cleanup() end
  send({ t = "cancelled", partial = kept and have or nil })
end

local function free_bytes(path)
  local out = capture("df -Pk " .. shq(path) .. " 2>/dev/null | tail -n 1")
  local avail = out:match("^%S+%s+%d+%s+%d+%s+(%d+)")
  return avail and tonumber(avail) * 1024 or nil
end

local function lower(s) return (s or ""):lower() end

-- ---------------------------------------------------------------------------
-- Download pelo fetch.sh em segundo plano, com retomada automatica nas quedas
-- (PH_STATUS). ifrange = validador para If-Range (arquivo mudou -> do zero).
local function start_fetch(url, part, logf, ifrange)
  os.remove(RCF); os.remove(PIDF); os.remove(STATUSF)
  local env = "PH_STATUS=" .. shq(STATUSF) .. " "
  if ifrange and ifrange ~= "" then env = env .. "PH_IFRANGE=" .. shq(ifrange) .. " " end
  sh(env .. "sh " .. shq(job.fetch_sh) .. " get " .. shq(url) .. " " .. shq(part) .. " "
    .. shq(PIDF) .. " " .. shq(RCF) .. " >" .. shq(logf) .. " 2>&1 &")
end

--- acompanha ate o fim: devolve o rc do fetch.sh ou "cancel"
local function watch_fetch(part, expected, on_retry)
  local last_push, last_st = -1, nil
  while true do
    love.timer.sleep(0.25)
    if check_cancel() then
      local pid = (read_all(PIDF) or ""):match("%d+")
      if pid then sh("kill " .. pid .. " 2>/dev/null") end
      -- espera o script terminar
      for _ = 1, 40 do
        love.timer.sleep(0.1)
        if read_all(RCF) then break end
      end
      return "cancel"
    end
    local s = read_all(RCF)
    local stl = read_all(STATUSF)
    if stl and stl ~= last_st then
      last_st = stl
      local n, mx, crc, wt, b = stl:match("^retry (%d+) (%d+) (%d+) (%d+) (%d+)")
      if n then
        log("conexao caiu (rc=" .. crc .. "): tentativa " .. n .. "/" .. mx .. " em " .. wt .. " s, " .. b .. " bytes guardados")
        send({ t = "net_retry", attempt = tonumber(n), max = tonumber(mx), rc = tonumber(crc),
          wait = tonumber(wt), done = tonumber(b), total = expected })
        if on_retry then on_retry(tonumber(b)) end
      elseif stl:match("^resume") then
        send({ t = "net_resume", done = fsize(part) or 0, total = expected })
      elseif stl:match("^restart") then
        log("servidor nao aceitou continuar: recomecando do zero")
        send({ t = "net_restart" })
      end
    end
    local done = fsize(part) or 0
    -- rc lido ANTES do estado: a ultima mudanca ("restart") nao se perde
    if s and s:match("%d+") then return tonumber(s:match("%d+")) end
    if done ~= last_push then
      send({ t = "progress", phase = "download", done = done, total = expected })
      last_push = done
    end
  end
end

--- consulta leve do link (fetch.sh probe: 1 KB com Range). ranges = servidor
--- respondeu 206 (aceita continuar); total = tamanho do arquivo inteiro
local function probe(url)
  local out = capture("sh " .. shq(job.fetch_sh) .. " probe " .. shq(url) .. " " .. shq(WORK) .. " 2>/dev/null")
  local r = {}
  for line in out:gmatch("[^\n]+") do
    local k, v = line:match("^(%u+)=(.*)$")
    if k then r[k] = v end
  end
  local function nz(v) return (v and v ~= "") and v or nil end
  local res = { rc = tonumber(r.RC or ""), status = tonumber(r.STATUS or ""), len = tonumber(r.LEN or ""),
    etag = nz(r.ETAG), lastmod = nz(r.LASTMOD) }
  local tot = (r.RANGE or ""):match("/(%d+)%s*$")
  res.ranges = res.status == 206 and tot ~= nil
  res.total = tonumber(tot or "") or ((res.status == 200) and res.len or nil)
  return res
end

-- ---------------------------------------------------------------------------
-- Extrator para RAR e 7z. Prefere o 7-Zip incluso (bin/7zzs, aarch64 estatico),
-- copiado para /tmp porque o cartao pode nao permitir executar binarios.
local function find_7z()
  local cands = {}
  if job.sevenzip and job.sevenzip ~= "" then cands[#cands + 1] = job.sevenzip end
  local tmpbin = "/tmp/r36sporthub-7zzs"
  if job.bundled_7z and sh("test -f " .. shq(job.bundled_7z)) then
    sh("cp -f " .. shq(job.bundled_7z) .. " " .. shq(tmpbin) .. " 2>/dev/null && chmod 755 " .. shq(tmpbin))
    cands[#cands + 1] = tmpbin
  end
  for _, n in ipairs({ "7zz", "7zzs", "7z", "7za" }) do
    local pth = capture("command -v " .. n .. " 2>/dev/null"):match("^(%S+)")
    if pth then cands[#cands + 1] = pth end
  end
  for _, c in ipairs(cands) do
    if sh(shq(c) .. " i >/dev/null 2>&1") then return c end
  end
  return nil
end

-- senha que abriu o arquivo (nil = sem senha). Nunca vai para o log.
local PWD = nil
local TARF = ""   -- opcao de compressao do tar ("", "z", "J" ou "j")
local function popt(pw) return pw and ("-p" .. shq(pw)) or "-p-" end

extract_7z = function(fmt)
  local X = find_7z()
  local unrar = (not X and fmt == "rar") and capture("command -v unrar 2>/dev/null"):match("^(%S+)") or nil
  if not X and not unrar then fail("no_extractor", fmt:upper()); return false end

  local entries, unpacked = 0, 0
  if X then
    log("extrator:", X)
    -- lista tecnica: caminhos, tamanhos, pastas, criptografia
    local function lst(pw) return capture(shq(X) .. " l -slt -ba " .. popt(pw) .. " " .. shq(ZIP) .. " 2>&1; echo __PHX:$?") end
    local listing = lst(nil)
    local lcode = tonumber(listing:match("__PHX:(%d+)")) or 2
    local pwlist = job.passwords or {}
    if lcode > 1 and (listing:find("Wrong password") or listing:find("Can not open encrypted")) then
      -- nomes tambem criptografados: so lista com a senha certa
      local found = false
      for i, pw in ipairs(pwlist) do
        local l2 = lst(pw)
        local c2 = tonumber(l2:match("__PHX:(%d+)")) or 2
        if c2 <= 1 and not l2:find("Wrong password") then
          PWD, listing, lcode, found = pw, l2, c2, true
          log("arquivo com senha: senha salva n." .. i .. " funcionou")
          break
        end
      end
      if not found then fail("encrypted"); return false end
    elseif listing:find("Encrypted = %+") then
      -- conteudo criptografado: testa a senha num arquivo pequeno do pacote
      local test, tsz
      for block in (listing .. "\n\n"):gmatch("(Path = .-)\n\n") do
        if block:find("\nEncrypted = %+") and not block:find("\nFolder = %+") then
          local sz = tonumber(block:match("\nSize = (%d+)")) or 0
          if not tsz or sz < tsz then test, tsz = block:match("^Path = ([^\n]*)"), sz end
        end
      end
      local found = false
      for i, pw in ipairs(pwlist) do
        local okt = sh(shq(X) .. " t " .. popt(pw) .. " -bso0 -bse0 -bsp0 " .. shq(ZIP)
          .. (test and (" " .. shq(test)) or "") .. " >/dev/null 2>&1")
        if okt then
          PWD, found = pw, true
          log("arquivo com senha: senha salva n." .. i .. " funcionou")
          break
        end
      end
      if not found then fail("encrypted"); return false end
    end
    if lcode > 1 then fail("bad_zip", (listing:match("ERROR: ([^\n]+)") or ""):sub(1, 80)); return false end
    for block in (listing .. "\n\n"):gmatch("(Path = .-)\n\n") do
      local path = block:match("^Path = ([^\n]*)")
      if path and path ~= "" then
        entries = entries + 1
        path = path:gsub("\\", "/")
        if path:sub(1, 1) == "/" or path:find("^%a:") or path:find("%.%./") or path:find("/%.%.$") or path == ".." then
          fail("unsafe_zip", path); return false
        end
        unpacked = unpacked + (tonumber(block:match("\nSize = (%d+)")) or 0)
      end
    end
  else
    log("extrator: unrar", unrar)
    local listing = capture(shq(unrar) .. " lb -p- " .. shq(ZIP) .. " 2>/dev/null")
    if listing == "" then
      for _, pw in ipairs(job.passwords or {}) do
        local l2 = capture(shq(unrar) .. " lb -p" .. shq(pw) .. " " .. shq(ZIP) .. " 2>/dev/null")
        if l2 ~= "" and sh(shq(unrar) .. " t -idq -p" .. shq(pw) .. " " .. shq(ZIP) .. " >/dev/null 2>&1") then
          PWD, listing = pw, l2
          break
        end
      end
    end
    for line in listing:gmatch("[^\n]+") do
      entries = entries + 1
      if line:sub(1, 1) == "/" or line:find("%.%./") then fail("unsafe_zip", line); return false end
    end
  end
  if entries == 0 then fail("bad_zip"); return false end

  local avail = free_bytes(job.ports_dir)
  if avail and avail < unpacked + job.margin then
    fail("no_space", string.format("%d|%d", unpacked + job.margin, avail)); return false
  end

  send({ t = "phase", phase = "extract", total = entries })
  local cmd
  if X then
    -- -mmt1: um processo de descompactacao (menos memoria no R36S)
    cmd = shq(X) .. " x -y " .. popt(PWD) .. " -mmt1 -bb1 -bso1 -bse1 -bsp0 -o" .. shq(STAGE) .. " " .. shq(ZIP) .. " 2>&1; echo __PHX:$?"
  else
    cmd = "cd " .. shq(STAGE) .. " && " .. shq(unrar) .. " x -o+ -y " .. popt(PWD) .. " " .. shq(ZIP) .. " 2>&1; echo __PHX:$?"
  end
  local h = io.popen(cmd)
  local count, code, lastpct, errl = 0, nil, -1, nil
  if h then
    for line in h:lines() do
      local c = line:match("^__PHX:(%d+)")
      if c then code = tonumber(c)
      else
        if line:match("^%- ") or line:match("^Extracting%s") or line:match("^Creating%s") then
          count = count + 1
        elseif not errl and (line:find("ERROR") or line:find("Error")) then
          errl = line
        end
        local pct = math.floor(count / entries * 100)
        if pct ~= lastpct then
          send({ t = "progress", phase = "extract", done = math.min(count, entries), total = entries })
          lastpct = pct
        end
        if count % 25 == 0 and check_cancel() then break end
      end
    end
    h:close()
  end
  if cancelled then cancel_done(); return false end
  -- 7-Zip: 0 = ok, 1 = aviso; 2 = erro fatal; 8 = sem memoria. unrar: 0 = ok
  if code == nil or code > 1 then
    if errl and (errl:find("[Ww]rong password") or errl:find("encrypted")) then fail("encrypted"); return false end
    if errl and errl:lower():find("space") then fail("no_space", ""); return false end
    if code == 8 then fail("no_memory"); return false end
    fail("bad_zip", (errl or (L("codigo ") .. tostring(code))):sub(1, 80)); return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Knulli: runtimes do PortMaster exigidos pelo port (mono, frt, godot...).
-- Baixados ANTES do port, um por vez, conferidos (tamanho + md5 do indice
-- oficial) e so entao movidos para PortMaster/libs. Nada e trocado: so entram
-- runtimes que faltam. Devolve true ou (nil, codigo, detalhe) / "cancel".
local function md5sum(p)
  return lower(capture("md5sum " .. shq(p) .. " 2>/dev/null"):match("^(%x+)") or "")
end
local function fetch_runtimes()
  local list = job.runtimes
  if type(list) ~= "table" or #list == 0 then return true end
  local libs = job.libs_dir
  if not libs or libs == "" then return nil, "runtime_failed", L("PortMaster não encontrado") end
  if not sh("mkdir -p " .. shq(libs)) or not sh("test -w " .. shq(libs)) then return nil, "no_write", libs end
  local need = 0
  for _, r in ipairs(list) do need = need + (tonumber(r.size) or 0) end
  local avail = free_bytes(libs)
  if avail and avail < need + job.margin then return nil, "no_space", string.format("%d|%d", need + job.margin, avail) end
  for _, r in ipairs(list) do
    local name = tostring(r.name or "")
    if not name:match("^[%w%._%-]+%.squashfs$") or not r.url or not r.md5 then return nil, "runtime_failed", name end
    if sh("test -f " .. shq(libs .. "/" .. name)) then
      log("runtime ja presente:", name)
    else
      log("baixando runtime:", name, r.url)
      local part = WORK .. "/" .. name .. ".part"
      local expected = tonumber(r.size)
      send({ t = "phase", phase = "download", total = expected, label = name })
      os.remove(part)
      start_fetch(r.url, part, WORK .. "/fetch_rt.log")
      local rc = watch_fetch(part, expected)
      if rc == "cancel" then return "cancel" end
      if rc ~= 0 then
        if rc == 23 then return nil, "no_space", "" end
        return nil, "runtime_failed", name .. " (rc=" .. tostring(rc) .. ")"
      end
      send({ t = "phase", phase = "verify", label = name })
      local got = fsize(part) or 0
      if expected and got ~= expected then return nil, "size_mismatch", string.format("%d|%d", got, expected) end
      if md5sum(part) ~= lower(r.md5) then return nil, "checksum", name end
      local dst = libs .. "/" .. name
      if not (sh("mv -f " .. shq(part) .. " " .. shq(dst .. ".porthub")) and sh("mv -f " .. shq(dst .. ".porthub") .. " " .. shq(dst))) then
        os.remove(dst .. ".porthub")
        return nil, "no_write", libs
      end
      sh("chmod 644 " .. shq(dst) .. " 2>/dev/null")
      log("runtime instalado:", dst)
    end
    if check_cancel() then return "cancel" end
  end
  return true
end

-- Knulli: port do PortMaster instalado -> port.json com "status" (o mesmo que o
-- harbourmaster grava: source, md5 do zip, Installed) e "files", e a assinatura
-- "# PORTMASTER: zip, script" nos .sh. Assim o PortMaster reconhece o port como
-- instalado por ele (atualizar/remover pelo PortMaster continua funcionando).
local function pm_finish(installed)
  local pm = job.pm
  if type(pm) ~= "table" or not pm.name then return end
  local okj, json = pcall(require, "lib.json")
  if not okj then return end
  local dirs, files = {}, {}
  for _, n in ipairs(installed) do
    if sh("test -d " .. shq(job.ports_dir .. "/" .. n)) then dirs[#dirs + 1] = n end
  end
  for _, d in ipairs(dirs) do
    local pj = job.ports_dir .. "/" .. d .. "/port.json"
    local text = read_all(pj)
    local okd, info = pcall(json.decode, text or "")
    if okd and type(info) == "table" and (info.name == nil or lower(info.name) == lower(pm.name)) then
      files = { ["port.json"] = d .. "/port.json" }
      for _, n in ipairs(installed) do files[n] = n end
      local status = { source = "PortMaster", md5 = pm.md5, status = "Installed" }
      local out
      if info.status == nil and info.files == nil and info.name ~= nil then
        -- o normal (port.json do zip): so acrescenta as duas chaves no fim,
        -- sem regravar o resto (null e {} vazios continuam como estao)
        local body = text:match("^(.*)}%s*$")
        if body then
          out = body:gsub("%s+$", "") .. ",\n    \"status\": " .. json.encode(status) .. ",\n    \"files\": "
            .. json.encode(files) .. "\n}\n"
        end
      end
      if not out then
        info.name, info.status, info.files, info.source = pm.name, status, files, nil
        out = json.encode(info, true)
      end
      local okv, chk = pcall(json.decode, out)
      okv = okv and type(chk) == "table"
      local fh = okv and io.open(pj, "wb")
      if fh then fh:write(out); fh:close(); log("port.json atualizado:", pj) end
      break
    end
  end
  for _, n in ipairs(installed) do
    if lower(n):match("%.sh$") then
      local p = job.ports_dir .. "/" .. n
      local text = read_all(p)
      if text and not text:find("PORTMASTER:", 1, true) then
        local first, rest = text:match("^(#![^\n]*\n)(.*)$")
        local sig = "# PORTMASTER: " .. pm.name .. ", " .. n .. "\n"
        local fh = io.open(p, "wb")
        if fh then fh:write(first and (first .. sig .. rest) or (sig .. text)); fh:close() end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
local function run()
  log("iniciando:", job.name, "->", job.ports_dir)

  -- 0) preparacao -----------------------------------------------------------
  send({ t = "phase", phase = "prepare" })
  -- parcial de um pedido anterior: sobrevive a erros ate a decisao de retomar
  KEEP = not job.local_file
  if not job.local_file then
    -- download antigo deste mesmo job ainda vivo (app fechado no meio): para
    -- antes, para nao haver dois processos gravando no mesmo arquivo. O [d]
    -- evita que o pkill ache o proprio shell que o executa.
    local pat = (WORK .. "/[d]ownload.zip.part"):gsub("%.", "\\.")
    sh("pkill -f " .. shq(pat) .. " >/dev/null 2>&1")
  end
  if not sh("test -d " .. shq(job.ports_dir)) then
    return fail("no_ports_dir", job.ports_dir)
  end
  if not sh("test -w " .. shq(job.ports_dir)) then
    return fail("no_write", job.ports_dir)
  end
  if job.local_file then cleanup() else cleanup_keep() end
  if not sh("mkdir -p " .. shq(STAGE)) then
    return fail("no_write", job.tmp_dir)
  end

  -- Knulli: runtimes do PortMaster que faltam (antes do port)
  if not job.local_file and job.runtimes then
    local okr, code, detail = fetch_runtimes()
    if okr == "cancel" then return cancel_done() end
    if not okr then return fail(code, detail) end
  end

  local expected, got
  if job.local_file then
    -- arquivo que ja esta no cartao (Gerenciador de arquivos): sem download
    PART = job.local_file
    got = fsize(PART) or 0
    log("arquivo local:", PART, got, "bytes")
  else

  -- tamanho esperado: o que o SERVIDOR informa vale mais que o do catalogo.
  -- Catalogos costumam trazer o tamanho arredondado (ex.: 1.6 GB em bytes) e
  -- isso fazia um download completo ser recusado como "incompleto".
  -- A consulta (probe, 1 KB com Range) tambem diz se da para continuar um
  -- parcial (206) e traz ETag/Last-Modified para saber se o arquivo mudou.
  local catalog_size = tonumber(job.expected_size)
  if catalog_size and catalog_size <= 0 then catalog_size = nil end
  local info = probe(job.url)
  local server_size
  if info.status == 200 or info.status == 206 then
    server_size = info.total
  end
  if not server_size then
    local h = capture("sh " .. shq(job.fetch_sh) .. " head " .. shq(job.url) .. " 2>/dev/null")
    server_size = tonumber(h:match("(%d+)"))
  end
  if server_size and server_size <= 0 then server_size = nil end
  if server_size and catalog_size and server_size ~= catalog_size then
    log("tamanho do catalogo (" .. catalog_size .. ") difere do servidor (" .. server_size .. "): usando o do servidor")
  end
  expected = server_size or catalog_size
  job.server_size = server_size
  log("servidor:", "HTTP " .. tostring(info.status), info.ranges and "aceita continuar (Range)" or "sem Range",
    "etag=" .. tostring(info.etag), "last-modified=" .. tostring(info.lastmod))

  -- 1) parcial de antes: continua so se for o MESMO arquivo -------------------
  local now = os.time()
  local have = fsize(PART) or 0
  local meta = read_meta()
  local resume_from = 0
  if have > 0 then
    local why
    if not info.ranges then
      why = "o servidor nao aceita continuar (sem Range)"
    elseif meta then
      if meta.url ~= job.url then why = "o link mudou"
      elseif meta.etag and info.etag and meta.etag ~= info.etag then why = "o arquivo mudou (ETag)"
      elseif meta.last_modified and info.lastmod and meta.last_modified ~= info.lastmod then why = "o arquivo mudou (Last-Modified)"
      elseif tonumber(meta.total) and server_size and tonumber(meta.total) ~= server_size then why = "o tamanho mudou"
      elseif now - (tonumber(meta.updated) or tonumber(meta.created) or 0) > MAX_AGE then why = "parcial com mais de 7 dias"
      end
    elseif not server_size then
      -- parcial sem metadados (versao anterior do hub fechada no meio): so
      -- continua quando da para conferir o tamanho final
      why = "parcial sem metadados e servidor sem tamanho"
    end
    if not why and server_size and have > server_size then why = "parcial maior que o arquivo" end
    if why then
      log("parcial descartado (" .. why .. "):", have, "bytes")
      os.remove(PART)
      meta = nil
      send({ t = "resume_discard", reason = why })
    else
      resume_from = have
      log("continuando o download do byte", have, "de", tostring(server_size))
    end
  else
    meta = nil
  end
  if resume_from == 0 then os.remove(META) end
  KEEP = info.ranges and true or false

  -- 2) espaco para o que falta ----------------------------------------------
  local avail = free_bytes(job.ports_dir)
  if expected and avail and avail < (expected - resume_from) + job.margin then
    return fail("no_space", string.format("%d|%d", (expected - resume_from) + job.margin, avail))
  end
  if check_cancel() then return cancel_done() end

  -- 3) download (em segundo plano, com acompanhamento) ---------------------
  META_T = { v = 1, id = job.id, slug = job.slug, name = job.name, url = job.url,
    total = expected, server_size = server_size, etag = info.etag, last_modified = info.lastmod,
    ranges = info.ranges or false, created = (meta and tonumber(meta.created)) or now, updated = now,
    state = "downloading", done = resume_from }
  if KEEP then write_meta(META_T) end
  send({ t = "resumable", ok = KEEP })
  -- If-Range: so ETag forte (sem W/) ou Last-Modified
  local ifrange = (info.etag and not info.etag:match("^W/")) and info.etag or info.lastmod
  send({ t = "phase", phase = "download", total = expected })
  if resume_from > 0 then
    send({ t = "resumed", from = resume_from, total = expected })
    send({ t = "progress", phase = "download", done = resume_from, total = expected })
  end
  local rc
  if server_size and resume_from == server_size then
    log("parcial ja estava completo")
    rc = 0
  else
    start_fetch(job.url, PART, WORK .. "/fetch.log", KEEP and ifrange or nil)
    rc = watch_fetch(PART, expected, function(b)
      if KEEP and META_T then META_T.done = b; META_T.updated = os.time(); write_meta(META_T) end
    end)
    if rc == "cancel" then return cancel_done() end
  end

  got = fsize(PART) or 0
  send({ t = "progress", phase = "download", done = got, total = expected })
  if rc ~= 0 then
    local flog = read_all(WORK .. "/fetch.log") or ""
    log("fetch rc=", rc, flog)
    if rc == 22 then
      local msg = flog:match("error:%s*([^\n]+)") or ""
      local http = tonumber(msg:match("(%d%d%d)") or "")
      -- erro do servidor passageiro (5xx, 408, 429): o parcial continua valendo
      if http and (http >= 500 or http == 408 or http == 429) then keep_partial("paused", rc)
      else KEEP = false end
      return fail("http_error", msg)
    end
    if rc == 127 then return fail("no_curl") end
    if rc == 23 then keep_partial("paused", rc); return fail("no_space", "") end
    -- rede: o parcial fica guardado para o proximo pedido do mesmo download
    if keep_partial("paused", rc) then
      return fail("net_paused", string.format("%d|%d|%d", got, expected or 0, rc))
    end
    return fail("net_error", tostring(rc))
  end
  -- baixou inteiro: daqui em diante qualquer falha apaga o arquivo
  KEEP = false
  os.remove(META)
  end -- fim do download

  -- 3) verificacao ----------------------------------------------------------
  send({ t = "phase", phase = "verify" })
  if got <= 0 then return fail("empty_file") end
  local f = io.open(PART, "rb")
  local head = f and f:read(512) or ""
  if f then f:close() end
  -- formato pela assinatura do arquivo (nao pela extensao do link)
  local fmt
  if head:sub(1, 2) == "PK" then fmt = "zip"
  elseif head:sub(1, 7) == "Rar!\26\7\0" or head:sub(1, 8) == "Rar!\26\7\1\0" then fmt = "rar"
  elseif head:sub(1, 6) == "7z\188\175\39\28" then fmt = "7z"
  elseif head:sub(258, 262) == "ustar" then fmt = "tar"; TARF = ""            -- .tar
  elseif head:sub(1, 2) == "\31\139" then fmt = "tar"; TARF = "z"            -- .tar.gz / .tgz
  elseif head:sub(1, 6) == "\253\55\122\88\90\0" then fmt = "tar"; TARF = "J" -- .tar.xz
  elseif head:sub(1, 3) == "BZh" then fmt = "tar"; TARF = "j"                -- .tar.bz2
  end
  if not fmt then
    local low = lower(head):gsub("^%s+", "")
    local what = "desconhecido"
    if low:find("^<!doct") or low:find("^<html") then
      what = (head:match("<[Tt][Ii][Tt][Ll][Ee]>%s*(.-)%s*</") or L("página HTML")):sub(1, 60)
    elseif low:sub(1, 1) == "{" or low:sub(1, 1) == "[" then
      what = L("resposta JSON")
    end
    return fail("not_zip", what)
  end
  log("formato do pacote:", fmt)
  if job.server_size and got ~= job.server_size then
    -- o servidor informou o tamanho e o arquivo veio diferente: download incompleto
    return fail("size_mismatch", string.format("%d|%d", got, job.server_size))
  elseif not job.local_file and not job.server_size and expected and got ~= expected then
    -- sem tamanho do servidor: o download terminou sem erro (curl/wget), mas o
    -- tamanho difere do catalogo, que pode estar arredondado. O hash (se houver)
    -- e a extracao (que falha com arquivo cortado), logo abaixo, conferem.
    log("aviso: tamanho baixado " .. got .. " difere do catalogo " .. expected .. " (servidor nao informou o tamanho)")
  end
  if job.sha256 and job.sha256 ~= "" then
    local sum = capture("sha256sum " .. shq(PART) .. " 2>/dev/null"):match("^(%x+)")
    if not sum then
      log("sha256sum indisponivel; pulando verificacao")
    elseif lower(sum) ~= lower(job.sha256) then
      return fail("checksum")
    end
  elseif job.md5 and job.md5 ~= "" then
    local sum = capture("md5sum " .. shq(PART) .. " 2>/dev/null"):match("^(%x+)")
    if sum and lower(sum) ~= lower(job.md5) then return fail("checksum") end
  end
  if job.local_file then
    ZIP = PART      -- usa o arquivo no lugar (so e excluido apos sucesso)
  elseif not os.rename(PART, ZIP) then
    return fail("no_write", WORK)
  end
  if check_cancel() then return cancel_done() end

  -- ZIP com senha ou dividido em partes: o 7-Zip (incluso no hub) cuida, como
  -- no PC. O unzip nao abre ZIP dividido nem testa varias senhas.
  local zip_pw = false
  if fmt == "zip" then
    if job.multipart then
      if find_7z() then fmt = "zip7" else return fail("no_extractor", "ZIP") end
    elseif sh("unzip -Z -v " .. shq(ZIP) .. " 2>/dev/null | grep -qiE 'file security status:[[:space:]]+encrypted'") then
      if find_7z() then fmt = "zip7" else zip_pw = true end
    end
  end
  if fmt == "zip" then
    if not sh("command -v unzip >/dev/null 2>&1") then return fail("no_unzip") end
    if zip_pw then
      for i, pw in ipairs(job.passwords or {}) do
        if sh("unzip -P " .. shq(pw) .. " -tqq " .. shq(ZIP) .. " >/dev/null 2>&1") then
          PWD = pw
          log("arquivo com senha: senha salva n." .. i .. " funcionou")
          break
        end
      end
      if not PWD then return fail("encrypted") end
    end
    -- lista do ZIP: tamanho descompactado, quantidade de itens, caminhos perigosos
    local listing = capture("unzip -Z1 " .. shq(ZIP) .. " 2>/dev/null")
    local entries = 0
    for line in listing:gmatch("[^\n]+") do
      entries = entries + 1
      if line:sub(1, 1) == "/" or line:find("%.%./") or line:find("/%.%.$") or line == ".." then
        return fail("unsafe_zip", line)
      end
    end
    if entries == 0 then return fail("bad_zip") end
    local summary = capture("unzip -l " .. shq(ZIP) .. " 2>/dev/null | tail -n 1")
    local unpacked = tonumber(summary:match("^%s*(%d+)")) or 0

    -- 4) espaco para extrair ---------------------------------------------------
    local avail = free_bytes(job.ports_dir)
    if avail and avail < unpacked + job.margin then
      return fail("no_space", string.format("%d|%d", unpacked + job.margin, avail))
    end

    -- 5) extracao para a pasta temporaria ------------------------------------
    send({ t = "phase", phase = "extract", total = entries })
    local h = io.popen("unzip -o " .. (PWD and ("-P " .. shq(PWD) .. " ") or "") .. shq(ZIP) .. " -d " .. shq(STAGE) .. " 2>&1; echo __PHX:$?")
    local count, code, lastpct = 0, nil, -1
    local errlines = {}
    if h then
      for line in h:lines() do
        local c = line:match("^__PHX:(%d+)")
        if c then
          code = tonumber(c)
        else
          if line:match("^%s+inflating:") or line:match("^%s+extracting:") or line:match("^%s+creating:")
              or line:match("^%s+linking:") then
            count = count + 1
          elseif line:lower():find("error") or line:lower():find("bad") then
            errlines[#errlines + 1] = line
          end
          local pct = math.floor(count / entries * 100)
          if pct ~= lastpct then
            send({ t = "progress", phase = "extract", done = count, total = entries })
            lastpct = pct
          end
          if count % 25 == 0 and check_cancel() then break end
        end
      end
      h:close()
    end
    if cancelled then return cancel_done() end
    -- unzip: 0 = ok, 1 = avisos (ok); >1 = erro (arquivo corrompido, disco cheio...)
    if code == nil or code > 1 then
      local detail = errlines[1] or (L("codigo ") .. tostring(code))
      if code == 50 then return fail("no_space", "") end
      return fail("bad_zip", detail)
    end
  elseif fmt == "tar" then
    -- TAR (.tar, .tar.gz, .tar.xz, .tar.bz2): o tar do sistema
    if not sh("command -v tar >/dev/null 2>&1") then return fail("no_extractor", "TAR") end
    -- lista: quantidade de itens, tamanho descompactado e caminhos perigosos
    local listing = capture("tar -tv" .. TARF .. "f " .. shq(ZIP) .. " 2>/dev/null")
    local entries, unpacked = 0, 0
    for line in listing:gmatch("[^\n]+") do
      -- "-rwxr-xr-x user/grupo 1234 2024-01-01 12:00 caminho" (links: "a -> b")
      local size, name = line:match("^%S+%s+%S+%s+(%d+)%s+%S+%s+%S+%s+(.+)$")
      if name then
        entries = entries + 1
        unpacked = unpacked + (tonumber(size) or 0)
        name = name:gsub(" %-> .*$", ""):gsub(" link to .*$", "")
        if name:sub(1, 1) == "/" or name:find("%.%./") or name:find("/%.%.$") or name == ".." then
          return fail("unsafe_zip", name)
        end
      end
    end
    if entries == 0 then return fail("bad_zip", "TAR") end
    local avail = free_bytes(job.ports_dir)
    if avail and avail < unpacked + job.margin then
      return fail("no_space", string.format("%d|%d", unpacked + job.margin, avail))
    end
    send({ t = "phase", phase = "extract", total = entries })
    local h = io.popen("tar -xv" .. TARF .. "f " .. shq(ZIP) .. " -C " .. shq(STAGE) .. " 2>&1; echo __PHX:$?")
    local count, code, lastpct = 0, nil, -1
    local errlines = {}
    if h then
      for line in h:lines() do
        local c = line:match("^__PHX:(%d+)")
        if c then
          code = tonumber(c)
        else
          if line:lower():find("^tar:") then errlines[#errlines + 1] = line else count = count + 1 end
          local pct = math.floor(math.min(count, entries) / entries * 100)
          if pct ~= lastpct then
            send({ t = "progress", phase = "extract", done = math.min(count, entries), total = entries })
            lastpct = pct
          end
          if count % 25 == 0 and check_cancel() then break end
        end
      end
      h:close()
    end
    if cancelled then return cancel_done() end
    if code ~= 0 then
      local detail = errlines[1] or (L("codigo ") .. tostring(code))
      if detail:find("No space") then return fail("no_space", "") end
      return fail("bad_zip", detail)
    end
  else
    -- RAR / 7z: extrator 7-Zip (incluso no hub) ou o do sistema
    local ok7, err7 = extract_7z(fmt == "zip7" and "zip" or fmt)
    if not ok7 then return end
  end

  -- 6) analise da estrutura ------------------------------------------------
  send({ t = "phase", phase = "analyze" })
  local JUNK = { ["__macosx"] = true, [".ds_store"] = true, ["thumbs.db"] = true, ["desktop.ini"] = true }

  local function list(dir)
    local items = {}
    local out = capture("cd " .. shq(dir) .. " && for f in * .[!.]* ..?*; do "
      .. "[ -e \"$f\" ] || [ -L \"$f\" ] || continue; "
      .. "if [ -d \"$f\" ] && [ ! -L \"$f\" ]; then echo \"D:$f\"; else echo \"F:$f\"; fi; done")
    for line in out:gmatch("[^\n]+") do
      local kind, name = line:match("^([DF]):(.+)$")
      if name and not JUNK[lower(name)] then
        items[#items + 1] = { name = name, dir = (kind == "D") }
      end
    end
    table.sort(items, function(a, b) return a.name < b.name end)
    return items
  end
  local function has_script(items)
    for _, it in ipairs(items) do
      if not it.dir and lower(it.name):match("%.sh$") then return true end
    end
    return false
  end

  -- Remove pastas "embrulho" para nao criar diretorios duplicados:
  --   roms/ports/Jogo.sh  ->  Jogo.sh
  --   ports/Jogo.sh       ->  Jogo.sh
  --   Jogo/Jogo.sh + Jogo/jogo/  ->  Jogo.sh + jogo/   (so se nao houver .sh na raiz)
  local root = STAGE
  for _ = 1, (job.mode == "extract" and 0 or 4) do
    local items = list(root)
    if #items == 1 and items[1].dir then
      local inner = root .. "/" .. items[1].name
      -- Pode haver varios embrulhos com nomes arbitrarios antes do .sh.
      -- So desce quando ha uma unica pasta; a validacao do script continua
      -- obrigatoria e nunca mistura duas arvores de ports diferentes.
      root = inner
    else
      break
    end
  end

  local items = list(root)
  if #items == 0 then return fail("empty_pkg") end

  -- porthub.txt (creditos do port: desenvolvedor, grupo, versao...) ao lado do
  -- .sh: o hub le e guarda dentro da pasta do jogo, para nao ficar solto na
  -- pasta ports (cada port traria o seu e um apagaria o do outro)
  local porthub_txt
  if job.mode ~= "extract" then
    local keep = {}
    local dirs = {}
    for _, it in ipairs(items) do if it.dir then dirs[#dirs + 1] = it.name end end
    for _, it in ipairs(items) do
      if not it.dir and lower(it.name) == "porthub.txt" then
        porthub_txt = read_all(root .. "/" .. it.name)
        if #dirs == 1 then
          sh("mv -f " .. shq(root .. "/" .. it.name) .. " " .. shq(root .. "/" .. dirs[1] .. "/porthub.txt"))
        else
          os.remove(root .. "/" .. it.name)
        end
        log("porthub.txt encontrado no pacote")
      else
        keep[#keep + 1] = it
      end
    end
    items = keep
  end
  if job.mode ~= "extract" and not has_script(items) and not job.allow_no_script then
    return fail("no_script")
  end

  -- Itens protegidos (PortMaster, o proprio hub, gamelist.xml) sao ignorados
  local install, skipped = {}, {}
  for _, it in ipairs(items) do
    if job.mode ~= "extract" and job.protected[lower(it.name)] then
      skipped[#skipped + 1] = it.name
    else
      install[#install + 1] = it
    end
  end
  if #install == 0 then return fail("empty_pkg") end

  -- 7) conflitos com o que ja esta instalado ------------------------------
  local conflicts = {}
  for _, it in ipairs(install) do
    if sh("test -e " .. shq(job.ports_dir .. "/" .. it.name) .. " -o -L " .. shq(job.ports_dir .. "/" .. it.name)) then
      conflicts[#conflicts + 1] = it.name
      it.exists = true
    end
  end
  if #conflicts > 0 and job.preapproved then
    log("substituicao ja confirmada pelo usuario:", table.concat(conflicts, ", "))
  elseif #conflicts > 0 then
    send({ t = "confirm", items = conflicts })
    local answer
    while answer == nil do
      local m = IN:demand(0.5)
      if m then
        if m.t == "answer" then answer = m.yes and true or false
        elseif m.t == "cancel" then answer = false end
      end
    end
    if not answer then return cancel_done() end
  end

  -- 8) instalacao -------------------------------------------------------------
  -- Adapta somente os launchers que serao instalados. Guarda o original antes
  -- de alterar; uma falha de backup interrompe antes de copiar o port.
  if job.knulli and job.mode ~= "extract" then
    local patch = require("core.portpatch")
    for _, it in ipairs(install) do
      if not it.dir and lower(it.name):match("%.sh$") then
        local path = root .. "/" .. it.name
        local text = read_all(path)
        local patched = patch.apply(text, job.ports_dir, job.slug)
        if text and patched ~= text then
          local backup = job.script_backup_dir .. "/" .. job.slug .. "/" .. os.date("%Y%m%d-%H%M%S")
          if not sh("mkdir -p " .. shq(backup) .. " && cp -p " .. shq(path) .. " " .. shq(backup .. "/" .. it.name)) then
            return fail("no_write", backup)
          end
          local f = io.open(path, "wb")
          if not f then return fail("no_write", path) end
          local wrote = f:write((patched:gsub("\r\n", "\n")))
          local closed = f:close()
          if not wrote or not closed then return fail("no_write", path) end
          log("launcher adaptado para Knulli:", it.name)
        end
      end
    end
  end
  send({ t = "phase", phase = "install", total = #install })
  local installed = {}
  for i, it in ipairs(install) do
    local src = root .. "/" .. it.name
    local dst = job.ports_dir .. "/" .. it.name
    local okmv
    if it.exists and it.dir and sh("test -d " .. shq(dst) .. " -a ! -L " .. shq(dst)) then
      -- Atualizacao: mescla, mantendo arquivos extras do usuario (saves, dados do jogo)
      okmv = sh("cp -a " .. shq(src) .. "/. " .. shq(dst) .. "/ 2>/dev/null || cp -rf "
        .. shq(src) .. "/. " .. shq(dst) .. "/")
    else
      if it.exists then sh("rm -rf " .. shq(dst)) end
      okmv = sh("mv -f " .. shq(src) .. " " .. shq(dst))
    end
    if not okmv then
      return fail("install_failed", it.name)
    end
    installed[#installed + 1] = it.name
    send({ t = "progress", phase = "install", done = i, total = #install })
  end

  -- scripts executaveis
  for _, name in ipairs(installed) do
    if lower(name):match("%.sh$") then
      sh("chmod +x " .. shq(job.ports_dir .. "/" .. name) .. " 2>/dev/null")
    end
  end
  -- RAR/7z feitos no Windows nao guardam a permissao de execucao:
  -- devolve +x aos scripts .sh e aos binarios ELF dentro das pastas do port
  if fmt ~= "zip" and job.mode ~= "extract" then
    for _, name in ipairs(installed) do
      local d = job.ports_dir .. "/" .. name
      if sh("test -d " .. shq(d) .. " -a ! -L " .. shq(d)) then
        -- pastas precisam de permissao de acesso (x) para o usuario do console
        sh("find " .. shq(d) .. " -type d -exec chmod u+rwx,go+rx {} + 2>/dev/null")
        sh("find " .. shq(d) .. " -type f \\( -name '*.sh' -o ! -name '*.*' -o -name '*.bin' -o -name '*.aarch64' -o -name '*.arm64' -o -name '*.elf' \\) "
          .. "-exec sh -c 'for f; do case \"$f\" in *.sh) chmod +x \"$f\";; *) [ \"$(head -c 4 \"$f\" 2>/dev/null)\" = \"$(printf \"\\177ELF\")\" ] && chmod +x \"$f\";; esac; done' sh {} + 2>/dev/null")
      end
    end
  end
  -- Knulli: port do PortMaster -> port.json/assinatura como o harbourmaster
  if job.pm then
    local okp, perr = pcall(pm_finish, installed)
    if not okp then log("port.json do PortMaster nao atualizado:", tostring(perr)) end
  end
  sh("sync")

  -- 9) limpeza (remove o ZIP temporario e a pasta de trabalho) ----------------
  cleanup()
  local deleted = false
  if job.local_file and job.delete_source then
    deleted = os.remove(job.local_file) and true or false
    -- arquivo em partes: as outras partes saem junto
    for _, ptn in ipairs(job.parts or {}) do
      if ptn ~= job.local_file then os.remove(ptn) end
    end
    log(deleted and L("arquivo compactado excluido:") or L("nao foi possivel excluir:"), job.local_file)
  end
  log("instalado:", table.concat(installed, ", "))
  -- origem: a senha dos grupos de ports e o proprio nome do grupo
  local source
  if PWD then
    for _, g in ipairs(job.groups or {}) do if g == PWD then source = g end end
  end
  send({ t = "done", entries = installed, skipped = skipped, deleted = deleted, source = source, porthub = porthub_txt })
end

local okrun, err = pcall(run)
if not okrun then
  log("falha interna:", err)
  pcall(cleanup)
  send({ t = "error", code = "internal", detail = tostring(err) })
end
