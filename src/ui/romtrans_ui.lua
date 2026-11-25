-- =============================================================================
--  Traducoes de ROMs (so Knulli) - tela
--  M.open() abre a lista (ui/screens/infolist.lua) com tres abas (L1/R1):
--    1. Para os seus jogos : traducoes que casam com as suas ROMs (por hash);
--                            jogos de CD aparecem igual, com o tamanho e o aviso
--                            de que levam alguns minutos
--    2. Ja traduzidos      : as que o app aplicou (desfazer) e as ja em PT-BR
--    3. Outras traducoes   : do indice, para jogos que voce nao tem ou tem em
--                            outra versao; jogos em .chd ainda nao verificados
--                            (com traducao conhecida pelo titulo) tem a acao
--                            "Verificar"; .pbp/.cso/.chd do PSP: "nao suportado"
--  Botoes (acoes do app): "a" detalhes/traduzir, "x" traduzir (aba 1) ou
--  verificar (aba 3) ou "Traducoes aplicadas" (aba 2: backups das originais,
--  ui/rtapplied_ui.lua), "y" procurar de novo, "select" recuperar a original (aba 2) ou pasta
--  de trabalho dos jogos de CD (abas 1 e 3). A busca, a traducao, a verificacao
--  e o desfazer rodam em segundo plano (threads/romtrans_thread.lua); da para
--  sair da tela. Traduzir e verificar mostram o progresso detalhado e podem
--  ser cancelados (A).
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local U = require("lib.util")
local C = require("config")
local T = require("ui.theme")
local G = require("ui.gfx")
local RT = require("core.romtrans")

local M = {}

local function tr(s) return I18N.tr(L(s)) end
local function fmt(s, ...) return string.format(tr(s), ...) end

local state = { res = nil, tab = 1 }
local TABS = { L("Para os seus jogos"), L("Já traduzidos"), L("Outras traduções") }

local OP_LABEL = { scan = L("Procurando traduções"), translate = L("Traduzindo"), undo = L("Desfazendo a tradução"),
  verify_chd = L("Verificando o CHD") }

-- operacoes com a tela de progresso detalhado (e cancelar)
local function busy_op(job) return job ~= nil and (job.op == "translate" or job.op == "verify_chd") end

local function status_line(job)
  local st = job.poll()
  local s
  if job.op == "scan" then
    s = tr(OP_LABEL.scan)
    if (st.total or 0) > 0 then s = s .. string.format("  %d/%d", st.done or 0, st.total) end
  else
    s = (st.text and st.text ~= "") and tr(st.text) or tr(OP_LABEL[job.op] or "Trabalhando")
    if (st.total or 0) > 0 then s = s .. string.format("  (%d/%d)", st.done or 0, st.total) end
  end
  if job.cancelling then s = s .. "  •  " .. tr("cancelando...") end
  return s, job.op == "scan" and st.text or nil
end

local to_items   -- (definida mais abaixo)

local function attach(scr)
  scr.update = function(self)
    if busy_op(RT.job) then self.saw_busy = true; return end
    if self.saw_busy and not RT.job then
      -- a tarefa terminou (talvez de outra abertura da tela): atualiza a lista
      self.saw_busy = nil
      to_items(self)
    end
    if not self.loading then return end
    if RT.job then
      local a, b = status_line(RT.job)
      self.loading = a
      self.status_sub = b
    else
      self.loading, self.status_sub = nil, nil
      to_items(self)
    end
  end
end

local function run(scr, op, params, on_ok, info)
  if RT.job then
    App.toast(L("Espere a tarefa em andamento terminar."), "warn")
    return false
  end
  local busy = op == "translate" or op == "verify_chd"
  if not busy then scr.loading = tr(OP_LABEL[op] or "Trabalhando") end
  scr.status_sub = nil
  attach(scr)
  local job = RT.run(op, params, function(ok, res)
    scr.loading = nil
    scr.status_sub = nil
    if not ok then
      local msg = tostring(res)
      if msg == "cancelado" then App.toast(L("Cancelado. Nada foi trocado."), "warn"); return end
      App.show_dialog({ title = L("A tarefa falhou"), kind = "error", body = msg })
      return
    end
    on_ok(res)
  end)
  if not job then scr.loading = nil; App.toast(L("Espere a tarefa em andamento terminar."), "warn"); return false end
  if info then job.name, job.cd = info.name, info.cd end
  return true
end

local function sysname(s) return U.upper(s or "") end

local function tlabel(t)
  local s = t.group and t.group ~= "" and fmt("tradução de %s", t.group) or tr("tradução")
  if t.version and t.version ~= "" then s = s .. " v" .. t.version end
  return s
end

local function status_tag(t)
  local st = RT.status_label(t)
  if st == "completa" then return L("COMPLETA"), T.c.green end
  if st == "parcial" then return L("PARCIAL"), T.c.yellow end
  return U.upper(st), T.c.accent2
end

local function reload_es_note()
  return tr("O EmulationStation mostra o nome novo quando você sair do Port Hub (a lista de jogos é recarregada).")
end

-------------------------------------------------------------------------------
-- jogos de CD: espaco e pasta de trabalho
-------------------------------------------------------------------------------
local function free_text(dir)
  local kb = RT.free_kb(dir)
  return kb and U.format_bytes(kb * 1024) or "?"
end

--- linhas extras do dialogo de traduzir um jogo de CD
local function cd_lines(m)
  local CD = RT.CD
  local list = m.kind == "chd" and CD.space_chd(m) or CD.space_file(m)
  local work = CD.work_dir()
  local lines = {
    tr("Jogo de CD: leva alguns minutos."),
    fmt("Pasta de trabalho: %s (livre: %s)", work, free_text(work)),
    fmt("Espaço no pior caso: %s (o app confere antes de começar)", U.format_bytes(CD.space_total(list))),
  }
  if m.kind == "chd" then
    lines[#lines + 1] = fmt("O CHD é extraído, a faixa %d recebe a tradução e o CHD é recriado e conferido; o nome do arquivo não muda.",
      m.track or 1)
    if not CD.installed() then lines[#lines + 1] = tr("Falta o chdman: instale em \"Converter para CHD\".") end
  end
  return lines
end

local function work_dir_dialog(scr)
  local CD = RT.CD
  local cur = CD.work_dir()
  local opts = {
    { dir = nil, show = RT.cfg.tmp_dir, label = L("Pasta do app (padrão)") },
    { dir = "/userdata/system/knulli-port-hub/work", label = L("Pasta do sistema") },
    { dir = "/userdata/tmp/knulli-port-hub", label = L("Pasta temporária do cartão") },
  }
  local buttons = {}
  for _, o in ipairs(opts) do
    local path = o.dir or o.show
    buttons[#buttons + 1] = { label = o.label, sub = path .. "  •  " .. fmt("livre: %s", free_text(path))
      .. ((path == cur) and ("  •  " .. tr("atual")) or ""),
      fn = function()
        local ok, err = CD.set_work_dir(o.dir)
        if ok then App.toast(fmt("Pasta de trabalho: %s", path), "ok")
        else App.show_dialog({ title = L("A tarefa falhou"), kind = "error", body = tr(tostring(err)) }) end
      end }
  end
  buttons[#buttons + 1] = { label = L("VOLTAR") }
  App.show_dialog({ title = L("Pasta de trabalho dos jogos de CD"), kind = "info", list = true, buttons = buttons,
    body = tr("Onde extrair e recriar os jogos de CD (só dentro de /userdata). Um CD extraído pode ter 700 MB; o app confere o espaço antes de cada tradução.") })
end

-------------------------------------------------------------------------------
-- itens de cada aba
-------------------------------------------------------------------------------
local function match_detail(m)
  local t = m.t
  local lines = {
    tr("Jogo:") .. " " .. (m.name or "") .. " (" .. sysname(m.sys) .. ")",
    tr("Arquivo:") .. " " .. m.rel .. (m.inzip and ("  →  " .. m.inzip) or "")
      .. (m.kind == "chd" and ("  →  " .. fmt("faixa %d", m.track or 1)) or "")
      .. "  (" .. U.format_bytes(m.size or 0) .. ")",
    tr("Tradução:") .. " " .. (t.title or t.id) .. " — " .. tlabel(t) .. " (" .. tr(RT.status_label(t)) .. ")",
    tr("Idioma:") .. " " .. (t.lang or "pt-BR") .. "   " .. tr("Formato:") .. " " .. U.upper(t.patch_format)
      .. "   " .. tr("Conferido por:") .. " " .. U.upper(m.how or "?"),
  }
  if m.header then lines[#lines + 1] = tr("A ROM tem header de 512 bytes (SMC); ele é retirado, como a tradução exige.") end
  if not t.result then lines[#lines + 1] = tr("O índice não traz o hash do resultado: o app confere só a ROM de origem.") end
  if t.notes and t.notes ~= "" then lines[#lines + 1] = tr("Notas:") .. " " .. t.notes end
  if t.page_url and t.page_url ~= "" then lines[#lines + 1] = tr("Página:") .. " " .. t.page_url end
  return table.concat(lines, "\n")
end

function to_items(scr)
  local res = state.res or { matches = {}, translated = {}, others = {} }
  local items = {}
  if state.tab == 1 then
    for _, m in ipairs(res.matches or {}) do
      local tag, tagc = status_tag(m.t)
      local sub = m.rel .. (m.inzip and "  •  zip" or "") .. "  •  " .. U.upper(m.t.patch_format)
        .. (m.header and ("  •  " .. tr("sem header")) or "")
      if m.cd then
        sub = sub .. "  •  " .. U.format_bytes(m.size or 0) .. "  •  " .. tr("jogo de CD: leva alguns minutos")
      end
      items[#items + 1] = { tag = tag, tagc = tagc,
        text = (m.name or m.rel) .. " (" .. sysname(m.sys) .. ") — " .. tlabel(m.t),
        sub = sub, ref = m, kind = "match" }
    end
    scr.p.empty = state.res and tr("Nenhuma tradução do índice casa com as suas ROMs.") or tr("Aperte X para procurar.")
  elseif state.tab == 2 then
    for _, x in ipairs(res.translated or {}) do
      local tag, tagc, sub
      if x.rec then
        local r = x.rec
        tag, tagc = L("PT-BR"), T.c.green
        sub = (r.group and (r.group .. " ") or "") .. (r.version and ("v" .. r.version .. "  •  ") or "")
          .. fmt("traduzido em %s", r.date or "?")
        if x.missing then tag, tagc, sub = L("SEM ARQUIVO"), T.c.red, tr("a ROM traduzida sumiu do cartão") end
        if x.backup_missing then tagc = T.c.orange; sub = sub .. "  •  " .. tr("sem a cópia da original") end
        if x.backup_deleted then sub = sub .. "  •  " .. tr("backup excluído") end
      else
        tag, tagc = L("JÁ EM PT-BR"), T.c.accent2
        sub = tr("já é o resultado da tradução") .. " — " .. tlabel(x.t)
      end
      items[#items + 1] = { tag = tag, tagc = tagc, text = (x.name or x.rel) .. " (" .. sysname(x.sys) .. ")",
        sub = sub, ref = x, kind = "translated" }
    end
    scr.p.empty = tr("Nenhuma ROM traduzida ainda.")
  else
    local TAG = { other_version = { L("OUTRA VERSÃO"), T.c.orange }, ptbr_name = { L("JÁ EM PT-BR?"), T.c.accent2 },
      missing = { L("VOCÊ NÃO TEM"), T.c.faint }, no_system = { L("SEM O SISTEMA"), T.c.faint },
      chd_verify = { L("VERIFICAR CHD"), T.c.yellow }, unsupported = { L("NÃO SUPORTADO"), T.c.red } }
    for _, o in ipairs(res.others or {}) do
      local tg = TAG[o.state] or TAG.missing
      local sub = tlabel(o.t) .. "  •  " .. tr(RT.status_label(o.t))
      if o.similar then sub = sub .. "  •  " .. tr("você tem:") .. " " .. o.similar end
      if o.state == "chd_verify" then
        sub = sub .. "  •  " .. U.format_bytes(o.file and o.file.size or 0) .. "  •  " .. tr("X: verificar")
      end
      items[#items + 1] = { tag = tg[1], tagc = tg[2], text = (o.t.title or o.t.id) .. " (" .. sysname(o.sys) .. ")",
        sub = sub, ref = o, kind = "other" }
    end
    scr.p.empty = tr("Nada aqui.")
  end
  scr.items = items
  scr.sel = math.max(1, math.min(scr.sel or 1, #items))
  scr.scroll = math.max(0, math.min(scr.scroll or 0, math.max(0, #items - 1)))
end

local function sub_line(scr)
  if scr.loading then return scr.status_sub end
  local res = state.res
  local n = res and { #res.matches, #res.translated, #res.others } or { 0, 0, 0 }
  local s = string.format("%s (%d)  •  L1/R1", tr(TABS[state.tab]), n[state.tab])
  if res then
    local src = { online = tr("índice atualizado"), cache = tr("índice do cache"), embutido = tr("índice embutido") }
    s = s .. "  •  " .. (src[res.index_source] or "") .. string.format(" (%d)", res.index_count or 0)
    if res.cancelled then s = s .. "  •  " .. tr("busca interrompida") end
  end
  return s
end

-------------------------------------------------------------------------------
-- tela de progresso (traduzir / verificar), desenhada no lugar da lista
-------------------------------------------------------------------------------
local function draw_busy(self)
  local job = RT.job
  local st = job.poll() or {}
  G.header(self.p.title or "", tr(OP_LABEL[job.op] or "Trabalhando"))
  local y = 90
  G.text_fit(T.f.h2, job.name or "...", 40, y, T.W - 80, T.c.text)
  if job.cd then G.text(T.f.small, tr("jogo de CD: leva alguns minutos"), 40, y + 34, T.c.dim) end
  local total = math.max(1, st.total or 1)
  G.text(T.f.small, fmt("Passo %d de %d", st.done or 0, st.total or 0), 40, y + 60, T.c.dim)
  local txt = (st.text and st.text ~= "") and tr(st.text) or tr("preparando...")
  if st.pct then txt = txt .. string.format("  %.0f%%", st.pct) end
  G.text_fit(T.f.body, txt, 40, y + 80, T.W - 80, T.c.yellow)
  if st.pct then G.progress(40, y + 106, T.W - 80, 12, st.pct / 100, T.c.accent2)
  else G.progress_busy(40, y + 106, T.W - 80, 12, App.t, T.c.accent2) end
  local frac = (math.max(0, (st.done or 1) - 1) + (st.pct or 0) / 100) / total
  G.text(T.f.small, tr("Total"), 40, y + 136, T.c.dim)
  G.progress(40, y + 156, T.W - 80, 8, math.min(1, frac), T.c.green)
  if job.cancelling then
    G.text(T.f.body, tr("cancelando... (nada é trocado; os arquivos temporários são apagados)"), 40, 380, T.c.orange)
  end
  local hints = {}
  if not job.cancelling then hints[#hints + 1] = { "a", L("Cancelar") } end
  hints[#hints + 1] = { "b", L("Sair (continua)") }
  G.hints(hints)
end

local function cancel_dialog()
  local job = RT.job
  if not busy_op(job) or job.cancelling then return end
  App.show_dialog({ title = L("Cancelar?"), kind = "warn",
    body = tr("O passo em andamento é interrompido e os arquivos temporários são apagados. O jogo fica como estava (nada é trocado)."),
    buttons = { { label = L("CANCELAR"), danger = true, fn = function() if RT.job then RT.job.cancel() end end },
      { label = L("CONTINUAR") } }, sel = 2 })
end

--- troca draw/action desta instancia da lista (as outras listas nao mudam)
local function hook(scr)
  local S = App.screens and App.screens.infolist
  if scr.rt_hooked or not S then return end
  scr.rt_hooked = true
  scr.draw = function(self)
    if busy_op(RT.job) then draw_busy(self) else S.draw(self) end
  end
  scr.action = function(self, act)
    if busy_op(RT.job) then
      if act == "b" then App.pop()
      elseif act == "a" then cancel_dialog() end
      return
    end
    S.action(self, act)
  end
end

-------------------------------------------------------------------------------
-- acoes
-------------------------------------------------------------------------------
local function scan(scr, online, after)
  run(scr, "scan", { online = online }, function(res)
    state.res = res
    to_items(scr)
    if after then after(res); return end
    local extra = {}
    if res.index_warn and res.index_source ~= "online" then
      extra[#extra + 1] = fmt("Sem o índice atualizado (%s); usando o %s.", tostring(res.index_warn),
        res.index_source == "cache" and tr("do cache") or tr("embutido"))
    end
    if res.errors and #res.errors > 0 then extra[#extra + 1] = fmt("%d arquivo(s) não puderam ser lidos.", #res.errors) end
    if #extra > 0 then App.toast(table.concat(extra, " "), "warn")
    else App.toast(fmt("%d tradução(ões) para os seus jogos.", #res.matches), "ok") end
  end)
end

local function translate(scr, m)
  if not m then return end
  if m.kind == "chd" and not RT.CD.installed() then
    App.show_dialog({ title = L("Falta o chdman"), kind = "warn",
      body = tr("Para traduzir jogos em CHD o app usa o chdman. Instale em \"Converter para CHD\" e tente de novo.") })
    return
  end
  local body = match_detail(m) .. "\n\n"
  if m.cd then body = body .. table.concat(cd_lines(m), "\n") .. "\n\n" end
  body = body
    .. fmt("A ROM original vai para %s e a traduzida fica no lugar, com o mesmo nome (saves e imagens continuam valendo).",
      RT.cfg.backup_dir .. "/" .. m.sys .. "/")
    .. " " .. tr("No gamelist, o nome ganha \" (PT-BR)\". Dá para desfazer depois.")
    .. "\n" .. tr("Precisa de internet para baixar o patch.")
  App.show_dialog({ title = L("Traduzir este jogo?"), kind = "info", body = body,
    buttons = { { label = L("TRADUZIR"), fn = function()
      run(scr, "translate", { match = m }, function(res)
        -- tira os casamentos do mesmo arquivo e poe no "Ja traduzidos"
        local keep = {}
        for _, x in ipairs(state.res.matches) do
          if not (x.sys == m.sys and x.rel == m.rel) then keep[#keep + 1] = x end
        end
        state.res.matches = keep
        table.insert(state.res.translated, 1, { key = res.rec.key, sys = m.sys, rel = m.rel, path = m.path,
          rec = res.rec, name = res.rec.gl_name_before or m.name })
        to_items(scr)
        local note = res.rec.verified and tr("O resultado confere com o índice.") or
          tr("O índice não traz o hash do resultado; confira o jogo.")
        if res.rec.kind == "chd" then note = note .. "\n" .. tr("O CHD novo foi conferido: extrai para a faixa traduzida.") end
        if res.gl_note then note = note .. "\n" .. fmt("Lista de jogos não alterada: %s.", tostring(res.gl_note)) end
        if res.reg_err then note = note .. "\n" .. tostring(res.reg_err) end
        App.show_dialog({ title = L("Tradução aplicada"), kind = "info",
          body = (m.name or m.rel) .. "\n\n" .. note .. "\n\n" .. fmt("A original está em %s.", res.rec.backup)
            .. "\n\n" .. reload_es_note() })
      end, { name = m.name or m.rel, cd = m.cd })
    end }, { label = L("CANCELAR") } } })
end

--- "Verificar" um .chd: extrai (um por vez), calcula o hash das faixas e procura de novo
local function verify_chd(scr, o)
  if not o or o.state ~= "chd_verify" or not o.file then return end
  local CD = RT.CD
  if not CD.installed() then
    App.show_dialog({ title = L("Falta o chdman"), kind = "warn",
      body = tr("Para verificar jogos em CHD o app usa o chdman. Instale em \"Converter para CHD\" e tente de novo.") })
    return
  end
  local f = o.file
  local work = CD.work_dir()
  local est = math.min(900 * 1024 * 1024, (f.size or 0) * 3)
  local body = table.concat({
    (f.name or f.rel) .. " (" .. sysname(f.sys) .. ")  •  " .. U.format_bytes(f.size or 0),
    "",
    tr("Para saber se a tradução serve, o app extrai este CHD, calcula o hash de cada faixa e apaga a cópia (o CHD não muda)."),
    fmt("A imagem extraída pode ter até ~%s em %s (livre: %s).", U.format_bytes(est), work, free_text(work)),
    tr("Leva alguns minutos. Dá para cancelar."),
  }, "\n")
  App.show_dialog({ title = L("Verificar este CHD?"), kind = "info", body = body,
    buttons = { { label = L("VERIFICAR"), fn = function()
      run(scr, "verify_chd", { file = f }, function(res)
        -- procura de novo (sem baixar o indice): o CHD verificado entra no casamento
        scan(scr, false, function(r2)
          local hit
          for _, m in ipairs(r2.matches) do if m.sys == f.sys and m.rel == f.rel then hit = m; break end end
          if hit then
            state.tab = 1
            scr.sel, scr.scroll = 1, 0
            for i, m in ipairs(r2.matches) do if m == hit then scr.sel = i end end
            to_items(scr)
            App.toast(L("O CHD confere: a tradução aparece em \"Para os seus jogos\"."), "ok")
          else
            App.show_dialog({ title = L("CHD verificado"), kind = "info",
              body = fmt("%s: nenhuma faixa confere com a versão exigida pela tradução (é outra versão do jogo).",
                f.name or f.rel) })
          end
        end)
      end, { name = f.name or f.rel, cd = true })
    end }, { label = L("CANCELAR") } } })
end

--- "Traduções aplicadas" (ui/rtapplied_ui.lua): depois de desfazer/excluir,
--- atualiza esta lista (excluir: so le o registro de novo; desfazer: procura)
local function applied_hook(scr)
  local RA = require("ui.rtapplied_ui")
  RA.on_change = function(kind)
    if not state.res then return end
    if kind == "delete" then
      local reg = RT.reg_load()
      for _, y in ipairs(state.res.translated or {}) do
        local rec = y.key and reg.items[y.key]
        if rec then y.rec = rec; y.backup_deleted = rec.backup_deleted; y.backup_missing = false end
      end
      to_items(scr)
    elseif not RT.job then
      scan(scr, false)   -- a ROM original volta para "Para os seus jogos"
    end
  end
  return RA
end

--- entrada do registro no formato de RT.applied() (estado e tamanho do backup)
local function applied_entry(key)
  for _, a in ipairs((RT.applied())) do if a.key == key then return a end end
end

local function undo(scr, x)
  if not x or not x.rec then return end
  local a = applied_entry(x.key)
  if not a then return end
  local RA = applied_hook(scr)
  if a.state == "missing" then
    App.show_dialog({ title = L("Sem a cópia da original"), kind = "warn",
      body = fmt("A cópia da ROM original não está mais em %s. Não dá para desfazer; você pode só tirar o jogo do registro.",
        tostring(x.rec.backup)),
      buttons = { { label = L("TIRAR DO REGISTRO"), danger = true, fn = function()
        RT.forget(x.key)
        local keep = {}
        for _, y in ipairs(state.res.translated) do if y ~= x then keep[#keep + 1] = y end end
        state.res.translated = keep
        to_items(scr)
      end }, { label = L("CANCELAR") } }, sel = 2 })
    return
  end
  RA.restore(a)
end

local function details(scr, it)
  if not it then return end
  local r = it.ref
  if it.kind == "match" then
    translate(scr, r)
  elseif it.kind == "translated" then
    if r.rec then
      local a = applied_entry(r.key)
      if a then applied_hook(scr).details(a) end
    else
      App.show_dialog({ title = it.text, kind = "info",
        body = tr("Este arquivo já é o resultado da tradução abaixo (traduzido fora do app):") .. "\n"
          .. (r.t.title or r.t.id) .. " — " .. tlabel(r.t) .. "\n\n" .. r.rel })
    end
  else
    if r.state == "chd_verify" then verify_chd(scr, r); return end
    local t = r.t
    local why = ({ other_version = tr("Você tem este jogo, mas em outra versão (o hash não confere). A tradução só funciona na versão exata abaixo."),
      ptbr_name = tr("Você tem um arquivo com nome de tradução para este jogo."),
      missing = tr("Você não tem este jogo nesta pasta."),
      no_system = fmt("Não há a pasta %s no cartão.", r.sys),
      unsupported = tr(r.why or "formato não suportado") })[r.state] or ""
    local rom = t.rom or {}
    local lines = { why, "",
      tr("Tradução:") .. " " .. tlabel(t) .. " (" .. tr(RT.status_label(t)) .. ")",
      tr("ROM exigida:") .. " " .. tostring(rom.name or "?") }
    if rom.size then lines[#lines + 1] = tr("Tamanho:") .. " " .. string.format("%d bytes", rom.size) end
    for _, k in ipairs({ "crc32", "md5", "sha1" }) do
      if rom[k] then lines[#lines + 1] = U.upper(k) .. ": " .. rom[k] end
    end
    if r.similar then lines[#lines + 1] = tr("Você tem:") .. " " .. r.similar end
    if t.page_url and t.page_url ~= "" then lines[#lines + 1] = tr("Página:") .. " " .. t.page_url end
    App.show_dialog({ title = (t.title or t.id) .. " (" .. sysname(r.sys) .. ")", kind = "info", body = table.concat(lines, "\n") })
  end
end

local function switch(scr, d)
  state.tab = (state.tab - 1 + d) % #TABS + 1
  scr.sel, scr.scroll = 1, 0
  to_items(scr)
end

local function cur_other(scr)
  local it = scr.items[scr.sel]
  return state.tab == 3 and it and it.ref and it.ref.state == "chd_verify" and it.ref or nil
end

function M.open()
  if not C.KNULLI and not os.getenv("PORTHUB_ROMTRANS_ROOT") then
    App.toast(L("Disponível só no Knulli."), "warn"); return
  end
  RT.app_setup()
  App.push("infolist", {
    title = L("Traduções de ROMs"),
    sub = sub_line,
    empty = tr("Aperte X para procurar."),
    load = function(scr)
      hook(scr)
      attach(scr)
      if busy_op(RT.job) then
        scr.saw_busy = true
        if state.res then to_items(scr) end
      elseif RT.job then
        scr.loading = tr(OP_LABEL[RT.job.op] or "Trabalhando")
      elseif state.res then
        to_items(scr)
      else
        scan(scr, true)
      end
    end,
    keys = {
      { key = "a", label = L("Detalhes"), enabled = function(scr) return scr.items[scr.sel] ~= nil end,
        fn = function(scr, it) details(scr, it) end },
      { key = "x", label = L("Traduzir"), enabled = function(scr) return state.tab == 1 and scr.items[scr.sel] ~= nil end,
        fn = function(scr, it) translate(scr, it and it.ref) end },
      { key = "x", label = L("Verificar"), enabled = function(scr) return cur_other(scr) ~= nil end,
        fn = function(scr) verify_chd(scr, cur_other(scr)) end },
      { key = "x", label = L("Traduções aplicadas"), enabled = function() return state.tab == 2 end,
        fn = function(scr) applied_hook(scr).open() end },
      { key = "select", label = L("Recuperar original"),
        enabled = function(scr) local it = scr.items[scr.sel]; return state.tab == 2 and it ~= nil and it.ref.rec ~= nil end,
        fn = function(scr, it) undo(scr, it and it.ref) end },
      { key = "select", label = L("Pasta de trabalho"), enabled = function() return state.tab ~= 2 end,
        fn = function(scr) work_dir_dialog(scr) end },
      { key = "y", label = L("Procurar de novo"), fn = function(scr) scan(scr, true) end },
      { key = "l1", label = "", fn = function(scr) switch(scr, -1) end },
      { key = "r1", label = L("Aba"), fn = function(scr) switch(scr, 1) end },
    },
  })
end

return M
