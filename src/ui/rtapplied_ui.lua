-- =============================================================================
--  Traducoes de ROMs: "Traduções aplicadas" (backups das ROMs originais)
--  Para cada jogo traduzido pelo app: sistema, data, patch, tamanho e estado do
--  backup (guardado / excluido / sumiu), com as acoes
--    - Recuperar versao original (o "desfazer": confirma antes)
--    - Marcar como testado (funcionou)
--    - Excluir backup (apaga so o arquivo da original; o traduzido fica)
--  e "Excluir backups de todos os testados" (em lote, com o total liberado).
--  Tema Premium: cartoes com a capa do jogo (ui/premium/rtapplied.lua); os
--  outros temas: lista (ui/screens/infolist.lua).
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local U = require("lib.util")
local T = require("ui.theme")
local RT = require("core.romtrans")

local M = {}

local function tr(s) return I18N.tr(L(s)) end
local function fmt(s, ...) return string.format(tr(s), ...) end

M.on_change = nil   -- fn(kind) chamado depois de desfazer/excluir (tela de traducoes)

local function changed(kind) if M.on_change then pcall(M.on_change, kind) end end

local function sysname(s) return U.upper(s or "") end

--- "PO.B.R.E v1.0 (IPS)"
function M.patch_label(rec)
  local s = (rec.group and rec.group ~= "") and rec.group or tr("tradução")
  if rec.version and rec.version ~= "" then s = s .. " v" .. rec.version end
  if rec.format and rec.format ~= "" then s = s .. " (" .. U.upper(rec.format) .. ")" end
  return s
end

--- "24/11/2026"
function M.date_label(d)
  local y, m, dd = tostring(d or ""):match("^(%d+)-(%d+)-(%d+)")
  if not y then return tostring(d or "?") end
  if I18N.lang == "pt-BR" or I18N.lang == "ru" then return dd .. "/" .. m .. "/" .. y end
  return y .. "-" .. m .. "-" .. dd
end

--- rotulo e cor (chave de cor) do estado do backup
function M.state_label(x)
  if x.rom_missing then return L("SEM A ROM"), "red" end
  if x.state == "kept" then return L("BACKUP GUARDADO"), "accent" end
  if x.state == "deleted" then return L("BACKUP EXCLUÍDO"), "dim" end
  return L("BACKUP SUMIU"), "warn"
end

M.STATE_WORD = { kept = L("guardado"), deleted = L("excluído"), missing = L("sumiu") }

function M.size_label(x)
  if x.state == "kept" then return U.format_bytes(x.size or 0) end
  if x.state == "deleted" and x.rec.backup_freed then return fmt("liberou %s", U.format_bytes(x.rec.backup_freed)) end
  return ""
end

--- jogos testados com backup guardado (e a ROM traduzida presente)
function M.tested_kept(list)
  local out, total = {}, 0
  for _, x in ipairs(list or {}) do
    if x.tested and x.state == "kept" and not x.rom_missing then out[#out + 1] = x; total = total + (x.size or 0) end
  end
  return out, total
end

-- ---------------------------------------------------------------------------
-- acoes
-- ---------------------------------------------------------------------------
local function do_undo(x, force, done)
  if RT.job then App.toast(L("Espere a tarefa em andamento terminar."), "warn"); return end
  App.toast(L("Recuperando a versão original..."), "info")
  local job = RT.run("undo", { key = x.key, force = force }, function(ok, res)
    if not ok then
      App.show_dialog({ title = L("A tarefa falhou"), kind = "error", body = tostring(res) })
      return
    end
    if res.need_force then
      App.show_dialog({ title = L("A ROM mudou"), kind = "warn",
        body = tr(res.reason or "") .. "\n\n" .. tr("Desfazer mesmo assim? O arquivo atual é apagado e a original volta."),
        buttons = { { label = L("DESFAZER"), danger = true, fn = function() do_undo(x, true, done) end },
          { label = L("CANCELAR") } }, sel = 2 })
      return
    end
    App.toast(L("Original devolvida."), "ok")
    if res.gl_note then
      App.show_dialog({ title = L("Original devolvida"), kind = "info",
        body = fmt("Lista de jogos não alterada: %s.", tostring(res.gl_note)) })
    end
    changed("undo")
    if done then done() end
  end)
  if not job then App.toast(L("Espere a tarefa em andamento terminar."), "warn") end
end

--- confirmacao antes de recuperar a original
function M.restore(x, done)
  if x.state == "deleted" then
    App.show_dialog({ title = L("Não dá para recuperar"), kind = "info",
      body = fmt("O backup da ROM original foi excluído em %s. A versão traduzida fica como está.",
        M.date_label(x.rec.backup_deleted)) })
    return
  end
  if x.state ~= "kept" then
    App.show_dialog({ title = L("Sem a cópia da original"), kind = "warn",
      body = fmt("A cópia da ROM original não está mais em %s. Não dá para desfazer; você pode só tirar o jogo do registro.",
        tostring(x.rec.backup)) })
    return
  end
  App.show_dialog({ title = L("Recuperar a versão original?"), kind = "warn", list = true,
    body = (x.name or x.rel) .. " (" .. sysname(x.sys) .. ")\n\n"
      .. fmt("A ROM original volta de %s para o lugar da traduzida e o \" (PT-BR)\" sai do nome.", tostring(x.rec.backup))
      .. "\n" .. tr("A versão traduzida é apagada (dá para traduzir de novo depois)."),
    buttons = { { label = L("RECUPERAR ORIGINAL"), danger = true, fn = function() do_undo(x, false, done) end },
      { label = L("CANCELAR") } }, sel = 2 })
end

--- confirmacao antes de excluir o backup de um jogo
function M.delete(x, done)
  if x.state ~= "kept" then return end
  if x.rom_missing then
    App.show_dialog({ title = L("O backup é a única cópia"), kind = "warn",
      body = tr("A ROM traduzida não está no cartão; o backup é a única cópia do jogo e não foi apagado.") })
    return
  end
  App.show_dialog({ title = L("Excluir o backup?"), kind = "warn", list = true,
    body = (x.name or x.rel) .. " (" .. sysname(x.sys) .. ")\n\n"
      .. fmt("A ROM original será apagada de vez; não dá para desfazer a tradução depois. Libera %s.", U.format_bytes(x.size or 0))
      .. "\n" .. tr("O jogo traduzido continua no lugar."),
    buttons = { { label = L("EXCLUIR BACKUP"), danger = true, fn = function()
      local r, err = RT.delete_backup(x.key)
      if not r then App.show_dialog({ title = L("A tarefa falhou"), kind = "error", body = tostring(err) }); return end
      App.toast(fmt("Backup excluído. %s liberados.", U.format_bytes(r.freed)), "ok")
      changed("delete")
      if done then done() end
    end }, { label = L("CANCELAR") } }, sel = 2 })
end

--- em lote: todos os testados com backup guardado
function M.delete_tested(list, done)
  local sel, total = M.tested_kept(list)
  if #sel == 0 then
    App.show_dialog({ title = L("Nenhum jogo testado"), kind = "info",
      body = tr("Marque como testado (Detalhes > \"Testei e funcionou\") os jogos traduzidos que já conferiu; depois dá para excluir os backups deles de uma vez.") })
    return
  end
  local names = {}
  for i, x in ipairs(sel) do
    if i > 6 then names[#names + 1] = fmt("... e mais %d", #sel - 6); break end
    names[#names + 1] = "• " .. (x.name or x.rel) .. " (" .. sysname(x.sys) .. ")  " .. U.format_bytes(x.size or 0)
  end
  App.show_dialog({ title = L("Excluir backups dos testados?"), kind = "warn", list = true,
    body = fmt("%d jogo(s) marcados como testados. As ROMs originais serão apagadas de vez; não dá para desfazer essas traduções depois. Libera %s.",
      #sel, U.format_bytes(total)) .. "\n\n" .. table.concat(names, "\n"),
    buttons = { { label = L("EXCLUIR BACKUPS"), danger = true, fn = function()
      local keys = {}
      for _, x in ipairs(sel) do keys[#keys + 1] = x.key end
      local freed, n, errs = RT.delete_backups(keys)
      if #errs > 0 then
        App.show_dialog({ title = L("Alguns backups não foram excluídos"), kind = "warn",
          body = fmt("%d excluído(s), %s liberados.", n, U.format_bytes(freed)) .. "\n\n" .. table.concat(errs, "\n") })
      else
        App.toast(fmt("%d backup(s) excluído(s). %s liberados.", n, U.format_bytes(freed)), "ok")
      end
      changed("delete")
      if done then done() end
    end }, { label = L("CANCELAR") } }, sel = 2 })
end

--- detalhes de um jogo com as acoes
function M.details(x, done)
  local rec = x.rec
  local lines = {
    tr("Sistema:") .. " " .. sysname(x.sys) .. "  •  " .. tr("Traduzido em:") .. " " .. M.date_label(rec.date),
    tr("Patch:") .. " " .. tostring(rec.title or "") .. " — " .. M.patch_label(rec),
    tr("Arquivo:") .. " " .. tostring(rec.rel) .. (rec.kind == "chd" and ("  →  " .. fmt("faixa %d", rec.track or 1)) or ""),
    tr("Backup:") .. " " .. tr(M.STATE_WORD[x.state] or "") .. ((x.size and ("  •  " .. U.format_bytes(x.size))) or ""),
  }
  if x.state == "kept" then lines[#lines + 1] = tostring(rec.backup) end
  if x.state == "deleted" then lines[#lines + 1] = fmt("Excluído em %s: não dá mais para recuperar a original.", M.date_label(rec.backup_deleted)) end
  if x.tested then lines[#lines + 1] = fmt("Testado em %s.", M.date_label(x.tested)) end
  local buttons = {}
  if x.state == "kept" then
    buttons[#buttons + 1] = { label = L("RECUPERAR VERSÃO ORIGINAL"), sub = L("Volta a ROM original e tira o \" (PT-BR)\" do nome"),
      fn = function() M.restore(x, done) end }
    buttons[#buttons + 1] = { label = x.tested and L("TESTADO: SIM") or L("TESTEI E FUNCIONOU"),
      sub = x.tested and L("Desmarcar") or L("Marca para excluir o backup em lote depois"),
      fn = function() RT.set_tested(x.key, not x.tested); if done then done() end end }
    buttons[#buttons + 1] = { label = L("EXCLUIR BACKUP"), danger = true,
      sub = fmt("Libera %s; depois não dá para recuperar a original", U.format_bytes(x.size or 0)),
      fn = function() M.delete(x, done) end }
  elseif x.state == "deleted" then
    buttons[#buttons + 1] = { label = L("RECUPERAR VERSÃO ORIGINAL"), disabled = true,
      sub = L("Indisponível: o backup da original foi excluído"), fn = function() M.restore(x, done) end }
  else
    buttons[#buttons + 1] = { label = L("TIRAR DO REGISTRO"), danger = true,
      sub = L("A cópia da original sumiu; o jogo continua como está"),
      fn = function() RT.forget(x.key); changed("forget"); if done then done() end end }
  end
  buttons[#buttons + 1] = { label = L("VOLTAR") }
  App.show_dialog({ title = (x.name or x.rel), kind = "info", list = true, body = table.concat(lines, "\n"),
    buttons = buttons, sel = x.state == "deleted" and #buttons or 1 })
end

-- ---------------------------------------------------------------------------
-- abrir
-- ---------------------------------------------------------------------------
function M.summary(list, total)
  local n = #list
  return fmt("%d jogo(s)  •  backups ocupam %s", n, U.format_bytes(total or 0))
end

function M.open()
  if not RT.cfg or RT.cfg.conf_dir == "/tmp/porthub-conf" then RT.app_setup() end
  if T.style and T.style.layout == "premium" then
    App.screens.prtapplied = App.screens.prtapplied or require("ui.premium.rtapplied")
    App.push("prtapplied")
    return
  end
  local function load(scr)
    local list, total = RT.applied()
    scr.rt_list, scr.rt_total = list, total
    local items = {}
    for _, x in ipairs(list) do
      local st, col = M.state_label(x)
      local sz = M.size_label(x)
      local tc = ({ accent = T.c.green, dim = T.c.faint, warn = T.c.orange, red = T.c.red })[col]
      items[#items + 1] = { tag = st, tagc = tc, text = (x.name or x.rel) .. " (" .. sysname(x.sys) .. ")",
        sub = M.date_label(x.rec.date) .. "  •  " .. M.patch_label(x.rec) .. (sz ~= "" and ("  •  " .. sz) or "")
          .. (x.tested and ("  •  " .. tr("testado")) or ""), ref = x }
    end
    scr.items = items
    scr.p.sub = M.summary(list, total)
    scr.sel = math.max(1, math.min(scr.sel or 1, #items))
  end
  App.push("infolist", { title = L("Traduções aplicadas"), sub = "",
    empty = L("Nenhuma ROM traduzida pelo app ainda."),
    load = load,
    keys = {
      { key = "a", label = L("Detalhes"), enabled = function(scr) return scr.items[scr.sel] ~= nil end,
        fn = function(scr, it) M.details(it.ref, function() load(scr) end) end },
      { key = "x", label = L("Excluir backups dos testados"),
        fn = function(scr) M.delete_tested(scr.rt_list, function() load(scr) end) end },
    } })
end

return M
