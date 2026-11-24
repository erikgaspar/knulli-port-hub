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

--- medidas da grade numa area (x, y, w, bottom). cards = true: cartoes largos
--- de 2 colunas (icone/imagem, nome em 2 linhas, descricao e etiquetas), usados
--- onde os itens nao tem capa nem nome curto (aba Utilitarios)
function PG.metrics(x, y, w, bottom, cards)
  if cards then
    local cols = 2
    local cw = (w - PG.GAP * (cols - 1)) / cols
    return { x = x, y = y, w = w, bottom = bottom, cw = cw, rh = 96, view = bottom - y, cols = cols, cards = true,
      nf = PS.font("b", 14), df = PS.font("r", 11), tf = PS.font("b", 10, true) }
  end
  local cw = (w - PG.GAP * (PG.COLS - 1)) / PG.COLS
  local nf = PS.font("m", 11)
  local rh = PG.COVER_H + PG.NAME_GAP + nf:getHeight()
  return { x = x, y = y, w = w, bottom = bottom, cw = cw, rh = rh, view = bottom - y, nf = nf, cols = PG.COLS }
end

--- atualiza a rolagem (chamar no update da tela). st = tabela de estado da tela
function PG.update(st, n, sel, m, dt)
  local rows = math.ceil(n / (m.cols or PG.COLS))
  local row = math.floor((math.max(1, sel) - 1) / (m.cols or PG.COLS))
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
    for col = 0, (m.cols or PG.COLS) - 1 do
      local i = row * (m.cols or PG.COLS) + col + 1
      if i > n then break end
      local p = items[i]
      local x = m.x + col * (m.cw + PG.GAP)
      local y = m.y + row * (m.rh + PG.GAP) - scroll
      local on = o.focus and i == o.sel
      local k = PS.fk((o.key or "pg") .. i, on)
      if m.cards and y + m.rh >= m.y - 4 and y <= m.bottom then
        PG.draw_card(p, x, y, m, k, on, o)
      elseif y + m.rh >= m.y - 4 and y <= m.bottom then
        local bx, by, bw, bh = PS.grow(x, y, m.cw, PG.COVER_H, k)
        PS.cover(p, bx, by, bw, bh, 10, o.bg or c.bg)
        PS.cover_badges(p, bx, by, bw, bh)
        if k > 0 then PS.focus(bx, by, bw, bh, 10, k) end
        PS.fit(m.nf, p.name or "", x, y + PG.COVER_H + PG.NAME_GAP + (k > 0 and 1 or 0), m.cw, on and c.text or c.dim2)
      elseif row == last and p and not p.builtin and not p.card_tags then
        -- linha logo abaixo da area visivel: ja pede a capa ao cache
        require("core.covers").get(p)
      end
    end
  end
  G.unclip()
  -- barra de rolagem discreta
  local rows = math.ceil(n / (m.cols or PG.COLS))
  local total = rows * (m.rh + PG.GAP) - PG.GAP
  if total > m.view + 2 then
    local h = math.max(18, m.view * m.view / total)
    local y = m.y + (m.view - h) * (scroll / math.max(1, total - m.view))
    PS.rect(636, y, 2, h, c.line, 1)
  end
end

--- um cartao largo: imagem/icone a esquerda, nome (2 linhas), descricao curta
--- (2 linhas) e etiquetas (integrado ao hub / PortMaster / tamanho / instalado)
--- Campos opcionais do item (ex.: Apps do Knulli): card_img (imagem pronta),
--- card_icon (id de ui/icons no quadro) e card_tags ({ {texto, cor}, ... } no
--- lugar das etiquetas padrao)
function PG.draw_card(p, x, y, m, k, on, o)
  local c = PS.c()
  local L = require("lib.i18n").L
  local bx, by, bw, bh = PS.grow(x, y, m.cw, m.rh, k, 0.015)
  PS.rect(bx, by, bw, bh, on and c.surf2 or c.surf, 12)
  -- imagem: icone da ferramenta (integrada) ou capa recortada em quadrado
  local isz = bh - 20
  local bgc = on and c.surf2 or c.surf
  -- imagem do proprio app (card_image: caminho dentro do .love), lida uma vez
  if p.card_image and p.card_img == nil then
    local ok, img = pcall(love.graphics.newImage, p.card_image)
    p.card_img = ok and img or false
    if ok then img:setFilter("linear", "linear") end
  end
  if p.card_img then
    PS.rect(bx + 10, by + 10, isz, isz, c.bg, 10)
    PS.draw_cover_fit(p.card_img, bx + 10, by + 10, isz, isz)
    PS.fillet(bx + 10, by + 10, isz, isz, 10, bgc)
  elseif p.card_icon then
    PS.rect(bx + 10, by + 10, isz, isz, on and c.line or c.surf2, 10)
    local s = math.floor(isz * 0.46)
    require("ui.icons").draw(p.card_icon, bx + 10 + (isz - s) / 2, by + 10 + (isz - s) / 2, c.accent, s / 24)
  else
    PS.cover(p, bx + 10, by + 10, isz, isz, 10, bgc)
  end
  local tx = bx + 10 + isz + 12
  local tw = bx + bw - 12 - tx
  -- nome em ate 2 linhas
  local nl = PS.lines(m.nf, p.name or "", tw, 2)
  local ty = by + 9
  for _, l in ipairs(nl) do PS.text(m.nf, l, tx, ty, on and c.text or c.dim2); ty = ty + m.nf:getHeight() end
  -- descricao curta: o que a ferramenta/port faz
  local d = p.short or (p.description or ""):match("^[^\n]+") or ""
  if d ~= "" and #nl < 2 then
    for _, l in ipairs(PS.lines(m.df, d, tw, 2)) do PS.text(m.df, l, tx, ty + 1, c.dim); ty = ty + m.df:getHeight() end
  elseif d ~= "" then
    PS.fit(m.df, d, tx, ty + 1, tw, c.dim)
  end
  -- etiquetas no rodape do cartao
  local px, py = tx, by + bh - 9 - 15
  local tags = p.card_tags
  if not tags then
    tags = {}
    if p.builtin then tags[#tags + 1] = { L("NO HUB"), c.accent }
    elseif p.source == "portmaster" then tags[#tags + 1] = { "PORTMASTER", c.dim2 } end
    if not p.builtin and p.size_label and p.size_label ~= "?" then tags[#tags + 1] = { p.size_label, c.dim } end
    local st = (not p.builtin) and App and App.status and App.status(p) or "none"
    if st == "installed" then tags[#tags + 1] = { L("INSTALADO"), c.accent }
    elseif st == "update" then tags[#tags + 1] = { L("ATUALIZAR"), c.warn } end
  end
  for i, t in ipairs(tags) do
    -- etiquetas proprias: so desenha a que cabe inteira no cartao
    if p.card_tags and i > 1 and px + m.tf:getWidth(PS.tr(t[1])) + 12 > bx + bw - 10 then break end
    local w = PS.pill(t[1], px, py, { font = m.tf, bg = c.bg, fg = t[2], px = 6, h = 15 })
    px = px + w + 5
    if px > bx + bw - 30 then break end
  end
  if k > 0 then PS.focus(bx, by, bw, bh, 12, k) end
end

--- navegacao pelo direcional; devolve o novo sel e se saiu pelo topo ("up")
function PG.move(sel, n, act, cols)
  cols = cols or PG.COLS
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
