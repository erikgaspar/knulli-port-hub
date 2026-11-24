-- =============================================================================
--  Tela "Pacote de músicas de games" (OverClocked ReMix) - core/musicpack.lua
--  Lista das faixas (jogo, remix, artistas, duracao, tamanho) com o que ja esta
--  instalado. X: instalar (so as do pacote / junto com as do Knulli) |
--  Y: remover | SELECT: creditos | A: detalhes da faixa | B: voltar (durante a
--  instalacao, B pergunta se quer cancelar).
--  Usa a lista padrao (infolist) e desenha o andamento no rodape.
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local T = require("ui.theme")
local G = require("ui.gfx")
local U = require("lib.util")
local MP = require("core.musicpack")
local Info = require("ui.screens.infolist")

local S = setmetatable({}, { __index = Info })
local PANEL_H = 50

local function mmss(s)
  s = math.floor(tonumber(s) or 0)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function load(scr)
  local idx = MP.index()
  if not idx then scr.items = {}; scr.p.empty = L("Índice do pacote de músicas não encontrado."); return end
  local st = MP.state()
  scr.state = st
  local items = {}
  for _, t in ipairs(idx.tracks) do
    local inst = st.tracks[t.id] ~= nil
    local arts = table.concat(type(t.artists) == "table" and t.artists or {}, ", ")
    items[#items + 1] = {
      tag = inst and I18N.tr(L("OK")) or nil, tagc = T.c.green,
      text = tostring(t.game or "") .. " — " .. tostring(t.title or ""),
      sub = arts .. "  •  " .. mmss(t.duration) .. "  •  ~" .. U.format_bytes(tonumber(t.size) or 0),
      ref = t,
      detail = function()
        return table.concat({
          tostring(t.game or ""), "\"" .. tostring(t.title or "") .. "\"", "",
          I18N.tr(L("Artista(s): ")) .. arts,
          I18N.tr(L("Duração: ")) .. mmss(t.duration),
          I18N.tr(L("Download: ")) .. U.format_bytes(tonumber(t.mp3_size) or 0) .. "  →  OGG ~" .. U.format_bytes(tonumber(t.size) or 0),
          I18N.tr(L("Página: ")) .. tostring(t.page or ""),
          "", I18N.tr(inst and L("Instalada") or L("Não instalada")),
        }, "\n")
      end }
  end
  scr.items = items
  local n, size, dl = MP.totals(idx)
  scr.p.sub = string.format(I18N.tr(L("%d faixas  •  ~%s no cartão  •  %d instaladas")), n, U.format_bytes(size), st.count)
  scr.sel = math.min(scr.sel or 1, math.max(1, #items))
  scr.totals = { n = n, size = size, dl = dl }
end

local function after(scr, action)
  return function(ok, out, rc)
    MP._idx = nil
    load(scr)
    if action == "remove" then
      if ok then App.toast(L("Pacote de músicas removido."), "ok")
      else App.show_dialog({ title = L("Não foi possível remover"), kind = "error", body = tostring(out) }) end
      return
    end
    if rc == 3 then App.toast(L("Instalação cancelada. As faixas já instaladas ficaram."), "info")
    elseif ok then
      App.toast(L("Músicas instaladas. Elas tocam no menu do Knulli."), "ok")
    else
      App.show_dialog({ title = L("Algumas faixas não foram instaladas"), kind = "warn",
        body = tostring(out) .. "\n\n" .. L("Tente de novo mais tarde (Instalar baixa só o que falta). Registro: ") .. MP.log_path("install") })
    end
  end
end

local function start(scr, action, mode)
  local ok, err = MP.start(action, mode, after(scr, action))
  if not ok then App.show_dialog({ title = L("Não foi possível começar"), kind = "error", body = tostring(err) }) end
end

local function ask_install(scr)
  if MP.job then return end
  local tt = scr.totals or {}
  local kn = MP.knulli_count()
  local body = string.format(I18N.tr(L("%d faixas do OverClocked ReMix (arranjos de fãs, gratuitos). Download ~%s, ocupa ~%s no cartão (OGG 96 kbps) em %s.\n\nBaixa uma por vez dos espelhos oficiais do OC ReMix, confere e converte no console. Precisa de Wi-Fi; leva alguns minutos. Faixas já instaladas ficam como estão.")),
    tt.n or 0, U.format_bytes(tt.dl or 0), U.format_bytes(tt.size or 0), MP.DEST .. "/" .. MP.FOLDER)
  App.show_dialog({ title = L("Instalar o pacote de músicas?"), kind = "info", list = true, body = body,
    buttons = {
      { label = L("Só as do pacote"), sub = L("O menu toca só as músicas da pasta de músicas (as do Knulli deixam de tocar)."),
        fn = function() start(scr, "install", "only") end },
      { label = L("Junto com as do Knulli"), sub = string.format(I18N.tr(L("Copia também as %d músicas do Knulli para %s/knulli.")), kn, MP.DEST),
        fn = function() start(scr, "install", "knulli") end },
      { label = L("Cancelar") } } })
end

local function ask_remove(scr)
  if MP.job then return end
  local st = MP.state()
  if st.count == 0 and #st.knulli == 0 then App.toast(L("O pacote de músicas não está instalado."), "info"); return end
  App.show_dialog({ title = L("Remover o pacote de músicas?"), kind = "warn",
    body = string.format(I18N.tr(L("Apaga só o que o pacote instalou: %d faixas em %s e a cópia das músicas do Knulli (%d). Outras músicas da pasta ficam.\n\nSem nenhuma música na pasta, o menu volta a tocar as do Knulli.")),
      st.count, MP.DEST .. "/" .. MP.FOLDER, #st.knulli),
    buttons = { { label = L("REMOVER"), danger = true, fn = function() start(scr, "remove") end }, { label = L("CANCELAR") } }, sel = 2 })
end

local function credits(scr)
  App.push("textview", { title = L("Créditos — OverClocked ReMix"), text = MP.credits_text(MP.index()) })
end

function S:enter(p)
  Info.enter(self, { title = L("Pacote de músicas de games"), sub = "", reload_on_resume = true,
    empty = L("Índice do pacote de músicas não encontrado."),
    load = load,
    keys = {
      { key = "x", label = L("Instalar"), fn = function(scr) ask_install(scr) end, enabled = function() return not MP.job end },
      { key = "y", label = L("Remover"), fn = function(scr) ask_remove(scr) end, enabled = function() return not MP.job end },
      { key = "select", label = L("Créditos"), fn = function(scr) credits(scr) end },
    } })
  -- indice novo do GitHub (sem travar; refaz a lista quando chegar)
  MP.refresh(function(ok) if ok and not MP.job then load(self) end end)
end

function S:visible()
  local rh = math.max(42, G.step(T.f.body, 22) + G.step(T.f.small, 16) + 8)
  local h = 436 - 50 - (MP.job and PANEL_H or 0)
  return math.max(1, math.floor(h / rh))
end

function S:update()
  local j = MP.job
  if j and (love.timer.getTime()) - (self.last_poll or -1) > 0.5 then
    self.last_poll = love.timer.getTime()
    self.prog = MP.progress()
  elseif not j then self.prog = nil end
end

function S:draw()
  Info.draw(self)
  local j = MP.job
  if not j then return end
  local y = 436 - PANEL_H + 2
  G.rect(12, y, T.W - 24, PANEL_H - 6, T.c.bg2 or T.c.bg1, 6)
  local p = self.prog or {}
  local label
  if j.action == "remove" then label = I18N.tr(L("Removendo…"))
  elseif j.cancelling then label = I18N.tr(L("Cancelando…"))
  elseif p.phase == "convert" then label = string.format(I18N.tr(L("Convertendo %d de %d: %s")), p.i or 0, p.n or 0, tostring(p.title or ""))
  elseif p.phase == "knulli" then label = I18N.tr(L("Copiando as músicas do Knulli…"))
  elseif p.i then label = string.format(I18N.tr(L("Baixando %d de %d: %s")), p.i, p.n or 0, tostring(p.title or ""))
  else label = I18N.tr(L("Preparando…")) end
  G.text_fit(T.f.small, label, 22, y + 5, T.W - 160, T.c.text)
  G.text(T.f.small, I18N.tr(L("Voltar: cancelar")), T.W - 130, y + 5, T.c.dim, "right", 110)
  local frac
  if p.n and p.n > 0 and p.i then
    local part = 0
    if p.phase == "download" and (p.size or 0) > 0 then part = 0.8 * math.min(1, (p.got or 0) / p.size)
    elseif p.phase == "convert" then part = 0.9 end
    frac = math.min(1, ((p.i - 1) + part) / p.n)
  end
  if frac then G.progress(22, y + 28, T.W - 44, 8, frac, T.c.accent)
  else G.progress_busy(22, y + 28, T.W - 44, 8, App.t, T.c.accent) end
end

function S:action(act)
  if MP.job then
    if act == "b" then
      if MP.job.action == "install" and not MP.job.cancelling then
        App.show_dialog({ title = L("Cancelar a instalação?"), kind = "warn",
          body = L("Para na faixa atual. As faixas já instaladas ficam (Remover apaga)."),
          buttons = { { label = L("PARAR"), danger = true, fn = function() MP.cancel() end },
            { label = L("SAIR DA TELA"), fn = function() App.pop() end },
            { label = L("CONTINUAR") } }, sel = 3 })
      end
      return
    end
    if act == "x" or act == "y" then App.toast(L("Aguarde: o pacote de músicas está trabalhando."), "info"); return end
  end
  return Info.action(self, act)
end

return S
