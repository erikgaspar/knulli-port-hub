-- =============================================================================
--  Tema Premium: "Traduções aplicadas" (tela "prtapplied")
--  Cartoes largos (2 colunas) com a capa do jogo (imagem do gamelist), sistema,
--  data, patch e etiquetas do backup. Topo: total ocupado pelos backups.
--    direcional: navegar | B (acao "a"): acoes do jogo | Y (acao "x"): excluir
--    backups dos testados | A (acao "b"): voltar
--  A logica (dialogos, desfazer, excluir) fica em ui/rtapplied_ui.lua.
-- =============================================================================
local L = require("lib.i18n").L
local U = require("lib.util")
local PS = require("ui.premium.style")
local PG = require("ui.premium.grid")
local RT = require("core.romtrans")
local RA = require("ui.rtapplied_ui")

local S = {}
local lg = love.graphics

local TOP = 40 + 44       -- cabecalho + faixa do resumo
local IMG = {}            -- caminho -> imagem (false = sem)

local function load_img(path)
  if not path then return nil end
  if IMG[path] == nil then
    IMG[path] = false
    local n = U.file_size(path)
    if n and n > 0 and n < 3 * 1024 * 1024 then
      local ok, img = pcall(function()
        local fd = love.filesystem.newFileData(U.read_file(path), path:match("([^/]+)$") or "img")
        return lg.newImage(love.image.newImageData(fd))
      end)
      if ok and img then img:setFilter("linear", "linear"); IMG[path] = img end
    end
  end
  return IMG[path] or nil
end

function S:enter()
  self.sel = self.sel or 1
  self:refresh()
end

function S:resume() self:refresh() end

function S:refresh()
  local list, total = RT.applied()
  self.list, self.total = list, total
  local c = PS.c()
  local imgs = {}
  local items = {}
  for _, x in ipairs(list) do
    if not imgs[x.sys] then imgs[x.sys] = RT.gl_images(x.sys) end
    local rec = x.rec
    local path = imgs[x.sys][rec.gl_rel or rec.rel] or imgs[x.sys][rec.rel]
    local st, col = RA.state_label(x)
    -- backup guardado: o tamanho vai na propria etiqueta (cabe o "TESTADO" do lado)
    if x.state == "kept" and not x.rom_missing then
      st = string.format(PS.tr(L("BACKUP %s")), U.format_bytes(x.size or 0))
    end
    local tags = { { st, c[col] or c.dim } }
    if x.tested then tags[#tags + 1] = { L("TESTADO"), c.accent } end
    items[#items + 1] = { name = x.name or x.rel, x = x, card_img = load_img(path),
      card_icon = "games",
      short = U.upper(x.sys or "") .. "  •  " .. RA.date_label(rec.date) .. "  •  " .. RA.patch_label(rec),
      card_tags = tags }
  end
  self.items = items
  self.ntested = #RA.tested_kept(list)
  self.sel = U.clamp(self.sel or 1, 1, math.max(1, #items))
end

function S:metrics()
  self.m = self.m or PG.metrics(20, TOP + 6, 600, PS.FOOT_Y - 8, true)
  return self.m
end

function S:update(dt)
  PG.update(self, #self.items, self.sel, self:metrics(), dt or 0)
end

function S:draw()
  local c = PS.c()
  PS.header(L("Traduções aplicadas"))
  -- resumo: total ocupado pelos backups
  local f = PS.font("b", 16)
  local sf = PS.font("r", 12)
  PS.text(f, U.format_bytes(self.total or 0), 20, 48, (self.total or 0) > 0 and c.text or c.dim)
  local tw = f:getWidth(U.format_bytes(self.total or 0))
  PS.fit(sf, string.format(PS.tr(L("em backups das ROMs originais  •  %d jogo(s) traduzido(s)")), #self.items),
    20 + tw + 10, 48 + f:getHeight() - sf:getHeight() - 1, 600 - tw - 10, c.dim)
  if #self.items == 0 then
    PS.fit(PS.font("r", 13), L("Nenhuma ROM traduzida pelo app ainda."), 20, 220, 600, c.dim, "center")
  else
    PG.draw(self, self:metrics(), { items = self.items, sel = self.sel, focus = true, key = "rta" })
  end
  local hints = { { "a", L("Ações") } }
  if (self.ntested or 0) > 0 then hints[#hints + 1] = { "x", L("Excluir backups dos testados") } end
  hints[#hints + 1] = { "b", L("Voltar") }
  PS.footer(hints)
end

function S:action(act)
  if act == "b" then App.pop(); return end
  local n = #self.items
  if act == "x" then RA.delete_tested(self.list, function() self:refresh() end); return end
  if n == 0 then return end
  if act == "a" then
    local it = self.items[self.sel]
    if it then RA.details(it.x, function() self:refresh() end) end
    return
  end
  local ns = PG.move(self.sel, n, act, 2)
  self.sel = ns
end

return S
