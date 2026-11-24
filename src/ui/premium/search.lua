-- =============================================================================
--  Tema Premium: busca instantanea (tela "search")
--  Campo + resultados (4 linhas com capa) + teclado virtual. A lista e refeita
--  a cada tecla (core/search.lua: indice pronto, pontuacao por campo, 1 erro
--  de digitacao). Busca vazia: ultimas buscas (Prefs) e sugestoes.
--    teclado: direcional | B (acao "a") digita | A (acao "b") apaga (vazio: volta)
--             X (acao "y") espaco | Y (acao "x") limpa | R1 ou cima: resultados
--    resultados: B detalhes | A ou L1 teclado | SELECT favorito
--    sugestoes: B busca o texto | SELECT apaga o historico
-- =============================================================================
local L = require("lib.i18n").L
local U = require("lib.util")
local PS = require("ui.premium.style")
local Search = require("core.search")
local Favorites = require("core.favorites")
local Catalog = require("core.catalog")

local PSr = {}

local KEYS = {
  { "A", "B", "C", "D", "E", "F", "G", "H", "I", "J" },
  { "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T" },
  { "U", "V", "W", "X", "Y", "Z", "1", "2", "3", "4" },
  { "5", "6", "7", "8", "9", "0", "ESPAÇO", "APAGAR", "LIMPAR", "VER" },
}
local KX, KW, KH, KG = 22, 56, 30, 4
local KY = PS.FOOT_Y - 6 - (#KEYS * (KH + KG) - KG)
local FIELD_Y, FIELD_H = 48, 38
local RES_Y = FIELD_Y + FIELD_H + 8
local ROW_H, VISIBLE = 50, 4
local MAXLEN = 32

function PSr.enter(self, params)
  self.query = ""
  self.kr, self.kc = 1, 1
  self.focus = "keys"
  self.sel, self.scroll = 1, 0
  self.chip = 1
  self.results = {}
  PSr.search(self)
end

function PSr.resume(self) PSr.search(self, true) end
function PSr.on_catalog(self) Search.invalidate(); PSr.search(self, true) end

--- refaz a lista (e as sugestoes, com a busca vazia)
function PSr.search(self, keep)
  local res, _, ms = Search.query(self.query)
  self.ms = ms
  self.results = res
  if self.query:match("^%s*$") then
    self.hist = Search.history()
    self.sugg = self.sugg or Search.suggestions(Catalog.ports, 5, 3)
    PSr.build_chips(self)
  end
  if not keep then self.sel, self.scroll = 1, 0 end
  PSr.clamp(self)
end

-- pilulas da busca vazia: linhas { label, items = { {text, x, w, hist} } }
function PSr.build_chips(self)
  local f = PS.font("m", 12, true)
  local lines = {}
  local function add(title, list, hist)
    if #list == 0 then return end
    local x, line = 20, nil
    local nlines = 0
    for _, t in ipairs(list) do
      local w = f:getWidth(t) + 24 + (hist and 18 or 0)
      if not line or x + w > 620 then
        if nlines >= 2 then break end
        line = { title = (nlines == 0) and title or nil, items = {} }
        lines[#lines + 1] = line
        nlines = nlines + 1
        x = 20
      end
      line.items[#line.items + 1] = { text = t, x = x, w = w, hist = hist }
      x = x + w + 8
    end
  end
  add(L("BUSCAS RECENTES"), self.hist or {}, true)
  add(L("SUGESTÕES"), self.sugg or {}, false)
  self.chips = lines
  self.cl = U.clamp(self.cl or 1, 1, math.max(1, #lines))
  self.cc = U.clamp(self.cc or 1, 1, math.max(1, lines[self.cl] and #lines[self.cl].items or 1))
end

local function empty_query(self) return self.query:match("^%s*$") ~= nil end

function PSr.clamp(self)
  local n = #self.results
  self.sel = U.clamp(self.sel, 1, math.max(1, n))
  if self.sel <= self.scroll then self.scroll = self.sel - 1 end
  if self.sel > self.scroll + VISIBLE then self.scroll = self.sel - VISIBLE end
  self.scroll = U.clamp(self.scroll, 0, math.max(0, n - VISIBLE))
  if self.focus == "list" then
    if empty_query(self) then
      if #(self.chips or {}) == 0 then self.focus = "keys" end
    elseif n == 0 then self.focus = "keys" end
  end
end

-- ---------------------------------------------------------------------------
-- desenho

local function meta_line(p)
  local parts = {}
  if p.category and p.category ~= "" then parts[#parts + 1] = PS.tr(p.category) end
  if p.author and p.author ~= "" then parts[#parts + 1] = string.format(PS.tr(L("por %s")), p.author) end
  if p.size then parts[#parts + 1] = U.format_bytes(p.size) end
  if p.section == "tools" then parts[#parts + 1] = PS.tr(L("Utilitário")) end
  return table.concat(parts, "  ·  ")
end

local function row_pill(p)
  local c = PS.c()
  local st = App.status(p)
  if st == "update" then return L("ATUALIZAR"), c.warn end
  if st ~= "none" then return L("INSTALADO"), c.accent end
  if p.h700 then
    local hs = p.h700.status
    if hs == "testado" then return L("TESTADO"), c.accent end
    if hs == "pesado" then return L("PESADO"), c.warn end
    return L("NÃO RODA"), c.red
  end
  return nil
end

local function draw_results(self)
  local c = PS.c()
  local nf, mf = PS.font("b", 13), PS.font("r", 11)
  local focus = self.focus == "list"
  local area_h = VISIBLE * ROW_H
  for i = self.scroll + 1, math.min(#self.results, self.scroll + VISIBLE) do
    local p = self.results[i]
    local y = RES_Y + (i - self.scroll - 1) * ROW_H
    local on = focus and i == self.sel
    local k = PS.fk("psr" .. i, on)
    if on or k > 0 then PS.rect(20, y, 600, ROW_H - 4, c.surf, 10, math.max(k, on and 1 or 0)) end
    PS.cover(p, 26, y + 3, 27, ROW_H - 10, 5, on and c.surf or c.bg)
    local pill, pc = row_pill(p)
    local pw = 0
    if pill then
      local pf = PS.font("x", 9, true)
      pw = pf:getWidth(PS.tr(pill)) + 12
      PS.pill(pill, 612 - pw, y + (ROW_H - 4) / 2 - 8, { font = pf, bg = pc, fg = c.bg, px = 6, h = 16 })
      pw = pw + 10
    end
    PS.fit(nf, p.name, 64, y + 6, 540 - pw, on and c.text or c.dim2)
    PS.fit(mf, meta_line(p), 64, y + 26, 540 - pw, c.dim)
    if k > 0 then PS.focus(20, y, 600, ROW_H - 4, 10, k) end
  end
  if #self.results > VISIBLE then
    local h = math.max(16, area_h * VISIBLE / #self.results)
    local yy = RES_Y + (area_h - 4 - h) * (self.scroll / (#self.results - VISIBLE))
    PS.rect(633, yy, 2, h, c.line, 1)
  end
end

local function draw_chips(self)
  local c = PS.c()
  local lf = PS.font("b", 10, true)
  local f = PS.font("m", 12, true)
  local y = RES_Y + 2
  if #(self.chips or {}) == 0 then
    local df = PS.font("r", 13)
    PS.fit(df, L("Digite o nome, a categoria ou o porter."), 20, RES_Y + 80, 600, c.dim, "center")
    return
  end
  for li, ln in ipairs(self.chips) do
    if ln.title then
      if li > 1 then y = y + 6 end
      PS.track(lf, ln.title, 20, y, c.dim, 0.08)
      y = y + lf:getHeight() + 6
    end
    for ci, it in ipairs(ln.items) do
      local on = self.focus == "list" and li == self.cl and ci == self.cc
      PS.rect(it.x, y, it.w, 28, c.surf, 14)
      local tx = it.x + 12
      if it.hist then
        PS.icon("clock", tx, y + 7, 14, c.dim)
        tx = tx + 18
      end
      PS.text(f, it.text, tx, y + 14 - f:getHeight() / 2, on and c.text or c.dim2)
      if on then PS.frame(it.x - 3, y - 3, it.w + 6, 34, c.accent, 17, 2) end
    end
    y = y + 28 + 8
  end
end

local function draw_keys(self)
  local c = PS.c()
  local lf, sf = PS.font("m", 14, true), PS.font("b", 10, true)
  for r, row in ipairs(KEYS) do
    for col, k in ipairs(row) do
      local x, y = KX + (col - 1) * (KW + KG), KY + (r - 1) * (KH + KG)
      local on = self.focus == "keys" and r == self.kr and col == self.kc
      local special = #k > 1
      PS.rect(x, y, KW, KH, on and c.accent or (special and c.surf2 or c.surf), 8)
      local f = special and sf or lf
      PS.fit(f, k, x + 2, y + KH / 2 - f:getHeight() / 2, KW - 4, on and c.bg or (special and c.dim2 or c.text), "center")
    end
  end
end

function PSr.draw(self)
  local c = PS.c()
  PS.rect(0, 0, 640, 480, c.bg)
  local right = nil
  if not empty_query(self) then
    local n = #self.results
    right = string.format(PS.tr(n == 1 and L("%d resultado") or L("%d resultados")), n)
  end
  PS.header(L("Buscar"), right)
  -- campo
  local kf = self.focus == "keys"
  PS.rect(20, FIELD_Y, 600, FIELD_H, c.surf, 10)
  if kf then PS.frame(20, FIELD_Y, 600, FIELD_H, c.accent, 10, 2) end
  PS.icon("search", 34, FIELD_Y + 11, 16, kf and c.accent or c.dim)
  local qf = PS.font("m", 15, true)
  local ty = FIELD_Y + FIELD_H / 2 - qf:getHeight() / 2
  if empty_query(self) then
    PS.fit(PS.font("r", 14, true), L("Nome, categoria ou porter"), 60, FIELD_Y + FIELD_H / 2 - PS.font("r", 14, true):getHeight() / 2, 540, c.dim)
    if kf and math.floor(App.t * 2) % 2 == 0 then PS.rect(59, FIELD_Y + 10, 2, FIELD_H - 20, c.accent) end
  else
    local q = self.query
    local w = qf:getWidth(q)
    local shown = q
    -- texto longo: mostra o fim
    while w > 530 and #shown > 1 do shown = shown:sub(2); w = qf:getWidth(shown) end
    PS.text(qf, shown, 60, ty, c.text)
    if kf and math.floor(App.t * 2) % 2 == 0 then PS.rect(61 + w, FIELD_Y + 10, 2, FIELD_H - 20, c.accent) end
  end
  -- resultados / sugestoes
  if empty_query(self) then
    draw_chips(self)
  elseif #self.results == 0 then
    local tf, df = PS.font("b", 15), PS.font("r", 12)
    PS.fit(tf, string.format(PS.tr(L("Nada encontrado para \"%s\"")), U.trim(self.query)), 20, RES_Y + 66, 600, c.text, "center")
    PS.fit(df, L("Confira a grafia ou use menos palavras."), 20, RES_Y + 92, 600, c.dim, "center")
  else
    draw_results(self)
  end
  draw_keys(self)
  if self.focus == "keys" then
    PS.footer({ { "a", L("Digitar") }, { "b", L("Apagar") }, { "y", L("Espaço") }, { "x", L("Limpar") }, { "r1", L("Resultados") } })
  elseif empty_query(self) then
    PS.footer({ { "a", L("Buscar") }, { "b", L("Teclado") }, { "select", L("Limpar histórico") } })
  else
    PS.footer({ { "a", L("Detalhes") }, { "b", L("Teclado") }, { "select", L("Favorito") } })
  end
end

-- ---------------------------------------------------------------------------
-- entrada

local function set_query(self, q)
  self.query = q:sub(1, MAXLEN)
  PSr.search(self)
end

local function to_list(self)
  if empty_query(self) then
    if #(self.chips or {}) > 0 then self.focus = "list" end
  elseif #self.results > 0 then
    self.focus = "list"
    Search.remember(self.query)
  end
end

local function press_key(self, k)
  if k == "ESPAÇO" then
    if self.query ~= "" and self.query:sub(-1) ~= " " then set_query(self, self.query .. " ") end
  elseif k == "APAGAR" then set_query(self, self.query:sub(1, -2))
  elseif k == "LIMPAR" then set_query(self, "")
  elseif k == "VER" then to_list(self)
  elseif #self.query < MAXLEN then set_query(self, self.query .. k)
  end
end

function PSr.action(self, act)
  if self.focus == "keys" then
    if act == "up" then
      if self.kr == 1 then to_list(self); if self.focus == "list" then return end end
      self.kr = (self.kr - 2) % #KEYS + 1
    elseif act == "down" then self.kr = self.kr % #KEYS + 1
    elseif act == "left" then self.kc = (self.kc - 2) % #KEYS[1] + 1
    elseif act == "right" then self.kc = self.kc % #KEYS[1] + 1
    elseif act == "a" then press_key(self, KEYS[self.kr][self.kc])
    elseif act == "b" then
      if self.query == "" then App.pop() else set_query(self, self.query:sub(1, -2)) end
    elseif act == "x" then set_query(self, "")
    elseif act == "y" then press_key(self, "ESPAÇO")
    elseif act == "r1" then to_list(self)
    end
    return
  end
  -- lista: sugestoes (busca vazia) ou resultados
  if empty_query(self) then
    local lines = self.chips or {}
    local ln = lines[self.cl]
    if act == "up" then
      if self.cl > 1 then
        local cx = ln.items[self.cc].x
        self.cl = self.cl - 1
        local best, bd = 1, math.huge
        for i, it in ipairs(lines[self.cl].items) do local d = math.abs(it.x - cx); if d < bd then best, bd = i, d end end
        self.cc = best
      end
    elseif act == "down" then
      if self.cl < #lines then
        local cx = ln.items[self.cc].x
        self.cl = self.cl + 1
        local best, bd = 1, math.huge
        for i, it in ipairs(lines[self.cl].items) do local d = math.abs(it.x - cx); if d < bd then best, bd = i, d end end
        self.cc = best
      else self.focus = "keys" end
    elseif act == "left" then self.cc = math.max(1, self.cc - 1)
    elseif act == "right" then self.cc = math.min(#ln.items, self.cc + 1)
    elseif act == "a" and ln then
      local it = ln.items[self.cc]
      set_query(self, U.upper(it.text))
      Search.remember(self.query)
      if #self.results > 0 then self.focus = "list" else self.focus = "keys" end
    elseif act == "select" then
      if #(self.hist or {}) > 0 then
        Search.clear_history()
        self.cl, self.cc = 1, 1
        PSr.search(self)
        App.toast(L("Histórico de buscas apagado."), "info")
      end
    elseif act == "b" or act == "l1" then self.focus = "keys"
    end
    PSr.clamp(self)
    return
  end
  local n = #self.results
  if act == "up" then
    if self.sel > 1 then self.sel = self.sel - 1 end
  elseif act == "down" then
    if self.sel < n then self.sel = self.sel + 1 else self.focus = "keys" end
  elseif act == "l2" then self.sel = math.max(1, self.sel - VISIBLE)
  elseif act == "r2" then self.sel = math.min(n, self.sel + VISIBLE)
  elseif act == "a" and n > 0 then
    Search.remember(self.query)
    App.push("details", { port = self.results[self.sel] })
  elseif act == "select" and n > 0 then
    local p = self.results[self.sel]
    local on = Favorites.toggle(p)
    App.toast(on and (p.name .. L(" adicionado aos favoritos")) or (p.name .. L(" removido dos favoritos")), "info")
  elseif act == "b" or act == "l1" then self.focus = "keys"
  end
  PSr.clamp(self)
end

return PSr
