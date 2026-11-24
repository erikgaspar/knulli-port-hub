-- =============================================================================
--  Busca de ports (tema Premium): indice pre-calculado + pontuacao
--
--  Normalizacao: minusculas, sem acentos, so letras/numeros (o resto separa
--  palavras; apostrofo some: "Shredder's" -> "shredders").
--  Campos (peso): nome 10, porter 6, categoria/generos 4, descricao curta 1.5.
--  Cada palavra da busca precisa casar em algum campo:
--    palavra inteira 1.0 | inicio de palavra 0.75 | trecho (>= 3 letras) 0.35
--    (descricao: so inteira/inicio)
--  Palavra com >= 5 letras sem nenhum inicio/inteira no nome, porter ou
--  categoria: tolera 1 erro (troca, falta, sobra ou duas letras trocadas)
--  contra o vocabulario do catalogo (0.5).
--  Bonus: nome comecando pela busca (+6), nome igual (+10). Busca colada
--  ("hollowknight", >= 4 letras) tambem acha o nome sem espacos (8).
--
--  Desempenho: cada campo do catalogo inteiro vira UMA string (" tok tok \n ...")
--  e cada palavra e procurada com string.find (codigo C), mapeando a posicao
--  para o port por busca binaria. O indice so e refeito quando o catalogo
--  (ou o idioma) muda.
-- =============================================================================
local I18N = require("lib.i18n")

local Search = {}

-- ---------------------------------------------------------------------------
-- normalizacao
local FOLD = {}
do
  -- U+00C0..U+00FF (Latin-1) -> ASCII
  local map = "AAAAAAACEEEEIIIIDNOOOOO OUUUUY  aaaaaaaceeeeiiiidnooooo ouuuuy y"
  for i = 0, 63 do
    local ch = map:sub(i + 1, i + 1)
    local cp = 0xC0 + i
    local b1, b2 = 0xC0 + math.floor(cp / 64), 0x80 + (cp % 64)
    FOLD[string.char(b1, b2)] = ch == " " and " " or ch:lower()
  end
  FOLD["\195\159"] = "ss"   -- sharp s
end

--- texto normalizado: "Zelda: The Wind Waker" -> "zelda the wind waker"
function Search.norm(s)
  s = tostring(s or "")
  if s == "" then return "" end
  s = s:gsub("['`]", ""):gsub("\226\128[\152\153]", "")
  s = s:gsub("[\195][\128-\191]", FOLD)
  s = s:lower():gsub("[^%w\128-\255]+", " ")
  return (s:gsub("^ +", ""):gsub(" +$", ""))
end
local norm = Search.norm

local function words(s)
  local t = {}
  for w in s:gmatch("%S+") do t[#t + 1] = w end
  return t
end

-- ---------------------------------------------------------------------------
-- indice
Search.W = { name = 10, por = 6, cat = 4, desc = 1.5 }
local FIELDS = { "name", "por", "cat", "desc" }
local FIELDS2 = { "name", "por", "cat" }
local FIELDS1 = { "name", "por" }
local STRONG = { name = true, por = true, cat = true }

local IDX = nil

-- palavras comuns que nao ajudam na descricao (o texto fica menor e mais rapido)
local STOP = {}
for w in ("the and for with from into your you are this that its was has have his her our their "
  .. "uma para com por que dos das nos nas sem mais seu sua"):gmatch("%S+") do STOP[w] = true end

--- palavras sem repeticao (e sem as curtas/comuns quando minlen > 1)
local function uniq(s, minlen)
  local seen, out = {}, {}
  for w in s:gmatch("%S+") do
    if not seen[w] and #w >= minlen and not (minlen > 1 and STOP[w]) then seen[w] = true; out[#out + 1] = w end
  end
  return table.concat(out, " ")
end

local function field_texts(p)
  local cat = { I18N.tr(p.category or "") }
  local Cats = require("core.categories")
  local off = Cats.BY_ID[p.category_id]
  if off then cat[#cat + 1] = off.name; cat[#cat + 1] = I18N.tr(off.name) end
  local g = p.attr and p.attr.genres
  if type(g) == "table" then for _, v in ipairs(g) do cat[#cat + 1] = tostring(v) end end
  if p.source == "portmaster" then cat[#cat + 1] = "portmaster" end
  local short = p.short or ""
  if p.i18n and p.i18n[I18N.lang] and p.i18n[I18N.lang].short ~= "" then short = short .. " " .. p.i18n[I18N.lang].short end
  return {
    name = norm(p.name),
    por = norm(p.author),
    cat = uniq(norm(table.concat(cat, " ")), 1),
    desc = uniq(norm(short), 3),
  }
end

--- monta (ou reaproveita) o indice de uma lista de ports
function Search.index(ports)
  ports = ports or require("core.catalog").ports
  if IDX and IDX.ports == ports and IDX.n == #ports and IDX.lang == I18N.lang then return IDX end
  local t0 = love and love.timer and love.timer.getTime()
  local ix = { ports = ports, n = #ports, lang = I18N.lang, names = {}, compact = {}, vocab = {}, starts = {} }
  local parts = { name = {}, por = {}, cat = {}, desc = {} }
  local cparts = {}
  local pos = { name = 1, por = 1, cat = 1, desc = 1 }
  local cpos = 1
  for f in pairs(parts) do ix.starts[f] = {} end
  ix.cstarts = {}
  for i, p in ipairs(ports) do
    local ft = field_texts(p)
    ix.names[i] = ft.name
    for _, f in ipairs(FIELDS) do
      local s = " " .. ft[f] .. " \n"
      ix.starts[f][i] = pos[f]
      parts[f][i] = s
      pos[f] = pos[f] + #s
      if STRONG[f] then
        for w in ft[f]:gmatch("%S+") do
          local v = ix.vocab[w]
          if not v then v = {}; ix.vocab[w] = v end
          if v[#v] ~= i then v[#v + 1] = i end
        end
      end
    end
    local c = ft.name:gsub(" ", "") .. "\n"
    ix.compact[i] = c
    ix.cstarts[i] = cpos
    cparts[i] = c
    cpos = cpos + #c
  end
  ix.text = {}
  for f, list in pairs(parts) do ix.text[f] = table.concat(list) end
  ix.ctext = table.concat(cparts)
  -- vocabulario agrupado por tamanho (tolerancia a erro so olha +-1 letra)
  ix.by_len = {}
  for w in pairs(ix.vocab) do
    local n = #w
    local b = ix.by_len[n]
    if not b then b = {}; ix.by_len[n] = b end
    b[#b + 1] = w
  end
  -- indices dos ports em ordem alfabetica (desempate na ordenacao)
  local ord = {}
  for i = 1, ix.n do ord[i] = i end
  local names = ix.names
  table.sort(ord, function(a, b) if names[a] ~= names[b] then return names[a] < names[b] end return a < b end)
  ix.order = ord
  if t0 then ix.build_ms = (love.timer.getTime() - t0) * 1000 end
  IDX = ix
  return ix
end

function Search.invalidate() IDX = nil end

-- posicao na string do campo -> indice do port (busca binaria)
local function owner(starts, n, pos)
  local lo, hi = 1, n
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if starts[mid] <= pos then lo = mid else hi = mid - 1 end
  end
  return lo
end

local byte = string.byte
--- a e b diferem em no maximo 1 edicao (troca, insercao, remocao, transposicao)
function Search.within1(a, b)
  local la, lb = #a, #b
  if la > lb then a, b, la, lb = b, a, lb, la end
  if lb - la > 1 then return false end
  local i = 1
  while i <= la and byte(a, i) == byte(b, i) do i = i + 1 end
  if i > la then return true end          -- igual ou uma letra a mais no fim
  if la == lb then
    -- troca de uma letra ou duas vizinhas trocadas
    if a:sub(i + 1) == b:sub(i + 1) then return true end
    return byte(a, i) == byte(b, i + 1) and byte(a, i + 1) == byte(b, i) and a:sub(i + 2) == b:sub(i + 2)
  end
  return a:sub(i) == b:sub(i + 1)          -- uma letra a mais no meio
end
local within1 = Search.within1

local FUZZY = 0.5

--- pontuacao de uma palavra em todos os ports: { [i] = pontos }
local function score_word(ix, w)
  local W = Search.W
  local out = {}
  local strong_hit = false
  local wl = #w
  local find = string.find
  -- palavras curtas: so os campos fortes (1 letra: nome e porter; descricao so com 3+)
  local fields = wl >= 3 and FIELDS or (wl == 2 and FIELDS2 or FIELDS1)
  for _, f in ipairs(fields) do
    local text, starts, weight = ix.text[f], ix.starts[f], W[f]
    local allow_sub = wl >= 3 and f ~= "desc"
    local pat = allow_sub and w or (" " .. w)
    local off = allow_sub and 0 or 1
    local init = 1
    while true do
      local a, b = find(text, pat, init, true)
      if not a then break end
      local s0 = a + off                    -- inicio da palavra encontrada
      local pre = byte(text, s0 - 1) == 32
      local lvl
      if pre then lvl = byte(text, b + 1) == 32 and 1 or 0.75 else lvl = 0.35 end
      if pre and STRONG[f] then strong_hit = true end
      local i = owner(starts, ix.n, s0)
      local sc = weight * lvl
      if (out[i] or 0) < sc then out[i] = sc end
      init = b + 1
    end
  end
  -- 1 erro de digitacao: so quando a palavra nao aparece como palavra/inicio
  if not strong_hit and wl >= 5 then
    for len = wl - 1, wl + 1 do
      for _, v in ipairs(ix.by_len[len] or {}) do
        if within1(w, v) then
          for _, i in ipairs(ix.vocab[v]) do
            -- campo da palavra parecida (o mais forte em que ela aparece)
            local best = 0
            for _, f in ipairs({ "name", "por", "cat" }) do
              local s = ix.text[f]
              local st = ix.starts[f][i]
              local e = (ix.starts[f][i + 1] or (#s + 1)) - 1
              local a = find(s, " " .. v .. " ", st, true)
              if a and a <= e then best = Search.W[f]; break end
            end
            local sc = best * FUZZY
            if (out[i] or 0) < sc then out[i] = sc end
          end
        end
      end
    end
  end
  return out
end

--- Busca. Devolve a lista de ports (maior pontuacao primeiro), as pontuacoes e o tempo (ms)
function Search.query(q, ports)
  local t0 = love and love.timer and love.timer.getTime()
  local ix = Search.index(ports)
  local nq = norm(q)
  local res = {}
  if nq == "" then return res, {}, 0 end
  local ws = words(nq)
  local acc, cnt = {}, {}
  for k, w in ipairs(ws) do
    local sw = score_word(ix, w)
    if k == 1 then
      for i, sc in pairs(sw) do acc[i] = sc; cnt[i] = 1 end
    else
      for i, sc in pairs(sw) do
        if cnt[i] == k - 1 then acc[i] = acc[i] + sc; cnt[i] = k end
      end
    end
  end
  local total = #ws
  local cand = {}
  for i, c in pairs(cnt) do if c == total then cand[i] = acc[i] end end
  -- busca colada no nome ("hollowknight", "zeldawind")
  local cq = nq:gsub(" ", "")
  if #cq >= 4 then
    local init = 1
    while true do
      local a, b = string.find(ix.ctext, cq, init, true)
      if not a then break end
      local i = owner(ix.cstarts, ix.n, a)
      local sc = (a == ix.cstarts[i]) and 12 or 8
      if (cand[i] or 0) < sc then cand[i] = sc end
      init = b + 1
    end
  end
  local names = ix.names
  for i, sc in pairs(cand) do
    local nm = names[i]
    if nm == nq then cand[i] = sc + 10
    elseif string.find(nm, nq, 1, true) == 1 then cand[i] = sc + 6 end
  end
  -- ordem: pontuacao (poucos valores diferentes) e, dentro dela, alfabetica.
  -- Percorre o catalogo ja em ordem alfabetica e separa em baldes por
  -- pontuacao: nada de comparar centenas de resultados um a um
  local buckets, keys = {}, {}
  for _, i in ipairs(ix.order) do
    local sc = cand[i]
    if sc then
      local b = buckets[sc]
      if not b then b = {}; buckets[sc] = b; keys[#keys + 1] = sc end
      b[#b + 1] = i
    end
  end
  table.sort(keys, function(a, b) return a > b end)
  local scores = {}
  for _, sc in ipairs(keys) do
    for _, i in ipairs(buckets[sc]) do
      local k = #res + 1
      res[k] = ix.ports[i]; scores[k] = sc
    end
  end
  local ms = t0 and (love.timer.getTime() - t0) * 1000 or 0
  Search.last_ms = ms
  return res, scores, ms
end

-- ---------------------------------------------------------------------------
-- historico (Prefs "search_hist": ultimas 8, mais recente primeiro, separadas por |)
Search.HIST_MAX = 8

function Search.history()
  local raw = require("core.prefs").get("search_hist") or ""
  local out = {}
  for s in raw:gmatch("[^|]+") do out[#out + 1] = s end
  return out
end

function Search.remember(q)
  q = tostring(q or ""):gsub("[|\r\n]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if q == "" then return end
  local key = norm(q)
  local out = { q }
  for _, h in ipairs(Search.history()) do
    if norm(h) ~= key and #out < Search.HIST_MAX then out[#out + 1] = h end
  end
  require("core.prefs").set("search_hist", table.concat(out, "|"))
end

function Search.clear_history() require("core.prefs").set("search_hist", nil) end

--- sugestoes para a busca vazia: categorias com mais ports e porters mais ativos
function Search.suggestions(ports, max_cats, max_porters)
  ports = ports or require("core.catalog").ports
  local cats, pors = {}, {}
  for _, p in ipairs(ports) do
    if p.section == "games" and p.category_id ~= "outros" then
      cats[p.category] = (cats[p.category] or 0) + 1
    end
    for a in tostring(p.author or ""):gmatch("[^,]+") do
      a = a:gsub("^%s+", ""):gsub("%s+$", "")
      if a ~= "" and #a <= 18 then pors[a] = (pors[a] or 0) + 1 end
    end
  end
  local function top(t, n)
    local l = {}
    for k, v in pairs(t) do l[#l + 1] = { k, v } end
    table.sort(l, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    local out = {}
    for i = 1, math.min(n, #l) do out[i] = l[i][1] end
    return out
  end
  local out = {}
  for _, c in ipairs(top(cats, max_cats or 5)) do out[#out + 1] = I18N.tr(c) end
  for _, c in ipairs(top(pors, max_porters or 3)) do out[#out + 1] = c end
  return out
end

return Search
