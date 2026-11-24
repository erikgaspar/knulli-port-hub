-- =============================================================================
--  Converter para CHD (so Knulli) - tela
--  M.open(): lista os jogos de CD que podem virar .chd (core/chdconv.lua).
--    B fisico ("a"): detalhes          Y fisico ("x"): converter o selecionado
--    X fisico ("y"): converter todos   SELECT: instalar/atualizar/remover o chdman
--  Procurar, converter e instalar rodam em segundo plano
--  (threads/chdconv_thread.lua). Durante a conversao a tela mostra o jogo
--  atual, o progresso e o tempo restante; da para sair (continua) ou cancelar.
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local U = require("lib.util")
local C = require("config")
local T = require("ui.theme")
local G = require("ui.gfx")
local CV = require("core.chdconv")

local M = {}

local function tr(s) return I18N.tr(L(s)) end
local function fmt(s, ...) return string.format(tr(s), ...) end

local STATUS = {
  ok = { nil, "accent2" },
  missing = { L("FALTA ARQUIVO"), "red" },
  outside = { L("INVÁLIDO"), "red" },
  empty = { L("INVÁLIDO"), "red" },
  exists = { L("JÁ TEM .CHD"), "faint" },
  shared = { L("TRILHA EM COMUM"), "orange" },
  unsupported = { L("NÃO SUPORTADO"), "faint" },
}

local WHY = {
  pbp = L("Arquivo .pbp (EBOOT do PlayStation): o chdman não lê esse formato. O emulador já abre o .pbp como está."),
  cso = L("Arquivo .cso (ISO comprimida do PSP): o chdman não lê esse formato."),
  psp = L("O PPSSPP do Knulli lê .chd, mas só no formato DVD (\"createdvd\"). O chdman 0.251 do Debian 12 não tem esse comando, então o PSP fica de fora."),
  missing = L("O .cue/.gdi cita arquivos que não estão no cartão. Nada é convertido nem apagado."),
  outside = L("O .cue/.gdi cita arquivos fora da pasta do sistema. Por segurança, não é convertido."),
  empty = L("O .cue/.gdi não cita nenhum arquivo de trilha."),
  exists = L("Já existe um .chd com o mesmo nome. Apague um dos dois antes de converter."),
  shared = L("Uma trilha deste jogo também é usada por outro .cue. Apagar quebraria o outro jogo."),
}

local PHASE = {
  compress = L("comprimindo"), verify = L("verificando"), finish = L("finalizando"),
  download = L("baixando"),
}

-------------------------------------------------------------------------------
-- lista
-------------------------------------------------------------------------------
local data   -- resultado do ultimo op_scan

local function convertible()
  local t, bytes, saved = {}, 0, 0
  for _, it in ipairs(data and data.items or {}) do
    if it.status == "ok" then t[#t + 1] = it; bytes = bytes + it.bytes; saved = saved + it.est_saved end
  end
  return t, bytes, saved
end

local function rel_of(it, f)
  local d = CV.sys_dir(it.sys) .. "/"
  return f:sub(1, #d) == d and f:sub(#d + 1) or f
end

local function detail_of(it)
  local t = { U.upper(it.sys) .. "  •  " .. CV.sys_dir(it.sys) .. "/" .. it.rel, "" }
  if it.status == "ok" then
    t[#t + 1] = fmt("Tamanho atual: %s  (%d arquivo(s))", U.format_bytes(it.bytes), #it.files)
    t[#t + 1] = fmt("Estimativa: .chd com cerca de %s, economia de cerca de %s (o real depende do jogo).",
      U.format_bytes(it.est_chd), U.format_bytes(it.est_saved))
    t[#t + 1] = fmt("Resultado: %s", it.out_rel)
    t[#t + 1] = ""
    t[#t + 1] = tr("Depois de criar e verificar o .chd, são apagados só estes arquivos:")
    for i, f in ipairs(it.files) do
      if i > 8 then t[#t + 1] = fmt("... e mais %d", #it.files - 8); break end
      t[#t + 1] = "• " .. rel_of(it, f)
    end
    if #it.m3u > 0 then t[#t + 1] = ""; t[#t + 1] = tr("Listas .m3u atualizadas: ") .. table.concat(it.m3u, ", ") end
  else
    local why = WHY[it.why or it.status]
    if why then t[#t + 1] = tr(why) end
    if #it.missing > 0 then
      t[#t + 1] = ""
      t[#t + 1] = tr("Arquivos citados que não foram encontrados:")
      for i, f in ipairs(it.missing) do if i <= 6 then t[#t + 1] = "• " .. f end end
    end
  end
  return table.concat(t, "\n")
end

local function header_sub()
  local inst = data and data.chdman
  local ch = inst and ("chdman " .. tostring(inst.version or "?")) or tr("chdman não instalado (SELECT)")
  if not data then return ch end
  local list, _, saved = convertible()
  return fmt("%d para converter  •  ~%s de economia (estimativa)", #list, U.format_bytes(saved)) .. "  •  " .. ch
end

local function to_items(scr)
  local order = { ok = 1, shared = 2, missing = 3, outside = 3, empty = 3, exists = 4, unsupported = 5 }
  local list = {}
  for _, it in ipairs(data.items) do list[#list + 1] = it end
  table.sort(list, function(a, b)
    local oa, ob = order[a.status] or 9, order[b.status] or 9
    if oa ~= ob then return oa < ob end
    if a.status == "ok" and a.est_saved ~= b.est_saved then return a.est_saved > b.est_saved end
    if a.sys ~= b.sys then return a.sys < b.sys end
    return a.name:lower() < b.name:lower()
  end)
  local items = {}
  for _, it in ipairs(list) do
    local st = STATUS[it.status] or { "?", "faint" }
    local sub = U.upper(it.sys) .. "  •  " .. U.format_bytes(it.bytes)
    if it.status == "ok" then
      sub = sub .. "  •  " .. fmt("economia estimada ~%s", U.format_bytes(it.est_saved))
      if #it.m3u > 0 then sub = sub .. "  •  .m3u" end
    end
    if it.hidden then sub = sub .. "  •  " .. tr("oculto na lista") end
    items[#items + 1] = { tag = st[1] or U.upper(it.kind), tagc = T.c[st[2]] or T.c.accent2, text = it.name,
      sub = sub, ref = it, detail = function() return detail_of(it) end }
  end
  scr.items = items
  scr.sel = math.min(scr.sel or 1, math.max(1, #items))
  scr.p.sub = header_sub()
end

-------------------------------------------------------------------------------
-- tela de progresso (conversao e instalacao) desenhada por cima da lista
-------------------------------------------------------------------------------
local function eta_text(job, frac)
  local el = love.timer.getTime() - (job.t0 or 0)
  if frac <= 0.01 or el < 4 then return tr("calculando...") end
  return U.format_time(el * (1 - frac) / frac)
end

local function draw_busy(self)
  local job = CV.job
  local st = job.poll() or {}
  G.header(self.p.title or "", job.op == "convert" and tr("Convertendo") or tr("chdman"))
  local y = 90
  if job.op == "convert" then
    G.text(T.f.small, fmt("Jogo %d de %d", st.index or 1, st.count or 1), 40, y, T.c.dim)
    G.text_fit(T.f.h2, st.name or "...", 40, y + 22, T.W - 80, T.c.text)
    local pct = st.pct or 0
    G.text(T.f.body, tr(PHASE[st.phase] or "preparando") .. string.format("  %.0f%%", pct), 40, y + 60, T.c.yellow)
    G.progress(40, y + 84, T.W - 80, 12, pct / 100, T.c.accent2)
    local frac = (st.total or 0) > 0 and (st.done or 0) / st.total or 0
    G.text(T.f.small, tr("Total da fila"), 40, y + 120, T.c.dim)
    G.progress(40, y + 140, T.W - 80, 12, frac, T.c.green)
    G.text(T.f.body, string.format("%.0f%%", frac * 100) .. "  •  " .. tr("restam ") .. eta_text(job, frac),
      40, y + 162, T.c.text)
  else
    G.text(T.f.h2, job.op == "uninstall" and tr("Removendo o chdman") or tr("Instalando o chdman"), 40, y + 10, T.c.text)
    if st.phase == "download" and (st.total or 0) > 0 then
      G.text(T.f.body, fmt("Baixando do Debian: %s de %s", U.format_bytes(st.done), U.format_bytes(st.total)), 40, y + 60, T.c.yellow)
      G.progress(40, y + 84, T.W - 80, 12, st.done / st.total, T.c.accent2)
      G.text(T.f.small, st.name or "", 40, y + 104, T.c.dim)
    else
      G.text(T.f.body, st.name or tr("preparando..."), 40, y + 60, T.c.yellow)
      G.progress_busy(40, y + 84, T.W - 80, 12, App.t, T.c.accent2)
    end
  end
  if job.cancelling then G.text(T.f.body, tr("cancelando... (o .chd parcial é apagado; os originais ficam)"), 40, 380, T.c.orange) end
  local hints = {}
  if job.op == "convert" and not job.cancelling then hints[#hints + 1] = { "a", L("Cancelar") } end
  hints[#hints + 1] = { "b", L("Sair (continua)") }
  G.hints(hints)
end

local function cancel_dialog()
  if not CV.job or CV.job.op ~= "convert" or CV.job.cancelling then return end
  App.show_dialog({ title = L("Cancelar a conversão?"), kind = "warn",
    body = L("O jogo em andamento é interrompido: o .chd parcial é apagado e os arquivos originais dele ficam como estavam. Os jogos já convertidos continuam convertidos."),
    buttons = { { label = L("CANCELAR CONVERSÃO"), danger = true, fn = function() if CV.job then CV.job.cancel() end end },
      { label = L("CONTINUAR") } }, sel = 2 })
end

local function busy(self) return CV.job ~= nil and CV.job.op ~= "scan" end

--- troca draw/action desta instancia da lista (as outras listas nao mudam)
local function hook(scr)
  if scr.chd_hooked then return end
  scr.chd_hooked = true
  local S = App.screens.infolist
  scr.draw = function(self)
    if busy(self) then draw_busy(self) else S.draw(self) end
  end
  scr.action = function(self, act)
    if busy(self) then
      if act == "b" then App.pop()
      elseif act == "a" or act == "x" then cancel_dialog() end
      return
    end
    S.action(self, act)
  end
  scr.update = function(self)
    if CV.job and CV.job.op == "scan" and self.loading then
      local st = CV.job.poll() or {}
      self.loading = tr("Procurando jogos de CD") .. ((st.count or 0) > 0 and string.format("  %d/%d", st.index or 0, st.count) or "")
      self.p.sub = st.name and U.upper(st.name) or nil
    end
  end
end

-------------------------------------------------------------------------------
-- acoes
-------------------------------------------------------------------------------
local scan

local function errors_text(list)
  if not list or #list == 0 then return "" end
  local t = {}
  for i = 1, math.min(#list, 6) do t[#t + 1] = "• " .. list[i].name .. ": " .. list[i].err end
  if #list > 6 then t[#t + 1] = fmt("... e mais %d", #list - 6) end
  return "\n\n" .. tr("Não convertidos (originais intactos):") .. "\n" .. table.concat(t, "\n")
end

local function start(scr, op, params, on_ok)
  if CV.job then App.toast(L("Espere a tarefa em andamento terminar."), "warn"); return false end
  local job = CV.run(op, params, function(ok, res)
    if not ok then
      App.show_dialog({ title = L("A tarefa falhou"), kind = "error", body = tostring(res) })
      if op ~= "scan" then M.refresh() elseif M.active then M.active.loading = nil end
      return
    end
    on_ok(res)
  end)
  if not job then App.toast(L("Espere a tarefa em andamento terminar."), "warn"); return false end
  return true
end

M.active = nil   -- instancia da lista aberta por ultimo (a tela pode ter sido reaberta)

scan = function(scr)
  hook(scr)
  scr.loading = tr("Procurando jogos de CD")
  local ok = start(scr, "scan", {}, function(res)
    data = res
    local s = M.active or scr
    s.loading = nil
    to_items(s)
  end)
  if not ok then scr.loading = nil end
end

--- procura de novo se a lista estiver na tela (depois de converter/instalar)
function M.refresh()
  local s = M.active
  if s and App.current() == s and not CV.job then scan(s) end
end

local function install_dialog(scr, reason)
  local man = CV.manifest()
  local inst = CV.installed()
  local pk = {}
  for _, d in ipairs(man and man.debs or {}) do pk[#pk + 1] = d.package .. " " .. d.version end
  local body = (reason and (tr(reason) .. "\n\n") or "")
    .. tr("O chdman (ferramenta do MAME que cria os .chd) não vem no Knulli. Ele é baixado do repositório oficial do Debian (deb.debian.org, Debian 12 \"bookworm\"), com o SHA256 de cada pacote conferido:")
    .. "\n" .. table.concat(pk, ", ")
    .. "\n\n" .. fmt("Download: %s  •  instala em %s", U.format_bytes(man and man.total or 0), CV.cfg.tool_dir)
  if inst then body = body .. "\n\n" .. fmt("Instalado agora: %s (%s)", tostring(inst.chdman or inst.version), tostring(inst.installed or "?")) end
  local buttons = {
    { label = inst and L("REINSTALAR") or L("INSTALAR"), fn = function()
      start(scr, "install", {}, function(res)
        App.toast(L("chdman instalado: ") .. tostring(res.version or ""), "ok")
        M.refresh()
      end)
    end },
  }
  if inst then
    buttons[#buttons + 1] = { label = L("REMOVER"), danger = true, fn = function()
      start(scr, "uninstall", {}, function()
        App.toast(L("chdman removido."), "ok")
        M.refresh()
      end)
    end }
  end
  buttons[#buttons + 1] = { label = L("CANCELAR") }
  App.show_dialog({ title = inst and L("chdman instalado") or L("Instalar o chdman?"), kind = "info", body = body,
    buttons = buttons, sel = 1 })
end

local function convert(scr, list)
  if not CV.installed() then install_dialog(scr, L("Para converter, primeiro instale o chdman.")); return end
  start(scr, "convert", { items = list }, function(r)
    local msg = fmt("%d jogo(s) convertido(s), %s liberados (%s → %s).", #r.ok, U.format_bytes(r.saved),
      U.format_bytes(r.before), U.format_bytes(r.after))
    if r.cancelled then msg = tr("Cancelado.") .. " " .. msg end
    if #r.failed > 0 then msg = msg .. "\n" .. fmt("%d falharam.", #r.failed) end
    msg = msg .. "\n\n" .. tr("O EmulationStation mostra as mudanças quando você sair do Port Hub (a lista de jogos é recarregada).")
    App.show_dialog({ title = (#r.failed > 0 or r.cancelled) and L("Conversão concluída com avisos") or L("Conversão concluída"),
      kind = #r.failed > 0 and "warn" or "ok", body = msg .. errors_text(r.failed) })
    pcall(App.update_free_space)
    M.refresh()
  end)
end

local function confirm_body(list, bytes, saved)
  local free = U.free_space(CV.cfg.root)
  local biggest = 0
  for _, it in ipairs(list) do biggest = math.max(biggest, it.bytes) end
  local t = { fmt("%d jogo(s), %s hoje. Economia estimada: ~%s (estimativa; o real depende do jogo).", #list,
    U.format_bytes(bytes), U.format_bytes(saved)), "",
    tr("Um por vez: cria o .chd, confere com \"chdman verify\" e só então apaga o .cue/.gdi/.iso e os arquivos que ele cita. O gamelist e os .m3u passam a apontar para o .chd. Se algo falhar, o .chd é apagado e os originais ficam."),
    "", fmt("Espaço livre: %s (cada jogo precisa de ~75%% do tamanho dele + 64 MB; o maior pede %s).",
      free and U.format_bytes(free) or "?", U.format_bytes(CV.need_kb(biggest) * 1024)),
    tr("Pode levar bastante tempo (vários minutos por jogo). Dá para sair desta tela; a conversão continua.") }
  return table.concat(t, "\n")
end

local function convert_selected(scr, item)
  local it = item and item.ref
  if not it then return end
  if it.status ~= "ok" then
    App.show_dialog({ title = it.name, kind = "info", body = detail_of(it) }); return
  end
  if not CV.installed() then install_dialog(scr, L("Para converter, primeiro instale o chdman.")); return end
  App.show_dialog({ title = L("Converter para CHD?"), kind = "warn",
    body = it.name .. "\n\n" .. confirm_body({ it }, it.bytes, it.est_saved),
    buttons = { { label = L("CONVERTER"), fn = function() convert(scr, { it }) end }, { label = L("CANCELAR") } }, sel = 1 })
end

local function convert_all(scr)
  local list, bytes, saved = convertible()
  if #list == 0 then App.toast(L("Nenhum jogo para converter."), "info"); return end
  if not CV.installed() then install_dialog(scr, L("Para converter, primeiro instale o chdman.")); return end
  App.show_dialog({ title = fmt("Converter %d jogos para CHD?", #list), kind = "warn",
    body = confirm_body(list, bytes, saved),
    buttons = { { label = L("CONVERTER TODOS"), danger = true, fn = function() convert(scr, list) end },
      { label = L("CANCELAR") } }, sel = 2 })
end

function M.open()
  if not C.KNULLI then App.toast(L("Disponível só no Knulli."), "warn"); return end
  CV.app_setup()
  App.push("infolist", { title = L("Converter para CHD"), sub = "",
    empty = L("Nenhum .cue, .gdi ou .iso nos sistemas que aceitam .chd."),
    load = function(scr)
      hook(scr)
      M.active = scr
      if CV.job then
        -- tarefa em andamento (a tela foi reaberta): mostra o progresso
        if CV.job.op == "scan" then scr.loading = tr("Procurando jogos de CD")
        elseif data then to_items(scr) end
        return
      end
      scan(scr)
    end,
    keys = {
      { key = "x", label = L("Converter"), fn = convert_selected },
      { key = "y", label = L("Converter todos"), fn = function(scr) convert_all(scr) end },
      { key = "select", label = L("chdman"), fn = function(scr) install_dialog(scr) end },
    } })
end

return M
