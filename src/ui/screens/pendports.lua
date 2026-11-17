-- =============================================================================
--  Meus Ports > "arquivos prontos para instalar"
--  Arquivos de port (.zip/.rar/.7z, inclusive em partes) soltos na pasta de
--  ports, como os baixados do Telegram. A instala um, Y instala todos (vao para
--  a Central de Downloads, um de cada vez). Senhas dos grupos, partes, origem e
--  capa do pacote: o instalador cuida (core/archives.lua, core/installer.lua).
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local T = require("ui.theme")
local G = require("ui.gfx")
local U = require("lib.util")
local C = require("config")
local Icons = require("ui.icons")
local PP = require("core.pendports")
local Downloads = require("core.downloads")

local S = {}
local TOP, RH = 84, 52

function S:enter()
  self.sel, self.scroll = 1, 0
  PP.scan()
end

function S:resume()
  PP.scan()
  self.sel = U.clamp(self.sel or 1, 1, math.max(1, #PP.list))
end

--- uma instalacao terminou com esta tela aberta: atualiza a lista
--- (o arquivo instalado sai da pasta ports)
function S:update()
  local busy = require("core.installer").busy()
  if self.was_busy and not busy then
    PP.scan()
    self.sel = U.clamp(self.sel or 1, 1, math.max(1, #PP.list))
  end
  self.was_busy = busy
end

local function queued(it) return Downloads.pending("file:" .. it.path) end

function S:draw()
  G.header(L("Prontos para instalar"), string.format(I18N.tr(L("%d arquivo(s)")), #PP.list))
  G.text_fit(T.f.small, L("Arquivos de port na pasta ") .. C.PORTS_DIR .. L(" (ex.: baixados do Telegram)."), 16, 54, T.W - 32, T.c.dim)
  local list = PP.list
  if #list == 0 then
    G.text(T.f.h3, L("Nenhum arquivo de port na pasta ports."), 0, 200, T.c.dim, "center", T.W)
    G.text(T.f.small, L("Copie o .zip, .rar, .7z ou .tar do port para a pasta ports e volte aqui."), 30, 236, T.c.faint, "center", T.W - 60)
  end
  local vis = math.floor((436 - TOP) / (RH + 6))
  if self.sel <= self.scroll then self.scroll = self.sel - 1 elseif self.sel > self.scroll + vis then self.scroll = self.sel - vis end
  for i = self.scroll + 1, math.min(#list, self.scroll + vis) do
    local it = list[i]
    local on = i == self.sel
    local pal, x, y, w, h = G.card(14, TOP + (i - self.scroll - 1) * (RH + 6), T.W - 28, RH, on, G.focus_k("pp" .. i, on), 8)
    Icons.draw("download", x + 12, y + 12, G.ink(T.c.yellow, pal), 28 / 24)
    local right = x + w - 10
    if queued(it) then
      local tw = T.f.pix8:getWidth(I18N.tr(L("NA FILA"))) + 12
      G.tag(L("NA FILA"), right - tw, y + 8, G.ink(T.c.yellow, pal), T.c.bg0, T.f.pix8)
      right = right - tw - 8
    end
    G.text_fit(T.f.bodyb, it.name, x + 52, y + 6, right - x - 60, pal.text)
    local sub = (it.kind or ""):upper():gsub("ZIPSPLIT", "ZIP"):gsub("ZIPSPAN", "ZIP") .. "  •  " .. U.format_bytes(it.size or 0)
    if it.parts > 1 then sub = sub .. "  •  " .. string.format(I18N.tr(L("%d partes")), it.parts) end
    G.text_fit(T.f.small, sub, x + 52, y + 29, w - 64, pal.dim)
  end
  G.hints({ { "a", L("Instalar") }, { "y", L("Instalar todos") }, { "b", L("Voltar") } })
end

local function confirm_all()
  local n = 0
  for _, it in ipairs(PP.list) do if not queued(it) then n = n + 1 end end
  if n == 0 then App.toast(L("Todos já estão na fila."), "info"); return end
  App.show_dialog({ title = L("Instalar todos?"), kind = "info",
    body = string.format(I18N.tr(L("%d arquivo(s) vão para a Central de Downloads e serão instalados um de cada vez.")), n)
      .. L("\n\nSenhas dos grupos e arquivos em partes são tratados sozinhos. Depois de cada instalação bem-sucedida, o arquivo compactado é excluído."),
    buttons = {
      { label = L("INSTALAR TODOS"), fn = function()
        for _, it in ipairs(PP.list) do if not queued(it) then PP.install(it) end end
      end },
      { label = L("CANCELAR") },
    } })
end

function S:action(act)
  local list = PP.list
  if act == "b" then App.pop(); return end
  if #list == 0 then return end
  if act == "up" then self.sel = math.max(1, self.sel - 1)
  elseif act == "down" then self.sel = math.min(#list, self.sel + 1)
  elseif act == "y" then confirm_all()
  elseif act == "a" then
    local it = list[self.sel]
    if queued(it) then App.open_downloads(false); return end
    App.show_dialog({ title = L("Instalar como port?"), kind = "info",
      body = it.name .. "  (" .. U.format_bytes(it.size or 0) .. ")"
        .. (it.parts > 1 and string.format(I18N.tr(L("\nArquivo em %d partes: todas serão usadas, como no PC.")), it.parts) or "")
        .. "\n\n" .. L("INSTALAR COMO PORT: instala em ") .. C.PORTS_DIR .. L(" com as verificações da loja (script .sh, sem pastas duplicadas).\n\n")
        .. L("Após a instalação bem-sucedida, o arquivo compactado será excluído."),
      buttons = {
        { label = L("INSTALAR"), fn = function() PP.install(it) end },
        { label = L("CANCELAR") },
      } })
  end
end

return S
