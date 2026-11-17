-- =============================================================================
--  Arquivos compactados: senhas e arquivos em varias partes
--  * Senhas: as dos grupos de ports (padrao do hub) + as do usuario em
--    <pasta do app>/senhas.txt (uma por linha; linhas com # sao comentario).
--    O instalador tenta primeiro sem senha e depois cada senha da lista.
--    As senhas nao entram em logs nem no "Reportar problema".
--  * Partes: jogo.part1.rar / jogo.part01.rar, jogo.7z.001, jogo.zip.001 e
--    ZIP dividido (jogo.zip + jogo.z01, z02...). Instalar qualquer parte usa a
--    primeira, como no PC; ao excluir, todas as partes saem juntas.
-- =============================================================================
local U = require("lib.util")
local C = require("config")

local M = {}

-- senhas dos grupos de ports (pedido do autor do projeto)
M.DEFAULT_PASSWORDS = { "R36SPORTSBR", "R36XBR" }
-- a senha e o nome do grupo do Telegram de onde o port veio
M.GROUP_LINKS = {
  R36XBR = "https://t.me/R36XBR",
  R36SPORTSBR = "https://t.me/R36SPORTSBR",
}

-- ---------------------------------------------------------------------------
-- porthub.txt: creditos do port, escrito por quem fez o port
--   desenvolvedor=Fulano / grupo=R36SPORTSBR / link=https://t.me/... /
--   versao=1.2 / data=2026-11-16 / descricao=... / agradecimentos=...
-- Aceita "chave=valor" ou "Chave: valor", sem diferenca de maiusculas/acentos.
local KEYS = {
  desenvolvedor = "developer", autor = "developer", developer = "developer", porter = "developer",
  criador = "developer", author = "developer",
  grupo = "group", group = "group",
  link = "link", site = "link", url = "link", telegram = "link",
  versao = "version", version = "version",
  data = "date", date = "date",
  descricao = "description", description = "description", desc = "description",
  agradecimentos = "thanks", creditos = "thanks", thanks = "thanks", credits = "thanks",
  nome = "title", jogo = "title", titulo = "title", title = "title", name = "title",
}
local function fold(s)
  return (s:lower():gsub("ã", "a"):gsub("á", "a"):gsub("â", "a"):gsub("é", "e"):gsub("ê", "e")
    :gsub("í", "i"):gsub("ó", "o"):gsub("ô", "o"):gsub("õ", "o"):gsub("ú", "u"):gsub("ç", "c"))
end

--- le o texto do porthub.txt. Devolve tabela (developer, group, link, ...) ou nil
function M.parse_credits(text)
  if type(text) ~= "string" or text == "" then return nil end
  text = text:gsub("^\239\187\191", "")   -- BOM do Bloco de Notas
  local out, n = {}, 0
  for line in text:gmatch("[^\r\n]+") do
    if not line:match("^%s*#") then
      local k, v = line:match("^%s*([^=:]-)%s*[=:]%s*(.-)%s*$")
      if k and v and v ~= "" then
        local key = KEYS[fold(k):gsub("%s+", "")]
        if key and not out[key] then
          out[key] = U.safe_utf8 and U.safe_utf8(v:sub(1, 300)) or v:sub(1, 300)
          n = n + 1
        end
      end
    end
  end
  if out.link and not out.link:match("^https?://") then out.link = nil end
  return n > 0 and out or nil
end

--- linhas de texto dos creditos para mostrar (desenvolvedor, versao, data, agradecimentos)
function M.credits_lines(cr)
  local L = require("lib.i18n").L
  if not cr then return {} end
  local t = {}
  if cr.developer then t[#t + 1] = L("Desenvolvedor: ") .. cr.developer end
  if cr.version then t[#t + 1] = L("Versão: ") .. cr.version end
  if cr.date then t[#t + 1] = L("Data: ") .. cr.date end
  if cr.thanks then t[#t + 1] = L("Agradecimentos: ") .. cr.thanks end
  return t
end

--- "Origem: grupo do Telegram X" + link na linha de baixo
function M.origin_text(group, link)
  local L = require("lib.i18n").L
  if not group then return nil end
  link = link or M.GROUP_LINKS[group]
  return L("Origem: grupo do Telegram ") .. group .. (link and ("\n" .. link) or "")
end

function M.file() return C.APP_DIR .. "/senhas.txt" end

local TEMPLATE = [[
# R36S PORT HUB - senhas de arquivos compactados (.zip, .rar, .7z)
# Uma senha por linha. Linhas que comecam com # sao ignoradas.
# Ao instalar um arquivo com senha, o hub tenta as senhas do hub
# (R36SPORTSBR, R36XBR) e depois as desta lista.
]]

--- cria o senhas.txt com instrucoes, se ainda nao existir
function M.ensure_file()
  local f = M.file()
  if not U.exists(f) then
    local h = io.open(f, "wb")
    if h then h:write(TEMPLATE); h:close() end
  end
end

--- senhas do usuario (senhas.txt)
function M.user_passwords()
  local out = {}
  local t = U.read_file(M.file()) or ""
  for line in t:gmatch("[^\r\n]+") do
    local s = line:gsub("^%s+", ""):gsub("%s+$", "")
    if s ~= "" and s:sub(1, 1) ~= "#" then out[#out + 1] = s end
  end
  return out
end

--- arquivo TAR pelo nome: "TAR", "TAR.GZ", "TAR.XZ" ou "TAR.BZ2" (nil se nao for)
local TAR_EXT = {
  { "%.tar$", "TAR" },
  { "%.tar%.gz$", "TAR.GZ" }, { "%.tgz$", "TAR.GZ" },
  { "%.tar%.xz$", "TAR.XZ" }, { "%.txz$", "TAR.XZ" },
  { "%.tar%.bz2$", "TAR.BZ2" }, { "%.tbz2?$", "TAR.BZ2" },
}
function M.tar_kind(name)
  local low = tostring(name or ""):lower()
  for _, e in ipairs(TAR_EXT) do
    if low:match(e[1]) then return e[2] end
  end
  return nil
end

--- nome sem a extensao de TAR (jogo.tar.gz -> jogo)
function M.strip_tar(name)
  local s = tostring(name or "")
  local low = s:lower()
  for _, e in ipairs(TAR_EXT) do
    local a = low:find(e[1])
    if a then return s:sub(1, a - 1) end
  end
  return s
end

--- salva uma senha digitada no teclado do hub no senhas.txt (sem repetir).
--- Devolve true se ja estava salva ou foi gravada agora.
function M.add_user_password(pw)
  pw = tostring(pw or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if pw == "" or pw:find("[\r\n]") then return false end
  for _, s in ipairs(M.DEFAULT_PASSWORDS) do if s == pw then return true end end
  for _, s in ipairs(M.user_passwords()) do if s == pw then return true end end
  M.ensure_file()
  local old = U.read_file(M.file()) or ""
  local h = io.open(M.file(), "ab")
  if not h then return false end
  if old ~= "" and old:sub(-1) ~= "\n" then h:write("\n") end
  h:write(pw, "\n")
  h:close()
  return true
end

--- a senha ja esta salva (padrao do hub ou senhas.txt)?
function M.is_saved(pw)
  for _, s in ipairs(M.passwords()) do if s == pw then return true end end
  return false
end

--- todas as senhas, sem repetir: padrao do hub primeiro
function M.passwords()
  local out, seen = {}, {}
  for _, list in ipairs({ M.DEFAULT_PASSWORDS, M.user_passwords() }) do
    for _, s in ipairs(list) do
      if not seen[s] then seen[s] = true; out[#out + 1] = s end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- partes
-- ---------------------------------------------------------------------------
--- informacoes de um nome de arquivo dividido:
--- { base, kind, index, first_name } ou nil se nao for parte
function M.part_info(name)
  local low = name:lower()
  local base, num = low:match("^(.-)%.part(%d+)%.rar$")
  if base then
    local n = tonumber(num)
    local orig_base = name:sub(1, #base)
    return { kind = "rar", index = n, base = orig_base,
      first_name = orig_base .. ".part" .. string.rep("0", #num - 1) .. "1" .. name:sub(-4) }
  end
  base, num = low:match("^(.-)%.(7z)%.(%d%d%d)$")
  if base then
    num = low:match("%.(%d%d%d)$")
    return { kind = "7z", index = tonumber(num), base = name:sub(1, #base), first_name = name:sub(1, -4) .. "001" }
  end
  base = low:match("^(.-)%.zip%.%d%d%d$")
  if base then
    num = low:match("%.(%d%d%d)$")
    return { kind = "zipsplit", index = tonumber(num), base = name:sub(1, #base), first_name = name:sub(1, -4) .. "001" }
  end
  base, num = low:match("^(.-)%.z(%d%d)$")
  if base then
    -- jogo.z01, z02... (a ultima parte e jogo.zip)
    return { kind = "zipspan", index = tonumber(num), base = name:sub(1, #base), first_name = name:sub(1, #base) .. ".zip" }
  end
  return nil
end

local function list_dir(dir)
  local out = {}
  for n in (U.capture("ls -1A " .. U.shq(dir) .. " 2>/dev/null") or ""):gmatch("[^\n]+") do out[#out + 1] = n end
  return out
end

--- todas as partes de um arquivo (caminhos completos, em ordem), a partir de
--- qualquer parte. Para arquivo comum devolve so ele.
function M.parts(path)
  local dir = path:match("^(.*)/[^/]*$") or "."
  local name = path:match("([^/]+)$") or path
  local info = M.part_info(name)
  local low = name:lower()
  local zip_base = low:match("^(.-)%.zip$")
  if not info and not zip_base then return { path } end
  local want = {}
  for _, n in ipairs(list_dir(dir)) do
    local i = M.part_info(n)
    local same
    if info and i and i.kind == info.kind and i.base:lower() == info.base:lower() then same = i.index end
    if not info and zip_base and i and i.kind == "zipspan" and i.base:lower() == zip_base then same = i.index end
    if info and info.kind == "zipspan" and n:lower() == info.base:lower() .. ".zip" then same = 9999 end
    if not info and n == name then same = 9999 end
    if same then want[#want + 1] = { n = n, i = same } end
  end
  table.sort(want, function(a, b) return a.i < b.i end)
  local out = {}
  for _, w in ipairs(want) do out[#out + 1] = dir .. "/" .. w.n end
  if #out == 0 then out = { path } end
  return out
end

--- primeira parte (a que o extrator abre). Para ZIP dividido em z01..: o .zip
function M.first_part(path)
  local dir = path:match("^(.*)/[^/]*$") or "."
  local name = path:match("([^/]+)$") or path
  local info = M.part_info(name)
  if not info then return path end
  -- part1.rar pode ter zeros (part01, part001): procura a de indice 1 de verdade
  for _, p in ipairs(M.parts(path)) do
    local i = M.part_info(p:match("([^/]+)$"))
    if i and i.index == 1 and info.kind ~= "zipspan" then return p end
  end
  return dir .. "/" .. info.first_name
end

--- quantas partes (1 = arquivo comum)
function M.count(path) return #M.parts(path) end

--- tamanho somado de todas as partes
function M.total_size(path)
  local t = 0
  for _, p in ipairs(M.parts(path)) do t = t + (U.file_size and U.file_size(p) or 0) end
  return t
end

--- o nome e de uma parte que NAO e a primeira (para esconder na lista)
function M.is_extra_part(name)
  local i = M.part_info(name)
  if not i then return false end
  if i.kind == "zipspan" then return true end
  return i.index ~= 1
end

return M
