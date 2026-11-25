-- =============================================================================
--  Knulli Port Hub: "Ajustes para o RG35XXH" (perfil recomendado do catalogo,
--  core/tune.lua): pergunta depois de instalar, dialogo com Aplicar/Desfazer.
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local C = require("config")
local Tune = require("core.tune")

local M = {}
local function tr(s) return I18N.tr(L(s)) end

local function cache_clear() if M.invalidate then M.invalidate() end end

M.STATE = { applied = L("aplicados"), partial = L("aplicados em parte"), none = L("não aplicados") }
M.STATE_CAP = { applied = L("Aplicados"), partial = L("Aplicados em parte"), none = L("Não aplicados") }

--- texto do resultado (toast)
local function result_text(sum)
  local parts = {}
  if sum.perf then parts[#parts + 1] = tr("modo desempenho") end
  if sum.zram then parts[#parts + 1] = tr("memória extra") end
  local n_ok, notes = 0, {}
  for _, r in ipairs(sum.settings or {}) do
    if r.status == "applied" then n_ok = n_ok + 1
    elseif r.status == "pending" then notes[#notes + 1] = string.format(tr("%s: o jogo ainda não criou o arquivo; aplico na próxima vez"), r.file)
    elseif r.status == "kept_user" then notes[#notes + 1] = string.format(tr("%s: %s mantido (você já tinha mudado)"), r.file, tostring(r.key))
    elseif r.status == "error" then notes[#notes + 1] = r.file .. ": " .. tr(r.msg or "erro") end
  end
  if n_ok > 0 then parts[#parts + 1] = string.format(tr("%d configuração(ões) do jogo"), n_ok) end
  return parts, notes
end

local function apply(p, done)
  cache_clear()
  Tune.apply(p, App.port_script(p), function(sum)
    if not sum then return end
    cache_clear()
    local parts, notes = result_text(sum)
    if #notes > 0 then
      App.show_dialog({ title = L("Ajustes aplicados"), kind = "info",
        body = (p.name or p.id) .. "\n\n" .. table.concat(parts, ", ") .. "\n\n" .. table.concat(notes, "\n") })
    else
      App.toast(tr("Ajustes do RG35XXH aplicados: ") .. table.concat(parts, ", "), "ok")
    end
    if done then done() end
  end)
end
M.apply = apply

local function body_of(p, t)
  local lines = { p.name or p.id, "" }
  for _, l in ipairs(Tune.describe(t)) do lines[#lines + 1] = "• " .. l end
  if t.note then lines[#lines + 1] = ""; lines[#lines + 1] = t.note end
  return table.concat(lines, "\n")
end

--- depois de instalar/atualizar um port pelo hub
function M.after_install(p)
  if not C.KNULLI or not p then return end
  local t = Tune.get(p)
  if not t or not Tune.auto() or not App.port_script(p) then return end
  if Tune.asked() then apply(p); return end
  App.show_dialog({ title = L("Ajustes recomendados"), kind = "info", list = true,
    body = tr("Aplicar ajustes recomendados para o RG35XXH?") .. "\n\n" .. body_of(p, t),
    buttons = {
      { label = L("APLICAR"), sub = L("Nos próximos ports aplica sozinho (muda em Configurações)"),
        fn = function() Tune.set_asked(); apply(p) end },
      { label = L("AGORA NÃO"), sub = L("Dá para aplicar depois na página do port") },
      { label = L("NUNCA APLICAR SOZINHO"), sub = L("Desliga em Configurações > Ajustes recomendados"),
        fn = function() Tune.set_asked(); Tune.set_auto(false) end },
    }, sel = 1 })
end

--- dialogo da pagina do port
function M.dialog(p, done)
  local st, t = Tune.state(p)
  if not t then return false end
  local installed = App.port_script(p) ~= nil
  local body = body_of(p, t) .. "\n\n" .. tr("Estado: ") .. tr(M.STATE[st] or "")
  local buttons = {}
  if installed and st ~= "applied" then
    buttons[#buttons + 1] = { label = L("APLICAR"), sub = L("Só mexe nas configurações do próprio port, com cópia antes"),
      fn = function() apply(p, done) end }
  end
  if st ~= "none" then
    buttons[#buttons + 1] = { label = L("DESFAZER"), sub = L("Tira o modo desempenho automático e volta as configurações do jogo"),
      fn = function()
        Tune.undo(p, App.port_script(p))
        cache_clear()
        App.toast(L("Ajustes desfeitos. A memória extra continua ligada."), "info")
        if done then done() end
      end }
  end
  if not installed then body = body .. "\n\n" .. tr("Instale o port para aplicar.") end
  buttons[#buttons + 1] = { label = L("VOLTAR") }
  App.show_dialog({ title = L("Ajustes para o RG35XXH"), kind = "info", list = true, body = body, buttons = buttons, sel = 1 })
  return true
end

--- texto curto para cartoes/linhas: "Modo desempenho, memória extra e 1 configuração  •  aplicados"
local cache = {}
function M.invalidate() cache = {} end

function M.summary(p)
  -- a pagina do port chama a cada quadro: guarda por 3 s (o estado le arquivos)
  local now = os.time()
  local c = cache[p.id]
  if c and now - c.t < 3 then return c.v, c.st end
  local v, st = M.summary_now(p)
  cache[p.id] = { t = now, v = v, st = st }
  return v, st
end

function M.summary_now(p)
  local st, t = Tune.state(p)
  if not t then return nil end
  local parts = {}
  if t.perf then parts[#parts + 1] = tr("modo desempenho") end
  if t.zram then parts[#parts + 1] = tr("memória extra") end
  local n = 0
  for _, s in ipairs(t.settings) do for _ in pairs(s.set) do n = n + 1 end end
  if n > 0 then parts[#parts + 1] = string.format(tr("%d configuração(ões) do jogo"), n) end
  local s = table.concat(parts, ", ")
  return tr(M.STATE_CAP[st] or "") .. "  •  " .. s, st
end

return M
