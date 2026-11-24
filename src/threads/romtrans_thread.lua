-- =============================================================================
--  Traducoes de ROMs - thread (core/romtrans.lua)
--  Recebe { out, st, ctl, op, cfg, params }:
--    roda M.op_<op>(params); progresso no canal "st" ({done, total, text, pct});
--    "cancel" no canal "ctl" pede para parar (no fim do item em curso);
--    no fim, em "out": { t = "done", results = { ok =, res = } } (formato do shjob).
-- =============================================================================
require("love.timer")
local job = ...
local OUT = love.thread.getChannel(job.out)
local ST = love.thread.getChannel(job.st)
local CTL = love.thread.getChannel(job.ctl)

local M = require("core.romtrans")
M.setup(job.cfg)

local cancelled = false
M.cancelled = function()
  if not cancelled and CTL:pop() == "cancel" then cancelled = true end
  return cancelled
end
local last = 0
local last_key
M.progress = function(done, total, text, pct)
  local now = love.timer.getTime()
  -- mudanca de passo/fase passa sempre; so a porcentagem e limitada
  local key = tostring(done) .. "|" .. tostring(text)
  if now - last < 0.1 and done ~= total and key == last_key then return end
  last, last_key = now, key
  ST:clear()
  ST:push({ done = done, total = total, text = tostring(text or ""), pct = pct })
end

local fn = M["op_" .. tostring(job.op)]
local ok, res
if not fn then ok, res = false, "operação desconhecida: " .. tostring(job.op)
else ok, res = pcall(fn, job.params or {}) end
if not ok then res = tostring(res) end
OUT:push({ t = "done", results = { ok = ok, res = res } })
