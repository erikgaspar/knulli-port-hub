-- =============================================================================
--  Traducoes de ROMs (so Knulli) - tela
--  M.open() abre a lista (ui/screens/infolist.lua) com tres abas (L1/R1):
--    1. Para os seus jogos : traducoes que casam com as suas ROMs (por hash)
--    2. Ja traduzidos      : as que o app aplicou (desfazer) e as ja em PT-BR
--    3. Outras traducoes   : do indice, para jogos que voce nao tem ou tem em
--                            outra versao (so informacao; nada de baixar ROM)
--  Botoes (acoes do app): "a" detalhes/traduzir, "x" traduzir, "y" procurar
--  de novo, "select" desfazer. A busca, a traducao e o desfazer rodam em
--  segundo plano (threads/romtrans_thread.lua); da para sair da tela.
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local U = require("lib.util")
local C = require("config")
local T = require("ui.theme")
local RT = require("core.romtrans")

local M = {}

local function tr(s) return I18N.tr(L(s)) end
local function fmt(s, ...) return string.format(tr(s), ...) end

local state = { res = nil, tab = 1 }
local TABS = { L("Para os seus jogos"), L("Já traduzidos"), L("Outras traduções") }

local OP_LABEL = { scan = L("Procurando traduções"), translate = L("Traduzindo"), undo = L("Desfazendo a tradução") }

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
    if not self.loading then return end
    if RT.job then
      local a, b = status_line(RT.job)
      self.loading = a
      self.status_sub = b
    else
      -- a tarefa era de outra abertura da tela (saiu e voltou): so atualiza
      self.loading, self.status_sub = nil, nil
      to_items(self)
    end
  end
end

local function run(scr, op, params, on_ok)
  if RT.job then
    App.toast(L("Espere a tarefa em andamento terminar."), "warn")
    return false
  end
  scr.loading = tr(OP_LABEL[op] or "Trabalhando")
  scr.status_sub = nil
  attach(scr)
  local job = RT.run(op, params, function(ok, res)
    scr.loading = nil
    scr.status_sub = nil
    if not ok then
      App.show_dialog({ title = L("A tarefa falhou"), kind = "error", body = tostring(res) })
      return
    end
    on_ok(res)
  end)
  if not job then scr.loading = nil; App.toast(L("Espere a tarefa em andamento terminar."), "warn"); return false end
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
-- itens de cada aba
-------------------------------------------------------------------------------
local function match_detail(m)
  local t = m.t
  local lines = {
    tr("Jogo:") .. " " .. (m.name or "") .. " (" .. sysname(m.sys) .. ")",
    tr("Arquivo:") .. " " .. m.rel .. (m.inzip and ("  →  " .. m.inzip) or ""),
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
      items[#items + 1] = { tag = tag, tagc = tagc,
        text = (m.name or m.rel) .. " (" .. sysname(m.sys) .. ") — " .. tlabel(m.t),
        sub = m.rel .. (m.inzip and "  •  zip" or "") .. "  •  " .. U.upper(m.t.patch_format)
          .. (m.header and ("  •  " .. tr("sem header")) or ""),
        ref = m, kind = "match" }
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
      missing = { L("VOCÊ NÃO TEM"), T.c.faint }, no_system = { L("SEM O SISTEMA"), T.c.faint } }
    for _, o in ipairs(res.others or {}) do
      local tg = TAG[o.state] or TAG.missing
      local sub = tlabel(o.t) .. "  •  " .. tr(RT.status_label(o.t))
      if o.similar then sub = sub .. "  •  " .. tr("você tem:") .. " " .. o.similar end
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
-- acoes
-------------------------------------------------------------------------------
local function scan(scr, online)
  run(scr, "scan", { online = online }, function(res)
    state.res = res
    to_items(scr)
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
  local body = match_detail(m) .. "\n\n"
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
        if res.gl_note then note = note .. "\n" .. fmt("Lista de jogos não alterada: %s.", tostring(res.gl_note)) end
        if res.reg_err then note = note .. "\n" .. tostring(res.reg_err) end
        App.show_dialog({ title = L("Tradução aplicada"), kind = "info",
          body = (m.name or m.rel) .. "\n\n" .. note .. "\n\n" .. fmt("A original está em %s.", res.rec.backup)
            .. "\n\n" .. reload_es_note() })
      end)
    end }, { label = L("CANCELAR") } } })
end

local function do_undo(scr, x, force)
  run(scr, "undo", { key = x.key, force = force }, function(res)
    if res.need_force then
      App.show_dialog({ title = L("A ROM mudou"), kind = "warn",
        body = tr(res.reason or "") .. "\n\n" .. tr("Desfazer mesmo assim? O arquivo atual é apagado e a original volta."),
        buttons = { { label = L("DESFAZER"), danger = true, fn = function() do_undo(scr, x, true) end },
          { label = L("CANCELAR") } }, sel = 2 })
      return
    end
    local note = res.gl_note and ("\n" .. fmt("Lista de jogos não alterada: %s.", tostring(res.gl_note))) or ""
    App.toast(L("Original devolvida."), "ok")
    if note ~= "" then App.show_dialog({ title = L("Original devolvida"), kind = "info", body = note }) end
    scan(scr, false)   -- a ROM original volta para "Para os seus jogos"
  end)
end

local function undo(scr, x)
  if not x or not x.rec then return end
  if x.backup_missing then
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
  App.show_dialog({ title = L("Desfazer a tradução?"), kind = "warn",
    body = (x.name or x.rel) .. " (" .. sysname(x.sys) .. ")\n\n"
      .. fmt("A ROM original volta de %s para o lugar da traduzida e o \" (PT-BR)\" sai do nome.", tostring(x.rec.backup)),
    buttons = { { label = L("DESFAZER"), danger = true, fn = function() do_undo(scr, x, false) end },
      { label = L("CANCELAR") } }, sel = 2 })
end

local function details(scr, it)
  if not it then return end
  local r = it.ref
  if it.kind == "match" then
    translate(scr, r)
  elseif it.kind == "translated" then
    if r.rec then
      local rec = r.rec
      local body = table.concat({
        tr("Arquivo:") .. " " .. rec.sys .. "/" .. rec.rel .. (rec.inzip and ("  →  " .. rec.inzip) or ""),
        tr("Tradução:") .. " " .. tostring(rec.title) .. " — " .. tlabel(rec),
        fmt("traduzido em %s", rec.date or "?") .. (rec.header_removed and ("  •  " .. tr("header SMC retirado")) or ""),
        tr("Original guardada em:") .. " " .. tostring(rec.backup),
      }, "\n")
      App.show_dialog({ title = it.text, kind = "info", body = body,
        buttons = { { label = L("DESFAZER"), danger = true, fn = function() undo(scr, r) end }, { label = L("VOLTAR") } }, sel = 2 })
    else
      App.show_dialog({ title = it.text, kind = "info",
        body = tr("Este arquivo já é o resultado da tradução abaixo (traduzido fora do app):") .. "\n"
          .. (r.t.title or r.t.id) .. " — " .. tlabel(r.t) .. "\n\n" .. r.rel })
    end
  else
    local t = r.t
    local why = ({ other_version = tr("Você tem este jogo, mas em outra versão (o hash não confere). A tradução só funciona na versão exata abaixo."),
      ptbr_name = tr("Você tem um arquivo com nome de tradução para este jogo."),
      missing = tr("Você não tem este jogo nesta pasta."),
      no_system = fmt("Não há a pasta %s no cartão.", r.sys) })[r.state] or ""
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
      attach(scr)
      if RT.job then
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
      { key = "select", label = L("Desfazer"),
        enabled = function(scr) local it = scr.items[scr.sel]; return state.tab == 2 and it ~= nil and it.ref.rec ~= nil end,
        fn = function(scr, it) undo(scr, it and it.ref) end },
      { key = "y", label = L("Procurar de novo"), fn = function(scr) scan(scr, true) end },
      { key = "l1", label = "", fn = function(scr) switch(scr, -1) end },
      { key = "r1", label = L("Aba"), fn = function(scr) switch(scr, 1) end },
    },
  })
end

return M
