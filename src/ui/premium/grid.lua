-- =============================================================================
--  Tema Premium: grade de capas (6 colunas, 2:3, nome embaixo, selos)
--  Usada pela Central e pelas listas de ports (Meus Ports, favoritos, areas).
--  Rolagem suave: a posicao anima ate deixar a linha escolhida inteira.
--  So as linhas visiveis pedem capas ao cache (mais a linha seguinte).
-- =============================================================================
local PS = require("ui.premium.style")
local PM = require("ui.premium.model")

local PG = {}

PG.COLS = 6
PG.GAP = 10
PG.COVER_H = 132
PG.NAME_GAP = 5

--- medidas da grade numa area (x, y, w, bottom)
function PG.metrics(x, y, w, bottom)
  local cw = (w - PG.GAP * (PG.COLS - 1)) / PG.COLS
  local nf = PS.font("m", 11)
  local rh = PG.COVER_H + PG.NAME_GAP + nf:getHeight()
  return { x = x, y = y, w = w, bottom = bottom, cw = cw, rh = rh, view = bottom - y, nf = nf }
end

--- atualiza a rolagem (chamar no update da tela). st = tabela de estado da tela
function PG.update(st, n, sel, m, dt)
  local rows = math.ceil(n / PG.COLS)
  local row = math.floor((math.max(1, sel) - 1) / PG.COLS)
  st.pg_target = PM.scroll_for(row, st.pg_target or 0, m.view - 4, m.rh, PG.GAP, rows)
  st.pg_scroll = PS.approach(st.pg_scroll or st.pg_target, st.pg_target, dt, 14)
end

--- desenha a grade. o = { items, sel, focus (a grade tem o foco), key (prefixo
--- da animacao do foco), bg (cor atras das capas) }
function PG.draw(st, m, o)
  local c = PS.c()
  local items = o.items
  local n = #items
  local G = require("ui.gfx")
  local scroll = math.floor((st.pg_scroll or 0) + 0.5)
  G.clip(0, m.y - 4, 640, m.view + 4)
  local first = math.max(0, math.floor((scroll - 8) / (m.rh + PG.GAP)))
  local last = math.floor((scroll + m.view) / (m.rh + PG.GAP)) + 1
  for row = first, last do
    for col = 0, PG.COLS - 1 do
      local i = row * PG.COLS + col + 1
      if i > n then break end
      local p = items[i]
      local x = m.x + col * (m.cw + PG.GAP)
      local y = m.y + row * (m.rh + PG.GAP) - scroll
      local on = o.focus and i == o.sel
      local k = PS.fk((o.key or "pg") .. i, on)
      if y + m.rh >= m.y - 4 and y <= m.bottom then
        local bx, by, bw, bh = PS.grow(x, y, m.cw, PG.COVER_H, k)
        PS.cover(p, bx, by, bw, bh, 10, o.bg or c.bg)
        PS.cover_badges(p, bx, by, bw, bh)
        if k > 0 then PS.focus(bx, by, bw, bh, 10, k) end
        PS.fit(m.nf, p.name or "", x, y + PG.COVER_H + PG.NAME_GAP + (k > 0 and 1 or 0), m.cw, on and c.text or c.dim2)
      elseif row == last and p and not p.builtin then
        -- linha logo abaixo da area visivel: ja pede a capa ao cache
        require("core.covers").get(p)
      end
    end
  end
  G.unclip()
  -- barra de rolagem discreta
  local rows = math.ceil(n / PG.COLS)
  local total = rows * (m.rh + PG.GAP) - PG.GAP
  if total > m.view + 2 then
    local h = math.max(18, m.view * m.view / total)
    local y = m.y + (m.view - h) * (scroll / math.max(1, total - m.view))
    PS.rect(636, y, 2, h, c.line, 1)
  end
end

--- navegacao pelo direcional; devolve o novo sel e se saiu pelo topo ("up")
function PG.move(sel, n, act)
  local cols = PG.COLS
  if n == 0 then return sel, nil end
  if act == "left" then
    if (sel - 1) % cols == 0 then return sel, "left" end
    return sel - 1
  elseif act == "right" then
    if sel % cols == 0 or sel >= n then return sel, "right" end
    return sel + 1
  elseif act == "up" then
    if sel <= cols then return sel, "up" end
    return sel - cols
  elseif act == "down" then
    if sel + cols <= n then return sel + cols end
    -- ultima linha incompleta: vai para o ultimo item
    local last_row = math.floor((n - 1) / cols)
    if math.floor((sel - 1) / cols) < last_row then return n end
    return sel, "down"
  end
  return sel
end

return PG
