-- =============================================================================
--  Tema Premium: painel de filtros da Central (folha sobre a grade)
--  Secoes com pilulas; o resultado e contado ao vivo (core/portfilter.lua).
--    direcional: pilulas (cima/baixo trocam de linha, mantendo a coluna)
--    B (acao "a"): marcar | A (acao "b"): fechar | Y (acao "x"): limpar tudo
--    L1/R1: secao anterior/seguinte
--  Estado em s.sheet (central.lua): { tab, f, base, counts, line, col, scroll }
-- =============================================================================
local L = require("lib.i18n").L
local PS = require("ui.premium.style")
local F = require("core.portfilter")
local Catalog = require("core.catalog")

local FS = {}

local TOP = 26                    -- topo da folha
local HEAD_H = 50                 -- titulo + contagem
local LBL_X, PILL_X, PILL_R = 20, 118, 620
local PH, PGAP, LGAP, SGAP = 28, 8, 8, 14

-- ---------------------------------------------------------------------------
-- modelo: secoes e pilulas

local function radio(f, key, val, label, count)
  return { label = label, on = f[key] == val, count = count, fn = function(ff) ff[key] = val end }
end

local function build(sh)
  local f, cnt = sh.f, sh.counts
  local secs = {}
  -- origem
  secs[#secs + 1] = { id = "origin", label = L("ORIGEM"), items = {
    radio(f, "origin", "all", F.ORI_LABEL.all), radio(f, "origin", "author", F.ORI_LABEL.author),
    radio(f, "origin", "pm", F.ORI_LABEL.pm) } }
  -- categorias (da aba; so as que tem ports nesta aba ou estao marcadas)
  local present = {}
  for _, p in ipairs(sh.base) do present[p.category_id] = true end
  local cats = { { label = L("Todas"), on = next(f.cats) == nil, fn = function(ff) ff.cats = {} end } }
  local seen = {}
  for _, c in ipairs(Catalog.categories) do
    if c.section == sh.tab and not seen[c.id] and (present[c.id] or f.cats[c.id]) then
      seen[c.id] = true
      local id = c.id
      cats[#cats + 1] = { label = c.name, count = cnt.cats[id] or 0, on = f.cats[id] == true, multi = true,
        fn = function(ff) if ff.cats[id] then ff.cats[id] = nil else ff.cats[id] = true end end }
    end
  end
  secs[#secs + 1] = { id = "cats", label = L("CATEGORIA"), items = cats }
  -- situacao
  local function toggle(key, val, label)
    return { label = label, on = f[key] == val, fn = function(ff) if ff[key] == val then ff[key] = nil else ff[key] = val end end }
  end
  secs[#secs + 1] = { id = "sit", label = L("SITUAÇÃO"), items = {
    { label = L("Qualquer"), on = f.sit == nil, fn = function(ff) ff.sit = nil end },
    toggle("sit", "inst", F.SIT_LABEL.inst), toggle("sit", "none", F.SIT_LABEL.none),
    toggle("sit", "upd", F.SIT_LABEL.upd), toggle("sit", "fav", F.SIT_LABEL.fav) } }
  -- RG35XXH
  secs[#secs + 1] = { id = "h700", label = "RG35XXH", items = {
    { label = L("Qualquer"), on = f.h700 == nil, fn = function(ff) ff.h700 = nil end },
    toggle("h700", "test", F.H7_LABEL.test), toggle("h700", "nobadge", F.H7_LABEL.nobadge),
    { label = L("Esconder pesados e que não rodam"), on = f.hide_heavy, multi = true,
      fn = function(ff) ff.hide_heavy = not ff.hide_heavy end } } }
  -- tamanho
  local sz = { { label = F.size_label(nil), on = f.size == nil, fn = function(ff) ff.size = nil end } }
  for _, z in ipairs(F.SIZES) do
    sz[#sz + 1] = { label = F.size_label(z), on = f.size == z, fn = function(ff) ff.size = (ff.size == z) and nil or z end }
  end
  secs[#secs + 1] = { id = "size", label = L("TAMANHO"), items = sz }
  -- runtime
  secs[#secs + 1] = { id = "nort", label = L("RUNTIME"), items = {
    { label = L("Qualquer"), on = not f.nort, fn = function(ff) ff.nort = false end },
    { label = L("Sem download extra"), on = f.nort, fn = function(ff) ff.nort = not ff.nort end } } }
  -- ordenar
  local so = {}
  for _, s in ipairs(F.SORTS) do so[#so + 1] = radio(f, "sort", s.id, s.label) end
  secs[#secs + 1] = { id = "sort", label = L("ORDENAR"), items = so }
  -- acoes
  secs[#secs + 1] = { id = "act", label = "", items = {
    { label = L("Limpar filtros"), action = "clear", fn = function(ff) F.clear(ff, true) end },
    { label = string.format(PS.tr(cnt.total == 1 and L("Ver %d port") or L("Ver %d ports")), cnt.total), action = "close", primary = true } } }
  return secs
end

-- layout: quebra as pilulas em linhas; devolve linhas { sec, y, items = { {it, x, w} } } e a altura
local function layout(secs)
  local f = PS.font("m", 12, true)
  local cf = PS.font("r", 11, true)
  local lines, y = {}, 0
  for si, sec in ipairs(secs) do
    local x = PILL_X
    local line = { sec = si, y = y, items = {}, first = true }
    lines[#lines + 1] = line
    for _, it in ipairs(sec.items) do
      local w = f:getWidth(PS.tr(it.label)) + 24
      if it.count then w = w + 6 + cf:getWidth(tostring(it.count)) end
      if it.multi then w = w + 14 end
      if x + w > PILL_R and #line.items > 0 then
        y = y + PH + LGAP
        x = PILL_X
        line = { sec = si, y = y, items = {} }
        lines[#lines + 1] = line
      end
      line.items[#line.items + 1] = { it = it, x = x, w = math.min(w, PILL_R - PILL_X) }
      x = x + w + PGAP
    end
    y = y + PH + SGAP + (si < #secs and 1 or 0)
  end
  return lines, y - SGAP
end

local function refresh(sh)
  sh.counts = F.counts(sh.base, sh.f, sh.ctx)
  sh.secs = build(sh)
  sh.lines, sh.content_h = layout(sh.secs)
  sh.line = math.max(1, math.min(sh.line or 1, #sh.lines))
  local ln = sh.lines[sh.line]
  sh.col = math.max(1, math.min(sh.col or 1, #ln.items))
end

--- abre o painel. base = ports da aba (sem filtro); f = filtro (editado ao vivo)
function FS.open(tab, base, f)
  local sh = { tab = tab, base = base, f = f, line = 1, col = 1, scroll = 0, target = 0, ctx = F.ctx() }
  refresh(sh)
  return sh
end

-- ---------------------------------------------------------------------------
-- desenho

local VIEW_Y = TOP + HEAD_H + 6
local function view_h() return PS.FOOT_Y - 8 - VIEW_Y end

function FS.update(sh, dt)
  local ln = sh.lines[sh.line]
  if ln then
    local vh = view_h()
    local top = ln.y - (ln.first and 0 or 6)
    local bottom = ln.y + PH + 6
    local t = sh.target or 0
    if top < t then t = top end
    if bottom > t + vh then t = bottom - vh end
    t = math.max(0, math.min(t, math.max(0, sh.content_h - vh + 4)))
    sh.target = t
  end
  sh.scroll = PS.approach(sh.scroll, sh.target, dt, 16)
end

local function draw_pill(e, y, focused)
  local c = PS.c()
  local it = e.it
  local f = PS.font("m", 12, true)
  local cf = PS.font("r", 11, true)
  local x, w = e.x, e.w
  local on = it.on
  local bg, fg = c.surf2, c.dim2
  if it.primary then bg, fg = c.accent, c.bg
  elseif on then bg, fg = c.accent, c.bg end
  if it.action == "clear" then
    PS.frame(x, y, w, PH, c.line, PH / 2, 1)
  else
    PS.rect(x, y, w, PH, bg, PH / 2)
  end
  local tx = x + 12
  if it.multi then
    -- caixinha de marcar (multipla escolha)
    local bx, by = tx, y + PH / 2 - 5
    if on then
      PS.rect(bx, by, 10, 10, c.bg, 3)
      PS.icon("check", bx + 1, by + 1, 8, c.accent)
    else
      PS.frame(bx, by, 10, 10, c.dim, 3, 1)
    end
    tx = tx + 14
  end
  local lw = PS.fit(f, it.label, tx, y + PH / 2 - f:getHeight() / 2, w - (tx - x) - 12 - (it.count and (6 + cf:getWidth(tostring(it.count))) or 0), fg)
  if it.count then
    local dim = (on or it.primary) and c.bg or (it.count == 0 and c.faint or c.dim)
    PS.text(cf, tostring(it.count), tx + lw + 6, y + PH / 2 - cf:getHeight() / 2, dim, on and 0.7 or 1)
  end
  if focused then PS.frame(x - 4, y - 4, w + 8, PH + 8, PS.c().accent, PH / 2 + 4, 2) end
end

function FS.draw(sh)
  local c = PS.c()
  local G = require("ui.gfx")
  PS.veil(0, 0, 640, 480, 0.62)
  -- folha (cantos de cima arredondados)
  PS.shadow(0, TOP, 640, PS.FOOT_Y - TOP, 16, -4, 0.6)
  PS.rect(0, TOP, 640, PS.FOOT_Y - TOP, c.surf, 16)
  PS.rect(0, TOP + 20, 640, PS.FOOT_Y - TOP - 20, c.surf)
  PS.rect(302, TOP + 7, 36, 4, c.line, 2)
  -- titulo e contagem ao vivo
  local tf = PS.font("b", 16, true)
  PS.text(tf, L("Filtros"), 20, TOP + 26 - tf:getHeight() / 2, c.text)
  local n = F.active_count(sh.f)
  if n > 0 then
    local nf = PS.font("b", 11, true)
    local tw = tf:getWidth(PS.tr(L("Filtros")))
    PS.pill(tostring(n), 20 + tw + 8, TOP + 26 - 9, { font = nf, bg = c.accent, fg = c.bg, h = 18, px = 6 })
  end
  local cf = PS.font("b", 13, true)
  local total = sh.counts.total
  local txt = string.format(PS.tr(total == 1 and L("%d port") or L("%d ports")), total)
  local tw = cf:getWidth(txt)
  PS.text(cf, txt, 620 - tw, TOP + 26 - cf:getHeight() / 2, total > 0 and c.accent or c.warn)
  local sf = PS.font("r", 12, true)
  local of = string.format(PS.tr(L("de %d")), #sh.base)
  PS.text(sf, of, 620 - tw - 6 - sf:getWidth(of), TOP + 26 - sf:getHeight() / 2, c.dim)
  PS.rect(20, TOP + HEAD_H, 600, 1, c.surf2)
  -- conteudo rolavel
  local vy, vh = VIEW_Y, view_h()
  local scroll = math.floor((sh.scroll or 0) + 0.5)
  G.clip(0, vy - 4, 640, vh + 8)
  local lf = PS.font("b", 10, true)
  local prev_sec
  for li, ln in ipairs(sh.lines) do
    local y = vy + ln.y - scroll
    if y + PH >= vy - 6 and y <= vy + vh + 4 then
      local sec = sh.secs[ln.sec]
      if ln.first and sec.label ~= "" then
        local on = sh.lines[sh.line].sec == ln.sec
        PS.track(lf, sec.label, LBL_X, y + PH / 2 - lf:getHeight() / 2, on and c.accent or c.dim, 0.08, PILL_X - LBL_X - 8)
      end
      for ci, e in ipairs(ln.items) do draw_pill(e, y, li == sh.line and ci == sh.col) end
    end
    if ln.first and prev_sec and y - SGAP / 2 - 1 >= vy - 4 and y - SGAP / 2 <= vy + vh then
      PS.rect(LBL_X, y - math.floor(SGAP / 2) - 1, 600, 1, c.surf2)
    end
    prev_sec = ln.sec
  end
  G.unclip()
  -- indicador de rolagem
  if sh.content_h > vh + 2 then
    local h = math.max(16, vh * vh / sh.content_h)
    local yy = vy + (vh - h) * (scroll / math.max(1, sh.content_h - vh))
    PS.rect(634, yy, 2, h, c.line, 1)
  end
  PS.footer({ { "a", L("Marcar") }, { "b", L("Fechar") }, { "x", L("Limpar") }, { { "l1", "r1" }, L("Seções") } })
end

-- ---------------------------------------------------------------------------
-- entrada. Devolve "close" quando o painel deve fechar, "changed" quando o
-- filtro mudou (a contagem ja foi refeita)

local function center(e) return e.x + e.w / 2 end

local function go_line(sh, li)
  local cur = sh.lines[sh.line].items[sh.col]
  local cx = cur and center(cur) or PILL_X
  sh.line = li
  local best, bd = 1, math.huge
  for i, e in ipairs(sh.lines[li].items) do
    local d = math.abs(center(e) - cx)
    if d < bd then best, bd = i, d end
  end
  sh.col = best
end

function FS.action(sh, act)
  local nl = #sh.lines
  if act == "b" then return "close" end
  if act == "up" then
    if sh.line > 1 then go_line(sh, sh.line - 1) end
    return
  elseif act == "down" then
    if sh.line < nl then go_line(sh, sh.line + 1) end
    return
  elseif act == "left" then
    if sh.col > 1 then sh.col = sh.col - 1
    elseif sh.line > 1 and sh.lines[sh.line - 1].sec == sh.lines[sh.line].sec then
      sh.line = sh.line - 1; sh.col = #sh.lines[sh.line].items
    end
    return
  elseif act == "right" then
    local ln = sh.lines[sh.line]
    if sh.col < #ln.items then sh.col = sh.col + 1
    elseif sh.line < nl and sh.lines[sh.line + 1].sec == ln.sec then sh.line = sh.line + 1; sh.col = 1 end
    return
  elseif act == "l1" or act == "r1" then
    local cs = sh.lines[sh.line].sec
    local target = act == "r1" and math.min(#sh.secs, cs + 1) or math.max(1, cs - 1)
    if act == "l1" and not sh.lines[sh.line].first then target = cs end
    for i, ln in ipairs(sh.lines) do if ln.sec == target and ln.first then sh.line = i; sh.col = 1; break end end
    return
  elseif act == "x" then
    F.clear(sh.f, true)
    refresh(sh)
    return "changed"
  elseif act == "a" then
    local e = sh.lines[sh.line].items[sh.col]
    if not e then return end
    local it = e.it
    if it.action == "close" then return "close" end
    if it.fn then it.fn(sh.f) end
    -- guarda a posicao (as linhas podem mudar com as contagens)
    local sec, label = sh.lines[sh.line].sec, it.label
    refresh(sh)
    for i, ln in ipairs(sh.lines) do
      if ln.sec == sec then
        for j, e2 in ipairs(ln.items) do
          if e2.it.label == label or (it.action and e2.it.action == it.action) then sh.line, sh.col = i, j end
        end
      end
    end
    return "changed"
  end
end

return FS
