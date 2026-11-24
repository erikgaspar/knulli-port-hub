-- =============================================================================
--  Gerenciador de espaco do cartao (Knulli Port Hub)
--  Lista os maiores jogos de TODOS os sistemas (pastas de ROMs) e dos ports,
--  cruzando com o gamelist.xml de cada sistema (nome, vezes jogado, ultima vez).
--  Apagar so vale para ROMs dentro da pasta de ROMs; os saves (pasta saves/)
--  nao sao tocados. Ports sao removidos pela tela Meus Ports (backup de saves).
-- =============================================================================
local L = require("lib.i18n").L
local U = require("lib.util")
local C = require("config")

local M = {}

M.MIN_KB = 20 * 1024          -- so entra na lista o que ocupa 20 MB ou mais

--- pasta de ROMs (pai da pasta de ports: /userdata/roms no Knulli, /roms no dArkOS)
function M.roms_root()
  return C.PORTS_DIR:match("^(.*)/[^/]+$") or "/roms"
end

--- comando que mede tudo (uma linha por item: "kb<TAB>caminho")
function M.scan_cmd()
  local root = U.shq(M.roms_root())
  return "cd " .. root .. " && du -sk -- */* 2>/dev/null | awk -F'\\t' '$1 >= " .. M.MIN_KB .. "'"
end

local function xml_unesc(s)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", "\""):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

--- le o gamelist de um sistema: path -> { name, playcount, lastplayed, hidden }
local GL = {}
function M.gamelist(sys)
  if GL[sys] then return GL[sys] end
  local t = {}
  local text = U.read_file(M.roms_root() .. "/" .. sys .. "/gamelist.xml") or ""
  for blk in text:gmatch("<game[%s>].-</game>") do
    local p = blk:match("<path>%s*(.-)%s*</path>")
    if p then
      p = xml_unesc(p):gsub("^%./", "")
      t[p] = { name = (xml_unesc(blk:match("<name>(.-)</name>") or ""):gsub("%s*%(launcher original%)", "")),
        playcount = tonumber(blk:match("<playcount>(%d+)</playcount>") or "") or 0,
        lastplayed = (tonumber(blk:match("<lastplayed>(%d%d%d%d)") or "0") or 0) >= 2000 and
          (blk:match("<lastplayed>(%d%d%d%d)") .. "-" .. blk:match("<lastplayed>%d%d%d%d(%d%d)") .. "-" .. blk:match("<lastplayed>%d%d%d%d%d%d(%d%d)")) or nil,
        hidden = blk:find("<hidden>true</hidden>", 1, true) ~= nil }
    end
  end
  GL[sys] = t
  return t
end
local PMAP
function M.reset() GL = {}; PMAP = nil end

--- ports: pasta -> script .sh que a usa (o gamelist dos ports e pelo .sh)
function M.port_map()
  if PMAP then return PMAP end
  PMAP = {}
  local dir = C.PORTS_DIR
  local list = U.capture and U.capture("cd " .. U.shq(dir) .. " && ls -1 -- *.sh 2>/dev/null") or ""
  for sh in list:gmatch("[^\n]+") do
    local text = U.read_file(dir .. "/" .. sh) or ""
    -- cabecalho padrao do PortMaster: "# PORTMASTER: pasta.zip, Nome.sh"
    local pm = text:match("PORTMASTER:%s*([%w%._%-]+)%s*,")
    if pm then pm = pm:gsub("%.zip$", ""); if not PMAP[pm] then PMAP[pm] = sh end end
    for folder in text:gmatch("/ports/([%w%._%-]+)") do
      if not PMAP[folder] and folder ~= "PortMaster" then PMAP[folder] = sh end
    end
    for folder in text:gmatch("GAMEDIR=[\"']?[^\n\"']-/([%w%._%-]+)[\"']?\n") do
      if not PMAP[folder] then PMAP[folder] = sh end
    end
  end
  return PMAP
end

--- monta os itens a partir da saida do du
function M.parse(out)
  local items, total = {}, 0
  local ports = C.PORTS_DIR:match("([^/]+)$")
  for line in (out or ""):gmatch("[^\n]+") do
    local kb, rel = line:match("^(%d+)\t(.+)$")
    kb = tonumber(kb)
    if kb and rel then
      local sys, name = rel:match("^([^/]+)/(.+)$")
      if sys and name and not name:match("^gamelist") and not name:match("^images$") and not name:match("^videos$")
          and not name:match("^media$") and not name:match("^manuals$") then
        local b = kb * 1024
        total = total + b
        local info = M.gamelist(sys)[name]
        if not info and sys == ports then
          local sh = M.port_map()[name]
          if sh then
            info = M.gamelist(sys)[sh]
            if not info or info.name == "" then info = { name = sh:gsub("%.[sS][hH]$", ""), playcount = info and info.playcount or 0 } end
          end
        end
        -- jogos em pasta (multidisco, scummvm...): procura uma entrada dentro dela
        if not info then
          for p, v in pairs(M.gamelist(sys)) do
            if p:sub(1, #name + 1) == name .. "/" and not v.hidden then info = v; break end
          end
        end
        items[#items + 1] = { sys = sys, rel = rel, file = name, bytes = b, is_port = sys == ports,
          name = (info and info.name ~= "" and info.name) or name:gsub("%.[%w]+$", ""),
          playcount = info and info.playcount or 0, lastplayed = info and info.lastplayed }
      end
    end
  end
  table.sort(items, function(a, b) return a.bytes > b.bytes end)
  return items, total
end

--- apaga uma ROM (arquivo ou pasta) dentro da pasta de ROMs. Ports: recusa.
function M.delete(it)
  if it.is_port then return nil, L("Ports são removidos pela tela Meus Ports (com backup dos saves).") end
  if not it.rel or it.rel:find("%.%.") or it.rel:sub(1, 1) == "/" or not it.rel:find("/") then
    return nil, L("caminho inválido")
  end
  local full = M.roms_root() .. "/" .. it.rel
  local ok = U.exec_ok("rm -rf -- " .. U.shq(full))
  M.reset()
  if not ok then return nil, L("não foi possível apagar ") .. full end
  return true
end

return M
