-- =============================================================================
--  Knulli: Bluetooth (core/btctl.lua)
--  Ligar/desligar, procurar aparelhos, parear (escolhido na lista ou modo
--  automatico de controles do Knulli), conectar/desconectar e esquecer.
--  Abrir: require("ui.screens.bluetooth").open()  (registra a tela se preciso)
--  Botoes (acao -> fisico no RG35XXH): a=B confirma | b=A volta |
--  x=Y procura/para | y=X atualiza.
-- =============================================================================
local L = require("lib.i18n").L
local T = require("ui.theme")
local G = require("ui.gfx")
local U = require("lib.util")
local BT = require("core.btctl")

local S = {}
S.fixed_text = true
local TOP, BOTTOM = 92, 436

--- abre a tela (registra em App.screens sem precisar mexer no main.lua)
function S.open()
  App.screens.bluetooth = App.screens.bluetooth or S
  App.push("bluetooth")
end

local KIND = { joystick = L("Controle"), audio = L("Áudio"), input = L("Entrada"), phone = L("Celular"), computer = L("Computador") }

function S:enter()
  self.sel, self.scroll = 1, 0
  self.st = nil
  self.rows = {}
  self.avail = BT.available()
  self.loading = true
  self.found = {}
  self.tick, self.name_t = 0, 0
  self.pair_t0 = nil
  self:refresh()
end

function S:leave() BT.scan_stop() end

function S:refresh()
  self.loading = true
  BT.status(function(st)
    self.st = st
    self.loading = false
    self:build()
  end)
end

--- monta as linhas: acoes, pareados, encontrados na busca
function S:build()
  local st = self.st or { paired = {} }
  local rows = {}
  local function head(t) rows[#rows + 1] = { head = t } end
  rows[#rows + 1] = { act = "power", text = st.enabled and L("Desligar o Bluetooth") or L("Ligar o Bluetooth"),
    sub = st.enabled and (st.running and L("Ligado") or L("Ligado nas configurações, mas o serviço não está rodando"))
      or L("Desligado") }
  if st.running then
    rows[#rows + 1] = { act = "scan", text = BT.scanning and L("Parar a busca") or L("Procurar aparelhos"),
      sub = L("Coloque o aparelho em modo de pareamento antes de procurar") }
    rows[#rows + 1] = { act = "auto", text = L("Parear controle automaticamente"),
      sub = L("Modo do Knulli: pareia o primeiro controle que entrar em pareamento (até 60 s)") }
  end
  local known = {}
  if st.running then
    head(L("PAREADOS") .. "  (" .. #st.paired .. ")")
    if #st.paired == 0 then rows[#rows + 1] = { note = L("Nenhum aparelho pareado.") } end
    for _, d in ipairs(st.paired) do
      known[d.mac] = true
      rows[#rows + 1] = { dev = d, paired = true }
    end
  end
  if BT.scanning or #self.found > 0 then
    local n = 0
    for _, d in ipairs(self.found) do if not known[d.mac] then n = n + 1 end end
    head(L("ENCONTRADOS") .. "  (" .. n .. ")" .. (BT.scanning and ("  •  " .. L("procurando...")) or ""))
    if n == 0 then rows[#rows + 1] = { note = BT.scanning and L("Procurando aparelhos por perto...") or L("Nenhum aparelho novo encontrado.") } end
    for _, d in ipairs(self.found) do
      if not known[d.mac] then rows[#rows + 1] = { dev = d } end
    end
  end
  -- mantem a selecao no mesmo item (por endereco/acao)
  local cur = self.rows and self.rows[self.sel]
  local key = cur and ((cur.dev and cur.dev.mac) or cur.act)
  self.rows = rows
  self.sel = nil
  for i, r in ipairs(rows) do
    if key and ((r.dev and r.dev.mac == key) or r.act == key) then self.sel = i end
  end
  if not self.sel then self.sel = 1 end
  self:clamp()
end

local function selectable(r) return r and (r.act or r.dev) end

local function row_h(r)
  if r.head then return 24 end
  if r.note then return 26 end
  return 40
end

function S:clamp()
  local n = #self.rows
  if n == 0 then self.sel = 1; return end
  self.sel = math.max(1, math.min(n, self.sel))
  if not selectable(self.rows[self.sel]) then
    for i = self.sel, n do if selectable(self.rows[i]) then self.sel = i; break end end
  end
  -- rolagem: o selecionado sempre visivel
  if self.sel <= self.scroll then self.scroll = math.max(0, self.sel - 2) end
  while true do
    local y = TOP
    for i = self.scroll + 1, self.sel do y = y + row_h(self.rows[i]) end
    if y <= BOTTOM or self.scroll >= self.sel - 1 then break end
    self.scroll = self.scroll + 1
  end
end

function S:move(dir)
  local n = #self.rows
  local i = self.sel
  for _ = 1, n do
    i = (i - 1 + dir) % n + 1
    if selectable(self.rows[i]) then self.sel = i; break end
  end
  if dir < 0 and self.sel <= self.scroll + 1 then self.scroll = math.max(0, self.sel - 2) end
  self:clamp()
end

function S:update(dt)
  if BT.scanning then
    self.tick = self.tick + dt
    self.name_t = self.name_t + dt
    if self.tick >= 1 then
      self.tick = 0
      self.found = BT.scan_list()
      if BT.scan_elapsed() >= BT.SCAN_SECS and BT.busy ~= "pair" then
        BT.scan_stop()
        App.toast(L("Busca concluída."), "info")
      end
      self:build()
    end
    if self.name_t >= 4 then
      self.name_t = 0
      BT.fill_names()
    end
  end
end

-- ---------------------------------------------------------------------------
-- desenho

local function dev_name(d) return d.name or d.mac end

function S:draw()
  local st = self.st
  G.header(L("Bluetooth"), st and (st.enabled and (st.running and L("Ligado") or L("Parado")) or L("Desligado")) or nil)
  -- faixa de estado
  G.panel(12, 48, T.W - 24, 38, { bg = T.c.bg1 })
  if self.loading and not st then
    G.text(T.f.body, L("Lendo o Bluetooth..."), 24, 59, T.c.yellow)
  elseif st then
    local on = st.enabled and st.running
    G.rect(24, 60, 12, 12, on and T.c.accent2 or T.c.faint, 6)
    local txt
    if not self.avail then txt = L("Bluetooth não encontrado neste sistema.")
    elseif on then txt = (st.name or L("Adaptador")) .. "  •  " .. (st.addr or "?") .. (st.powered and "" or ("  •  " .. L("rádio desligado")))
    elseif st.enabled then txt = L("O serviço Bluetooth não está rodando (sem agente ou sem adaptador).")
    else txt = L("Bluetooth desligado. Ligue para procurar e parear aparelhos.") end
    G.text_fit(T.f.body, txt, 44, 58, T.W - 80, on and T.c.text or T.c.dim)
  end
  -- linhas
  local y = TOP
  for i = self.scroll + 1, #(self.rows or {}) do
    local r = self.rows[i]
    local h = row_h(r)
    if y + h > BOTTOM + 4 then break end
    if r.head then
      G.text(T.f.pix8, r.head, 18, y + 9, T.c.accent2)
    elseif r.note then
      G.text_fit(T.f.small, r.note, 22, y + 5, T.W - 44, T.c.faint)
    else
      local on = i == self.sel
      G.rect(12, y, T.W - 24, h - 4, on and T.c.bg3 or T.c.bg1, 5)
      if on then G.frame(12, y, T.W - 24, h - 4, T.c.accent, 5, 2) end
      if r.act then
        G.text_fit(T.f.bodyb, r.text, 22, y + 3, T.W - 48, T.c.text)
        G.text_fit(T.f.small, r.sub or "", 22, y + 20, T.W - 48, T.c.dim)
      else
        local d = r.dev
        local x = 22
        local k = KIND[d.kind or ""]
        if k then x = x + G.tag(k, x, y + 6, d.kind == "joystick" and T.c.accent2 or T.c.yellow, T.c.bg0, T.f.pix8) + 8 end
        G.text_fit(T.f.bodyb, dev_name(d), x, y + 3, T.W - 200 - x, d.name and T.c.text or T.c.dim)
        local sub = d.mac
        if d.battery then sub = sub .. "  •  " .. L("bateria ") .. d.battery .. "%" end
        G.text_fit(T.f.small, sub, 22, y + 20, T.W - 200, T.c.faint)
        local right, rc
        if r.paired then
          right, rc = d.connected and L("CONECTADO") or L("PAREADO"), d.connected and T.c.green or T.c.dim
        else
          right, rc = L("NOVO"), T.c.yellow
        end
        G.text(T.f.pix8, right, T.W - 34 - T.f.pix8:getWidth(right), y + 14, rc)
      end
    end
    y = y + h
  end
  -- pareamento / ligar em andamento
  if BT.busy then self:draw_busy() end
  local hints = {}
  if not BT.busy then
    hints[#hints + 1] = { "dpad", L("Navegar") }
    local cur = self.rows and self.rows[self.sel]
    if cur and cur.dev then hints[#hints + 1] = { "a", cur.paired and L("Opções") or L("Parear") }
    elseif cur and cur.act then hints[#hints + 1] = { "a", L("Escolher") } end
    if self.st and self.st.running then hints[#hints + 1] = { "x", BT.scanning and L("Parar busca") or L("Procurar") } end
    hints[#hints + 1] = { "y", L("Atualizar") }
    hints[#hints + 1] = { "b", L("Voltar") }
  elseif BT.busy == "pair" then
    hints[#hints + 1] = { "b", L("Cancelar pareamento") }
  end
  G.hints(hints)
end

local BUSY = { pair = L("PAREANDO..."), power = L("AGUARDE..."), connect = L("CONECTANDO..."),
  disconnect = L("DESCONECTANDO..."), forget = L("ESQUECENDO APARELHO...") }

function S:draw_busy()
  local x, y, w, h = 50, 170, T.W - 100, 120
  G.rect(x, y, w, h, T.c.bg0, 8, 0.96)
  G.frame(x, y, w, h, T.c.yellow, 8, 2)
  G.text(T.f.pix8, BUSY[BT.busy] or L("AGUARDE..."), x, y + 16, T.c.yellow, "center", w)
  local msg
  if BT.busy == "pair" then
    msg = BT.agent_status() or L("Deixe o aparelho em modo de pareamento perto do console.")
    if self.pair_t0 then
      local left = math.max(0, 60 - math.floor(love.timer.getTime() - self.pair_t0))
      G.text(T.f.small, string.format(L("até %d s"), left), x, y + h - 26, T.c.faint, "center", w)
    end
  elseif BT.busy == "power" then
    msg = L("Reiniciando os serviços do Bluetooth...")
  end
  if msg then G.text_fit(T.f.body, msg, x + 16, y + 42, w - 32, T.c.text) end
  G.progress_busy(x + 30, y + 74, w - 60, 8, App.t, T.c.yellow)
end

-- ---------------------------------------------------------------------------
-- acoes

local function fail_text(msg)
  if msg == "busy" then return L("Já existe uma operação de Bluetooth em andamento.") end
  if msg == "agent" then return L("O agente de Bluetooth do Knulli não está rodando. Desligue e ligue o Bluetooth.") end
  return tostring(msg or L("Sem resposta do Bluetooth."))
end

function S:after(title_ok, title_fail)
  return function(ok, msg)
    if ok then App.toast(title_ok, "ok") else
      App.show_dialog({ title = title_fail, kind = "error", body = fail_text(msg) })
    end
    self:refresh()
  end
end

function S:do_power()
  local st = self.st or {}
  if st.enabled then
    local conn = 0
    for _, d in ipairs(st.paired or {}) do if d.connected then conn = conn + 1 end end
    App.show_dialog({ title = L("Desligar o Bluetooth?"), kind = "warn",
      body = (conn > 0 and (string.format(L("%d aparelho(s) conectado(s) agora vão desconectar."), conn) .. "\n\n") or "")
        .. L("Os aparelhos pareados continuam salvos. O Knulli grava a escolha e mantém desligado depois de reiniciar."),
      buttons = { { label = L("DESLIGAR"), fn = function()
        BT.set_enabled(false, self:after(L("Bluetooth desligado."), L("Não foi possível desligar o Bluetooth")))
      end }, { label = L("VOLTAR") } }, sel = 2 })
  else
    BT.set_enabled(true, self:after(L("Bluetooth ligado."), L("Não foi possível ligar o Bluetooth")))
  end
end

function S:toggle_scan()
  if not (self.st and self.st.running) then return end
  if BT.scanning then
    BT.scan_stop()
  else
    local ok, why = BT.scan_start()
    if not ok then App.show_dialog({ title = L("Não foi possível procurar"), kind = "error", body = fail_text(why) }); return end
    self.found = {}
    self.tick, self.name_t = 0.7, 0
  end
  self:build()
end

function S:pair(d)
  App.show_dialog({ title = L("Parear este aparelho?"), kind = "info",
    body = dev_name(d) .. "\n" .. d.mac .. "\n\n" .. L("Deixe o aparelho em modo de pareamento. O Knulli pareia, confia e conecta (até 60 s). Fones e caixas de som viram a saída de áudio quando conectam."),
    buttons = { { label = L("PAREAR"), fn = function()
      self.pair_t0 = love.timer.getTime()
      BT.pair(d.mac, function(ok, msg)
        self.pair_t0 = nil
        self.found = {}
        if ok then App.toast(L("Pareado: ") .. dev_name(d), "ok")
        else
          App.show_dialog({ title = L("Pareamento não concluído"), kind = "error",
            body = L("O aparelho não ficou pareado.") .. (msg and ("\n\n" .. L("Último aviso do Knulli: ") .. tostring(msg)) or "")
              .. "\n\n" .. L("Confira se ele está em modo de pareamento e perto do console, e tente de novo.") })
        end
        self:refresh()
      end)
      self:build()
    end }, { label = L("VOLTAR") } }, sel = 1 })
end

function S:pair_auto()
  App.show_dialog({ title = L("Parear controle automaticamente"), kind = "info",
    body = L("Coloque o controle em modo de pareamento agora. O Knulli procura e pareia o primeiro controle que aparecer (até 60 s). Só controles: para fones e caixas de som use \"Procurar aparelhos\"."),
    buttons = { { label = L("COMEÇAR"), fn = function()
      self.pair_t0 = love.timer.getTime()
      BT.pair_input(function(ok, msg)
        self.pair_t0 = nil
        App.toast(tostring(msg or (ok and L("Concluído.") or L("Sem resposta do Bluetooth."))), ok and "info" or "warn")
        self:refresh()
      end)
    end }, { label = L("VOLTAR") } }, sel = 1 })
end

function S:device_menu(d)
  local btns = {}
  if d.connected then
    btns[#btns + 1] = { label = L("DESCONECTAR"), fn = function()
      BT.disconnect(d.mac, self:after(L("Desconectado: ") .. dev_name(d), L("Não foi possível desconectar")))
    end }
  else
    btns[#btns + 1] = { label = L("CONECTAR"), fn = function()
      App.toast(L("Conectando: ") .. dev_name(d), "info")
      BT.connect(d.mac, self:after(L("Conectado: ") .. dev_name(d), L("Não foi possível conectar")))
    end }
  end
  btns[#btns + 1] = { label = L("ESQUECER"), fn = function()
    App.show_dialog({ title = L("Esquecer este aparelho?"), kind = "warn",
      body = dev_name(d) .. "\n" .. d.mac .. "\n\n" .. L("Ele sai da lista de pareados do Knulli. Para usar de novo, será preciso parear outra vez."),
      buttons = { { label = L("ESQUECER"), fn = function()
        BT.forget(d.mac, self:after(L("Aparelho esquecido."), L("Não foi possível esquecer o aparelho")))
      end }, { label = L("VOLTAR") } }, sel = 2 })
  end }
  btns[#btns + 1] = { label = L("VOLTAR") }
  App.show_dialog({ title = dev_name(d), kind = "info", list = true,
    body = d.mac .. "  •  " .. (d.connected and L("Conectado") or L("Pareado, não conectado"))
      .. (KIND[d.kind or ""] and ("  •  " .. KIND[d.kind]) or "") .. (d.battery and ("  •  " .. L("bateria ") .. d.battery .. "%") or ""),
    buttons = btns, sel = 1 })
end

function S:action(act)
  if BT.busy then
    if BT.busy == "pair" and act == "b" then BT.cancel_pair(); App.toast(L("Cancelando o pareamento..."), "info") end
    return
  end
  if act == "b" then App.pop(); return end
  if act == "y" then self:refresh(); return end
  if act == "x" then self:toggle_scan(); return end
  if not self.rows or #self.rows == 0 then return end
  if act == "up" then self:move(-1)
  elseif act == "down" then self:move(1)
  elseif act == "a" then
    local r = self.rows[self.sel]
    if not r then return end
    if r.act == "power" then self:do_power()
    elseif r.act == "scan" then self:toggle_scan()
    elseif r.act == "auto" then self:pair_auto()
    elseif r.dev and r.paired then self:device_menu(r.dev)
    elseif r.dev then self:pair(r.dev) end
  end
end

return S
