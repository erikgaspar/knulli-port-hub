-- =============================================================================
--  Traducoes de ROMs - jogos de CD (psx, segacd, pcenginecd, saturn, dreamcast)
--  Complemento de core/romtrans.lua (ligado por CD.bind(RT) no fim dele).
--
--  No indice, o "rom" de um jogo de CD e o hash do arquivo que recebe o patch:
--  o .bin da faixa de dados (normalmente "Track 1" do Redump) ou o .iso.
--
--  .cue/.bin e .iso soltos: o fluxo normal do romtrans (o .bin casa pelo hash;
--      arquivos grandes so tem hash calculado quando o tamanho bate com o
--      indice). Aqui ficam so a pasta de trabalho, o calculo de espaco e o
--      .cue/.m3u que representam o jogo no gamelist.
--  .chd: o hash das faixas so sai extraindo. "Verificar" (um CHD por vez):
--      chdman extractcd -> divide em uma faixa por arquivo (romtrans_patch.py
--      cdsplit) -> hash de cada faixa -> cache "SHA1 do CHD -> faixas"
--      (cache/romtrans_chd.json) -> apaga a extracao. Traduzir: extractcd ->
--      patch na faixa que casou -> createcd -> verify -> extrai o CHD novo e
--      confere todas as faixas -> original para o backup -> CHD novo no lugar,
--      com o MESMO nome. Desfazer (romtrans.op_undo) devolve o .chd original.
--      GD-ROM (Dreamcast): extrai para .gdi (uma faixa por arquivo) e recria
--      do .gdi, para continuar GD-ROM.
--  Nao suportado: .pbp (EBOOT do PSP com PS1), .cso e .chd do PSP (DVD: o
--      chdman 0.251 nao tem createdvd).
--
--  O chdman e o do "Converter para CHD" (core/chdconv.lua: mesmo local,
--  mesmo jeito de rodar com progresso e cancelamento).
-- =============================================================================
local U = require("lib.util")
local json = require("lib.json")

local CD = {}
local RT   -- core.romtrans (CD.bind)

CD.SYSTEMS = { psx = true, segacd = true, pcenginecd = true, saturn = true, dreamcast = true }

CD.MARGIN = 32 * 1024 * 1024          -- folga em cada conta de espaco
CD.PATCH_GUESS = 64 * 1024 * 1024     -- tamanho do patch quando o indice nao diz

CD.WHY = {
  pbp = "arquivo .pbp (EBOOT do PSP com jogo de PS1): não suportado — converta para CHD (ou .cue/.bin) no computador primeiro",
  cso = "arquivo .cso (imagem comprimida do PSP): não suportado",
  psp_chd = ".chd do PSP é um DVD; o chdman 0.251 deste aparelho não recria CHD de DVD (falta o createdvd)",
  dvd = "este .chd não é de CD (DVD/disco rígido): não suportado",
  subcode = "este .chd guarda o subcódigo das faixas: não suportado",
}

function CD.bind(rt) RT = rt end

local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end
local function lower(s) return (s or ""):lower() end
local function ext_of(p) return lower((p or ""):match("%.([^./]+)$") or "") end
local function dir_of(p) return p:match("^(.*)/[^/]*$") or "." end
local function sh_ok(cmd)
  local r = os.execute(cmd .. " >/dev/null 2>&1")
  return r == 0 or r == true
end
local function fsize(p) return RT.fsize(p) end

--- e jogo de CD (para avisos e pasta de trabalho)?
function CD.is_cd(sys, rel)
  local e = ext_of(rel)
  if e == "chd" or e == "iso" or e == "cue" then return true end
  return CD.SYSTEMS[sys] == true and (e == "bin" or e == "img")
end

--- motivo de "nao suportado" para um arquivo do scan (ou nil)
function CD.unsupported(f)
  if f.kind == "pbp" then return CD.WHY.pbp end
  if f.kind == "cso" then return CD.WHY.cso end
  if f.kind == "chd" and f.sys == "psp" then return CD.WHY.psp_chd end
  return nil
end

-------------------------------------------------------------------------------
-- pasta de trabalho (so dentro de /userdata) e espaco
-------------------------------------------------------------------------------
function CD.valid_work_dir(p)
  p = trim(p or "")
  return p:sub(1, 10) == "/userdata/" and not p:find("/%.%.") and not p:find("[%c\"'`$\\]") and #p > 10
end

function CD.settings_path() return RT.cfg.conf_dir .. "/romtrans_settings.json" end

function CD.load_settings()
  local ok, d = pcall(json.decode, U.read_file(CD.settings_path()) or "")
  return (ok and type(d) == "table") and d or {}
end

--- pasta de trabalho atual (a da configuracao, se valida; senao a tmp do app)
function CD.work_dir()
  local w = RT.cfg.work_dir
  if w and w ~= "" then return w end
  return RT.cfg.tmp_dir
end

--- troca a pasta de trabalho (nil = padrao). ok | nil, erro
function CD.set_work_dir(p)
  if p and not CD.valid_work_dir(p) then return nil, "a pasta de trabalho precisa ficar dentro de /userdata" end
  local d = CD.load_settings()
  d.work_dir = p
  U.exec_ok("mkdir -p " .. U.shq(RT.cfg.conf_dir))
  local text = json.encode(d, true)
  local tmp = CD.settings_path() .. ".tmp"
  if not U.write_file(tmp, text) or not os.rename(tmp, CD.settings_path()) then
    os.remove(tmp); return nil, "não foi possível gravar a configuração"
  end
  RT.cfg.work_dir = p
  return true
end

--- particao (dispositivo do df) de um caminho (sobe ate achar o que existe)
function CD.dev_of(path)
  local p = path
  for _ = 1, 12 do
    if sh_ok("test -e " .. U.shq(p)) then break end
    p = dir_of(p)
  end
  local out = U.capture("df -P " .. U.shq(p) .. " 2>/dev/null | tail -1") or ""
  return out:match("^(%S+)") or p
end

--- confere o espaco de uma lista { {dir, bytes, what}, ... } somando por particao.
--- devolve true | nil, mensagem
function CD.check_space(list)
  local per, order = {}, {}
  for _, it in ipairs(list) do
    if (it[2] or 0) > 0 then
      local d = CD.dev_of(it[1])
      if not per[d] then per[d] = { dir = it[1], bytes = 0 }; order[#order + 1] = d end
      per[d].bytes = per[d].bytes + it[2]
    end
  end
  for _, d in ipairs(order) do
    local x = per[d]
    local need = x.bytes + CD.MARGIN
    local free = RT.free_kb(x.dir)
    if free and free * 1024 < need then
      return nil, string.format("espaço insuficiente em %s: no pior caso precisa de %s, há %s livres", x.dir,
        U.format_bytes(need), U.format_bytes(free * 1024))
    end
  end
  return true
end

-------------------------------------------------------------------------------
-- chdman (o do "Converter para CHD")
-------------------------------------------------------------------------------
function CD.chdman() return (RT.cfg.chdman_dir or "") .. "/chdman.sh" end

function CD.installed()
  return fsize(CD.chdman()) ~= nil and fsize((RT.cfg.chdman_dir or "") .. "/bin/chdman") ~= nil
end

local CH
local function chd_run(args, on_pct)
  CH = CH or require("core.chdconv")
  CH.setup({ tool_dir = RT.cfg.chdman_dir })
  CH.cancelled = function() return RT.cancelled() end
  return CH.run_chdman(args, on_pct or function() end)
end

--- chdman info -v: { sha1, logical, gd, tracks = { {n, type, subtype, frames} } } | nil, erro
function CD.info(path)
  if not CD.installed() then return nil, "o chdman não está instalado (instale em \"Converter para CHD\")" end
  local out, rc = RT.run_cmd(U.shq(CD.chdman()) .. " info -v -i " .. U.shq(path))
  if rc ~= 0 then
    return nil, "o chdman não leu o arquivo: " .. (trim(out):match("([^\n]+)$") or ("código " .. rc))
  end
  local r = { tracks = {} }
  r.sha1 = lower(out:match("\nSHA1:%s+(%x+)") or "")
  r.logical = tonumber(((out:match("Logical size:%s+([%d,]+)") or ""):gsub(",", "")))
  r.gd = out:find("Tag='CHGD'", 1, true) ~= nil
  for n, ty, sub, fr in out:gmatch("TRACK:(%d+) TYPE:(%S+) SUBTYPE:(%S+) FRAMES:(%d+)") do
    r.tracks[#r.tracks + 1] = { n = tonumber(n), type = ty, subtype = sub, frames = tonumber(fr) }
  end
  if r.sha1 == "" or not r.logical then return nil, "resposta inesperada do chdman info" end
  return r
end

--- o CHD pode ser tratado? nil | motivo
local function info_problem(info)
  if #info.tracks == 0 then return CD.WHY.dvd end
  for _, t in ipairs(info.tracks) do
    if t.subtype ~= "NONE" then return CD.WHY.subcode end
  end
  return nil
end

-------------------------------------------------------------------------------
-- cache "SHA1 do CHD -> hashes das faixas" e "arquivo (caminho|tamanho|mtime) -> SHA1"
-------------------------------------------------------------------------------
function CD.cache_path() return RT.cfg.cache_dir .. "/romtrans_chd.json" end

function CD.cache_load()
  local ok, d = pcall(json.decode, U.read_file(CD.cache_path()) or "")
  if not ok or type(d) ~= "table" or d.format ~= 1 then d = { format = 1 } end
  d.chd = type(d.chd) == "table" and d.chd or {}
  d.files = type(d.files) == "table" and d.files or {}
  return d
end

function CD.cache_save(c)
  U.exec_ok("mkdir -p " .. U.shq(RT.cfg.cache_dir))
  -- tira as entradas de arquivos que sumiram
  for k in pairs(c.files) do
    local p = k:match("^(.*)|%d+|%d+$")
    if p and not fsize(p) then c.files[k] = nil end
  end
  local text = json.encode(c)
  local tmp = CD.cache_path() .. ".tmp"
  if U.write_file(tmp, text) then os.rename(tmp, CD.cache_path()) end
end

local function file_key(path, size, mtime) return path .. "|" .. tostring(size) .. "|" .. tostring(mtime) end

local function mtime_of(path)
  return tonumber(trim(U.capture("stat -c %Y " .. U.shq(path) .. " 2>/dev/null") or ""))
end
CD.mtime_of = mtime_of

--- faixas conhecidas de um .chd do scan (ou nil se ainda nao verificado)
function CD.cached(cache, f)
  local sha = cache.files[file_key(f.path, f.size, f.mtime)]
  local e = sha and cache.chd[sha]
  if e then return e, sha end
  return nil
end

-------------------------------------------------------------------------------
-- extracao
-------------------------------------------------------------------------------
--- roda o cdsplit do python lendo o progresso
local function cdsplit(cue, dir, report)
  local outj = dir .. "/split.json"
  local h = io.popen(RT.py_cmd("cdsplit " .. U.shq(cue) .. " " .. U.shq(dir) .. " " .. U.shq(outj)) .. " 2>&1")
  if not h then error("não foi possível rodar o python3", 0) end
  local other = {}
  for line in h:lines() do
    local d, t = line:match("^P\t(%d+)\t(%d+)$")
    if d then report(tonumber(d) / math.max(1, tonumber(t)) * 100)
    elseif not line:match("^OK") then other[#other + 1] = line end
  end
  h:close()
  local ok, d = pcall(json.decode, U.read_file(outj) or "")
  os.remove(outj)
  if not ok or type(d) ~= "table" or type(d.tracks) ~= "table" then
    local msg = table.concat(other, "\n")
    error("não foi possível separar as faixas: " .. ((msg:match("ERRO: ([^\n]+)") or msg):sub(-200)), 0)
  end
  for _, t in ipairs(d.tracks) do t.path = dir .. "/" .. t.file end
  return d.cue, d.tracks
end

--- extrai o CHD em dir (uma faixa por arquivo). report(fase, pct).
--- devolve { src = .cue/.gdi para o createcd, tracks = { {n, path, size, crc32, md5, sha1} } }
function CD.extract(chd, dir, info, report)
  if not sh_ok("mkdir -p " .. U.shq(dir)) then error("não foi possível criar " .. dir, 0) end
  if info.gd then
    local gdi = dir .. "/disc.gdi"
    local ok, out, canc = chd_run("extractcd -i " .. U.shq(chd) .. " -o " .. U.shq(gdi),
      function(p) report("extract", p) end)
    if canc then error("cancelado", 0) end
    if not ok then error("o chdman não extraiu o CHD: " .. (out ~= "" and out or "?"), 0) end
    CH = CH or require("core.chdconv")
    local names = CH.gdi_files(U.read_file(gdi) or "")
    local tracks = {}
    for i, n in ipairs(names) do
      report("hash", (i - 1) / #names * 100)
      local p = dir .. "/" .. n
      local h, err = RT.hash(p)
      if not h then error(err, 0) end
      tracks[#tracks + 1] = { n = i, path = p, file = n, size = h.size, crc32 = h.crc32, md5 = h.md5, sha1 = h.sha1 }
      if RT.cancelled() then error("cancelado", 0) end
    end
    if #tracks == 0 then error("o .gdi extraído não tem faixas", 0) end
    return { src = gdi, tracks = tracks }
  end
  local cue, bin = dir .. "/x.cue", dir .. "/x.bin"
  local ok, out, canc = chd_run("extractcd -i " .. U.shq(chd) .. " -o " .. U.shq(cue) .. " -ob " .. U.shq(bin),
    function(p) report("extract", p) end)
  if canc then error("cancelado", 0) end
  if not ok then error("o chdman não extraiu o CHD: " .. (out ~= "" and out or "?"), 0) end
  if RT.cancelled() then error("cancelado", 0) end
  local ncue, tracks = cdsplit(cue, dir, function(p) report("hash", p) end)
  os.remove(cue)
  return { src = ncue, tracks = tracks }
end

local function strip_tracks(tracks)
  local t = {}
  for _, x in ipairs(tracks) do
    t[#t + 1] = { n = x.n, type = x.type, size = x.size, crc32 = x.crc32, md5 = x.md5, sha1 = x.sha1 }
  end
  return t
end

local PHASE = { extract = "Extraindo o CHD", hash = "Separando as faixas e calculando os hashes",
  create = "Recriando o CHD", verify = "Conferindo o CHD novo", check = "Extraindo o CHD novo para conferir",
  checkhash = "Conferindo as faixas do CHD novo" }
CD.PHASE = PHASE

-------------------------------------------------------------------------------
-- VERIFICAR um .chd (um por vez): hash de cada faixa para o cache
-------------------------------------------------------------------------------
function CD.op_verify(p)
  local f = p.file
  if not f or not f.path then error("nada para verificar", 0) end
  if not RT.inside_root(f.path) then error("caminho fora da pasta de ROMs: " .. tostring(f.path), 0) end
  local why = CD.unsupported(f)
  if why then error(why, 0) end
  RT.progress(1, 3, "Lendo o CHD")
  local size = fsize(f.path)
  if not size then error("o arquivo não está mais em " .. f.path, 0) end
  local info, err = CD.info(f.path)
  if not info then error(err, 0) end
  local prob = info_problem(info)
  if prob then error(prob, 0) end
  local cache = CD.cache_load()
  local mt = mtime_of(f.path)
  if cache.chd[info.sha1] then
    cache.files[file_key(f.path, size, mt)] = info.sha1
    CD.cache_save(cache)
    return { ok = true, sha1 = info.sha1, tracks = cache.chd[info.sha1].tracks, cached = true }
  end
  local work_base = CD.work_dir()
  local sok, serr = CD.check_space({ { work_base, info.logical, "extração" } })
  if not sok then error(serr, 0) end
  local work = RT.new_workdir(work_base)
  local ok, res = pcall(function()
    local x = CD.extract(f.path, work .. "/x", info, function(ph, pct)
      RT.progress(ph == "extract" and 2 or 3, 3, PHASE[ph], pct)
    end)
    return x
  end)
  sh_ok("rm -rf " .. U.shq(work))
  if not ok then error(res, 0) end
  cache = CD.cache_load()
  cache.chd[info.sha1] = { tracks = strip_tracks(res.tracks), gd = info.gd, logical = info.logical,
    chd_size = size, date = os.date("%Y-%m-%d %H:%M") }
  cache.files[file_key(f.path, size, mt)] = info.sha1
  CD.cache_save(cache)
  return { ok = true, sha1 = info.sha1, tracks = cache.chd[info.sha1].tracks }
end

-------------------------------------------------------------------------------
-- espaco para traduzir (pior caso)
-------------------------------------------------------------------------------
local function patch_guess(t)
  return tonumber(t.patch_size) or CD.PATCH_GUESS
end

--- .bin/.iso solto: resultado (T) + patch na pasta de trabalho; resultado na
--- pasta do jogo se for outra particao; original no backup se for outra particao
function CD.space_file(m)
  local T = (m.before and m.before.size) or m.size or 0
  local work = CD.work_dir()
  local list = { { work, T + patch_guess(m.t) } }
  if CD.dev_of(work) ~= CD.dev_of(m.path) then list[#list + 1] = { dir_of(m.path), T } end
  if CD.dev_of(RT.cfg.backup_dir) ~= CD.dev_of(m.path) then list[#list + 1] = { RT.cfg.backup_dir, m.size or 0 } end
  return list
end

--- .chd: extraido (E) + faixa traduzida (T) + patch, ou E + CHD novo (C)
function CD.space_chd(m, logical)
  local E = logical or ((m.cd_logical or 0) > 0 and m.cd_logical) or (m.size or 0) * 3
  local T = (m.before and m.before.size) or 0
  local C = math.floor((m.size or 0) * 1.15)
  local work = CD.work_dir()
  local list = { { work, E + math.max(T + patch_guess(m.t), C) } }
  if CD.dev_of(work) ~= CD.dev_of(m.path) then list[#list + 1] = { dir_of(m.path), C } end
  if CD.dev_of(RT.cfg.backup_dir) ~= CD.dev_of(m.path) then list[#list + 1] = { RT.cfg.backup_dir, m.size or 0 } end
  return list
end

--- total do pior caso (para mostrar na tela)
function CD.space_total(list)
  local n = 0
  for _, it in ipairs(list) do n = n + (it[2] or 0) end
  return n + CD.MARGIN
end

-------------------------------------------------------------------------------
-- TRADUZIR um .chd
-------------------------------------------------------------------------------
function CD.translate_chd(m, ctx)
  local t = m.t
  local steps = 8
  local function step(i, text, pct) RT.progress(i, steps, text, pct) end
  if not CD.installed() then error("o chdman não está instalado (instale em \"Converter para CHD\")", 0) end
  step(1, "Lendo o CHD")
  local info, ierr = CD.info(m.path)
  if not info then error(ierr, 0) end
  local prob = info_problem(info)
  if prob then error(prob, 0) end
  if m.chd_sha1 and info.sha1 ~= m.chd_sha1 then error("o CHD mudou desde a verificação; procure de novo", 0) end
  local sok, serr = CD.check_space(CD.space_chd(m, info.logical))
  if not sok then error(serr, 0) end

  local work = RT.new_workdir(CD.work_dir())
  local ok, res = pcall(function()
    step(1, "Baixando o patch")
    local patch = RT.get_patch(t, work)
    if RT.cancelled() then error("cancelado", 0) end

    local x = CD.extract(m.path, work .. "/x", info, function(ph, pct)
      step(ph == "extract" and 2 or 3, PHASE[ph], pct)
    end)
    step(3, "Conferindo a faixa")
    local tr
    for _, tk in ipairs(x.tracks) do
      if tk.n == m.track and RT.hash_match(t.rom, tk) then tr = tk end
    end
    if not tr then
      for _, tk in ipairs(x.tracks) do if RT.hash_match(t.rom, tk) then tr = tk end end
    end
    if not tr then error("nenhuma faixa do CHD confere com a versão exigida pela tradução (hash diferente)", 0) end
    if RT.cancelled() then error("cancelado", 0) end

    step(4, "Aplicando a tradução")
    local outp = work .. "/track.out"
    local o, e = RT.py("apply " .. U.shq(t.patch_format) .. " " .. U.shq(tr.path) .. " " .. U.shq(patch) .. " " .. U.shq(outp))
    if not o then error("o patch não pôde ser aplicado: " .. e, 0) end
    os.remove(patch)
    local ah, aerr = RT.hash(outp)
    if not ah then error(aerr, 0) end
    local verified = false
    if t.result then
      if not RT.hash_match(t.result, ah) then
        error("o resultado não confere com o hash esperado pelo índice; nada foi trocado", 0)
      end
      verified = true
    end
    if ah.size % 2048 ~= 0 and ah.size % 2352 ~= 0 then
      error("a faixa traduzida não tem um número inteiro de setores; nada foi trocado", 0)
    end
    if not os.remove(tr.path) or not os.rename(outp, tr.path) then error("não foi possível trocar a faixa", 0) end
    if RT.cancelled() then error("cancelado", 0) end

    step(5, PHASE.create, 0)
    local newchd = work .. "/new.chd"
    local cok, cout, ccanc = chd_run("createcd -i " .. U.shq(x.src) .. " -o " .. U.shq(newchd),
      function(p) step(5, PHASE.create, p) end)
    if ccanc then error("cancelado", 0) end
    if not cok then error("o chdman não recriou o CHD: " .. (cout ~= "" and cout or "?"), 0) end
    -- a extracao nao serve mais: libera o espaco antes de conferir
    sh_ok("rm -rf " .. U.shq(work .. "/x"))

    step(6, PHASE.verify, 0)
    local vok, vout, vcanc = chd_run("verify -i " .. U.shq(newchd), function(p) step(6, PHASE.verify, p) end)
    if vcanc then error("cancelado", 0) end
    if not vok then error("o CHD novo não passou na verificação: " .. (vout ~= "" and vout or "?"), 0) end
    local ninfo, nerr = CD.info(newchd)
    if not ninfo then error(nerr, 0) end
    if #ninfo.tracks ~= #info.tracks or ninfo.gd ~= info.gd then
      error("o CHD novo não tem as mesmas faixas do original; nada foi trocado", 0)
    end
    local y = CD.extract(newchd, work .. "/chk", ninfo, function(ph, pct)
      step(6, ph == "extract" and PHASE.check or PHASE.checkhash, pct)
    end)
    for i, tk in ipairs(y.tracks) do
      local want = (x.tracks[i].n == tr.n) and ah or x.tracks[i]
      if tk.sha1 ~= want.sha1 or tk.size ~= want.size then
        error(string.format("a faixa %d do CHD novo não confere; nada foi trocado", tk.n), 0)
      end
    end
    local new_tracks = strip_tracks(y.tracks)
    sh_ok("rm -rf " .. U.shq(work .. "/chk"))
    if RT.cancelled() then error("cancelado", 0) end

    step(7, "Guardando o CHD original e gravando o traduzido")
    local before_size = fsize(m.path)
    local bpath = RT.install_file(newchd, m)
    local after_size = fsize(m.path)

    -- cache: o CHD novo ja tem as faixas conhecidas (aparece como "ja traduzido")
    local cache = CD.cache_load()
    cache.chd[ninfo.sha1] = { tracks = new_tracks, gd = ninfo.gd, logical = ninfo.logical, chd_size = after_size,
      date = os.date("%Y-%m-%d %H:%M") }
    cache.files[file_key(m.path, after_size, mtime_of(m.path))] = ninfo.sha1
    local bm = mtime_of(bpath)
    if bm then cache.files[file_key(m.path, before_size, bm)] = info.sha1 end
    CD.cache_save(cache)

    step(8, "Atualizando a lista de jogos")
    return RT.finish_translate(m, {
      kind = "chd", track = tr.n, verified = verified, backup = bpath,
      before = tr, after = ah,
      file_before = { size = before_size }, file_after = { size = after_size },
      chd_before = { sha1 = info.sha1, size = before_size }, chd_after = { sha1 = ninfo.sha1, size = after_size },
    })
  end)
  sh_ok("rm -rf " .. U.shq(work))
  if not ok then error(res, 0) end
  return res
end

--- o .chd atual e o que o app gravou? (para o desfazer: so o cabecalho, rapido)
function CD.same_chd(rec)
  local info = CD.info(rec.path)
  return info ~= nil and rec.chd_after ~= nil and info.sha1 == rec.chd_after.sha1
end

return CD
