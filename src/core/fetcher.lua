-- =============================================================================
--  Fila de downloads pequenos (catalogo e capas) em uma thread separada
-- =============================================================================
local C = require("config")
local U = require("lib.util")

local F = { thread = nil, handlers = {}, pending = 0, seq = 0 }

function F.start()
  if F.thread then return end
  F.req = love.thread.getChannel("hub_fetch_req")
  F.res = love.thread.getChannel("hub_fetch_res")
  F.req:clear(); F.res:clear()
  F.thread = love.thread.newThread("threads/fetch_thread.lua")
  F.thread:start(C.FETCH_SH)
end

--- Agenda um download. cb(ok, out_path, reason)
function F.get(kind, url, out, cb, priority)
  F.start()
  F.seq = F.seq + 1
  local id = kind .. ":" .. F.seq
  F.handlers[id] = cb
  F.pending = F.pending + 1
  if priority then
    -- catalogo passa na frente das capas
    local queued = {}
    local m = F.req:pop()
    while m do queued[#queued + 1] = m; m = F.req:pop() end
    F.req:push({ id = id, kind = kind, url = url, out = out })
    for _, q in ipairs(queued) do F.req:push(q) end
  else
    F.req:push({ id = id, kind = kind, url = url, out = out })
  end
  return id
end

-- Segunda fila, so para downloads pequenos porem demorados (ex.: catalogo do
-- PortMaster, ~2,6 MB): assim capas e o catalogo do hub nao esperam por eles.
local BG = { thread = nil }
function F.get_bg(kind, url, out, cb)
  if not BG.thread then
    BG.req = love.thread.getChannel("hub_fetchbg_req")
    BG.res = love.thread.getChannel("hub_fetchbg_res")
    BG.req:clear(); BG.res:clear()
    BG.thread = love.thread.newThread("threads/fetch_thread.lua")
    BG.thread:start(C.FETCH_SH, "hub_fetchbg_req", "hub_fetchbg_res")
  end
  F.seq = F.seq + 1
  local id = kind .. ":" .. F.seq
  F.handlers[id] = cb
  BG.req:push({ id = id, kind = kind, url = url, out = out })
  return id
end

local function update_bg()
  if not BG.thread then return end
  local err = BG.thread:getError()
  if err then
    U.log("erro na thread de downloads (2a fila):", err)
    BG.thread = nil
    return
  end
  local m = BG.res:pop()
  while m do
    local cb = F.handlers[m.id]
    F.handlers[m.id] = nil
    if cb then
      local ok, e = pcall(cb, m.ok, m.out, m.reason)
      if not ok then U.log("erro no retorno do download:", e) end
    end
    m = BG.res:pop()
  end
end

function F.update()
  update_bg()
  if not F.thread then return end
  local err = F.thread:getError()
  if err then
    U.log("erro na thread de downloads:", err)
    F.thread = nil
    -- avisa todos os pendentes
    for id, cb in pairs(F.handlers) do pcall(cb, false, nil, "erro interno") end
    F.handlers = {}
    F.pending = 0
    return
  end
  local m = F.res:pop()
  while m do
    local cb = F.handlers[m.id]
    F.handlers[m.id] = nil
    F.pending = math.max(0, F.pending - 1)
    if cb then
      local ok, e = pcall(cb, m.ok, m.out, m.reason)
      if not ok then U.log("erro no retorno do download:", e) end
    end
    m = F.res:pop()
  end
end

--- Baixa so os primeiros `bytes` de um arquivo (ex.: manifesto de um .zip).
--- cb(ok, out_path, reason)
function F.get_part(kind, url, out, bytes, cb)
  F.start()
  F.seq = F.seq + 1
  local id = kind .. ":" .. F.seq
  F.handlers[id] = cb
  F.pending = F.pending + 1
  local queued = {}
  local m = F.req:pop()
  while m do queued[#queued + 1] = m; m = F.req:pop() end
  F.req:push({ id = id, kind = kind, url = url, out = out, part = bytes })
  for _, q in ipairs(queued) do F.req:push(q) end
  return id
end

--- Remove pedidos de capa ainda nao iniciados (ao trocar de tela)
function F.drop_covers()
  if not F.req then return end
  local keep = {}
  local m = F.req:pop()
  while m do
    if m.kind ~= "cover" then keep[#keep + 1] = m
    else
      local cb = F.handlers[m.id]
      F.handlers[m.id] = nil
      F.pending = math.max(0, F.pending - 1)
      if cb then pcall(cb, false, nil, "cancelado") end
    end
    m = F.req:pop()
  end
  for _, k in ipairs(keep) do F.req:push(k) end
end

function F.stop()
  if F.req then F.req:clear(); F.req:push({ t = "quit" }) end
  if BG.req then BG.req:clear(); BG.req:push({ t = "quit" }) end
end

return F
