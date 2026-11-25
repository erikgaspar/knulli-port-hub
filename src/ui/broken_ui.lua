-- =============================================================================
--  Knulli Port Hub: "Itens escondidos" (Configuracoes > Downloads)
--  Itens do catalogo com download quebrado (core/broken.lua): motivo, quando
--  falhou, ultima verificacao; A = detalhes (reativar / verificar este),
--  Y = verificar todos agora.
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local T = require("ui.theme")
local B = require("core.broken")
local Clock = require("core.clock")

local M = {}

local function tr(s) return I18N.tr(s) end
local function Catalog() return require("core.catalog") end

local function day(s)
  local y, m, d = tostring(s or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then return nil end
  return Clock.date(os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }), true)
end

function M.checked_label(mark)
  local t = B.last_checked(mark)
  if not t then return tr(L("ainda não verificado")) end
  return Clock.datetime(t, true)
end

local function since_label(m)
  return day(m.date) or (m.t and Clock.date(m.t, true)) or "?"
end

--- texto curto do item na lista
function M.sub(h)
  local m = h.mark
  return tr(B.reason_text(m)) .. "  •  " .. tr(L("desde ")) .. since_label(m)
    .. "  •  " .. tr(L("verificado: ")) .. M.checked_label(m)
end

local function after_check(scr, restored, nchk, nnet, single)
  if #restored > 0 then
    pcall(Catalog().reapply)
    App.on_catalog_changed()
  end
  if scr and scr.p and scr.p.load then scr.loading = nil; scr.p.load(scr) end
  local msg
  if nchk == 0 and nnet > 0 then
    msg = L("Sem resposta do servidor (verifique o Wi-Fi). Nada foi mudado.")
    App.toast(tr(msg), "warn")
    return
  end
  if #restored > 0 then
    for _, p in ipairs(restored) do App.toast(p.name .. tr(L(" voltou a ficar disponível.")), "ok") end
    -- o aviso na Central nao precisa repetir o que ja apareceu aqui
    B.restored = {}
  else
    App.toast(single and tr(L("Continua sem funcionar. O item segue escondido."))
      or string.format(tr(L("%d verificado(s): continuam sem funcionar.")), nchk), "info")
  end
end

local function run_check(scr, list, single)
  if B.checking then App.toast(tr(L("Já existe uma verificação em andamento.")), "info"); return end
  if scr then scr.loading = tr(L("Verificando os links...")) end
  B.recheck(list, true, function(restored, nchk, nnet) after_check(scr, restored, nchk, nnet, single) end)
end

local function details(scr, h)
  local p, m = h.port, h.mark
  local lines = {
    tr(L("Motivo: ")) .. tr(B.reason_text(m)),
    tr(L("Falhou em: ")) .. since_label(m) .. (m.catalog and ("  (" .. tr(L("marcado no catálogo do Knulli Port Hub")) .. ")") or ""),
    tr(L("Última verificação: ")) .. M.checked_label(m),
  }
  if m.note and m.note ~= "" then lines[#lines + 1] = m.note end
  if m.detail and m.detail ~= "" then lines[#lines + 1] = "(" .. m.detail .. ")" end
  lines[#lines + 1] = tr(L("Link: ")) .. (#(p.download_url or "") > 70 and (p.download_url:sub(1, 67) .. "...") or (p.download_url or ""))
  lines[#lines + 1] = ""
  lines[#lines + 1] = m.kind == "package"
    and tr(L("O hub verifica 1 vez por dia, sem baixar o jogo: se o arquivo do servidor mudar (ou o link no catálogo), o item volta sozinho."))
    or tr(L("O hub verifica 1 vez por dia, sem baixar o jogo: se o link voltar a responder com o arquivo (ou mudar no catálogo), o item volta sozinho."))
  App.show_dialog({ title = p.name, kind = "info", body = table.concat(lines, "\n"),
    buttons = {
      { label = L("REATIVAR"), fn = function()
          B.clear(p, "user")
          pcall(Catalog().reapply)
          App.on_catalog_changed()
          if scr and scr.p and scr.p.load then scr.p.load(scr) end
          App.toast(p.name .. tr(L(" voltou para a Central.")), "ok")
        end },
      { label = L("VERIFICAR AGORA"), fn = function() run_check(scr, { h }, true) end },
      { label = L("VOLTAR") },
    } })
end

--- lista dos escondidos (para outras telas)
function M.hidden() return Catalog().hidden or {} end

function M.count_label()
  local n = #M.hidden()
  if n == 0 then return tr(L("nenhum")) end
  return string.format(tr(L("%d item(ns)")), n)
end

function M.open()
  App.push("infolist", {
    title = L("Itens escondidos"),
    sub = function(scr)
      local n = #(scr.items or {})
      return n == 0 and tr(L("Downloads quebrados")) or string.format(tr(L("%d com download quebrado")), n)
    end,
    empty = L("Nenhum item escondido. Quando o download de um item do catálogo não funciona (link quebrado ou pacote inválido), ele sai da Central e aparece aqui."),
    reload_on_resume = true,
    load = function(scr)
      local items = {}
      for _, h in ipairs(M.hidden()) do
        local m = h.mark
        items[#items + 1] = { tag = m.kind == "package" and tr(L("PACOTE")) or tr(L("LINK")),
          tagc = m.kind == "package" and T.c.orange or T.c.red,
          text = h.port.name .. (m.catalog and ("  •  " .. tr(L("catálogo"))) or ""),
          sub = M.sub(h), h = h,
          on_a = function(s, it) details(s, it.h) end }
      end
      scr.items = items
      if scr.sel and scr.sel > #items then scr.sel = math.max(1, #items) end
    end,
    keys = {
      { key = "x", label = L("Verificar agora"), enabled = function(scr) return #(scr.items or {}) > 0 and not B.checking end,
        fn = function(scr) run_check(scr, M.hidden(), false) end },
    },
  })
end

return M
