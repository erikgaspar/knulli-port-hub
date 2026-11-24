-- =============================================================================
--  Tela "Apps do Knulli" (Knulli App Store integrada) - usa a lista padrao
--  (infolist). A: detalhes | X: instalar/atualizar | Y: remover |
--  SELECT: reparar | R1: abrir a Knulli App Store completa | B: voltar
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local T = require("ui.theme")
local U = require("lib.util")
local C = require("config")
local K = require("core.kstore")

local M = {}

local ST = {
  none = { L("NÃO INSTALADO"), "dim" },
  installed = { L("INSTALADO"), "green" },
  update = { L("ATUALIZAÇÃO"), "yellow" },
}

local function to_items(scr)
  local apps, err = K.list(true)
  if not apps then scr.items = {}; scr.p.empty = err; return end
  local items = {}
  for _, a in ipairs(apps) do
    local st = ST[a.status]
    local ver = a.status == "update" and (a.installed_version .. " → " .. a.version)
      or (a.status == "installed" and a.installed_version or a.version)
    items[#items + 1] = { tag = I18N.tr(st[1]), tagc = T.c[st[2]] or T.c.dim, text = a.name,
      sub = (K.TYPE[a.type] and I18N.tr(K.TYPE[a.type]) or (a.type or "")) .. "  •  v" .. ver .. "  •  " .. a.summary,
      ref = a,
      detail = function()
        local t = { a.summary, "", I18N.tr(L("Versão no catálogo: ")) .. a.version }
        if a.installed_version then t[#t + 1] = I18N.tr(L("Versão instalada: ")) .. a.installed_version end
        t[#t + 1] = I18N.tr(L("Situação na loja: ")) .. (a.review == "experimental" and I18N.tr(L("experimental")) or a.review)
        if a.license ~= "" then t[#t + 1] = I18N.tr(L("Licença: ")) .. a.license end
        if a.repository ~= "" then t[#t + 1] = a.repository end
        for i, n in ipairs(a.notes) do
          if i > 2 then break end
          t[#t + 1] = ""; t[#t + 1] = (#n > 420 and (n:sub(1, 417) .. "...") or n)
        end
        return table.concat(t, "\n")
      end }
  end
  scr.items = items
  local n_inst, n_upd = 0, 0
  for _, a in ipairs(apps) do
    if a.status ~= "none" then n_inst = n_inst + 1 end
    if a.status == "update" then n_upd = n_upd + 1 end
  end
  scr.p.sub = string.format(I18N.tr(L("%d apps  •  %d instalados  •  %d com atualização")), #apps, n_inst, n_upd)
  scr.sel = math.min(scr.sel or 1, math.max(1, #items))
end

local function run(scr, app, action)
  local cmd, err = K.command(app, action)
  if not cmd then App.show_dialog({ title = L("Não foi possível começar"), kind = "error", body = tostring(err) }); return end
  local verb = ({ install = L("Instalando "), update = L("Atualizando "), repair = L("Reparando "), uninstall = L("Removendo ") })[action]
  scr.loading = I18N.tr(verb) .. app.name .. "..."
  require("core.shjob").start({ cmd }, function(res, terr)
    scr.loading = nil
    local r = res and res[1]
    local ok = r and r.rc == 0
    to_items(scr)
    if ok then
      App.toast(app.name .. ": " .. I18N.tr(({ install = L("instalado"), update = L("atualizado"), repair = L("reparado"), uninstall = L("removido") })[action]), "ok")
    else
      App.show_dialog({ title = L("A Knulli App Store não concluiu"), kind = "error",
        body = (r and r.out ~= "" and r.out or tostring(terr or "?"))
          .. "\n\n" .. L("Nada foi alterado pela metade: o instalador da loja desfaz a operação em caso de erro. Registro: ")
          .. K.STATE .. "/hub-" .. action .. ".log" })
    end
  end)
end

local function confirm(scr, app, action)
  local titles = { install = L("Instalar app?"), update = L("Atualizar app?"), repair = L("Reparar app?"), uninstall = L("Remover app?") }
  local labels = { install = L("INSTALAR"), update = L("ATUALIZAR"), repair = L("REPARAR"), uninstall = L("REMOVER") }
  local body = app.name .. "  (v" .. app.version .. ")\n" .. app.summary
  if action == "uninstall" then
    body = body .. "\n\n" .. L("Remove só os arquivos que o app instalou e devolve os originais que ele trocou. Dados declarados pelo app são mantidos.")
  else
    body = body .. "\n\n" .. L("Todos os apps da Knulli App Store são experimentais. Precisa de internet; a instalação é feita pelo instalador da própria loja.")
  end
  App.show_dialog({ title = titles[action], kind = action == "uninstall" and "warn" or "info", body = body,
    buttons = { { label = labels[action], danger = action == "uninstall", fn = function() run(scr, app, action) end },
      { label = L("CANCELAR") } }, sel = action == "uninstall" and 2 or 1 })
end

--- abre a Knulli App Store completa (o hub fecha e reabre depois)
function M.open_store()
  if not U.file_size(C.PORTS_DIR .. "/" .. K.SCRIPT) then
    App.toast(L("O atalho da Knulli App Store não está na pasta de ports."), "warn"); return
  end
  App.launch_port({ id = "knulli-app-store", name = "Knulli App Store", script_override = K.SCRIPT })
end

function M.open()
  if not K.available() then
    App.show_dialog({ title = L("Knulli App Store não instalada"), kind = "info",
      body = L("Os apps do Knulli vêm da Knulli App Store (comunidade). Instale-a pelo site do projeto:\n") .. K.REPO
        .. L("\n\nDepois de instalada, os apps aparecem aqui.") })
    return
  end
  App.push("infolist", { title = L("Apps do Knulli"), sub = "", reload_on_resume = true,
    empty = L("Nenhum app na lista da Knulli App Store."),
    load = function(scr) to_items(scr) end,
    keys = {
      { key = "x", label = L("Instalar / atualizar"), fn = function(scr, it)
        local a = it and it.ref; if not a then return end
        if a.status == "installed" then App.toast(a.name .. I18N.tr(L(" já está na versão mais nova. SELECT repara.")), "info"); return end
        confirm(scr, a, a.status == "update" and "update" or "install")
      end },
      { key = "y", label = L("Remover"), fn = function(scr, it)
        local a = it and it.ref; if not a then return end
        if a.status == "none" then App.toast(a.name .. I18N.tr(L(" não está instalado.")), "info"); return end
        confirm(scr, a, "uninstall")
      end },
      { key = "select", label = L("Reparar"), fn = function(scr, it)
        local a = it and it.ref; if not a or a.status == "none" then return end
        confirm(scr, a, "repair")
      end },
      { key = "r1", label = L("Loja completa"), fn = function() M.open_store() end },
    } })
end

return M
