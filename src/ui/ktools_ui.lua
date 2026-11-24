-- =============================================================================
--  Ferramentas do Knulli (menu principal do Knulli Port Hub)
--  Lista com rolagem (infolist): cada item abre a sua ferramenta com B (acao "a").
--  Ferramentas cujo arquivo nao existe nesta versao ficam de fora.
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local T = require("ui.theme")

local M = {}

local function has(mod)
  return love.filesystem.getInfo(mod:gsub("%.", "/") .. ".lua") ~= nil
end

local function call(mod, fn, ...)
  local ok, m = pcall(require, mod)
  if not ok or type(m[fn]) ~= "function" then
    App.toast(L("Esta ferramenta não está disponível nesta versão."), "warn")
    return
  end
  m[fn](...)
end

local function entries()
  local e = {}
  local function add(cond, tag, text, sub, fn, id)
    if cond then e[#e + 1] = { id = id, tag = I18N.tr(tag), tagc = T.c.accent2, text = text, sub = sub, on_a = fn } end
  end
  add(true, L("ESPAÇO"), L("Gerenciador de espaço do cartão"), L("Maiores jogos × vezes jogado; apagar ROMs sem perder saves"),
    function() call("ui.settings_extra", "space_manager") end, "space")
  add(has("ui.chdconv_ui"), L("ESPAÇO"), L("Converter jogos para CHD"), L("Diminui jogos de CD (PS1, Sega CD, Dreamcast...)"),
    function() call("ui.chdconv_ui", "open") end, "chd")
  add(has("ui.romtrans_ui"), L("PT-BR"), L("Traduzir jogos (PT-BR)"), L("Procura patches de tradução para as suas ROMs e aplica"),
    function() call("ui.romtrans_ui", "open") end, "romtrans")
  add(has("ui.libtools_ui"), L("BIBLIOTECA"), L("Biblioteca: manutenção"), L("Faxina das listas, imagens automáticas, multidisco e vídeos"),
    function() call("ui.libtools_ui", "open") end, "library")
  add(App.screens.fullbackup ~= nil, L("SAVES"), L("Backup completo dos saves"), L("Saves de todos os sistemas e ports num arquivo"),
    function() App.push("fullbackup") end, "backup")
  add(has("ui.perf_ui"), L("DESEMPENHO"), L("Relatórios de compatibilidade"), L("Como cada port rodou no RG35XXH; exportar para o catálogo"),
    function() call("ui.perf_ui", "open_reports") end, "reports")
  add(App.screens.monitor ~= nil, L("SISTEMA"), L("Monitor do console"), L("Temperatura, CPU, RAM e bateria ao vivo"),
    function() App.push("monitor") end, "monitor")
  add(App.screens.bluetooth ~= nil, L("SISTEMA"), L("Controle Bluetooth"), L("Procurar, parear e conectar controles"),
    function() App.push("bluetooth") end, "bluetooth")
  return e
end

M.entries = entries

function M.open()
  -- Tema Premium: grade de cartoes (ui/premium/tools.lua); os outros temas: lista
  if T.style.layout == "premium" then
    App.screens.ptools = App.screens.ptools or require("ui.premium.tools")
    App.push("ptools")
    return
  end
  App.push("infolist", { title = L("Ferramentas do Knulli"), sub = "",
    empty = L("Nenhuma ferramenta disponível."),
    load = function(scr) scr.items = entries() end })
end

return M
