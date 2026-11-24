-- =============================================================================
--  Knulli Port Hub - thread que reduz a arte "hero" baixada (core/heroart.lua)
--  Pedido (canal "hub_hero_req"): { id=, src= arquivo baixado (jpg/png),
--    out= PNG de saida, w= largura maxima }
--  Resposta ("hub_hero_res"): { id=, ok=, bytes=, w=, h=, err= }
--  A Steam entrega library_hero.jpg com 3840 px: decodificar e reduzir aqui
--  evita travar a interface e guarda so uma imagem de ~640 px.
-- =============================================================================
require("love.image")
require("love.filesystem")

local REQ = love.thread.getChannel("hub_hero_req")
local RES = love.thread.getChannel("hub_hero_res")

local okffi, ffi = pcall(require, "ffi")

--- reducao por media de caixa (amostras n x n por pixel de saida)
local function downscale(src, dst)
  local sw, sh = src:getDimensions()
  local dw, dh = dst:getDimensions()
  local fx, fy = sw / dw, sh / dh
  local n = math.max(1, math.min(4, math.floor(math.min(fx, fy) + 0.5)))
  local inv = 1 / (n * n)
  local sp = okffi and src.getFFIPointer and ffi.cast("uint8_t*", src:getFFIPointer()) or nil
  local dp = okffi and dst.getFFIPointer and ffi.cast("uint8_t*", dst:getFFIPointer()) or nil
  local floor = math.floor
  for y = 0, dh - 1 do
    for x = 0, dw - 1 do
      local r, g, b = 0, 0, 0
      for j = 0, n - 1 do
        local sy = floor((y + (j + 0.5) / n) * fy)
        if sy >= sh then sy = sh - 1 end
        for i = 0, n - 1 do
          local sx = floor((x + (i + 0.5) / n) * fx)
          if sx >= sw then sx = sw - 1 end
          if sp then
            local o = (sy * sw + sx) * 4
            r = r + sp[o]; g = g + sp[o + 1]; b = b + sp[o + 2]
          else
            local pr, pg, pb = src:getPixel(sx, sy)
            r = r + pr * 255; g = g + pg * 255; b = b + pb * 255
          end
        end
      end
      if dp then
        local o = (y * dw + x) * 4
        dp[o] = floor(r * inv + 0.5); dp[o + 1] = floor(g * inv + 0.5); dp[o + 2] = floor(b * inv + 0.5); dp[o + 3] = 255
      else
        dst:setPixel(x, y, r * inv / 255, g * inv / 255, b * inv / 255, 1)
      end
    end
  end
end

local function work(r)
  local f = assert(io.open(r.src, "rb"))
  local bytes = f:read("*a")
  f:close()
  local fd = love.filesystem.newFileData(bytes, "hero.img")
  local src = love.image.newImageData(fd)
  if src:getFormat() ~= "rgba8" then error("formato " .. tostring(src:getFormat())) end
  local sw, sh = src:getDimensions()
  local tw = math.min(tonumber(r.w) or 640, sw)
  local th = math.max(1, math.floor(sh * tw / sw + 0.5))
  local out = src
  if tw < sw then
    out = love.image.newImageData(tw, th, "rgba8")
    downscale(src, out)
  end
  local enc = out:encode("png")
  local data = enc:getString()
  local tmp = r.out .. ".tmp"
  local o = assert(io.open(tmp, "wb"))
  o:write(data)
  o:close()
  os.remove(r.out)
  assert(os.rename(tmp, r.out), "falha ao salvar")
  return #data, tw, th
end

while true do
  local r = REQ:demand()
  if type(r) == "table" and r.t == "quit" then break end
  if type(r) == "table" and r.src and r.out then
    local ok, bytes, w, h = pcall(work, r)
    if ok then
      RES:push({ id = r.id, ok = true, bytes = bytes, w = w, h = h })
    else
      os.remove(r.out .. ".tmp")
      RES:push({ id = r.id, ok = false, err = tostring(bytes) })
    end
  end
end
