-- =============================================================================
--  Converter para CHD - thread (core/chdconv.lua)
--  Recebe { out, st, ctl, op, cfg, params }:
--    roda M.op_<op>(params); progresso no canal "st" (tabela do M.progress);
--    "cancel" no canal "ctl" pede para parar (o chdman em curso e interrompido);
--    no fim, em "out": { t = "done", results = { ok =, res = } } (formato do shjob).
-- =============================================================================
require("love.timer")
local job = ...
local OUT = love.thread.getChannel(job.out)
local ST = love.thread.getChannel(job.st)
local CTL = love.thread.getChannel(job.ctl)

local M = require("core.chdconv")
M.setup(job.cfg)

local cancelled = false
M.cancelled = function()
  if not cancelled and CTL:pop() == "cancel" then cancelled = true end
  return cancelled
end
local last, last_phase = 0, nil
M.progress = function(info)
  local now = love.timer.getTime()
  if now - last < 0.15 and info.phase == last_phase then return end
  last, last_phase = now, info.phase
  ST:clear()
  ST:push(info)
end

local fn = M["op_" .. tostring(job.op)]
local ok, res
if not fn then ok, res = false, "operação desconhecida: " .. tostring(job.op)
else ok, res = pcall(fn, job.params or {}) end
if not ok then res = tostring(res) end
OUT:push({ t = "done", results = { ok = ok, res = res } })
