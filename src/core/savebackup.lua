-- =============================================================================
--  Backup dos saves dos ports
--  Ports do PortMaster guardam o progresso dentro da propria pasta do jogo,
--  quase sempre em conf/ (XDG_DATA_HOME/XDG_CONFIG_HOME apontam para la),
--  savedata/, saves/, save/ ou userdata/, alem de arquivos .sav/.srm/.save.
--  Este modulo procura SO esses itens dentro das pastas do port instalado e
--  guarda um .tar.gz em <pasta do app>/backups/saves/<id do port>/.
--  Nada do port e alterado no backup; a restauracao so grava por cima dos
--  mesmos caminhos (pede confirmacao antes).
-- =============================================================================
local L = require("lib.i18n").L
local U = require("lib.util")
local C = require("config")

local M = {}

M.DIRS = { "conf", "savedata", "saves", "save", "userdata" }
M.EXTS = { "sav", "srm", "save" }
M.KEEP = 5                         -- backups guardados por port
M.MAX_BYTES = 300 * 1024 * 1024    -- acima disso o hub avisa antes

function M.root() return C.APP_DIR .. "/backups/saves" end
function M.dir(p) return M.root() .. "/" .. U.slug(tostring(p.id)) end

--- pastas do port (relativas a pasta de ports) a partir do registro de instalados
function M.port_dirs(p)
  local Manifest = require("core.manifest")
  local rec = Manifest.data and Manifest.data[p.id]
  local out = {}
  for _, e in ipairs(rec and rec.entries or {}) do
    if not e:find("/") and U.is_dir(C.PORTS_DIR .. "/" .. e) then out[#out + 1] = e end
  end
  return out
end

--- comando find que lista os itens de save (caminhos relativos a pasta de ports)
local function find_cmd(dirs)
  local dn, ex = {}, {}
  for _, d in ipairs(M.DIRS) do dn[#dn + 1] = "-iname " .. U.shq(d) end
  for _, e in ipairs(M.EXTS) do ex[#ex + 1] = "-iname " .. U.shq("*." .. e) end
  local q = {}
  for _, d in ipairs(dirs) do q[#q + 1] = U.shq(d) end
  return "cd " .. U.shq(C.PORTS_DIR) .. " && find " .. table.concat(q, " ")
    .. " -maxdepth 3 \\( -type d \\( " .. table.concat(dn, " -o ") .. " \\) -prune -print \\)"
    .. " -o \\( -type f \\( " .. table.concat(ex, " -o ") .. " \\) -size -20M -print \\) 2>/dev/null"
end

--- itens de save do port agora (sincrono, leve: so find). Devolve lista, bytes
function M.find(p, dirs)
  dirs = dirs or M.port_dirs(p)
  if #dirs == 0 then return {}, 0 end
  local out = U.capture("timeout 5 sh -c " .. U.shq(find_cmd(dirs))) or ""
  local items = {}
  for line in out:gmatch("[^\n]+") do
    -- um item dentro de outro ja listado nao entra duas vezes
    local dup = false
    for _, it in ipairs(items) do
      if line:sub(1, #it + 1) == it .. "/" then dup = true; break end
    end
    if not dup then items[#items + 1] = line end
  end
  local bytes = 0
  if #items > 0 then
    local q = {}
    for _, it in ipairs(items) do q[#q + 1] = U.shq(it) end
    local du = U.capture("cd " .. U.shq(C.PORTS_DIR) .. " && timeout 5 du -sck " .. table.concat(q, " ") .. " 2>/dev/null | tail -n 1") or ""
    bytes = (tonumber(du:match("^(%d+)")) or 0) * 1024
  end
  return items, bytes
end

--- backups ja feitos do port (mais novo primeiro): { {path, name, date, bytes} }
function M.list(p)
  local d = M.dir(p)
  local out = U.capture("ls -1t " .. U.shq(d) .. " 2>/dev/null") or ""
  local res = {}
  for n in out:gmatch("[^\n]+") do
    if n:match("^saves_.*%.tar%.gz$") then
      local y, mo, da, h, mi = n:match("saves_(%d%d%d%d)(%d%d)(%d%d)_(%d%d)(%d%d)")
      res[#res + 1] = { path = d .. "/" .. n, name = n,
        date = y and string.format("%s/%s/%s %s:%s", da, mo, y, h, mi) or n,
        bytes = U.file_size and U.file_size(d .. "/" .. n) or nil }
    end
  end
  return res
end

--- faz o backup em segundo plano. on_done(ok, path_ou_erro, n_itens)
function M.backup(p, on_done, items)
  items = items or M.find(p)
  if #items == 0 then
    if on_done then on_done(false, L("Nenhum save encontrado na pasta deste port.")) end
    return
  end
  local d = M.dir(p)
  local path = d .. "/saves_" .. os.date("%Y%m%d_%H%M%S") .. ".tar.gz"
  local list = d .. "/.lista.txt"
  os.execute("mkdir -p " .. U.shq(d) .. " 2>/dev/null")
  local f = io.open(list, "wb")
  if not f then
    if on_done then on_done(false, L("Não foi possível gravar na pasta de backups.")) end
    return
  end
  f:write(table.concat(items, "\n"), "\n")
  f:close()
  local cmd = "cd " .. U.shq(C.PORTS_DIR) .. " && tar -czf " .. U.shq(path) .. " -T " .. U.shq(list)
    .. " 2>&1; rc=$?; rm -f " .. U.shq(list) .. "; sync; exit $rc"
  require("core.shjob").start({ "sh -c " .. U.shq(cmd) }, function(res, err)
    local r = res and res[1]
    if not r or r.rc ~= 0 then
      os.remove(path)
      U.log("backup de saves falhou:", p.id, err or (r and r.out))
      if on_done then on_done(false, L("O tar não conseguiu criar o arquivo: ") .. tostring(err or (r and r.out) or "?")) end
      return
    end
    -- mantem so os M.KEEP mais recentes deste port
    os.execute("cd " .. U.shq(d) .. " 2>/dev/null && ls -1t saves_*.tar.gz 2>/dev/null | tail -n +" .. (M.KEEP + 1)
      .. " | while read -r f; do rm -f -- \"$f\"; done")
    U.log("backup de saves:", p.id, path, #items .. " itens")
    if on_done then on_done(true, path, #items) end
  end)
end

--- restaura um backup (grava por cima dos mesmos caminhos). on_done(ok, msg)
function M.restore(p, path, on_done)
  local cmd = "cd " .. U.shq(C.PORTS_DIR) .. " && tar -xzf " .. U.shq(path) .. " 2>&1; rc=$?; sync; exit $rc"
  require("core.shjob").start({ "sh -c " .. U.shq(cmd) }, function(res, err)
    local r = res and res[1]
    local ok = r and r.rc == 0
    U.log("restaurar saves:", p.id, path, ok and "ok" or tostring(err or (r and r.out)))
    if on_done then on_done(ok, ok and nil or tostring(err or (r and r.out) or "?")) end
  end)
end

return M
