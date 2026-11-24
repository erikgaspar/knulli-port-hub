-- =============================================================================
--  Knulli: backup completo dos saves (um unico .tar.gz)
--   * /userdata/saves inteiro (todos os sistemas). "So saves" deixa de fora os
--     save states (*.state*, *.ppst do PPSSPP e suas miniaturas, pastas states/),
--     que costumam ser grandes; "saves + states" leva tudo.
--   * saves dos ports: em TODAS as pastas de <ports> (inclusive ports instalados
--     fora do hub), com as mesmas regras de core/savebackup.lua (M.DIRS/M.EXTS:
--     conf/, savedata/, saves/, save/ (= soh/Save), userdata/, *.sav/*.srm/*.save)
--     mais native-saves/ (ports "nextos"). A pasta do proprio hub fica de fora.
--   * configuracoes (opcional): knulli.conf (tem a senha do Wi-Fi!), configs do
--     EmulationStation, ajustes/remaps do RetroArch, PPSSPP e pareados Bluetooth.
--  Destino: /userdata/backups/knulli-port-hub/saves-<data>.tar.gz (+ .info).
--  Os caminhos ficam no arquivo como no cartao (userdata/...), entao restaurar
--  so grava por cima dos mesmos caminhos (extrai em "/"); nada e apagado.
--  Antes de gravar: tamanho estimado (sem compressao, pior caso) x espaco livre.
--  Tudo que demora roda em core/shjob (segundo plano). Somente no Knulli.
-- =============================================================================
local U = require("lib.util")
local C = require("config")

local M = {}

M.ROOT = "/userdata/backups/knulli-port-hub"
M.SAVES = "/userdata/saves"
M.MARGIN_KB = 64 * 1024              -- sobra minima no cartao depois do backup
-- pastas/arquivos de save dos ports (mesma base do backup por port)
local SB = require("core.savebackup")
M.PORT_DIRS = {}
for _, d in ipairs(SB.DIRS) do M.PORT_DIRS[#M.PORT_DIRS + 1] = d end
M.PORT_DIRS[#M.PORT_DIRS + 1] = "native-saves"
M.PORT_EXTS = SB.EXTS
-- pastas de <ports> que nunca sao de jogo
local SKIP_PORT = { images = true, autoinstall = true, PortMaster = true, ["knulli-app-store"] = false }
-- configuracoes opcionais (so as que existirem)
M.CONFIGS = {
  "/userdata/system/knulli.conf",
  "/userdata/system/configs/emulationstation/es_settings.cfg",
  "/userdata/system/configs/emulationstation/es_input.cfg",
  "/userdata/system/configs/emulationstation/es_systems_*.cfg",
  "/userdata/system/configs/retroarch/config",
  "/userdata/system/configs/retroarch/retroarchcustom.cfg",
  "/userdata/system/configs/ppsspp/PSP/SYSTEM",
  "/userdata/system/bluetooth/bluetooth.tar",
}
-- save states dentro de /userdata/saves (excluidos no modo "so saves").
-- Para o tar (curinga casa "/" nas exclusoes do GNU tar) e para o find (estimativa).
M.STATE_TAR = { "userdata/saves/*/states", "userdata/saves/*.state*", "userdata/saves/*.ppst",
  "userdata/saves/psp/*_[0-9].jpg", "userdata/saves/*.undo.jpg" }
local STATE_FIND = "\\( -path '*/states/*' -o -name '*.state*' -o -name '*.ppst' -o -path '*/psp/*_[0-9].jpg' -o -name '*.undo.jpg' \\)"

local PRE = "unset LD_LIBRARY_PATH; export LC_ALL=C; "
local function shc(cmd) return "sh -c " .. U.shq(PRE .. "{ " .. cmd .. "; } 2>&1") end
local function rel(p) return (p:gsub("^/+", "")) end

M.job = nil      -- { kind = "backup"|"restore", path=, t0=, bytes= }

-- ---------------------------------------------------------------------------
-- levantamento (o que entra e quanto ocupa), em segundo plano

local function ports_dir()
  local p = U.trim(U.capture("readlink -f -- " .. U.shq(C.PORTS_DIR) .. " 2>/dev/null") or "")
  return p ~= "" and p or C.PORTS_DIR
end

local function app_dir_name()
  local real = U.trim(U.capture("readlink -f -- " .. U.shq(C.APP_DIR) .. " 2>/dev/null") or "")
  return (real ~= "" and real or C.APP_DIR):match("([^/]+)/*$")
end

--- script do levantamento: linhas "SAVES kb", "STATES kb", "PORT kb<TAB>rel",
--- "CONF kb<TAB>rel", "FREE kb"
local function scan_script(dest)
  local P = ports_dir()
  local hub = app_dir_name()
  local dn, ex = {}, {}
  for _, d in ipairs(M.PORT_DIRS) do dn[#dn + 1] = "-iname " .. U.shq(d) end
  for _, e in ipairs(M.PORT_EXTS) do ex[#ex + 1] = "-iname " .. U.shq("*." .. e) end
  local skip = {}
  for k, v in pairs(SKIP_PORT) do if v then skip[#skip + 1] = k end end
  if hub then skip[#skip + 1] = hub end
  local case = {}
  for _, s in ipairs(skip) do case[#case + 1] = U.shq(s) end
  local conf = {}
  for _, c in ipairs(M.CONFIGS) do conf[#conf + 1] = c:gsub("([^%w/%._%-%*])", "\\%1") end
  return table.concat({
    "cd / || exit 2",
    "S=" .. U.shq(rel(M.SAVES)),
    "if [ -d \"$S\" ]; then",
    "  echo \"SAVES $(du -sk --apparent-size \"$S\" 2>/dev/null | cut -f1)\"",
    "  echo \"STATES $(find \"$S\" -type f " .. STATE_FIND .. " -printf '%s\\n' 2>/dev/null | awk '{s+=$1} END{printf \"%d\", s/1024}')\"",
    "fi",
    "P=" .. U.shq(rel(P)),
    "if [ -d \"$P\" ]; then",
    "  for d in \"$P\"/*/; do",
    "    n=$(basename \"$d\")",
    "    case \"$n\" in " .. table.concat(case, "|") .. "|*-images) continue ;; esac",
    "    find \"$P/$n\" -maxdepth 3 \\( -type d \\( " .. table.concat(dn, " -o ") .. " \\) -prune -print \\)"
      .. " -o \\( -type f \\( " .. table.concat(ex, " -o ") .. " \\) -size -20M -print \\) 2>/dev/null",
    "  done | awk 'index($0, \"/.\") { next } { for (i in seen) if (index($0, i \"/\") == 1) next; seen[$0]=1; print }' | while IFS= read -r it; do",
    "    printf 'PORT %s\\t%s\\n' \"$(du -sk --apparent-size \"$it\" 2>/dev/null | cut -f1)\" \"$it\"",
    "  done",
    "fi",
    "for c in " .. table.concat(conf, " ") .. "; do",
    "  [ -e \"$c\" ] && printf 'CONF %s\\t%s\\n' \"$(du -sk --apparent-size \"$c\" 2>/dev/null | cut -f1)\" \"${c#/}\"",
    "done",
    "D=" .. U.shq(dest) .. "; while [ ! -d \"$D\" ]; do D=$(dirname \"$D\"); done",
    "echo \"FREE $(df -Pk \"$D\" | awk 'NR==2{print $4}')\"",
  }, "\n")
end

--- cb(info) info = { saves_kb, states_kb, ports = {{rel, kb, port}}, ports_kb,
---   configs = {{rel, kb}}, configs_kb, free_kb, ports_dir, dest }
function M.scan(opts, cb)
  opts = opts or {}
  local dest = opts.dest or M.ROOT
  require("core.shjob").start({ shc("timeout 60 sh -c " .. U.shq(scan_script(dest))) }, function(res, err)
    local out = res and res[1] and res[1].out or ""
    local info = { saves_kb = 0, states_kb = 0, ports = {}, ports_kb = 0, configs = {}, configs_kb = 0, dest = dest,
      ports_dir = ports_dir(), error = err }
    for l in out:gmatch("[^\n]+") do
      local k, v = l:match("^(%u+) (%d+)$")
      if k == "SAVES" then info.saves_kb = tonumber(v)
      elseif k == "STATES" then info.states_kb = tonumber(v)
      elseif k == "FREE" then info.free_kb = tonumber(v) end
      local kb, path = l:match("^PORT (%d*)\t(.+)$")
      if path then
        local port = path:sub(#rel(info.ports_dir) + 2):match("^([^/]+)")
        info.ports[#info.ports + 1] = { rel = path, kb = tonumber(kb) or 0, port = port }
        info.ports_kb = info.ports_kb + (tonumber(kb) or 0)
      end
      kb, path = l:match("^CONF (%d*)\t(.+)$")
      if path then
        info.configs[#info.configs + 1] = { rel = path, kb = tonumber(kb) or 0 }
        info.configs_kb = info.configs_kb + (tonumber(kb) or 0)
      end
    end
    -- ports distintos (para mostrar "N ports")
    local seen, n = {}, 0
    for _, p in ipairs(info.ports) do if p.port and not seen[p.port] then seen[p.port] = true; n = n + 1 end end
    info.ports_n = n
    if cb then cb(info) end
  end)
end

--- tamanho estimado (KB, sem compressao) do backup escolhido
function M.estimate(info, mode, configs)
  local kb = (info.saves_kb or 0) + (info.ports_kb or 0)
  if mode ~= "states" then kb = kb - (info.states_kb or 0) end
  if configs then kb = kb + (info.configs_kb or 0) end
  return math.max(0, kb)
end

--- cabe no cartao? true | false, faltam_kb
function M.fits(info, est_kb)
  if not info.free_kb then return true end
  local need = est_kb + M.MARGIN_KB
  if info.free_kb >= need then return true end
  return false, need - info.free_kb
end

-- ---------------------------------------------------------------------------
-- backups feitos

local function parse_meta(txt)
  local m = {}
  for l in (txt or ""):gmatch("[^\n]+") do
    local k, v = l:match("^([%w_]+)=(.*)$")
    if k then m[k] = v end
  end
  return m
end

function M.meta(path) return parse_meta(U.read_file(path .. ".info")) end

--- { {path, name, date, bytes, meta} } mais novo primeiro
function M.list(dest)
  dest = dest or M.ROOT
  local out = U.capture("ls -1t " .. U.shq(dest) .. " 2>/dev/null") or ""
  local res = {}
  for n in out:gmatch("[^\n]+") do
    if n:match("^saves%-.*%.tar%.gz$") then
      local path = dest .. "/" .. n
      local y, mo, da, h, mi = n:match("saves%-(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)")
      res[#res + 1] = { path = path, name = n, bytes = U.file_size(path), meta = M.meta(path),
        date = y and string.format("%s/%s/%s %s:%s", da, mo, y, h, mi) or n }
    end
  end
  return res
end

function M.delete(path)
  if type(path) ~= "string" or not path:match("/saves%-[^/]*%.tar%.gz$") then return false end
  local ok = os.remove(path)
  os.remove(path .. ".info")
  return ok and true or false
end

-- ---------------------------------------------------------------------------
-- fazer backup

--- opts = { info = (de M.scan), mode = "saves"|"states", configs = bool, dest = }
--- on_done(ok, path_ou_erro, meta)
function M.backup(opts, on_done)
  local info = opts.info
  if M.job then if on_done then on_done(false, "busy") end return false end
  if not info then if on_done then on_done(false, "scan") end return false end
  local dest = opts.dest or info.dest or M.ROOT
  local mode = opts.mode == "states" and "states" or "saves"
  local items = {}
  if (info.saves_kb or 0) > 0 then items[#items + 1] = rel(M.SAVES) end
  for _, p in ipairs(info.ports) do items[#items + 1] = p.rel end
  if opts.configs then for _, c in ipairs(info.configs) do items[#items + 1] = c.rel end end
  if #items == 0 then if on_done then on_done(false, "empty") end return false end
  local est = M.estimate(info, mode, opts.configs)
  local fits, missing = M.fits(info, est)
  if not fits then if on_done then on_done(false, "space", { missing_kb = missing }) end return false end
  os.execute("mkdir -p " .. U.shq(dest) .. " 2>/dev/null")
  local stamp = os.date("%Y%m%d-%H%M%S")
  local path = dest .. "/saves-" .. stamp .. ".tar.gz"
  local list = dest .. "/.lista-" .. stamp .. ".txt"
  if not U.write_file(list, table.concat(items, "\n") .. "\n") then
    if on_done then on_done(false, "write") end
    return false
  end
  local exc = {}
  if mode == "saves" then
    for _, p in ipairs(M.STATE_TAR) do exc[#exc + 1] = "--exclude=" .. U.shq(p) end
  end
  -- rc 1 do GNU tar = aviso ("arquivo mudou durante a leitura"): o backup vale
  local cmd = "tar -czf " .. U.shq(path .. ".part") .. " -C / " .. table.concat(exc, " ")
    .. " --ignore-failed-read -T " .. U.shq(list) .. "; rc=$?; rm -f " .. U.shq(list)
    .. "; if [ $rc -le 1 ]; then mv -f " .. U.shq(path .. ".part") .. " " .. U.shq(path)
    .. " && n=$(tar -tzf " .. U.shq(path) .. " | grep -vc '/$'); echo \"__FILES=$n\"; else rm -f " .. U.shq(path .. ".part") .. "; fi; sync; exit $rc"
  M.job = { kind = "backup", path = path, part = path .. ".part", t0 = love.timer.getTime(), est_kb = est }
  require("core.shjob").start({ shc(cmd) }, function(res, err)
    M.job = nil
    local r = res and res[1]
    local rc = r and r.rc or 2
    if rc > 1 or not U.exists(path) then
      U.log("backup completo falhou:", tostring(err or (r and r.out)))
      if on_done then on_done(false, tostring(err or (r and r.out) or "?")) end
      return
    end
    local meta = {
      created = os.date("%Y-%m-%d %H:%M:%S"), mode = mode, configs = opts.configs and "1" or "0",
      files = (r.out or ""):match("__FILES=(%d+)") or "?", est_kb = tostring(est),
      ports = tostring(info.ports_n or 0), items = tostring(#items),
    }
    local mt = {}
    for _, k in ipairs({ "created", "mode", "configs", "files", "est_kb", "ports", "items" }) do mt[#mt + 1] = k .. "=" .. meta[k] end
    mt[#mt + 1] = "paths=" .. table.concat(items, "|")
    U.write_file(path .. ".info", table.concat(mt, "\n") .. "\n")
    U.log("backup completo:", path, meta.files .. " arquivos", mode)
    if on_done then on_done(true, path, meta) end
  end)
  return true
end

--- bytes ja gravados do backup em andamento (para a barra)
function M.progress()
  local j = M.job
  if not j then return nil end
  if j.kind == "backup" then
    j.bytes = U.file_size(j.part) or j.bytes or 0
    return j.bytes, (j.est_kb or 0) * 1024
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- restaurar

--- extrai por cima dos mesmos caminhos. opts.base = raiz da extracao ("/"; nos
--- testes, uma pasta em /tmp). Recusa arquivos com caminhos fora de userdata/.
--- on_done(ok, msg, n_arquivos)
function M.restore(path, opts, on_done)
  opts = opts or {}
  local base = opts.base or "/"
  if M.job then if on_done then on_done(false, "busy") end return false end
  if not U.exists(path) then if on_done then on_done(false, "missing") end return false end
  local F = U.shq(path)
  local cmd = "L=$(tar -tzf " .. F .. ") || exit 2; "
    .. "bad=$(printf '%s\\n' \"$L\" | grep -v '^userdata/' | grep -c .); "
    .. "dots=$(printf '%s\\n' \"$L\" | grep -c '\\(^\\|/\\)\\.\\.\\(/\\|$\\)'); "
    .. "if [ \"$bad\" != 0 ] || [ \"$dots\" != 0 ]; then echo __UNSAFE; exit 3; fi; "
    .. "mkdir -p " .. U.shq(base) .. " && tar -xzf " .. F .. " -C " .. U.shq(base) .. "; rc=$?; "
    .. "echo \"__FILES=$(printf '%s\\n' \"$L\" | grep -vc '/$')\"; sync; exit $rc"
  M.job = { kind = "restore", path = path, t0 = love.timer.getTime() }
  require("core.shjob").start({ shc(cmd) }, function(res, err)
    M.job = nil
    local r = res and res[1]
    local out = r and r.out or ""
    local ok = r and r.rc == 0
    local n = tonumber(out:match("__FILES=(%d+)"))
    local msg = nil
    if not ok then msg = out:find("__UNSAFE") and "unsafe" or tostring(err or out) end
    U.log("restaurar backup completo:", path, "em", base, ok and "ok" or tostring(msg))
    if on_done then on_done(ok and true or false, msg, n) end
  end)
  return true
end

return M
