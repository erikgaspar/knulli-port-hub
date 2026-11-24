-- =============================================================================
--  Tema Premium: imagens pre-calculadas (desfoque barato em Canvas)
--  O desfoque e feito UMA vez por imagem: a imagem e reduzida para ~32 px e
--  ampliada de volta em duas etapas com filtro linear. O resultado fica num
--  Canvas guardado (poucos por vez); por quadro so se desenha o Canvas pronto.
-- =============================================================================
local T = require("ui.theme")
local PS = require("ui.premium.style")

local PI = {}
local lg = love.graphics

local CACHE, ORDER = {}, {}
PI.MAX = 4

local function touch(key)
  for i, k in ipairs(ORDER) do if k == key then table.remove(ORDER, i); break end end
  ORDER[#ORDER + 1] = key
  while #ORDER > PI.MAX do
    local old = table.remove(ORDER, 1)
    local cv = CACHE[old]
    if cv and cv.release then cv:release() end
    CACHE[old] = nil
  end
end

--- desenha em `cv` com o estado grafico limpo (e volta ao Canvas de antes:
--- o hub pode estar desenhando num Canvas logico ou na captura de tela)
local function render_to(cv, fn)
  lg.push("all")
  lg.setCanvas(cv)
  lg.origin()
  lg.setScissor()
  lg.clear(0, 0, 0, 0)
  lg.setColor(1, 1, 1, 1)
  fn()
  lg.pop()
end
PI.render_to = render_to

local function new_canvas(w, h)
  local cv = lg.newCanvas(math.max(1, math.floor(w)), math.max(1, math.floor(h)))
  cv:setFilter("linear", "linear")
  return cv
end

--- imagem desfocada no tamanho w x h (modo "cover"); `key` identifica a imagem
--- (ex.: slug do port). opts = { dark = 0..1 (veu por cima), alpha = 0..1
--- (opacidade da imagem sobre o fundo), bg = cor do fundo, pad = sobra nas bordas }
function PI.blurred(img, key, w, h, opts)
  if not img then return nil end
  opts = opts or {}
  local ck = table.concat({ key, w, h, opts.dark or 0, opts.alpha or 1, opts.pad or 0 }, "|")
  local cv = CACHE[ck]
  if cv then touch(ck); return cv end
  local ok, res = pcall(function()
    local iw, ih = img:getDimensions()
    local pad = opts.pad or 0
    local tw, th = w + 2 * pad, h + 2 * pad
    -- etapa 1: ~32 px no lado maior (ja recortado no formato do destino)
    local k = 32 / math.max(tw, th)
    local sw, sh = math.max(4, math.floor(tw * k + 0.5)), math.max(4, math.floor(th * k + 0.5))
    -- (reducao em duas etapas: menos serrilhado que ir direto para 32 px)
    local pre = new_canvas(sw * 3, sh * 3)
    render_to(pre, function()
      local s = math.max(sw * 3 / iw, sh * 3 / ih)
      lg.draw(img, (sw * 3 - iw * s) / 2, (sh * 3 - ih * s) / 2, 0, s, s)
    end)
    local small = new_canvas(sw, sh)
    render_to(small, function() lg.draw(pre, 0, 0, 0, 1 / 3, 1 / 3) end)
    pre:release()
    -- etapa 2: 4x maior (suaviza os blocos da reducao)
    local mid = new_canvas(sw * 4, sh * 4)
    render_to(mid, function() lg.draw(small, 0, 0, 0, 4, 4) end)
    -- etapa 3: tamanho final, com fundo, opacidade e veu
    local out = new_canvas(w, h)
    render_to(out, function()
      local bg = opts.bg or T.c.bg0
      lg.clear(bg[1], bg[2], bg[3], 1)
      lg.setColor(1, 1, 1, opts.alpha or 1)
      lg.draw(mid, -pad, -pad, 0, tw / (sw * 4), th / (sh * 4))
      if (opts.dark or 0) > 0 then
        lg.setColor(PS.VEIL[1], PS.VEIL[2], PS.VEIL[3], opts.dark)
        lg.rectangle("fill", 0, 0, w, h)
      end
    end)
    small:release(); mid:release()
    return out
  end)
  if not ok then
    require("lib.util").log("premium: desfoque falhou:", tostring(res))
    return nil
  end
  CACHE[ck] = res
  touch(ck)
  return res
end

--- fundo de tela inteira (Detalhes): capa desfocada a 35% sobre o fundo + veu 0.62
function PI.backdrop(img, key)
  return PI.blurred(img, key, 640, 480, { alpha = 0.35, dark = 0.62, pad = 40 })
end

--- libera tudo (troca de tema)
function PI.clear()
  for k, cv in pairs(CACHE) do if cv.release then cv:release() end end
  CACHE, ORDER = {}, {}
end

return PI
