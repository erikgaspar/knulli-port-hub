-- =============================================================================
--  Filtros e ordenacao da Central (tema Premium). Sem desenho: testavel no
--  console. Um estado por aba ("games", "tools"), lembrado em Prefs
--  (chave "pf_<aba>", ex.: "o=pm;c=acao,rpg;s=inst;h=test;x=1;z=200;r=1;o2=az").
--
--  f = {
--    origin = "all" | "author" | "pm",
--    cats   = { [category_id] = true, ... }     (vazio = todas)
--    sit    = nil | "inst" | "none" | "upd" | "fav"
--    h700   = nil | "test" | "nobadge"
--    hide_heavy = bool  (esconde "pesado" e "nao_funciona")
--    size   = nil | 50 | 200 | 1024             (MB; tamanho desconhecido fica de fora)
--    nort   = bool  (so ports sem runtime para baixar)
--    sort   = "az" | "added" | "updated" | "size_asc" | "size_desc" | "tested"
--  }
-- =============================================================================
local L = require("lib.i18n").L
local Search = require("core.search")

local F = {}

F.SORTS = {
  { id = "az", label = L("A–Z") },
  { id = "added", label = L("Adicionados recentemente") },
  { id = "updated", label = L("Atualizados recentemente") },
  { id = "size_asc", label = L("Menor tamanho") },
  { id = "size_desc", label = L("Maior tamanho") },
  { id = "tested", label = L("Testados primeiro") },
}
F.SORT_BY_ID = {}
for _, s in ipairs(F.SORTS) do F.SORT_BY_ID[s.id] = s end
F.SIZES = { 50, 200, 1024 }
local MB = 1024 * 1024

function F.new()
  return { origin = "all", cats = {}, sit = nil, h700 = nil, hide_heavy = false, size = nil, nort = false, sort = "az" }
end

function F.copy(f)
  local o = {}
  for k, v in pairs(f) do o[k] = v end
  o.cats = {}
  for k, v in pairs(f.cats or {}) do o.cats[k] = v end
  return o
end

--- quantos filtros (sem contar a ordenacao) estao ligados
function F.active_count(f)
  local n = 0
  if f.origin ~= "all" then n = n + 1 end
  for _ in pairs(f.cats) do n = n + 1 end
  if f.sit then n = n + 1 end
  if f.h700 then n = n + 1 end
  if f.hide_heavy then n = n + 1 end
  if f.size then n = n + 1 end
  if f.nort then n = n + 1 end
  return n
end

function F.is_default(f) return F.active_count(f) == 0 and f.sort == "az" end

-- ---------------------------------------------------------------------------
-- Prefs
local SIT = { inst = true, none = true, upd = true, fav = true }
local H7 = { test = true, nobadge = true }
local ORI = { all = true, author = true, pm = true }

function F.encode(f)
  local t = {}
  if f.origin ~= "all" then t[#t + 1] = "o=" .. f.origin end
  local cs = {}
  for k in pairs(f.cats) do cs[#cs + 1] = k end
  table.sort(cs)
  if #cs > 0 then t[#t + 1] = "c=" .. table.concat(cs, ",") end
  if f.sit then t[#t + 1] = "s=" .. f.sit end
  if f.h700 then t[#t + 1] = "h=" .. f.h700 end
  if f.hide_heavy then t[#t + 1] = "x=1" end
  if f.size then t[#t + 1] = "z=" .. f.size end
  if f.nort then t[#t + 1] = "r=1" end
  if f.sort ~= "az" then t[#t + 1] = "o2=" .. f.sort end
  return table.concat(t, ";")
end

function F.decode(s)
  local f = F.new()
  for k, v in tostring(s or ""):gmatch("([%w]+)=([^;]*)") do
    if k == "o" and ORI[v] then f.origin = v
    elseif k == "c" then for id in v:gmatch("[^,]+") do f.cats[id] = true end
    elseif k == "s" and SIT[v] then f.sit = v
    elseif k == "h" and H7[v] then f.h700 = v
    elseif k == "x" then f.hide_heavy = v == "1"
    elseif k == "z" and tonumber(v) then
      for _, z in ipairs(F.SIZES) do if z == tonumber(v) then f.size = z end end
    elseif k == "r" then f.nort = v == "1"
    elseif k == "o2" and F.SORT_BY_ID[v] then f.sort = v
    end
  end
  return f
end

function F.load(tab)
  return F.decode(require("core.prefs").get("pf_" .. tostring(tab)))
end

function F.save(tab, f)
  local s = F.encode(f)
  local P = require("core.prefs")
  local key = "pf_" .. tostring(tab)
  if (P.get(key) or "") ~= s then P.set(key, s ~= "" and s or nil) end
end

-- ---------------------------------------------------------------------------
-- teste de cada port
--- contexto de uma passada (cache dos runtimes presentes, favoritos, status)
function F.ctx()
  return { rt = {}, status = App and App.status, fav = require("core.favorites") }
end

-- pasta libs do PortMaster: achar custa alguns "test -d" no shell; guardada 30 s
local libs_cache = { t = -100 }
local function libs_dir()
  local now = os.time()
  if now - libs_cache.t > 30 or now < libs_cache.t then
    local ok, PMC = pcall(require, "core.pmcatalog")
    libs_cache.dir = ok and PMC.libs_dir() or nil
    libs_cache.t = now
  end
  return libs_cache.dir
end

local function needs_download(p, ctx)
  local need = p.attr and p.attr.runtime
  if type(need) ~= "table" or #need == 0 then return false end
  if ctx.libs == nil then
    ctx.libs = libs_dir() or false
    ctx.rt_name = require("core.pmcatalog").rt_name
  end
  for _, n in ipairs(need) do
    local name = ctx.rt_name and ctx.rt_name(n) or n
    if name then
      local have = ctx.rt[name]
      if have == nil then
        have = ctx.libs and require("lib.util").exists(ctx.libs .. "/" .. name) or false
        ctx.rt[name] = have
      end
      if not have then return true end
    end
  end
  return false
end

--- o port passa no filtro? skip = "cats" ignora as categorias (contagens)
function F.passes(p, f, ctx, skip)
  if p.builtin then return false end
  if f.origin == "pm" and p.source ~= "portmaster" then return false end
  if f.origin == "author" and p.source == "portmaster" then return false end
  if skip ~= "cats" and next(f.cats) and not f.cats[p.category_id] then return false end
  local hs = p.h700 and p.h700.status
  if f.h700 == "test" and hs ~= "testado" then return false end
  if f.h700 == "nobadge" and hs ~= nil then return false end
  if f.hide_heavy and (hs == "pesado" or hs == "nao_funciona") then return false end
  if f.size then
    local sz = tonumber(p.size)
    if not sz or sz > f.size * MB then return false end
  end
  if f.sit then
    if f.sit == "fav" then
      if not ctx.fav.is(p) then return false end
    else
      local st = ctx.status and ctx.status(p) or "none"
      if f.sit == "inst" and st == "none" then return false end
      if f.sit == "none" and st ~= "none" then return false end
      if f.sit == "upd" and st ~= "update" then return false end
    end
  end
  if f.nort and needs_download(p, ctx) then return false end
  return true
end

-- ---------------------------------------------------------------------------
-- ordenacao
local function day_num(s)
  local y, m, d = tostring(s or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then return nil end
  return tonumber(y) * 372 + tonumber(m) * 31 + tonumber(d)
end
F.day_num = day_num

--- dia da ultima atualizacao: "updated" do catalogo; PortMaster: a versao e a
--- data da atualizacao; sem nada, a data de entrada
function F.updated_day(p)
  return day_num(p.updated_at) or (p.source == "portmaster" and day_num(p.version)) or day_num(p.added)
end

local H_ORDER = { testado = 1, [""] = 2, pesado = 3, nao_funciona = 4 }

--- chave de ordenacao pelo nome (sem acento, minusculas; artigos "the" contam)
function F.name_key(p)
  local k = p._nk
  if k and p._nk_src == p.name then return k end
  k = Search.norm(p.name)
  p._nk, p._nk_src = k, p.name
  return k
end

--- letra inicial (A-Z; numero/simbolo = "#")
function F.letter(p)
  if p.builtin then return "*" end
  local c = F.name_key(p):sub(1, 1):upper()
  if c == "" then return "#" end
  if not c:match("%a") then return "#" end
  return c
end

function F.sort(list, mode)
  mode = mode or "az"
  local key = {}
  for i, p in ipairs(list) do
    local nk = F.name_key(p)
    local k
    if mode == "added" then k = -(day_num(p.added) or -1)
    elseif mode == "updated" then k = -(F.updated_day(p) or -1)
    elseif mode == "size_asc" then k = tonumber(p.size) or math.huge
    elseif mode == "size_desc" then k = -(tonumber(p.size) or -1)
    elseif mode == "tested" then k = H_ORDER[p.h700 and p.h700.status or ""] or 2
    else k = 0 end
    -- catalogo do autor sempre antes; PortMaster sempre no fim (em qualquer ordenacao)
    local grp = (p.source == "portmaster") and 1 or 0
    key[p] = { grp, k, nk, i }
  end
  table.sort(list, function(a, b)
    local ka, kb = key[a], key[b]
    if ka[1] ~= kb[1] then return ka[1] < kb[1] end
    if ka[2] ~= kb[2] then return ka[2] < kb[2] end
    if ka[3] ~= kb[3] then return ka[3] < kb[3] end
    return ka[4] < kb[4]
  end)
  return list
end

--- aplica filtro e ordenacao numa lista (nova)
function F.apply(list, f, ctx)
  ctx = ctx or F.ctx()
  local out = {}
  for _, p in ipairs(list) do if F.passes(p, f, ctx) then out[#out + 1] = p end end
  return F.sort(out, f.sort)
end

--- contagens para o painel: total que passa e por categoria (ignorando o
--- filtro de categoria, para mostrar quantos cada pilula traria)
function F.counts(list, f, ctx)
  ctx = ctx or F.ctx()
  local by_cat, total = {}, 0
  local any_cat = next(f.cats) ~= nil
  for _, p in ipairs(list) do
    if F.passes(p, f, ctx, "cats") then
      local c = p.category_id
      by_cat[c] = (by_cat[c] or 0) + 1
      if not any_cat or f.cats[c] then total = total + 1 end
    end
  end
  return { total = total, cats = by_cat }
end

-- ---------------------------------------------------------------------------
-- textos
F.SIT_LABEL = { inst = L("Instalado"), none = L("Não instalado"), upd = L("Com atualização"), fav = L("Favoritos") }
F.H7_LABEL = { test = L("Testado"), nobadge = L("Sem selo") }
F.ORI_LABEL = { all = L("Todos"), author = L("Catálogo do autor"), pm = "PortMaster" }

function F.size_label(z)
  if not z then return L("Qualquer") end
  if z >= 1024 then return string.format(require("lib.i18n").tr(L("até %d GB")), z / 1024) end
  return string.format(require("lib.i18n").tr(L("até %d MB")), z)
end

--- pilulas da faixa de filtros ativos: { {key=, label=}, ... }
--- cat_name(id) devolve o nome da categoria
function F.chips(f, cat_name)
  local out = {}
  if f.origin ~= "all" then out[#out + 1] = { key = "origin", label = F.ORI_LABEL[f.origin] } end
  local cs = {}
  for id in pairs(f.cats) do cs[#cs + 1] = cat_name and cat_name(id) or id end
  table.sort(cs)
  if #cs == 1 then out[#out + 1] = { key = "cats", label = cs[1] }
  elseif #cs > 1 then
    out[#out + 1] = { key = "cats", label = string.format(require("lib.i18n").tr(L("%d categorias")), #cs) }
  end
  if f.sit then out[#out + 1] = { key = "sit", label = F.SIT_LABEL[f.sit] } end
  if f.h700 then out[#out + 1] = { key = "h700", label = F.H7_LABEL[f.h700] } end
  if f.hide_heavy then out[#out + 1] = { key = "hide_heavy", label = L("Sem pesados") } end
  if f.size then out[#out + 1] = { key = "size", label = F.size_label(f.size) } end
  if f.nort then out[#out + 1] = { key = "nort", label = L("Sem download extra") } end
  if f.sort ~= "az" then out[#out + 1] = { key = "sort", label = F.SORT_BY_ID[f.sort].label } end
  return out
end

--- desliga um item da faixa (chave de F.chips)
function F.clear_key(f, key)
  if key == "origin" then f.origin = "all"
  elseif key == "cats" then f.cats = {}
  elseif key == "sit" then f.sit = nil
  elseif key == "h700" then f.h700 = nil
  elseif key == "hide_heavy" then f.hide_heavy = false
  elseif key == "size" then f.size = nil
  elseif key == "nort" then f.nort = false
  elseif key == "sort" then f.sort = "az"
  end
end

function F.clear(f, keep_sort)
  local s = f.sort
  f.origin, f.cats, f.sit, f.h700, f.hide_heavy, f.size, f.nort = "all", {}, nil, nil, false, nil, false
  f.sort = keep_sort and s or "az"
end

return F
