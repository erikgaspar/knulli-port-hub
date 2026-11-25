-- =============================================================================
--  Knulli Port Hub: interface do modo desempenho e dos relatorios do RG35XXH
--    M.after_play(p, id)   ao voltar de um port: "Como rodou?" (uma vez por sessao)
--    M.ask(p, opts)        dialogo Bem / Pesado / Nao funcionou / Pular (+ comentario)
--    M.port_menu(p)        opcoes de desempenho na pagina do port (acao "x")
--    M.detail_lines(p)     linhas "DESEMPENHO NO RG35XXH" para a pagina do port
--    M.open_reports()      tela "Meus relatórios de compatibilidade" (infolist)
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local C = require("config")
local T = require("ui.theme")
local Perf = require("core.perf")
local H = require("core.h700reports")

local M = {}

M.STATUS = {
  testado = { L("RODOU BEM"), "green" },
  pesado = { L("PESADO"), "yellow" },
  nao_funciona = { L("NÃO FUNCIONA"), "red" },
}

local function tr(s) return I18N.tr(s) end

-- ---------------------------------------------------------------------------
-- "Como rodou?"
-- ---------------------------------------------------------------------------
local function saved_toast(edit)
  App.toast(edit and L("Avaliação atualizada.")
    or L("Obrigado! Relatório salvo em Meus relatórios de compatibilidade."), "ok")
end

local function save(p, status, note, s, opts)
  local e = { id = tostring(p.id), name = p.name or tostring(p.id), status = status, note = note }
  if s then
    e.minutes = s.minutes
    e.perf = s.perf
    if s.summary then e.temp_max = s.summary.temp_max; e.temp_avg = s.summary.temp_avg end
  end
  if H.set(e) then
    saved_toast(opts and opts.edit)
  else
    App.toast(L("Não foi possível salvar o relatório (pasta do app somente leitura?)."), "error")
  end
  -- pagina do port aberta: refaz o texto (a avaliacao aparece na hora)
  local cur = App.current()
  if cur and cur.name == "details" and cur.layout then cur:layout() end
  if opts and opts.done then opts.done() end
end

local function ask_note(p, status, s, opts)
  local prev = opts and opts.prev_note or ""
  App.show_dialog({
    title = L("Quer deixar um comentário?"), kind = "info",
    body = L("Ex.: \"quedas na primeira fase\", \"precisa do runtime mono\". Fica junto da avaliação e vai na exportação para o catálogo."),
    buttons = {
      { label = prev ~= "" and L("EDITAR COMENTÁRIO") or L("ESCREVER COMENTÁRIO"), fn = function()
        App.push("textinput", {
          title = L("Comentário"), label = p.name or tostring(p.id), value = prev, mode = "full", max = 140,
          hint = L("Curto: o que funcionou ou não."),
          on_ok = function(v) save(p, status, v, s, opts) end,
          on_cancel = function() save(p, status, prev, s, opts) end,
        })
      end },
      { label = prev ~= "" and L("MANTER COMENTÁRIO") or L("SALVAR SEM COMENTÁRIO"), fn = function() save(p, status, prev, s, opts) end },
    },
    cancel = function() save(p, status, prev, s, opts) end,
  })
end

--- p = { id, name }; opts = { session = (Perf.take_session), edit = bool, prev_note, done = fn }
function M.ask(p, opts)
  opts = opts or {}
  local s = opts.session
  local body = p.name or tostring(p.id)
  if s then
    local info = Perf.summary_text({ minutes = s.minutes,
      temp_max = s.summary and s.summary.temp_max, temp_avg = s.summary and s.summary.temp_avg })
    if info ~= "" then body = body .. "\n" .. tr(L("Esta sessão: ")) .. info .. (s.perf and tr(L(" (modo desempenho)")) or "") end
  end
  local function pick(st) return function() ask_note(p, st, s, opts) end end
  local buttons = {
    { label = L("RODOU BEM"), sub = L("Jogável, sem quedas que atrapalhem"), fn = pick("testado") },
    { label = L("PESADO (QUEDAS)"), sub = L("Abre e dá para jogar, mas engasga ou cai o FPS"), fn = pick("pesado") },
    { label = L("NÃO FUNCIONOU"), sub = L("Não abre, trava ou fica injogável"), fn = pick("nao_funciona") },
  }
  if opts.edit then
    buttons[#buttons + 1] = { label = L("CANCELAR") }
  else
    buttons[#buttons + 1] = { label = L("PULAR"), sub = L("Pergunta de novo na próxima vez") }
    buttons[#buttons + 1] = { label = L("NÃO PERGUNTAR MAIS SOBRE ESTE PORT"), fn = function()
      H.set_muted(p.id, true)
      App.toast(L("Certo. Para avaliar depois, use X na página do port."), "info")
    end }
  end
  App.show_dialog({ title = opts.edit and L("Mudar avaliação") or L("Como rodou?"), kind = "info", list = true,
    body = body, buttons = buttons, sel = 1 })
end

--- chamado por return_from_tool depois de abrir a pagina do port
function M.after_play(p, id)
  if not C.KNULLI then return end
  id = tostring(p and p.id or id or "")
  if id == "" then return end
  local s = Perf.take_session(id)          -- consome: so uma vez por sessao de jogo
  if not s then return end
  if App.dialog or not H.should_ask(id) then return end
  -- sessao curta demais (abriu e fechou na hora): nao pergunta
  if s.minutes and s.minutes < 0.5 then return end
  M.ask(p or { id = id, name = id }, { session = s })
end

-- ---------------------------------------------------------------------------
-- pagina do port
-- ---------------------------------------------------------------------------
--- linhas de texto para a caixa de descricao ({} quando nao ha nada)
function M.detail_lines(p)
  if not C.KNULLI or not p or p.builtin then return {} end
  local out = {}
  local last = Perf.last(p.id)
  if last then
    out[#out + 1] = tr(L("Último modo desempenho: ")) .. Perf.summary_text(last)
      .. ((last.start_iso or "") ~= "" and (" (" .. last.start_iso:sub(1, 16) .. ")") or "")
  end
  if Perf.always(p.id) then out[#out + 1] = tr(L("Este port sempre abre em modo desempenho.")) end
  if require("core.tune").get(p) then
    out[#out + 1] = tr(L("Ajustes para o RG35XXH: ")) .. (require("ui.tune_ui").summary(p) or "")
  end
  local r = H.get(tostring(p.id))
  if r then
    local st = M.STATUS[r.status]
    out[#out + 1] = tr(L("Sua avaliação: ")) .. tr(st[1]) .. " (" .. tostring(r.date or "") .. ")"
      .. ((r.note or "") ~= "" and (": " .. r.note) or "")
  end
  if #out > 0 or (Perf.available() and App.port_script(p)) then
    out[#out + 1] = tr(L("Use X para o modo desempenho e para avaliar"))
  end
  return out
end

--- opcoes da acao "x" na pagina do port
function M.port_menu(p)
  if not C.KNULLI or not p or p.builtin then return false end
  local script = App.port_script(p)
  local has_perf = Perf.available()
  local always = Perf.always(p.id)
  local r = H.get(tostring(p.id))
  local buttons = {}
  if script and has_perf then
    buttons[#buttons + 1] = { label = L("INICIAR EM MODO DESEMPENHO"),
      sub = L("CPU no máximo, GPU a 696 MHz e o menu pausado; mede a temperatura"),
      fn = function() App.launch_port(p, { perf = true }) end }
    buttons[#buttons + 1] = { label = always and L("SEMPRE EM MODO DESEMPENHO: LIGADO") or L("SEMPRE EM MODO DESEMPENHO: DESLIGADO"),
      sub = L("Vale também ao abrir pelo menu do Knulli"),
      fn = function()
        Perf.set_always_port(p, script, not always)
        App.toast(not always and L("Este port vai abrir sempre em modo desempenho.")
          or L("Este port volta a abrir no modo normal."), "info")
        local cur = App.current()
        if cur and cur.layout then cur:layout() end
      end }
    if always then
      buttons[#buttons + 1] = { label = L("INICIAR NO MODO NORMAL"), sub = L("Só desta vez"),
        fn = function() App.launch_port(p, { perf = false }) end }
    end
  end
  if require("core.tune").get(p) then
    local TU = require("ui.tune_ui")
    buttons[#buttons + 1] = { label = L("AJUSTES PARA O RG35XXH"), sub = TU.summary(p), fn = function() TU.dialog(p) end }
  end
  local last = Perf.last(p.id)
  if last then
    buttons[#buttons + 1] = { label = L("ÚLTIMO DESEMPENHO"), sub = Perf.summary_text(last),
      fn = function()
        App.show_dialog({ title = L("Último modo desempenho"), kind = "info",
          body = string.format(tr(L("%s\n\nInício: %s\nDuração: %s\nTemperatura máxima: %s °C\nTemperatura média: %s °C\n\nO H700 começa a reduzir a velocidade sozinho perto de 60 °C e mais forte em 70 °C.")),
            p.name, last.start_iso ~= "" and last.start_iso or "?",
            last.minutes and (Perf.dec(last.minutes) .. " min") or "?",
            last.temp_max and Perf.dec(last.temp_max) or "?", last.temp_avg and Perf.dec(last.temp_avg) or "?") })
      end }
  end
  buttons[#buttons + 1] = { label = r and L("MUDAR AVALIAÇÃO") or L("AVALIAR: COMO RODOU?"),
    sub = r and (tr(M.STATUS[r.status][1]) .. ((r.note or "") ~= "" and (": " .. r.note) or "")) or L("Vai para Meus relatórios de compatibilidade"),
    fn = function()
      H.set_muted(p.id, false)
      M.ask(p, { edit = r ~= nil, prev_note = r and r.note or "" })
    end }
  buttons[#buttons + 1] = { label = L("VOLTAR") }
  App.show_dialog({ title = L("Desempenho no RG35XXH"), kind = "info", list = true, body = p.name,
    buttons = buttons, sel = 1 })
  return true
end

-- ---------------------------------------------------------------------------
-- Meus relatorios de compatibilidade
-- ---------------------------------------------------------------------------
local function load_items(scr)
  H.load()
  local items = {}
  for _, r in ipairs(H.list()) do
    local st = M.STATUS[r.status]
    local meas = Perf.summary_text({ minutes = tonumber(r.minutes), temp_max = tonumber(r.temp_max_c) })
    local sub = { tostring(r.date or "") }
    if meas ~= "" then sub[#sub + 1] = meas .. (r.perf and tr(L(" (desempenho)")) or "") end
    if (r.note or "") ~= "" then sub[#sub + 1] = r.note end
    items[#items + 1] = { tag = tr(st[1]), tagc = T.c[st[2]] or T.c.dim, text = r.name or r.id,
      sub = table.concat(sub, "  •  "), ref = r,
      detail = function()
        local t = { tr(L("Avaliação: ")) .. tr(st[1]), tr(L("Data: ")) .. tostring(r.date or "") .. " " .. tostring(r.time or ""),
          tr(L("Testado em: ")) .. tostring(r.tested_on or H.tested_on()), "id: " .. r.id }
        if meas ~= "" then t[#t + 1] = tr(L("Sessão: ")) .. meas .. (r.perf and tr(L(" (modo desempenho)")) or "") end
        if (r.note or "") ~= "" then t[#t + 1] = ""; t[#t + 1] = r.note end
        return table.concat(t, "\n")
      end }
  end
  scr.items = items
  local n = { testado = 0, pesado = 0, nao_funciona = 0 }
  for _, it in ipairs(items) do n[it.ref.status] = n[it.ref.status] + 1 end
  scr.p.sub = string.format(tr(L("%d relatórios  •  %d bem  •  %d pesados  •  %d não funcionam")),
    #items, n.testado, n.pesado, n.nao_funciona)
  scr.sel = math.min(scr.sel or 1, math.max(1, #items))
end

-- L1: liga/desliga a pergunta "Como rodou?" ao voltar de um port
local function ask_label()
  return H.ask_enabled() and L("Perguntar ao sair: sim") or L("Perguntar ao sair: não")
end

function M.open_reports()
  App.push("infolist", {
    title = L("Meus relatórios de compatibilidade"),
    empty = L("Nenhum relatório ainda. Depois de jogar um port aberto pelo hub, responda \"Como rodou?\" (ou use X na página do port)."),
    load = load_items,
    reload_on_resume = true,
    keys = {
      { key = "y", label = L("Mudar avaliação"), enabled = function(scr) return #scr.items > 0 end,
        fn = function(scr, it)
          if not it then return end
          local r = it.ref
          M.ask({ id = r.id, name = r.name }, { edit = true, prev_note = r.note or "",
            done = function() load_items(scr) end })
        end },
      { key = "x", label = L("Exportar para o catálogo"), enabled = function(scr) return #scr.items > 0 end,
        fn = function()
          local path, n = H.export()
          if path then
            App.show_dialog({ title = L("Relatórios exportados"), kind = "ok",
              body = string.format(tr(L("%d port(s) gravados em:\n%s\n\nMesmo formato do knulli-catalog.json: copie os itens de \"ports\" para lá e publique.")), n, path) })
          else
            App.show_dialog({ title = L("Não foi possível exportar"), kind = "error", body = tostring(n) })
          end
        end },
      { key = "select", label = L("Apagar"), enabled = function(scr) return #scr.items > 0 end,
        fn = function(scr, it)
          if not it then return end
          App.show_dialog({ title = L("Apagar relatório?"), kind = "warn", body = it.text,
            buttons = { { label = L("APAGAR"), danger = true, fn = function() H.remove(it.ref.id); load_items(scr) end },
              { label = L("CANCELAR") } }, sel = 2 })
        end },
      { key = "l1", label = ask_label(),
        fn = function(scr)
          H.set_ask_enabled(not H.ask_enabled())
          scr.p.keys[#scr.p.keys].label = ask_label()   -- o rodape le o rotulo a cada quadro
          App.toast(H.ask_enabled() and L("Vou perguntar \"Como rodou?\" depois de cada port sem avaliação.")
            or L("Não vou mais perguntar \"Como rodou?\" ao sair dos jogos."), "info")
        end },
    },
  })
end

return M
