-- =============================================================================
--  Knulli Port Hub: tela da memoria extra (zram) e avisos antes de abrir port
--  pesado / que fechou por falta de memoria. So no Knulli (Z.available()).
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local Z = require("core.zram")

local M = {}
local tr = I18N.tr

M.EXPLAIN = L("Usa parte da RAM comprimida como memória extra. Ajuda ports pesados a não fecharem por falta de memória.")

--- linhas de estado (RAM livre, tamanho, uso)
function M.status_lines(st)
  st = st or Z.status()
  local out = {}
  if st.active then
    out[#out + 1] = tr(L("Estado: ")) .. tr(st.enabled and L("ligada (liga sozinha ao iniciar)") or L("ligada só até reiniciar"))
  else
    out[#out + 1] = tr(L("Estado: ")) .. tr(st.enabled and L("desligada (deveria ligar ao iniciar)") or L("desligada"))
  end
  out[#out + 1] = string.format(tr(L("RAM livre: %s de %s")), Z.mb(st.ram_free), Z.mb(st.ram_total))
  if st.active then
    out[#out + 1] = tr(L("Tamanho do zram: ")) .. Z.mb(st.size)
    local u = tr(L("Em uso: ")) .. Z.mb(st.used)
    if st.mem_used and (st.used or 0) > 0 then u = u .. string.format(tr(L(" (ocupa %s da RAM)")), Z.mb(st.mem_used)) end
    out[#out + 1] = u
  end
  return out
end

--- texto curto do estado (cartao do tema Premium)
function M.short(st)
  st = st or Z.status()
  if not st.active then return L("Desligada"), false end
  return string.format(tr(L("Ligada  •  %s")), Z.mb(st.size)), true
end

local busy = false

--- liga/desliga (persistente) e chama done(ok, st) no fim
function M.toggle(on, done)
  if busy then return end
  busy = true
  App.toast(on and L("Ligando a memória extra...") or L("Desligando a memória extra (pode levar alguns segundos)..."), "info")
  Z.set(on, function(ok, st)
    busy = false
    if ok then
      App.toast(on and L("Memória extra ligada. Continua ligada depois de reiniciar.")
        or L("Memória extra desligada."), "ok")
    else
      App.toast(on and L("Não consegui ligar a memória extra.") or L("Não consegui desligar a memória extra."), "error")
    end
    if done then done(ok, st) end
  end)
end

function M.open()
  if not Z.available() then
    App.toast(L("Esta ferramenta não está disponível nesta versão."), "warn")
    return
  end
  local st = Z.status()
  local body = tr(M.EXPLAIN) .. "\n\n" .. table.concat(M.status_lines(st), "\n")
  local function reopen() if not App.dialog then M.open() end end
  local with_perf = Z.with_perf()
  local ask = Z.ask_enabled()
  local buttons = {
    { label = st.active and L("DESLIGAR") or L("LIGAR"),
      sub = st.active and L("Para de usar a memória extra (fica salvo)") or L("Fica salvo: continua ligada depois de reiniciar"),
      fn = function() M.toggle(not st.active, reopen) end },
    { label = with_perf and L("JUNTO COM O MODO DESEMPENHO: SIM") or L("JUNTO COM O MODO DESEMPENHO: NÃO"),
      sub = L("Liga a memória extra enquanto um port roda em modo desempenho"),
      fn = function() Z.set_with_perf(not with_perf); reopen() end },
    { label = ask and L("AVISAR ANTES DE PORT PESADO: SIM") or L("AVISAR ANTES DE PORT PESADO: NÃO"),
      sub = L("Pergunta se quer ligar quando o port usa muita memória"),
      fn = function() Z.set_ask_enabled(not ask); reopen() end },
    { label = L("VOLTAR") },
  }
  App.show_dialog({ title = L("Memória extra (zram)"), kind = "info", list = true, body = body,
    buttons = buttons, sel = 1 })
end

-- ---------------------------------------------------------------------------
-- antes de abrir um port pelo hub
-- ---------------------------------------------------------------------------
--- pergunta (se precisar) e chama cont(opts_extra) para seguir com a abertura.
--- Devolve true se mostrou uma pergunta (a abertura continua por cont).
function M.before_launch(p, perf, cont)
  if not Z.available() or not p or p.builtin then return false end
  local oom = Z.oom(p.id)
  local heavy = Z.heavy(p)
  if not oom and not heavy then return false end
  local st = Z.status()
  -- modo desempenho ja liga o zram junto (se a opcao estiver ligada)
  local perf_zram = perf and Z.with_perf()
  if not st.active and not perf_zram and Z.ask_enabled() then
    local body = oom and tr(L("Na última vez este port fechou por falta de memória.")) .. "\n\n" .. tr(M.EXPLAIN)
      or tr(M.EXPLAIN)
    local buttons = {
      { label = L("LIGAR"), sub = L("Fica salvo: continua ligada depois de reiniciar"), fn = function()
        M.toggle(true, function() cont({}) end)
      end },
      { label = L("AGORA NÃO"), fn = function() cont({}) end },
    }
    buttons[#buttons + 1] = { label = L("NÃO PERGUNTAR DE NOVO"),
        sub = L("Dá para mudar em Ferramentas > Memória extra"),
        fn = function() Z.set_ask_enabled(false); cont({}) end }
    App.show_dialog({ title = L("Este port usa muita memória"), kind = "warn", list = true,
      body = (p.name or tostring(p.id)) .. "\n\n" .. tr(L("Ligar a memória extra (zram)?")) .. "\n" .. body,
      buttons = buttons, sel = 1 })
    return true
  end
  -- fechou por falta de memoria com o zram ja ligado: sugere o modo desempenho
  if oom and not perf and require("core.perf").available() then
    App.show_dialog({ title = L("Faltou memória"), kind = "warn", list = true,
      body = (p.name or tostring(p.id)) .. "\n\n" .. tr(L("Na última vez este port fechou por falta de memória.")) .. " "
        .. tr(L("A memória extra já está ligada. O modo desempenho deixa a CPU no máximo e pausa o menu enquanto joga.")),
      buttons = {
        { label = L("ABRIR EM MODO DESEMPENHO"), fn = function() cont({ perf = true }) end },
        { label = L("ABRIR NO MODO NORMAL"), fn = function() cont({ perf = false }) end },
      }, sel = 1 })
    return true
  end
  return false
end

--- ao voltar de um port aberto pelo hub: le o resultado gravado pelo launcher
function M.after_play(id)
  if not Z.available() then return end
  local r = Z.take_exit(id)
  if r and r.oom then
    App.toast(L("O port fechou por falta de memória. Na próxima vez o hub sugere a memória extra."), "warn")
  elseif r and not r.oom and r.rc == 0 then
    -- rodou e saiu normalmente: tira a marca
    Z.set_oom(r.id, false)
  end
end

return M
