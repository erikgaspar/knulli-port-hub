-- =============================================================================
--  Ports "na fila" da pasta ports: arquivos .zip/.rar/.7z (inclusive em partes)
--  que o usuario copiou para a pasta de ports (ex.: baixados do Telegram) e que
--  tem cara de port (um script .sh dentro). Aparecem em Meus Ports com o atalho
--  "Instalar", e a tela inicial avisa uma vez por sessao.
--  So le a lista do arquivo (nao extrai nada). O resultado fica em cache por
--  arquivo (nome + tamanho + data), entao abrir Meus Ports de novo e rapido.
-- =============================================================================
local U = require("lib.util")
local C = require("config")
local AR = require("core.archives")

local M = { cache = {}, list = {}, scanned = false, notified = false }

local EXT = { zip = true, rar = true, ["7z"] = true }

--- 7-Zip executavel: o do ambiente de testes, o incluso no hub (copiado para a
--- pasta temporaria, porque o cartao pode nao permitir executar) ou o do sistema
local sevenzip
local function find_7z()
  if sevenzip ~= nil then return sevenzip or nil end
  local cands = {}
  local env = os.getenv("PORTHUB_7Z")
  if env and env ~= "" then cands[#cands + 1] = env end
  local bundled = C.APP_DIR .. "/bin/7zzs"
  if U.exists(bundled) then
    local tmp = "/tmp/r36sporthub-7zzs-list"
    os.execute("cp -f " .. U.shq(bundled) .. " " .. U.shq(tmp) .. " 2>/dev/null && chmod 755 " .. U.shq(tmp) .. " 2>/dev/null")
    cands[#cands + 1] = tmp
  end
  for _, n in ipairs({ "7zz", "7zzs", "7z", "7za" }) do
    local pth = (U.capture("command -v " .. n .. " 2>/dev/null") or ""):match("^(%S+)")
    if pth then cands[#cands + 1] = pth end
  end
  for _, c in ipairs(cands) do
    if U.exec_ok(U.shq(c) .. " i >/dev/null 2>&1") then sevenzip = c; return c end
  end
  sevenzip = false
  return nil
end

--- nomes dentro do arquivo (tenta sem senha e com as senhas salvas)
local function listing(path)
  -- TAR (o 7-Zip so mostraria o .tar de dentro de um .tar.gz)
  local tk = AR.tar_kind(path)
  if tk then
    local flag = ({ ["TAR"] = "", ["TAR.GZ"] = "z", ["TAR.XZ"] = "J", ["TAR.BZ2"] = "j" })[tk] or ""
    local names = {}
    for l in (U.capture("timeout 20 tar -t" .. flag .. "f " .. U.shq(path) .. " 2>/dev/null") or ""):gmatch("[^\n]+") do
      names[#names + 1] = l
    end
    return names, true
  end
  local X = find_7z()
  if X then
    local locked = false
    local function try(pw)
      local out = U.capture("timeout 20 " .. U.shq(X) .. " l -ba -slt " .. (pw and ("-p" .. U.shq(pw)) or "-p-")
        .. " " .. U.shq(path) .. " 2>&1") or ""
      local names = {}
      for p in out:gmatch("Path = ([^\n]+)") do names[#names + 1] = p end
      if #names == 0 and (out:find("[Ww]rong password") or out:find("encrypted")) then locked = true end
      return names
    end
    local names = try(nil)
    if #names == 0 then
      for _, pw in ipairs(AR.passwords()) do
        names = try(pw)
        if #names > 0 then break end
      end
    end
    -- senha desconhecida (nem a lista de arquivos abre): entra na lista e o
    -- instalador pede a senha no teclado
    return names, true, (#names == 0 and locked)
  end
  if path:lower():match("%.zip$") then
    local names = {}
    for l in (U.capture("unzip -Z1 " .. U.shq(path) .. " 2>/dev/null") or ""):gmatch("[^\n]+") do names[#names + 1] = l end
    return names, true
  end
  return {}, false
end

--- o arquivo tem um script .sh na raiz ou numa pasta logo abaixo (formato de port)?
--- Ficam de fora o proprio hub (update/pacote completo: update_manifest.json,
--- pasta r36sporthub) e o PortMaster: nao sao ports para instalar por aqui.
local function looks_like_port(names)
  for _, n in ipairs(names) do
    local l = n:gsub("\\", "/"):lower():gsub("^%./", "")
    if l == "update_manifest.json" or l == "r36sporthub" or l:find("^r36sporthub/") or l == "r36s port hub.sh"
      or l == "portmaster" or l:find("^portmaster/") or l == "portmaster.sh" then
      return false
    end
  end
  for _, n in ipairs(names) do
    local p = n:gsub("\\", "/")
    local _, depth = p:gsub("/", "")
    if p:lower():match("%.sh$") and depth <= 1 then return true end
  end
  return false
end

--- varre a pasta de ports. Devolve a lista { path, name, size, parts, kind }
function M.scan()
  local dir = C.PORTS_DIR
  local out = U.capture("cd " .. U.shq(dir) .. " 2>/dev/null && stat -L -c '%F|%s|%Y|%n' -- * 2>/dev/null") or ""
  local found, cache = {}, {}
  for line in out:gmatch("[^\n]+") do
    local kind, size, mtime, name = line:match("^([^|]*)|(%d+)|(%d+)|(.*)$")
    if kind == "regular file" or kind == "regular empty file" then
      local low = name:lower()
      local ext = low:match("%.([%w]+)$")
      local pi = AR.part_info(name)
      if (EXT[ext] or pi or AR.tar_kind(name)) and not AR.is_extra_part(name) then
        local path = dir .. "/" .. name
        local key = name .. "|" .. size .. "|" .. mtime
        local c = M.cache[key]
        if not c then
          local names, could, locked = listing(path)
          -- sem extrator para conferir ou com senha desconhecida: entra na lista
          -- mesmo assim (o instalador confere e pede a senha)
          c = { port = (not could) or locked or looks_like_port(names) }
        end
        cache[key] = c
        if c.port then
          local parts = AR.count(path)
          found[#found + 1] = { path = path, name = name, size = parts > 1 and AR.total_size(path) or tonumber(size),
            parts = parts, kind = (pi and pi.kind) or AR.tar_kind(name) or ext }
        end
      end
    end
  end
  table.sort(found, function(a, b) return a.name:lower() < b.name:lower() end)
  M.cache, M.list, M.scanned = cache, found, true
  return found
end

function M.count() return #M.list end

--- pedido de instalacao (mesmo formato do Gerenciador de arquivos > instalar como port)
function M.install(it)
  local p = { id = "file:" .. it.path, slug = U.slug("file_" .. it.name), name = it.name, size = it.size,
    download_url = "", install_check = {}, version = "" }
  App.install(p, { local_file = it.path, delete_source = true, mode = "port" })
end

return M
