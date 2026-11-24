-- =============================================================================
--  Tema Premium: dados das telas (sem desenho; testavel no console)
--    pick_continue  qual port o cartao CONTINUAR mostra
--    play_meta      "Ontem • 1h 12min • máx. 54 °C"
--    news           novidades do catalogo (campo "added" mais novo primeiro)
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")

local M = {}

--- ids dos ultimos ports abertos pelo hub (mais recente primeiro)
function M.recent_ids(raw)
  local out = {}
  for id in tostring(raw or ""):gmatch("[^,]+") do out[#out + 1] = id end
  return out
end

--- Cartao CONTINUAR: o ultimo port aberto pelo hub que ainda esta instalado.
--- Sem nenhum, um destaque do catalogo (o atual da vitrine) e, sem destaques,
--- o port mais novo do catalogo. Devolve p, "continue" | "featured" (ou nil).
---   ids: recent_ids; by_id: Catalog.by_id; status: App.status;
---   featured: lista de destaques; ports: Catalog.ports; feat_i: destaque atual
function M.pick_continue(ids, by_id, status, featured, ports, feat_i)
  for _, id in ipairs(ids or {}) do
    local p = by_id and by_id[id]
    if p and not p.builtin and status(p) ~= "none" then return p, "continue" end
  end
  if featured and #featured > 0 then
    local i = feat_i or 1
    if i < 1 or i > #featured then i = 1 end
    return featured[i], "featured"
  end
  local news = M.news(ports, 1)
  if news[1] then return news[1], "featured" end
  return nil
end

--- novidades: ports com "added" (AAAA-MM-DD), mais novos primeiro; completa
--- com os ultimos do catalogo (os itens novos costumam entrar no fim)
function M.news(ports, n)
  n = n or 10
  local dated, seen, out = {}, {}, {}
  for i, p in ipairs(ports or {}) do
    if not p.builtin and type(p.added) == "string" and p.added:match("^%d%d%d%d%-%d%d%-%d%d") then
      dated[#dated + 1] = { p = p, a = p.added:sub(1, 10), i = i }
    end
  end
  table.sort(dated, function(a, b)
    if a.a ~= b.a then return a.a > b.a end
    return a.i > b.i
  end)
  for _, e in ipairs(dated) do
    if #out >= n then break end
    out[#out + 1] = e.p; seen[e.p] = true
  end
  for i = #(ports or {}), 1, -1 do
    if #out >= n then break end
    local p = ports[i]
    if not seen[p] and not p.builtin then out[#out + 1] = p; seen[p] = true end
  end
  return out
end

--- quantos ports estao com o selo NOVO (is_new = Catalog.is_new)
function M.new_count(ports, is_new)
  local c = 0
  for _, p in ipairs(ports or {}) do if is_new(p) then c = c + 1 end end
  return c
end

--- "Hoje" | "Ontem" | "Há 3 dias" | "12/10" (t = os.time da sessao)
function M.when_label(t, now)
  if not t then return nil end
  now = now or os.time()
  local function day(x) local d = os.date("*t", x); return os.time({ year = d.year, month = d.month, day = d.day, hour = 12 }) end
  local diff = math.floor((day(now) - day(t)) / 86400 + 0.5)
  if diff <= 0 then return I18N.tr(L("Hoje")) end
  if diff == 1 then return I18N.tr(L("Ontem")) end
  if diff < 7 then return string.format(I18N.tr(L("Há %d dias")), diff) end
  return os.date("%d/%m", t)
end

--- "42 min" | "1h 12min" | "1h"
function M.dur_label(minutes)
  minutes = tonumber(minutes)
  if not minutes or minutes < 1 then return nil end
  local m = math.floor(minutes + 0.5)
  if m < 60 then return m .. " min" end
  local h, r = math.floor(m / 60), m % 60
  return r == 0 and (h .. "h") or (h .. "h " .. r .. "min")
end

local function dec(v)
  local s = string.format("%.0f", v)
  return s
end

--- linha de informacoes da ultima sessao: quando, quanto tempo e temperatura
--- maxima. last_play = Perf.last_play(id); perf_last = Perf.last(id)
function M.play_meta(last_play, perf_last, now)
  local parts = {}
  local t = last_play and last_play.start or (perf_last and perf_last.start)
  local w = M.when_label(t, now)
  if w then parts[#parts + 1] = w end
  local mins = (last_play and last_play.minutes) or (perf_last and perf_last.minutes)
  local d = M.dur_label(mins)
  if d then parts[#parts + 1] = d end
  local tmax = (last_play and last_play.temp_max) or (perf_last and perf_last.temp_max)
  if tmax and tmax > 0 then parts[#parts + 1] = I18N.tr(L("máx. ")) .. dec(tmax) .. " °C" end
  return table.concat(parts, " • ")
end

--- selo h700 do port: texto, tipo ("ok" | "warn" | "bad") ou nil
function M.h700_badge(p, long)
  if not p or not p.h700 then return nil end
  local s = p.h700.status
  if s == "testado" then return long and L("TESTADO NO RG35XXH") or L("TESTADO"), "ok" end
  if s == "pesado" then return long and L("PESADO NO RG35XXH") or L("PESADO"), "warn" end
  return long and L("NÃO RODA NO RG35XXH") or L("NÃO RODA"), "bad"
end

--- posicao da rolagem para que a linha `row` (0 = primeira) fique inteira na
--- area visivel de altura `view` (linhas de altura `rh` + `gap`)
function M.scroll_for(row, cur, view, rh, gap, total_rows)
  local top = row * (rh + gap)
  local bottom = top + rh
  local s = cur or 0
  if top < s then s = top end
  if bottom > s + view then s = bottom - view end
  local maxs = math.max(0, (total_rows or 0) * (rh + gap) - gap - view)
  if s > maxs then s = maxs end
  if s < 0 then s = 0 end
  return s
end

return M
