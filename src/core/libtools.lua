-- =============================================================================
--  Biblioteca: manutencao (so Knulli) - logica
--
--  Quatro ferramentas para as listas de jogos do EmulationStation (gamelist.xml
--  de cada pasta de sistema em /userdata/roms):
--   1. faxina    : entradas cujo arquivo sumiu (remove, junto das imagens que
--                  so elas usavam), scripts .sh internos de ports em subpastas
--                  (oculta) e ROMs com extensao de outro sistema (so reporta;
--                  mover e opcional);
--   2. imagens   : capa/print/logo do libretro-thumbnails para quem nao tem
--                  <image> (ou cujo arquivo sumiu);
--   3. multidisco: cria <Nome>.m3u para "(Disc 1)/(Disc 2)" e oculta os discos;
--   4. videos    : limpa <video> mortos e reduz os videos existentes (ffmpeg).
--
--  Regras de seguranca:
--   * o gamelist e gravado num arquivo temporario e trocado de uma vez (rename);
--   * antes da 1a gravacao do dia, copia de seguranca em
--     <APP_DIR>/backups/gamelists/<AAAA-MM-DD>/<sistema>.xml;
--   * o texto original de cada <game> e preservado (so a tag mexida muda);
--   * sistema com quase tudo "morto" (cartao/pasta nao montada?) e ignorado.
--
--  As operacoes demoradas rodam em threads/libtools_thread.lua (M.run). As
--  funcoes M.op_* tambem podem ser chamadas direto (testes).
--  Este modulo nao depende de love.* nem de config na carga (roda na thread).
-- =============================================================================
local U = require("lib.util")

local M = {}

-- configuracao (preenchida por M.setup; a thread recebe a mesma tabela)
M.cfg = {
  root = "/userdata/roms",
  backup_dir = "/tmp/porthub-backups/gamelists",
  cache_dir = "/tmp/porthub-cache/libtools",
  es_systems = { "/usr/share/emulationstation/es_systems.cfg" },
  es_systems_glob = "/userdata/system/configs/emulationstation/es_systems_*.cfg",
  es_settings = "/userdata/system/configs/emulationstation/es_settings.cfg",
}
function M.setup(cfg)
  for k, v in pairs(cfg or {}) do M.cfg[k] = v end
end

-- ganchos de progresso/cancelamento (a thread troca)
M.progress = function(done, total, text) end
M.cancelled = function() return false end

M.IMG_LIMIT = 50          -- imagens: jogos por vez
M.IMG_MAX_PX = 400        -- imagens: lado maior depois de reduzir
M.MIN_FREE_KB = 150 * 1024
M.VIDEO = { w = 320, h = 240, kbps = 250, secs = 15 }

-- tags de midia de uma entrada (caminhos de arquivo)
M.MEDIA_TAGS = { "image", "thumbnail", "marquee", "video", "fanart", "titleshot", "manual", "magazine",
  "map", "bezel", "boxback", "boxart", "wheel", "cartridge", "mix" }

-------------------------------------------------------------------------------
-- utilitarios
-------------------------------------------------------------------------------
local function u8(c)
  if c < 0x80 then return string.char(c)
  elseif c < 0x800 then return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64)
  elseif c < 0x10000 then
    return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
  end
  return string.char(0xF0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64,
    0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end

function M.unesc(s)
  if not s then return nil end
  s = s:gsub("&#[xX](%x+);", function(h) return u8(tonumber(h, 16)) end)
  s = s:gsub("&#(%d+);", function(d) return u8(tonumber(d)) end)
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", "\""):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

function M.esc(s)
  return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function exists(p)
  local f = io.open(p, "rb")   -- no Linux tambem abre pastas
  if f then f:close(); return true end
  return false
end
M.exists = exists

local function lines(cmd)
  local t = {}
  local h = io.popen(cmd .. " 2>/dev/null")
  if not h then return t end
  for l in h:lines() do if l ~= "" then t[#t + 1] = l end end
  h:close()
  return t
end

local function sh_ok(cmd)
  local r = os.execute(cmd .. " >/dev/null 2>&1")
  return r == 0 or r == true
end

local function mkdir_p(d) return sh_ok("mkdir -p " .. U.shq(d)) end

local function fsize(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:seek("end")
  f:close()
  return s
end

local function lower(s) return (s or ""):lower() end
local function ext_of(p) return lower(p:match("%.([^./]+)$") or "") end
local function base_of(p) return (p:match("([^/]+)$") or p) end
local function stem(p) return (base_of(p):gsub("%.[^.]+$", "")) end
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

--- espaco livre (KB) na pasta
function M.free_kb(path)
  local out = U.capture("df -Pk " .. U.shq(path or M.cfg.root) .. " 2>/dev/null | tail -1") or ""
  return tonumber(out:match("^%S+%s+%d+%s+%d+%s+(%d+)"))
end

--- pastas de sistema (nomes) dentro da raiz
function M.system_dirs()
  local t = {}
  for _, l in ipairs(lines("cd " .. U.shq(M.cfg.root) .. " && find . -mindepth 1 -maxdepth 1 -type d")) do
    local n = l:gsub("^%./", "")
    if n ~= "" and not n:find("^%.") then t[#t + 1] = n end
  end
  table.sort(t)
  return t
end

function M.sys_dir(sys) return M.cfg.root .. "/" .. sys end

--- caminho absoluto de um <path> do gamelist (nil se nao der para resolver)
function M.abs(sys, p)
  if not p or p == "" then return nil end
  if p:sub(1, 1) == "/" then return p end
  if p:sub(1, 1) == "~" or p:find("%%") then return nil end
  p = p:gsub("^%./", "")
  return M.sys_dir(sys) .. "/" .. p
end

--- midia segura para apagar: dentro da pasta do sistema, sem ".."
local function inside_sys(sys, abs)
  if not abs or abs:find("/%.%./") or abs:find("/%.%.$") then return false end
  local d = M.sys_dir(sys) .. "/"
  return abs:sub(1, #d) == d
end

-------------------------------------------------------------------------------
-- extensoes de cada sistema (es_systems.cfg + es_systems_*.cfg do usuario)
-------------------------------------------------------------------------------
local EXT
function M.system_exts()
  if EXT then return EXT end
  EXT = {}
  local files = {}
  for _, f in ipairs(M.cfg.es_systems or {}) do files[#files + 1] = f end
  if M.cfg.es_systems_glob then
    for _, f in ipairs(lines("ls -1 " .. M.cfg.es_systems_glob)) do files[#files + 1] = f end
  end
  for _, f in ipairs(files) do
    local text = U.read_file(f) or ""
    for blk in text:gmatch("<system>(.-)</system>") do
      local name = trim(blk:match("<name>(.-)</name>") or "")
      local path = trim(blk:match("<path>(.-)</path>") or "")
      local ext = blk:match("<extension>(.-)</extension>") or ""
      local folder = path:match("([^/]+)/*$") or name
      if folder ~= "" then
        local set = {}
        for e in ext:gmatch("%S+") do set[lower(e:gsub("^%.", ""))] = true end
        EXT[folder] = set
      end
    end
  end
  return EXT
end
function M.reset() EXT = nil end

-------------------------------------------------------------------------------
-- gamelist.xml: leitura que preserva o texto, edicao por tag, gravacao atomica
-------------------------------------------------------------------------------
local SKELETON = "<?xml version=\"1.0\"?>\n<gameList>\n</gameList>\n"

local function next_open(text, pos)
  local s1 = text:find("<game[%s>/]", pos)
  local s2 = text:find("<folder[%s>/]", pos)
  if s1 and (not s2 or s1 < s2) then return s1, "game" end
  if s2 then return s2, "folder" end
end

function M.parse(text)
  text = text or SKELETON
  local doc = { parts = {}, entries = {}, added = {}, nl = text:find("\r\n", 1, true) and "\r\n" or "\n",
    indent = "\t", cindent = "\t\t" }
  local pos, first = 1, true
  while true do
    local s, tag = next_open(text, pos)
    if not s then break end
    local head_end = text:find(">", s, true)
    if not head_end then break end
    if text:sub(head_end - 1, head_end - 1) == "/" then
      -- <game/> vazio: fica como texto
      doc.parts[#doc.parts + 1] = text:sub(pos, head_end)
      pos = head_end + 1
    else
      local _, ce = text:find("</" .. tag .. "%s*>", head_end)
      if not ce then break end
      -- comeca no inicio da linha (com o recuo) e termina com a quebra de linha
      local ls = s
      while ls > 1 and text:sub(ls - 1, ls - 1):match("[ \t]") do ls = ls - 1 end
      local at_line = ls == 1 or text:sub(ls - 1, ls - 1) == "\n"
      local bs, be = at_line and ls or s, ce
      if at_line then
        local _, e2 = text:find("^[ \t]*\r?\n", ce + 1)
        if e2 then be = e2 end
      end
      if bs > pos then doc.parts[#doc.parts + 1] = text:sub(pos, bs - 1) end
      local body = text:sub(bs, be)
      local e = { kind = tag, text = body, path = M.unesc(body:match("<path>%s*(.-)%s*</path>")) }
      if first then
        first = false
        doc.indent = at_line and text:sub(ls, s - 1) or "\t"
        doc.cindent = body:match("\n([ \t]*)<path>") or (doc.indent .. doc.indent)
        if doc.cindent == "" then doc.cindent = doc.indent .. doc.indent end
      end
      doc.parts[#doc.parts + 1] = e
      doc.entries[#doc.entries + 1] = e
      pos = be + 1
    end
  end
  if pos <= #text then doc.parts[#doc.parts + 1] = text:sub(pos) end
  return doc
end

function M.get(e, name)
  local v = e.text:match("<" .. name .. ">(.-)</" .. name .. ">")
  return v and M.unesc(trim(v)) or nil
end

function M.is_hidden(e) return (M.get(e, "hidden") or "") == "true" end

function M.set(doc, e, name, value)
  local v = M.esc(value)
  local open, close = "<" .. name .. ">", "</" .. name .. ">"
  local s = e.text:find(open, 1, true)
  if s then
    local cs, ce = e.text:find(close, s, true)
    if cs then
      e.text = e.text:sub(1, s + #open - 1) .. v .. e.text:sub(cs)
      e.dirty = true
      return
    end
  end
  -- tag vazia <name/> : troca
  local es, ee = e.text:find("<" .. name .. "%s*/>")
  if es then
    e.text = e.text:sub(1, es - 1) .. open .. v .. close .. e.text:sub(ee + 1)
    e.dirty = true
    return
  end
  -- acrescenta antes do fechamento
  local cpat = "</" .. e.kind .. "%s*>"
  local cs
  local i = 1
  while true do
    local a = e.text:find(cpat, i)
    if not a then break end
    cs = a; i = a + 1
  end
  if not cs then return end
  local ls = cs
  while ls > 1 and e.text:sub(ls - 1, ls - 1):match("[ \t]") do ls = ls - 1 end
  if ls > 1 and e.text:sub(ls - 1, ls - 1) == "\n" then
    e.text = e.text:sub(1, ls - 1) .. doc.cindent .. open .. v .. close .. doc.nl .. e.text:sub(ls)
  else
    e.text = e.text:sub(1, cs - 1) .. open .. v .. close .. e.text:sub(cs)
  end
  e.dirty = true
end

function M.del(doc, e, name)
  local n0 = e.text
  local pat = "\r?\n[ \t]*<" .. name .. ">.-</" .. name .. ">"
  local t = e.text:gsub(pat, "", 1)
  if t == n0 then t = e.text:gsub("<" .. name .. ">.-</" .. name .. ">", "", 1) end
  if t == n0 then t = e.text:gsub("<" .. name .. "%s*/>", "", 1) end
  if t ~= n0 then e.text = t; e.dirty = true; return true end
  return false
end

--- nova entrada (fields: lista de { tag, valor }), acrescentada antes de </gameList>
function M.add(doc, kind, fields)
  local nl, ci = doc.nl, doc.cindent
  local t = { doc.indent .. "<" .. kind .. ">" }
  for _, f in ipairs(fields) do
    t[#t + 1] = ci .. "<" .. f[1] .. ">" .. M.esc(f[2]) .. "</" .. f[1] .. ">"
  end
  t[#t + 1] = doc.indent .. "</" .. kind .. ">"
  local body = table.concat(t, nl) .. nl
  local e = { kind = kind, text = body, path = nil, new = true }
  for _, f in ipairs(fields) do if f[1] == "path" then e.path = f[2] end end
  doc.added[#doc.added + 1] = e
  doc.entries[#doc.entries + 1] = e
  return e
end

--- copia de uma entrada (outro caminho), acrescentada no fim
function M.add_copy(doc, src, path)
  local body = src.text
  local ps, pe = body:find("<path>.-</path>")
  if ps then body = body:sub(1, ps - 1) .. "<path>" .. M.esc(path) .. "</path>" .. body:sub(pe + 1) end
  -- a copia nao herda o id do scraper (o EmulationStation guarda um por arquivo)
  body = body:gsub("^([ \t]*<%a+)%s+[^>]*>", "%1>", 1)
  if not body:find("\n$") then body = body .. doc.nl end
  local e = { kind = src.kind, text = body, path = path, new = true }
  doc.added[#doc.added + 1] = e
  doc.entries[#doc.entries + 1] = e
  return e
end

function M.remove(doc, e) e.removed = true; doc.changed = true end

function M.serialize(doc)
  local out = {}
  for _, p in ipairs(doc.parts) do
    if type(p) == "string" then out[#out + 1] = p
    elseif not p.removed then out[#out + 1] = p.text end
  end
  local s = table.concat(out)
  local add = {}
  for _, e in ipairs(doc.added) do if not e.removed then add[#add + 1] = e.text end end
  if #add > 0 then
    local at
    local i = 1
    while true do
      local a = s:find("</gameList>", i, true)
      if not a then break end
      at = a; i = a + 1
    end
    if at then
      local ls = at
      while ls > 1 and s:sub(ls - 1, ls - 1):match("[ \t]") do ls = ls - 1 end
      if ls > 1 and s:sub(ls - 1, ls - 1) ~= "\n" then
        s = s:sub(1, at - 1) .. doc.nl .. table.concat(add) .. s:sub(at)
      else
        s = s:sub(1, ls - 1) .. table.concat(add) .. s:sub(ls)
      end
    else
      s = s .. table.concat(add) .. "</gameList>" .. doc.nl
    end
  end
  return s
end

function M.load(sys)
  local file = M.sys_dir(sys) .. "/gamelist.xml"
  local text = U.read_file(file)
  local doc = M.parse(text and text:find("<gameList", 1, true) and text or SKELETON)
  doc.sys, doc.file, doc.orig, doc.existed = sys, file, text, text ~= nil
  -- indice por caminho normalizado
  doc.by_path = {}
  for _, e in ipairs(doc.entries) do
    if e.path then doc.by_path[e.path:gsub("^%./", "")] = e end
  end
  return doc
end

function M.find(doc, rel)
  return doc.by_path and doc.by_path[(rel or ""):gsub("^%./", "")]
end

--- copia de seguranca (1a vez do dia) - devolve caminho ou nil, erro
function M.backup(doc)
  if not doc.existed then return true end
  local dir = M.cfg.backup_dir .. "/" .. os.date("%Y-%m-%d")
  local dst = dir .. "/" .. doc.sys .. ".xml"
  if exists(dst) then return dst end
  if not mkdir_p(dir) then return nil, "não foi possível criar " .. dir end
  if not U.write_file(dst, doc.orig or "") then return nil, "não foi possível gravar " .. dst end
  if (fsize(dst) or -1) ~= #(doc.orig or "") then return nil, "cópia de segurança incompleta: " .. dst end
  return dst
end

--- houve alguma mudanca no documento?
function M.changed(doc)
  if doc.changed or #doc.added > 0 then return true end
  for _, e in ipairs(doc.entries) do if e.dirty or e.removed then return true end end
  return false
end

--- grava (copia de seguranca + temporario + rename). true ou nil, erro
--- (sem mudancas: nao grava nada)
function M.save(doc)
  if not M.changed(doc) then return true end
  local ok, err = M.backup(doc)
  if not ok then return nil, err end
  -- o arquivo mudou no disco desde a leitura (o EmulationStation gravou)? nao sobrescreve
  local now = U.read_file(doc.file)
  if (now or false) ~= (doc.orig or false) then
    return nil, "o gamelist de " .. doc.sys .. " mudou durante a operação; rode de novo"
  end
  local text = M.serialize(doc)
  local tmp = doc.file .. ".porthub.tmp"
  if not U.write_file(tmp, text) then return nil, "não foi possível gravar " .. tmp end
  if (fsize(tmp) or -1) ~= #text then os.remove(tmp); return nil, "gravação incompleta (cartão cheio?)" end
  local rok, rerr = os.rename(tmp, doc.file)
  if not rok then os.remove(tmp); return nil, tostring(rerr) end
  doc.orig = text
  doc.existed = true
  return true
end

-------------------------------------------------------------------------------
-- 1. FAXINA
-------------------------------------------------------------------------------
-- extensoes que nunca indicam "sistema errado" (genericas, auxiliares, midia)
local GENERIC = {}
for e in ([[zip 7z rar bin iso img chd cue m3u sh squashfs txt xml png jpg jpeg gif bmp webp mp4 mkv avi
  pdf nfo cfg ini json srm sav state dat db log bak md lua py so tmp sub ccd mdf mds toc wav mp3 ogg flac
  opt keep lst ips bps ups xdelta rtc zst gz tar exe dll conf info]]):gmatch("%S+") do GENERIC[e] = true end

-- prioridade do destino sugerido quando a extensao vale em varios sistemas
local MAIN = { gb = 1, gbc = 1, gba = 1, nes = 1, snes = 1, megadrive = 1, mastersystem = 1, gamegear = 1,
  psx = 1, n64 = 1, nds = 1, pcengine = 1, ngpc = 1, ngp = 1, wswanc = 1, wswan = 1, sega32x = 1,
  virtualboy = 1, lynx = 1, atari2600 = 1, atari7800 = 1, sg1000 = 1, fds = 1, pokemini = 1 }

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

--- varredura (somente leitura). Devolve { items = {...}, stats = {...}, skipped = {...} }
function M.op_clean_scan()
  M.reset()
  local exts = M.system_exts()
  local systems = M.system_dirs()
  -- extensao -> sistemas que aceitam
  local owners = {}
  for sys, set in pairs(exts) do
    for e in pairs(set) do owners[e] = owners[e] or {}; owners[e][#owners[e] + 1] = sys end
  end
  local have_dir = {}
  for _, s in ipairs(systems) do have_dir[s] = true end
  local items, skipped = {}, {}
  local st = { dead = 0, scripts = 0, suspects = 0, media = 0, media_bytes = 0 }
  for si, sys in ipairs(systems) do
    if M.cancelled() then break end
    M.progress(si, #systems, sys)
    local sdir = M.sys_dir(sys)
    local doc = exists(sdir .. "/gamelist.xml") and M.load(sys) or nil
    -- (a) entradas mortas
    if doc then
      local refs = {}
      for _, e in ipairs(doc.entries) do
        for _, tg in ipairs(M.MEDIA_TAGS) do
          local a = M.abs(sys, M.get(e, tg))
          if a then refs[a] = (refs[a] or 0) + 1 end
        end
      end
      local dead, total = {}, 0
      for _, e in ipairs(doc.entries) do
        if e.path then
          total = total + 1
          local a = M.abs(sys, e.path)
          if a and not exists(a) then dead[#dead + 1] = e end
        end
      end
      if #dead >= 10 and #dead > total * 0.8 then
        skipped[#skipped + 1] = { sys = sys, dead = #dead, total = total }
      else
        for _, e in ipairs(dead) do
          local media, bytes = {}, 0
          for _, tg in ipairs(M.MEDIA_TAGS) do
            local a = M.abs(sys, M.get(e, tg))
            if a and refs[a] == 1 and inside_sys(sys, a) and exists(a) then
              media[#media + 1] = a
              bytes = bytes + (fsize(a) or 0)
              refs[a] = 0
            end
          end
          st.dead = st.dead + 1
          st.media = st.media + #media
          st.media_bytes = st.media_bytes + bytes
          items[#items + 1] = { kind = "dead", sys = sys, path = e.path, name = M.get(e, "name") or stem(e.path),
            folder = e.kind == "folder", media = media, bytes = bytes }
        end
      end
    end
    -- (b) scripts internos (sistemas que aceitam .sh: ports, tools...)
    if exts[sys] and exts[sys].sh then
      local found = lines("cd " .. U.shq(sdir) .. " && find . -mindepth 2 -type f -name '*.sh'")
      local by_folder, order = {}, {}
      for _, f in ipairs(found) do
        local rel = f:gsub("^%./", "")
        local top = rel:match("^([^/]+)/")
        local e = doc and M.find(doc, rel)
        local fe = doc and M.find(doc, top)
        local folder_hidden = fe and M.is_hidden(fe)
        if top and not folder_hidden then
          local g = by_folder[top]
          if not g then
            g = { scripts = {}, keep = 0 }
            by_folder[top] = g
            order[#order + 1] = top
          end
          if e and M.is_hidden(e) then
            -- ja oculto
          elseif e and (M.get(e, "desc") or M.get(e, "image")) then
            g.keep = g.keep + 1   -- tem descricao/imagem: lancador de verdade, fica
          else
            g.scripts[#g.scripts + 1] = rel
          end
        end
      end
      for _, top in ipairs(order) do
        local g = by_folder[top]
        if #g.scripts > 0 then
          st.scripts = st.scripts + #g.scripts
          items[#items + 1] = { kind = "scripts", sys = sys, folder = top, scripts = g.scripts,
            hide_folder = g.keep == 0, name = top }
        end
      end
    end
    -- (c) ROMs com extensao de outro sistema
    local own = exts[sys]
    if own and not own.sh then
      for _, f in ipairs(lines("cd " .. U.shq(sdir) .. " && find . -mindepth 1 -maxdepth 1 -type f")) do
        local rel = f:gsub("^%./", "")
        local e = ext_of(rel)
        if e ~= "" and not own[e] and not GENERIC[e] and owners[e] and not rel:find("^gamelist") then
          local cands = {}
          for _, o in ipairs(owners[e]) do if o ~= sys then cands[#cands + 1] = o end end
          table.sort(cands, function(a, b)
            local pa = (have_dir[a] and 0 or 2) + (MAIN[a] and 0 or 1)
            local pb = (have_dir[b] and 0 or 2) + (MAIN[b] and 0 or 1)
            if pa ~= pb then return pa < pb end
            return #a < #b
          end)
          if #cands > 0 and #cands <= 4 then
            local ge = doc and M.find(doc, rel)
            st.suspects = st.suspects + 1
            items[#items + 1] = { kind = "suspect", sys = sys, file = rel, ext = e, target = cands[1],
              targets = cands, name = (ge and M.get(ge, "name")) or stem(rel), skip = true }
          end
        end
      end
    end
  end
  return { items = items, stats = st, skipped = skipped }
end

--- aplica os itens (os com skip=true ficam de fora). Devolve resumo.
function M.op_clean_apply(p)
  local items = p.items or {}
  local by_sys, order = {}, {}
  local function bucket(sys)
    if not by_sys[sys] then by_sys[sys] = {}; order[#order + 1] = sys end
    return by_sys[sys]
  end
  for _, it in ipairs(items) do
    if not it.skip then
      local b = bucket(it.sys)
      b[#b + 1] = it
      if it.kind == "suspect" then bucket(it.target) end
    end
  end
  local res = { removed = 0, media = 0, freed = 0, hidden = 0, moved = 0, errors = {} }
  local docs = {}
  local function doc_of(sys)
    if not docs[sys] then docs[sys] = M.load(sys) end
    return docs[sys]
  end
  local pending_rm = {}   -- midias a apagar so depois de gravar o gamelist
  local moves = {}
  for si, sys in ipairs(order) do
    M.progress(si, #order, sys)
    local doc = doc_of(sys)
    for _, it in ipairs(by_sys[sys]) do
      if it.kind == "dead" then
        local e = M.find(doc, it.path)
        local a = e and M.abs(sys, e.path)
        if e and a and not exists(a) then
          M.remove(doc, e)
          res.removed = res.removed + 1
          for _, m in ipairs(it.media or {}) do
            if inside_sys(sys, m) then pending_rm[#pending_rm + 1] = { sys = sys, path = m } end
          end
        end
      elseif it.kind == "scripts" then
        for _, rel in ipairs(it.scripts) do
          local e = M.find(doc, rel)
          if e then
            if not M.is_hidden(e) then M.set(doc, e, "hidden", "true"); res.hidden = res.hidden + 1 end
          elseif exists(M.sys_dir(sys) .. "/" .. rel) then
            M.add(doc, "game", { { "path", "./" .. rel }, { "name", stem(rel) }, { "hidden", "true" } })
            res.hidden = res.hidden + 1
          end
        end
        if it.hide_folder then
          local fe = M.find(doc, it.folder)
          if fe then
            if not M.is_hidden(fe) then M.set(doc, fe, "hidden", "true") end
          else
            M.add(doc, "folder", { { "path", "./" .. it.folder }, { "name", it.folder }, { "hidden", "true" } })
          end
        end
      elseif it.kind == "suspect" then
        moves[#moves + 1] = it
      end
    end
  end
  -- mover ROMs (o arquivo vai para a pasta certa; a entrada e as imagens vao junto)
  for _, it in ipairs(moves) do
    local src = M.sys_dir(it.sys) .. "/" .. it.file
    local dst = M.sys_dir(it.target) .. "/" .. base_of(it.file)
    if not exists(src) then
      res.errors[#res.errors + 1] = it.file .. ": arquivo não encontrado"
    elseif exists(dst) then
      res.errors[#res.errors + 1] = it.file .. ": já existe em " .. it.target
    elseif not mkdir_p(M.sys_dir(it.target)) or not sh_ok("mv -n -- " .. U.shq(src) .. " " .. U.shq(dst)) then
      res.errors[#res.errors + 1] = it.file .. ": não foi possível mover"
    else
      res.moved = res.moved + 1
      local sdoc, tdoc = doc_of(it.sys), doc_of(it.target)
      local e = M.find(sdoc, it.file)
      if e and not M.find(tdoc, base_of(it.file)) then
        local ne = M.add_copy(tdoc, e, "./" .. base_of(it.file))
        -- midias com caminho relativo: move o arquivo para o mesmo lugar no destino
        for _, tg in ipairs(M.MEDIA_TAGS) do
          local v = M.get(e, tg)
          local a = M.abs(it.sys, v)
          if v and v:sub(1, 1) ~= "/" and a and inside_sys(it.sys, a) and exists(a) then
            local ta = M.abs(it.target, v)
            if not exists(ta) then
              mkdir_p(ta:match("^(.*)/[^/]+$"))
              sh_ok("mv -n -- " .. U.shq(a) .. " " .. U.shq(ta))
            end
          end
        end
        ne.dirty = true
      end
      if e then M.remove(sdoc, e) end
    end
  end
  for sys, doc in pairs(docs) do
    local ok, err = M.save(doc)
    if not ok then res.errors[#res.errors + 1] = sys .. ": " .. tostring(err); doc.failed = true end
  end
  -- so agora (gamelist gravado) apaga as imagens das entradas mortas
  for _, m in ipairs(pending_rm) do
    if not docs[m.sys].failed then
      local sz = fsize(m.path) or 0
      if os.remove(m.path) then res.media = res.media + 1; res.freed = res.freed + sz end
    end
  end
  return res
end

-------------------------------------------------------------------------------
-- 2. IMAGENS (libretro-thumbnails)
-------------------------------------------------------------------------------
M.LIBRETRO = {
  gb = "Nintendo - Game Boy", gb2players = "Nintendo - Game Boy", sgb = "Nintendo - Game Boy",
  gbc = "Nintendo - Game Boy Color", gbc2players = "Nintendo - Game Boy Color",
  gba = "Nintendo - Game Boy Advance", nes = "Nintendo - Nintendo Entertainment System",
  fds = "Nintendo - Family Computer Disk System", snes = "Nintendo - Super Nintendo Entertainment System",
  ["snes-msu1"] = "Nintendo - Super Nintendo Entertainment System", sfc = "Nintendo - Super Nintendo Entertainment System",
  satellaview = "Nintendo - Satellaview", sufami = "Nintendo - Sufami Turbo",
  n64 = "Nintendo - Nintendo 64", nds = "Nintendo - Nintendo DS", virtualboy = "Nintendo - Virtual Boy",
  pokemini = "Nintendo - Pokemon Mini",
  megadrive = "Sega - Mega Drive - Genesis", genesis = "Sega - Mega Drive - Genesis",
  ["msu-md"] = "Sega - Mega Drive - Genesis", mastersystem = "Sega - Master System - Mark III",
  gamegear = "Sega - Game Gear", sega32x = "Sega - 32X", segacd = "Sega - Mega-CD - Sega CD",
  saturn = "Sega - Saturn", dreamcast = "Sega - Dreamcast", sg1000 = "Sega - SG-1000",
  naomi = "Sega - Naomi", atomiswave = "Atomiswave",
  psx = "Sony - PlayStation", psp = "Sony - PlayStation Portable",
  pcengine = "NEC - PC Engine - TurboGrafx 16", pcenginecd = "NEC - PC Engine CD - TurboGrafx-CD",
  supergrafx = "NEC - PC Engine SuperGrafx", pc98 = "NEC - PC-98",
  neogeo = "SNK - Neo Geo", neogeocd = "SNK - Neo Geo CD", ngp = "SNK - Neo Geo Pocket",
  ngpc = "SNK - Neo Geo Pocket Color", wswan = "Bandai - WonderSwan", wswanc = "Bandai - WonderSwan Color",
  wonderswan = "Bandai - WonderSwan", wonderswancolor = "Bandai - WonderSwan Color",
  mame = "MAME", fbneo = "FBNeo - Arcade Games", atari2600 = "Atari - 2600", atari5200 = "Atari - 5200",
  atari7800 = "Atari - 7800", lynx = "Atari - Lynx", jaguar = "Atari - Jaguar", atarist = "Atari - ST",
  colecovision = "Coleco - ColecoVision", intellivision = "Mattel - Intellivision", vectrex = "GCE - Vectrex",
  msx1 = "Microsoft - MSX", msx2 = "Microsoft - MSX2", c64 = "Commodore - 64", amiga500 = "Commodore - Amiga",
  zxspectrum = "Sinclair - ZX Spectrum", amstradcpc = "Amstrad - CPC", dos = "DOS", scummvm = "ScummVM",
  ["3do"] = "The 3DO Company - 3DO", supervision = "Watara - Supervision", channelf = "Fairchild - Channel F",
  o2em = "Magnavox - Odyssey2", x68000 = "Sharp - X68000", tic80 = "TIC-80",
}

-- pasta do libretro-thumbnails para cada tipo de imagem
M.KINDS = { box = "Named_Boxarts", snap = "Named_Snaps", logo = "Named_Logos" }

--- nome no padrao libretro (caracteres proibidos viram "_")
function M.libretro_name(s)
  return (s:gsub("[&%*/:`<>%?\\|\"]", "_"))
end

local function urlenc(s)
  return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end
function M.repo_of(lrname) return (lrname:gsub(" ", "_")) end

-- acentos comuns -> ascii (para comparar nomes)
local ACC = { ["á"] = "a", ["à"] = "a", ["â"] = "a", ["ã"] = "a", ["ä"] = "a", ["é"] = "e", ["ê"] = "e",
  ["è"] = "e", ["ë"] = "e", ["í"] = "i", ["ï"] = "i", ["ó"] = "o", ["ô"] = "o", ["õ"] = "o", ["ö"] = "o",
  ["ú"] = "u", ["ü"] = "u", ["ç"] = "c", ["ñ"] = "n", ["Á"] = "a", ["É"] = "e", ["Í"] = "i", ["Ó"] = "o",
  ["Ú"] = "u", ["Ç"] = "c" }

--- chave de comparacao: sem regiao/tags, sem "the", so letras e numeros
function M.key(s)
  s = (s or ""):gsub("[\195][\128-\191]", function(c) return ACC[c] or "" end)
  s = s:lower():gsub("%b()", " "):gsub("%b[]", " "):gsub("&", " and ")
  s = s:gsub(",%s*the%f[%W]", " "):gsub("^%s*the%s+", " ")
  s = s:gsub("%f[%w]ii%f[%W]", "2"):gsub("%f[%w]iii%f[%W]", "3"):gsub("%f[%w]iv%f[%W]", "4")
  return (s:gsub("[^%w]", ""))
end

local REGION = { { "%(usa", 1 }, { "%(world", 2 }, { "%(usa, europe", 1 }, { "%(europe", 3 }, { "%(brazil", 4 },
  { "%(japan, usa", 2 }, { "%(japan", 6 } }
local function region_score(n)
  local l = n:lower()
  local best = 5
  for _, r in ipairs(REGION) do if l:find(r[1]) and r[2] < best then best = r[2] end end
  if l:find("%(beta") or l:find("%(proto") or l:find("%(demo") or l:find("%(sample") then best = best + 10 end
  return best
end

local function json_str(s)
  return (s:gsub("\\u(%x%x%x%x)", function(h) return u8(tonumber(h, 16)) end):gsub("\\(.)", "%1"))
end

--- baixa url -> out. Devolve o codigo HTTP (0 = falha de rede/transferencia incompleta)
local function http_get(url, out, timeout)
  local cmd = "curl -sSL --connect-timeout 10 -m " .. (timeout or 40) .. " -A 'KnulliPortHub' -o " .. U.shq(out)
    .. " -w '%{http_code}' " .. U.shq(url)
  local s = U.capture(cmd .. " 2>/dev/null; echo \" rc=$?\"") or ""
  local code, rc = s:match("(%d+)%s+rc=(%d+)")
  if tonumber(rc) ~= 0 then return 0 end
  return tonumber(code) or 0
end

--- indice de nomes de um tipo (cache em disco). Devolve { names = {set}, by_key = {key -> {nomes}} } ou nil
local IDX, ROOTS = {}, {}
function M.index(lrname, kind)
  local id = lrname .. "|" .. kind
  if IDX[id] ~= nil then return IDX[id] or nil end
  local repo = M.repo_of(lrname)
  local cdir = M.cfg.cache_dir .. "/libretro/" .. repo
  local cfile = cdir .. "/" .. kind .. ".txt"
  local text = U.read_file(cfile)
  if not text then
    mkdir_p(cdir)
    local tmp = cdir .. "/tree.json"
    local folder = M.KINDS[kind]
    -- pastas da raiz do repositorio (uma chamada por repositorio: a API aceita 60/hora sem conta)
    if ROOTS[repo] == nil then
      ROOTS[repo] = false
      for _, br in ipairs({ "master", "main" }) do
        if http_get("https://api.github.com/repos/libretro-thumbnails/" .. repo .. "/git/trees/" .. br, tmp, 30) == 200 then
          local j = U.read_file(tmp) or ""
          local t = {}
          for p, s in j:gmatch('"path"%s*:%s*"([^"]+)".-"sha"%s*:%s*"(%x+)"') do t[p] = s end
          if next(t) then ROOTS[repo] = t; break end
        end
      end
    end
    local sha = ROOTS[repo] and ROOTS[repo][folder]
    if sha and http_get("https://api.github.com/repos/libretro-thumbnails/" .. repo .. "/git/trees/" .. sha, tmp, 90) == 200 then
      local j = U.read_file(tmp) or ""
      local t = {}
      -- nomes do libretro nunca tem aspas nem barra invertida (viram "_")
      for p in j:gmatch('"path"%s*:%s*"([^"]*)"') do
        p = json_str(p)
        if p:lower():match("%.png$") then t[#t + 1] = (p:gsub("%.[pP][nN][gG]$", "")) end
      end
      -- resposta completa: termina em "}" e nao veio cortada pelo GitHub
      local complete = j:match("}%s*$") and j:find('"truncated"%s*:%s*false')
      if #t > 0 and complete then
        text = table.concat(t, "\n") .. "\n"
        U.write_file(cfile, text)
      end
    end
    os.remove(tmp)
    if not text then IDX[id] = false; return nil end
  end
  local idx = { names = {}, by_key = {} }
  for n in text:gmatch("[^\n]+") do
    idx.names[n] = true
    local k = M.key(n)
    if k ~= "" then
      idx.by_key[k] = idx.by_key[k] or {}
      table.insert(idx.by_key[k], n)
    end
  end
  IDX[id] = idx
  return idx
end

--- melhor nome do libretro para um jogo (candidatos = nomes do arquivo/gamelist)
function M.match(idx, cands)
  for _, c in ipairs(cands) do
    local n = M.libretro_name(c)
    if idx.names[n] then return n end
  end
  local function best_of(list)
    local best, bs = nil, 99
    for _, n in ipairs(list) do
      local s = region_score(n)
      if s < bs then best, bs = n, s end
    end
    return best
  end
  for _, c in ipairs(cands) do
    local list = idx.by_key[M.key(c)]
    if list then return best_of(list) end
  end
  -- ultimo recurso: so o titulo antes do subtitulo ("Jogo II - Subtitulo" -> "Jogo II"),
  -- com pelo menos 6 letras para nao confundir com outro jogo
  for _, c in ipairs(cands) do
    local head = c:match("^(.-)%s+%-%s+")
    local k = head and M.key(head)
    if k and #k >= 6 and idx.by_key[k] then return best_of(idx.by_key[k]) end
  end
  return nil
end

local function is_png(path)
  local f = io.open(path, "rb")
  if not f then return false end
  local h = f:read(8) or ""
  f:close()
  return h == "\137PNG\r\n\26\n"
end

--- baixa uma imagem do libretro (segue os "atalhos" em texto). true ou nil, motivo
function M.fetch_thumb(lrname, kind, name, out)
  local folder = M.KINDS[kind]
  local repo = M.repo_of(lrname)
  local tmp = out .. ".part"
  local n = name
  for _ = 1, 3 do
    local urls = {
      "https://raw.githubusercontent.com/libretro-thumbnails/" .. repo .. "/master/" .. folder .. "/" .. urlenc(n) .. ".png",
      "https://thumbnails.libretro.com/" .. urlenc(lrname) .. "/" .. folder .. "/" .. urlenc(n) .. ".png",
    }
    local code = 0
    for _, u in ipairs(urls) do
      code = http_get(u, tmp, 40)
      if code == 200 then break end
      if code == 404 and u:find("githubusercontent", 1, true) then
        -- 404 no GitHub: o outro servidor so ajuda se o GitHub estiver fora
        break
      end
    end
    if code ~= 200 then os.remove(tmp); return nil, "http " .. code end
    if is_png(tmp) then
      local ok = os.rename(tmp, out)
      if not ok then os.remove(tmp); return nil, "gravar" end
      return true
    end
    -- arquivo "atalho" (symlink do git em texto): aponta para outro nome
    local body = trim(U.read_file(tmp) or "")
    os.remove(tmp)
    if #body == 0 or #body > 400 or body:find("[<\n]") then return nil, "não é PNG" end
    n = (base_of(body):gsub("%.[pP][nN][gG]$", ""))
  end
  return nil, "atalho em laço"
end

--- quem precisa de imagem: { by_sys = { sys = { {path, file, name, need={...}} } }, totals }
function M.op_images_scan(p)
  p = p or {}
  local exts = M.system_exts()
  local ports_map = p.ports_covers or {}
  local res = { systems = {}, total = 0 }
  local systems = M.system_dirs()
  for si, sys in ipairs(systems) do
    if M.cancelled() then break end
    M.progress(si, #systems, sys)
    local lr = M.LIBRETRO[sys]
    local is_ports = exts[sys] and exts[sys].sh
    if (lr or is_ports) and exts[sys] then
      local sdir = M.sys_dir(sys)
      local doc = M.load(sys)
      local list = {}
      local seen = {}
      local function check(rel, e)
        local need = {}
        local function dead(tag)
          local v = e and M.get(e, tag)
          return not v or v == "" or not exists(M.abs(sys, v) or "")
        end
        if dead("image") then
          need.image = true
          if dead("thumbnail") then need.thumbnail = true end
          if dead("marquee") then need.marquee = true end
          local cands = { stem(rel) }
          local nm = e and M.get(e, "name")
          if nm and nm ~= "" and nm ~= cands[1] then cands[#cands + 1] = nm end
          local item = { path = "./" .. rel, file = stem(rel), cands = cands, name = nm or stem(rel), need = need }
          if is_ports then
            item.url = ports_map[base_of(rel)]
            if item.url then list[#list + 1] = item end
          else
            list[#list + 1] = item
          end
        end
      end
      for _, e in ipairs(doc.entries) do
        if e.path then seen[(e.path:gsub("^%./", ""))] = true end
        if e.kind == "game" and e.path and not M.is_hidden(e) then
          local rel = e.path:gsub("^%./", "")
          local a = M.abs(sys, e.path)
          local okp = not is_ports or not rel:find("/")
          if a and okp and exists(a) then check(rel, e) end
        end
      end
      -- arquivos sem entrada no gamelist (o EmulationStation mostra sem imagem)
      for _, f in ipairs(lines("cd " .. U.shq(sdir) .. " && find . -mindepth 1 -maxdepth 1 -type f")) do
        local rel = f:gsub("^%./", "")
        if not seen[rel] and exts[sys][ext_of(rel)] and not rel:find("^gamelist") then check(rel, nil) end
      end
      if #list > 0 then
        table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
        res.systems[#res.systems + 1] = { sys = sys, libretro = lr, ports = is_ports and true or false, games = list }
        res.total = res.total + #list
      end
    end
  end
  return res
end

--- reduz as imagens (lado maior = max px) com o PIL; silencioso se nao houver python/PIL
local function shrink_images(files, maxpx)
  if #files == 0 then return end
  local lst = M.cfg.cache_dir .. "/shrink.lst"
  mkdir_p(M.cfg.cache_dir)
  U.write_file(lst, table.concat(files, "\n") .. "\n")
  local py = "import os,sys\nfrom PIL import Image\nM=int(sys.argv[2])\n"
    .. "for p in open(sys.argv[1],encoding='utf-8').read().split('\\n'):\n"
    .. "  if not p: continue\n"
    .. "  try:\n"
    .. "    im=Image.open(p)\n"
    .. "    if max(im.size)<=M: continue\n"
    .. "    im.thumbnail((M,M))\n"
    .. "    if im.mode not in ('RGB','RGBA','P','L','LA'): im=im.convert('RGBA')\n"
    .. "    im.save(p+'.tmp.png',optimize=True); os.replace(p+'.tmp.png',p)\n"
    .. "  except Exception as e: print('ERR',p,e)\n"
  local pyf = M.cfg.cache_dir .. "/shrink.py"
  U.write_file(pyf, py)
  os.execute("cd /tmp && python3 -I " .. U.shq(pyf) .. " " .. U.shq(lst) .. " " .. tonumber(maxpx) .. " >/dev/null 2>&1")
  os.remove(lst)
end

--- baixa as imagens. p = { systems = { {sys, libretro, ports, games} }, limit, main = "box"|"snap" }
function M.op_images_run(p)
  local limit = p.limit or M.IMG_LIMIT
  local main = p.main == "snap" and "snap" or "box"
  local res = { ok = 0, partial = 0, missing = 0, failed = 0, bytes = 0, errors = {}, done_games = 0 }
  local free = M.free_kb(M.cfg.root)
  if free and free < M.MIN_FREE_KB then
    res.errors[#res.errors + 1] = "pouco espaço livre"
    res.nospace = true
    return res
  end
  local total = 0
  for _, s in ipairs(p.systems or {}) do total = total + #s.games end
  total = math.min(total, limit)
  local n = 0
  for _, s in ipairs(p.systems or {}) do
    if n >= limit or M.cancelled() then break end
    local sys = s.sys
    local doc = M.load(sys)
    local imgdir = M.sys_dir(sys) .. "/images"
    mkdir_p(imgdir)
    local new_files = {}
    local changed = false
    for _, g in ipairs(s.games) do
      if n >= limit or M.cancelled() then break end
      n = n + 1
      M.progress(n, total, g.name)
      local got = {}
      local function target(suffix) return imgdir .. "/" .. g.file .. "-" .. suffix .. ".png" end
      local function rel_of(abs) return "./images/" .. base_of(abs) end
      local function get(kind, suffix)
        local out = target(suffix)
        if exists(out) and is_png(out) then return out end
        if s.ports then
          if kind ~= "box" or not g.url then return nil end
          local tmp = out .. ".part"
          if http_get(g.url, tmp, 40) == 200 and (fsize(tmp) or 0) > 0 then
            local h = U.read_file(tmp) or ""
            local okimg = h:sub(1, 8) == "\137PNG\r\n\26\n" or h:sub(1, 3) == "\255\216\255"
            if okimg and os.rename(tmp, out) then new_files[#new_files + 1] = out; return out end
          end
          os.remove(tmp)
          return nil
        end
        local idx = M.index(s.libretro, kind)
        local name = idx and M.match(idx, g.cands)
        if idx and not name then return nil end
        local tries = name and { name } or { M.libretro_name(g.cands[1]) }
        for _, nm in ipairs(tries) do
          local ok = M.fetch_thumb(s.libretro, kind, nm, out)
          if ok then new_files[#new_files + 1] = out; return out end
        end
        return nil
      end
      local primary, second = main, main == "box" and "snap" or "box"
      local img
      if g.need.image then
        img = get(primary, "image")
        if not img then img = get(second, "image") end
        if img then got.image = img end
      end
      if g.need.thumbnail then
        if main == "box" and got.image then got.thumbnail = got.image
        elseif not s.ports then got.thumbnail = get("box", "thumb") end
      end
      if g.need.marquee and not s.ports then got.marquee = get("logo", "marquee") end
      if got.image or got.thumbnail or got.marquee then
        local e = M.find(doc, g.path)
        if not e then
          e = M.add(doc, "game", { { "path", g.path }, { "name", g.name } })
          doc.by_path[g.path:gsub("^%./", "")] = e
        end
        for _, tg in ipairs({ "image", "thumbnail", "marquee" }) do
          if got[tg] then M.set(doc, e, tg, rel_of(got[tg])) end
        end
        changed = true
        if got.image then res.ok = res.ok + 1 else res.partial = res.partial + 1 end
      else
        res.missing = res.missing + 1
      end
    end
    shrink_images(new_files, p.max_px or M.IMG_MAX_PX)
    for _, f in ipairs(new_files) do res.bytes = res.bytes + (fsize(f) or 0) end
    if changed then
      local ok, err = M.save(doc)
      if not ok then res.errors[#res.errors + 1] = sys .. ": " .. tostring(err); res.failed = res.failed + 1 end
    end
  end
  res.done_games = n
  res.cancelled = M.cancelled()
  return res
end

-------------------------------------------------------------------------------
-- 3. JOGOS DE VARIOS DISCOS
-------------------------------------------------------------------------------
M.DISC_SYSTEMS = { "psx", "segacd", "dreamcast", "pcenginecd", "saturn" }
local DISC_EXT = { cue = 3, chd = 1, pbp = 2, gdi = 4, iso = 5 }

-- marcadores de disco (texto em minusculas; posicoes iguais ao original)
local DISC_PATS = {
  "%s*%(%s*dis[ck]o?%s*(%d+)[^%)]*%)",
  "%s*%(%s*cd%s*(%d+)[^%)]*%)",
  "%s*%[%s*dis[ck]o?%s*(%d+)[^%]]*%]",
  "%s+%-?%s*dis[ck]o?%s*(%d+)$",
  "%s+%-?%s*cd%s*(%d+)$",
}

--- "Final Fantasy VII (USA) (Disc 2)" -> "Final Fantasy VII (USA)", 2
function M.disc_info(name)
  local l = name:lower()
  for _, pat in ipairs(DISC_PATS) do
    local s, e, num = l:find(pat)
    if s then
      local base = (name:sub(1, s - 1) .. name:sub(e + 1)):gsub("%s%s+", " ")
      return trim(base), tonumber(num)
    end
  end
  return nil
end

function M.op_multidisc_scan()
  M.reset()
  local exts = M.system_exts()
  local res = { groups = {}, notes = {} }
  for si, sys in ipairs(M.DISC_SYSTEMS) do
    M.progress(si, #M.DISC_SYSTEMS, sys)
    local sdir = M.sys_dir(sys)
    if exists(sdir) then
      local doc = M.load(sys)
      local groups, order = {}, {}
      for _, f in ipairs(lines("cd " .. U.shq(sdir) .. " && find . -mindepth 1 -maxdepth 2 -type f")) do
        local rel = f:gsub("^%./", "")
        local e = ext_of(rel)
        if DISC_EXT[e] then
          local base, num = M.disc_info(stem(rel))
          if base and num then
            local dir = rel:match("^(.*)/[^/]+$") or ""
            local k = lower(base)
            local g = groups[k]
            if not g then
              g = { sys = sys, base = base, discs = {} }
              groups[k] = g; order[#order + 1] = k
            end
            local cur = g.discs[num]
            if not cur or DISC_EXT[e] < DISC_EXT[ext_of(cur)] then g.discs[num] = rel end
            g.dir = g.dir or dir
          end
        end
      end
      local m3u_ok = exts[sys] == nil or exts[sys].m3u
      for _, k in ipairs(order) do
        local g = groups[k]
        local nums = {}
        for nn in pairs(g.discs) do nums[#nums + 1] = nn end
        table.sort(nums)
        if #nums >= 2 and g.discs[1] then
          local files = {}
          for _, nn in ipairs(nums) do files[#files + 1] = g.discs[nn] end
          local m3u = g.base .. ".m3u"
          local gap = nums[#nums] ~= #nums
          local d1 = M.find(doc, files[1])
          local hidden_n = 0
          for _, f in ipairs(files) do
            local de = M.find(doc, f)
            if de and M.is_hidden(de) then hidden_n = hidden_n + 1 end
          end
          local has_m3u = exists(sdir .. "/" .. m3u)
          local status = has_m3u and (hidden_n == #files and "ok" or "hide") or "new"
          if not m3u_ok then status = "nom3u" end
          if status ~= "ok" then
            res.groups[#res.groups + 1] = { sys = sys, base = g.base, m3u = m3u, files = files, gap = gap,
              status = status, name = d1 and M.get(d1, "name") or g.base, skip = status == "nom3u" }
          end
        end
      end
      if not m3u_ok then res.notes[#res.notes + 1] = sys end
    end
  end
  return res
end

function M.op_multidisc_apply(p)
  local res = { created = 0, hidden = 0, errors = {} }
  local docs = {}
  for i, g in ipairs(p.groups or {}) do
    M.progress(i, #p.groups, g.base)
    if not g.skip and g.status ~= "nom3u" then
      local sys = g.sys
      local sdir = M.sys_dir(sys)
      docs[sys] = docs[sys] or M.load(sys)
      local doc = docs[sys]
      local m3u_abs = sdir .. "/" .. g.m3u
      local okfiles = true
      for _, f in ipairs(g.files) do if not exists(sdir .. "/" .. f) then okfiles = false end end
      if not okfiles then
        res.errors[#res.errors + 1] = g.base .. ": disco não encontrado"
      else
        if not exists(m3u_abs) then
          local tmp = m3u_abs .. ".porthub.tmp"
          if U.write_file(tmp, table.concat(g.files, "\n") .. "\n") and os.rename(tmp, m3u_abs) then
            res.created = res.created + 1
          else
            os.remove(tmp)
            res.errors[#res.errors + 1] = g.base .. ": não foi possível criar o .m3u"
            okfiles = false
          end
        end
        if okfiles then
          if not M.find(doc, g.m3u) then
            local d1 = M.find(doc, g.files[1])
            local e
            if d1 then
              e = M.add_copy(doc, d1, "./" .. g.m3u)
              M.del(doc, e, "hidden")
              local nm = M.get(e, "name")
              if nm then
                local b = M.disc_info(nm)
                if b then M.set(doc, e, "name", b) end
              end
            else
              e = M.add(doc, "game", { { "path", "./" .. g.m3u }, { "name", g.base } })
            end
            doc.by_path[g.m3u] = e
          end
          for _, f in ipairs(g.files) do
            local de = M.find(doc, f)
            if de then
              if not M.is_hidden(de) then M.set(doc, de, "hidden", "true"); res.hidden = res.hidden + 1 end
            else
              de = M.add(doc, "game", { { "path", "./" .. f }, { "name", stem(f) }, { "hidden", "true" } })
              doc.by_path[f] = de
              res.hidden = res.hidden + 1
            end
          end
        end
      end
    end
  end
  for sys, doc in pairs(docs) do
    local ok, err = M.save(doc)
    if not ok then res.errors[#res.errors + 1] = sys .. ": " .. tostring(err) end
  end
  return res
end

-------------------------------------------------------------------------------
-- 4. VIDEOS
-------------------------------------------------------------------------------
--- credenciais do ScreenScraper guardadas pelo EmulationStation (so diz se existem)
function M.scraper_account()
  local t = U.read_file(M.cfg.es_settings) or ""
  local user = t:match('name="ScreenScraperUser"%s+value="([^"]*)"')
  local pass = t:match('name="ScreenScraperPass"%s+value="([^"]*)"')
  return (user and user ~= "" and pass and pass ~= "") and user or nil
end

function M.op_video_scan()
  local res = { dead = 0, dead_sys = {}, videos = {}, bytes = 0, big = 0, free_kb = M.free_kb(M.cfg.root),
    ffmpeg = sh_ok("command -v ffmpeg"), account = M.scraper_account() ~= nil }
  local systems = M.system_dirs()
  for si, sys in ipairs(systems) do
    M.progress(si, #systems, sys)
    local f = M.sys_dir(sys) .. "/gamelist.xml"
    if exists(f) then
      local doc = M.load(sys)
      local nd = 0
      for _, e in ipairs(doc.entries) do
        local v = M.get(e, "video")
        if v and v ~= "" then
          local a = M.abs(sys, v)
          if a and exists(a) then
            local sz = fsize(a) or 0
            res.videos[#res.videos + 1] = { sys = sys, path = e.path, video = v, abs = a, bytes = sz }
            res.bytes = res.bytes + sz
            if sz > 1024 * 1024 then res.big = res.big + 1 end
          elseif a then
            nd = nd + 1
          end
        end
      end
      if nd > 0 then res.dead = res.dead + nd; res.dead_sys[#res.dead_sys + 1] = { sys = sys, n = nd } end
    end
  end
  table.sort(res.videos, function(a, b) return a.bytes > b.bytes end)
  return res
end

function M.op_video_clean()
  local res = { removed = 0, errors = {} }
  local systems = M.system_dirs()
  for si, sys in ipairs(systems) do
    M.progress(si, #systems, sys)
    if exists(M.sys_dir(sys) .. "/gamelist.xml") then
      local doc = M.load(sys)
      local n = 0
      for _, e in ipairs(doc.entries) do
        local v = M.get(e, "video")
        local a = v and M.abs(sys, v)
        if v and (v == "" or (a and not exists(a))) then
          if M.del(doc, e, "video") then n = n + 1 end
        end
      end
      if n > 0 then
        local ok, err = M.save(doc)
        if ok then res.removed = res.removed + n else res.errors[#res.errors + 1] = sys .. ": " .. tostring(err) end
      end
    end
  end
  return res
end

--- reduz um video (ffmpeg). true, novo_tamanho | nil, motivo | false (ja leve)
function M.shrink_video(abs, audio)
  local V = M.VIDEO
  local info = U.capture("ffprobe -v error -select_streams v:0 -show_entries stream=width,height:format=duration,bit_rate -of default=nw=1 "
    .. U.shq(abs) .. " 2>/dev/null") or ""
  local w = tonumber(info:match("width=(%d+)"))
  local br = tonumber(info:match("bit_rate=(%d+)"))
  local dur = tonumber(info:match("duration=([%d%.]+)"))
  if w and w <= V.w and br and br <= (V.kbps + 150) * 1000 and dur and dur <= V.secs + 1 then return false end
  local tmp = abs:gsub("%.[^./]+$", "") .. ".porthub.tmp.mp4"
  local vf = "scale=" .. V.w .. ":" .. V.h .. ":force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2,fps=24"
  local acodec = audio and "-c:a aac -ac 1 -ar 22050 -b:a 32k" or "-an"
  local cmd = "ffmpeg -nostdin -hide_banner -loglevel error -y -i " .. U.shq(abs) .. " -t " .. V.secs
    .. " -vf " .. U.shq(vf) .. " -c:v libx264 -preset veryfast -profile:v baseline -pix_fmt yuv420p -b:v " .. V.kbps
    .. "k -maxrate " .. (V.kbps + 50) .. "k -bufsize " .. (V.kbps * 2) .. "k " .. acodec
    .. " -movflags +faststart " .. U.shq(tmp)
  local ok = sh_ok(cmd)
  local ns = fsize(tmp) or 0
  local os_ = fsize(abs) or 0
  if not ok or ns < 1024 then os.remove(tmp); return nil, "ffmpeg falhou" end
  if ns >= os_ then os.remove(tmp); return false end
  return tmp, ns, os_
end

--- p = { videos = { {sys, path, video, abs} }, audio = bool }
function M.op_video_shrink(p)
  local res = { done = 0, skipped = 0, failed = 0, saved = 0, errors = {} }
  local list = p.videos or {}
  local docs = {}
  for i, v in ipairs(list) do
    if M.cancelled() then break end
    M.progress(i, #list, base_of(v.abs))
    local free = M.free_kb(M.cfg.root)
    if free and free < 20 * 1024 then res.errors[#res.errors + 1] = "pouco espaço livre"; break end
    local tmp, ns, os_ = M.shrink_video(v.abs, p.audio)
    if tmp then
      -- mesmo nome se ja for .mp4; senao vira .mp4 e o gamelist aponta para o novo
      local final = v.abs:lower():match("%.mp4$") and v.abs or (v.abs:gsub("%.[^./]+$", "") .. ".mp4")
      if final ~= v.abs and exists(final) then os.remove(tmp); res.failed = res.failed + 1
      elseif os.rename(tmp, final) then
        if final ~= v.abs then
          docs[v.sys] = docs[v.sys] or M.load(v.sys)
          local e = M.find(docs[v.sys], v.path)
          if e then M.set(docs[v.sys], e, "video", (v.video:gsub("%.[^./]+$", "") .. ".mp4")) end
          os.remove(v.abs)
        end
        res.done = res.done + 1
        res.saved = res.saved + (os_ - ns)
      else
        os.remove(tmp); res.failed = res.failed + 1
      end
    elseif tmp == false then
      res.skipped = res.skipped + 1
    else
      res.failed = res.failed + 1
      res.errors[#res.errors + 1] = base_of(v.abs) .. ": " .. tostring(ns)
    end
  end
  for sys, doc in pairs(docs) do
    local ok, err = M.save(doc)
    if not ok then res.errors[#res.errors + 1] = sys .. ": " .. tostring(err) end
  end
  res.cancelled = M.cancelled()
  return res
end

-------------------------------------------------------------------------------
-- execucao em segundo plano (so no app: usa love.thread e core.shjob)
-------------------------------------------------------------------------------
M.job = nil   -- { op, status = {done,total,text}, cancel() }

function M.busy() return M.job ~= nil end

--- roda M.op_<op>(params) na thread. on_done(ok, res_ou_erro)
function M.run(op, params, on_done)
  if M.job then return nil, "ocupado" end
  local Sh = require("core.shjob")
  Sh.seq = Sh.seq + 1
  local base = "hub_libtools_" .. Sh.seq
  local out = love.thread.getChannel(base)
  local st = love.thread.getChannel(base .. "_st")
  local ctl = love.thread.getChannel(base .. "_ctl")
  out:clear(); st:clear(); ctl:clear()
  local th = love.thread.newThread("threads/libtools_thread.lua")
  local job = { op = op, status = { done = 0, total = 0, text = "" }, st = st, ctl = ctl }
  function job.cancel() ctl:push("cancel"); job.cancelling = true end
  function job.poll()
    local m = st:pop()
    while m do job.status = m; m = st:pop() end
    return job.status
  end
  M.job = job
  -- registra no shjob: ele chama on_done em qualquer tela (Sh.update roda a cada quadro)
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
