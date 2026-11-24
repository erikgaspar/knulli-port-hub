-- =============================================================================
--  Ferramentas do Knulli (menu principal do Knulli Port Hub)
--  Lista vertical com as ferramentas proprias da adaptacao para o Knulli.
-- =============================================================================
local L = require("lib.i18n").L

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

function M.open()
  local b = {}
  if has("ui.libtools_ui") then
    b[#b + 1] = { label = L("Biblioteca: manutenção"), sub = L("Faxina das listas, imagens automáticas, multidisco e vídeos"),
      fn = function() call("ui.libtools_ui", "open") end }
  end
  b[#b + 1] = { label = L("Gerenciador de espaço do cartão"), sub = L("Maiores jogos × vezes jogado; apagar ROMs sem perder saves"),
    fn = function() call("ui.settings_extra", "space_manager") end }
  if App.screens.fullbackup then
    b[#b + 1] = { label = L("Backup completo dos saves"), sub = L("Saves de todos os sistemas e ports num arquivo"),
      fn = function() App.push("fullbackup") end }
  end
  if App.screens.monitor then
    b[#b + 1] = { label = L("Monitor do console"), sub = L("Temperatura, CPU, RAM e bateria ao vivo"),
      fn = function() App.push("monitor") end }
  end
  if App.screens.bluetooth then
    b[#b + 1] = { label = L("Controle Bluetooth"), sub = L("Procurar, parear e conectar controles"),
      fn = function() App.push("bluetooth") end }
  end
  if has("ui.perf_ui") then
    b[#b + 1] = { label = L("Relatórios de compatibilidade"), sub = L("Como cada port rodou no RG35XXH; exportar para o catálogo"),
      fn = function() call("ui.perf_ui", "open_reports") end }
  end
  App.show_dialog({ title = L("Ferramentas do Knulli"), kind = "info", list = true,
    body = L("Escolha uma ferramenta:"), buttons = b })
end

return M
