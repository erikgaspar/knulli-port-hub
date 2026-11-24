-- =============================================================================
--  Knulli: Backup completo dos saves (core/fullbackup.lua)
--  Fazer backup (so saves | saves + states, configuracoes opcionais) com o
--  tamanho estimado e o espaco livre ANTES; lista dos backups (tamanho/data);
--  restaurar (com confirmacao, so por cima dos mesmos caminhos) e apagar.
--  Os arquivos ficam em /userdata/backups/knulli-port-hub (pelo FTP do hub:
--  /backups/knulli-port-hub).
--  Abrir: require("ui.screens.fullbackup").open()  (registra a tela se preciso)
--  Botoes (acao -> fisico no RG35XXH): a=B escolhe | b=A volta |
--  x=Y o que entra no backup | y=X calcular de novo.
-- =============================================================================
local L = require("lib.i18n").L
local T = require("ui.theme")
local G = require("ui.gfx")
local U = require("lib.util")
local FB = require("core.fullbackup")

local S = {}
S.fixed_text = true
local TOP, BOTTOM = 166, 418

function S.open()
  App.screens.fullbackup = App.screens.fullbackup or S
  App.push("fullbackup")
end

function S:enter(p)
  p = p or {}
  self.dest = p.dest or FB.ROOT
  self.sel, self.scroll = 1, 0
  self.configs = false
  self.info = nil
  self.rows = {}
  self:load_list()
  self:rescan()
end

function S:rescan()
  self.scanning = true
  FB.scan({ dest = self.dest }, function(info)
    self.scanning = false
    self.info = info
    self:build()
  end)
  self:build()
end

function S:load_list()
  self.list = FB.list(self.dest)
end

local function kb(n) return U.format_bytes((n or 0) * 1024) end

function S:build()
  local info = self.info
  local rows = {}
  local function est(mode) return info and ("≈ " .. kb(FB.estimate(info, mode, self.configs))) or L("calculando...") end
  rows[#rows + 1] = { act = "saves", text = L("Fazer backup: só saves"), right = est("saves"),
    sub = L("Saves dos sistemas e dos ports, sem os save states (menor)") }
  rows[#rows + 1] = { act = "states", text = L("Fazer backup: saves + states"), right = est("states"),
    sub = L("Inclui os save states (*.state, PPSSPP...): pode ficar bem maior") }
  rows[#rows + 1] = { act = "configs", text = L("Incluir configurações"), right = self.configs and L("SIM") or L("NÃO"),
    sub = L("knulli.conf (tem a senha do Wi-Fi), EmulationStation, RetroArch, PPSSPP, Bluetooth") }
  rows[#rows + 1] = { head = L("BACKUPS FEITOS") .. "  (" .. #self.list .. ")" }
  if #self.list == 0 then rows[#rows + 1] = { note = L("Nenhum backup ainda.") } end
  for _, b in ipairs(self.list) do rows[#rows + 1] = { bk = b } end
  self.rows = rows
  self:clamp()
end

local function selectable(r) return r and (r.act or r.bk) end
local function row_h(r) if r.head then return 24 elseif r.note then return 24 end return 38 end

function S:clamp()
  local n = #self.rows
  self.sel = math.max(1, math.min(n, self.sel))
  if not selectable(self.rows[self.sel]) then
    for i = self.sel, n do if selectable(self.rows[i]) then self.sel = i; break end end
    if not selectable(self.rows[self.sel]) then
      for i = self.sel, 1, -1 do if selectable(self.rows[i]) then self.sel = i; break end end
    end
  end
  if self.sel <= self.scroll then self.scroll = math.max(0, self.sel - 1) end
  while true do
    local y = TOP
    for i = self.scroll + 1, self.sel do y = y + row_h(self.rows[i]) end
    if y <= BOTTOM or self.scroll >= self.sel - 1 then break end
    self.scroll = self.scroll + 1
  end
end

function S:move(dir)
  local n, i = #self.rows, self.sel
  for _ = 1, n do
    i = (i - 1 + dir) % n + 1
    if selectable(self.rows[i]) then self.sel = i; break end
  end
  if dir < 0 and self.sel <= 4 then self.scroll = 0 end
  self:clamp()
end

-- ---------------------------------------------------------------------------
-- desenho

local MODE = { saves = L("só saves"), states = L("saves + states") }

function S:draw()
  G.header(L("Backup dos saves"), #self.list .. " " .. L("backup(s)"))
  -- resumo do que entra
  G.panel(12, 48, T.W - 24, 112, { bg = T.c.bg1 })
  local info = self.info
  local y = 56
  local function line(k, v, c)
    G.text_fit(T.f.small, k, 24, y + 2, 190, T.c.faint)
    G.text_fit(T.f.bodyb, v, 220, y, T.W - 250, c or T.c.text)
    y = y + 20
  end
  if not info then
    G.text(T.f.body, L("Calculando o tamanho dos saves..."), 24, 92, T.c.yellow)
    G.progress_busy(24, 120, T.W - 48, 6, App.t, T.c.yellow)
  else
    line(L("Saves dos sistemas"), kb((info.saves_kb or 0) - (info.states_kb or 0)) .. "   +   " .. L("states ") .. kb(info.states_kb))
    line(L("Saves dos ports"), kb(info.ports_kb) .. "  •  " .. string.format(L("%d port(s), %d pasta(s)/arquivo(s)"), info.ports_n or 0, #info.ports))
    line(L("Configurações"), kb(info.configs_kb) .. "  •  " .. string.format(L("%d item(ns)"), #info.configs), self.configs and T.c.text or T.c.dim)
    local free = info.free_kb
    line(L("Livre no cartão"), free and kb(free) or L("não informado"), free and free < 1024 * 1024 and T.c.orange or T.c.green)
    G.text_fit(T.f.small, L("Destino: ") .. self.dest .. "   •   " .. L("FTP do hub: /backups/knulli-port-hub"), 24, y + 2, T.W - 48, T.c.faint)
  end
  -- linhas
  y = TOP
  for i = self.scroll + 1, #self.rows do
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
        G.text_fit(T.f.bodyb, r.text, 22, y + 3, T.W - 200, T.c.text)
        G.text_fit(T.f.small, r.sub, 22, y + 19, T.W - 60, T.c.dim)
        local rc = r.act == "configs" and (self.configs and T.c.green or T.c.dim) or T.c.yellow
        G.text(T.f.bodyb, r.right or "", T.W - 186, y + 3, rc, "right", 160)
      else
        local b = r.bk
        local m = b.meta or {}
        G.text_fit(T.f.bodyb, b.date, 22, y + 3, 220, T.c.text)
        local sub = (MODE[m.mode] or "?") .. (m.configs == "1" and ("  •  " .. L("com configurações")) or "")
          .. (m.files and m.files ~= "?" and ("  •  " .. m.files .. L(" arquivo(s)")) or "")
        G.text_fit(T.f.small, sub, 22, y + 19, T.W - 200, T.c.dim)
        local sz = U.format_bytes(b.bytes or 0)
        G.text(T.f.bodyb, sz, T.W - 186, y + 3, T.c.text, "right", 160)
      end
    end
    y = y + h
  end
  if FB.job then self:draw_busy() end
  local hints = {}
  if not FB.job then
    hints[#hints + 1] = { "dpad", L("Navegar") }
    local cur = self.rows[self.sel]
    if cur then hints[#hints + 1] = { "a", cur.bk and L("Opções") or (cur.act == "configs" and L("Alternar") or L("Fazer backup")) } end
    if self.info then hints[#hints + 1] = { "x", L("O que entra") } end
    hints[#hints + 1] = { "y", L("Recalcular") }
    hints[#hints + 1] = { "b", L("Voltar") }
  end
  G.hints(hints)
end

function S:draw_busy()
  local j = FB.job
  local x, y, w, h = 50, 170, T.W - 100, 120
  G.rect(x, y, w, h, T.c.bg0, 8, 0.96)
  G.frame(x, y, w, h, T.c.yellow, 8, 2)
  G.text(T.f.pix8, j.kind == "backup" and L("FAZENDO BACKUP...") or L("RESTAURANDO..."), x, y + 16, T.c.yellow, "center", w)
  local secs = math.floor(love.timer.getTime() - (j.t0 or 0))
  if j.kind == "backup" then
    local done = FB.progress() or 0
    G.text(T.f.body, U.format_bytes(done) .. L(" gravados (compactado)") .. "  •  " .. secs .. " s", x, y + 42, T.c.text, "center", w)
  else
    G.text(T.f.body, L("Extraindo os arquivos...") .. "  •  " .. secs .. " s", x, y + 42, T.c.text, "center", w)
  end
  G.progress_busy(x + 30, y + 74, w - 60, 8, App.t, T.c.yellow)
  G.text(T.f.small, L("Não desligue o console."), x, y + h - 24, T.c.faint, "center", w)
end


-- ---------------------------------------------------------------------------
-- acoes

local function fail(title, why, extra)
  local body
  if why == "busy" then body = L("Já existe um backup ou restauração em andamento.")
  elseif why == "empty" then body = L("Nenhum save encontrado.")
  elseif why == "scan" then body = L("Aguarde o cálculo do tamanho terminar.")
  elseif why == "write" then body = L("Não foi possível gravar na pasta de backups.")
  elseif why == "space" then
    body = L("Não há espaço livre suficiente no cartão para este backup.") .. "\n\n"
      .. L("Faltam cerca de ") .. kb(extra and extra.missing_kb) .. L(". Libere espaço ou escolha \"só saves\".")
  elseif why == "unsafe" then body = L("Este arquivo tem caminhos fora de /userdata e não será restaurado.")
  elseif why == "missing" then body = L("O arquivo de backup não existe mais.")
  else body = tostring(why or "?") end
  App.show_dialog({ title = title, kind = "error", body = body })
end

function S:do_backup(mode)
  local info = self.info
  if not info then App.toast(L("Aguarde o cálculo do tamanho terminar."), "warn"); return end
  local est = FB.estimate(info, mode, self.configs)
  local fits, missing = FB.fits(info, est)
  if not fits then fail(L("Espaço insuficiente"), "space", { missing_kb = missing }); return end
  App.show_dialog({ title = L("Fazer o backup agora?"), kind = "info",
    body = L("Tipo: ") .. MODE[mode] .. (self.configs and (" + " .. L("configurações")) or "") .. "\n"
      .. L("Tamanho estimado: até ") .. kb(est) .. L(" (compactado costuma ficar menor)") .. "\n"
      .. L("Livre no cartão: ") .. (info.free_kb and kb(info.free_kb) or "?") .. "\n"
      .. L("Destino: ") .. self.dest .. "\n\n"
      .. L("Pode levar alguns minutos. Os jogos e saves não são alterados."),
    buttons = { { label = L("FAZER BACKUP"), fn = function()
      FB.backup({ info = info, mode = mode, configs = self.configs, dest = self.dest }, function(ok, res, meta)
        self:load_list()
        self:rescan()
        if ok then
          App.show_dialog({ title = L("Backup concluído"), kind = "ok",
            body = res .. "\n" .. U.format_bytes(U.file_size(res) or 0) .. "  •  " .. tostring(meta and meta.files or "?") .. L(" arquivo(s)")
              .. "\n\n" .. L("Para guardar fora do console, copie pelo FTP do hub (pasta /backups/knulli-port-hub).") })
        else
          fail(L("Backup não concluído"), res, meta)
        end
      end)
    end }, { label = L("VOLTAR") } }, sel = 1 })
end

function S:restore(b)
  local m = b.meta or {}
  App.show_dialog({ title = L("Restaurar este backup?"), kind = "warn",
    body = b.date .. "  •  " .. (MODE[m.mode] or "?") .. "  •  " .. U.format_bytes(b.bytes or 0) .. "\n\n"
      .. L("Os arquivos do backup substituem os atuais NOS MESMOS CAMINHOS: o progresso salvo depois desta data, nesses arquivos, será perdido. Arquivos que não estão no backup não são apagados nem alterados.")
      .. (m.configs == "1" and ("\n\n" .. L("Este backup também tem configurações (knulli.conf, EmulationStation...): elas voltam a ser as da data do backup. Reinicie o console depois.")) or ""),
    buttons = { { label = L("RESTAURAR"), fn = function()
      FB.restore(b.path, { base = self.restore_base }, function(ok, why, n)
        self:rescan()
        if ok then
          App.show_dialog({ title = L("Backup restaurado"), kind = "ok",
            body = string.format(L("%s arquivo(s) restaurado(s)."), tostring(n or "?"))
              .. (m.configs == "1" and ("\n\n" .. L("Reinicie o console para as configurações valerem.")) or "") })
        else
          fail(L("Não foi possível restaurar"), why)
        end
      end)
    end }, { label = L("VOLTAR") } }, sel = 2 })
end

function S:delete(b)
  App.show_dialog({ title = L("Apagar este backup?"), kind = "warn",
    body = b.name .. "\n" .. U.format_bytes(b.bytes or 0) .. "\n\n" .. L("O arquivo será apagado do cartão. Os saves atuais não são alterados."),
    buttons = { { label = L("APAGAR"), fn = function()
      if FB.delete(b.path) then App.toast(L("Backup apagado."), "info") else App.toast(L("Não foi possível apagar o backup."), "error") end
      self:load_list()
      self:rescan()
    end }, { label = L("VOLTAR") } }, sel = 2 })
end

function S:backup_menu(b)
  local m = b.meta or {}
  App.show_dialog({ title = L("Backup de ") .. b.date, kind = "info", list = true,
    body = b.path .. "\n" .. U.format_bytes(b.bytes or 0) .. "  •  " .. (MODE[m.mode] or "?")
      .. (m.configs == "1" and ("  •  " .. L("com configurações")) or "")
      .. (m.files and ("  •  " .. m.files .. L(" arquivo(s)")) or "")
      .. "\n\n" .. L("Copiar para o PC: FTP do hub, pasta /backups/knulli-port-hub."),
    buttons = { { label = L("RESTAURAR"), fn = function() self:restore(b) end },
      { label = L("APAGAR"), fn = function() self:delete(b) end },
      { label = L("VOLTAR") } }, sel = 3 })
end

--- lista do que entra (infolist)
function S:show_items()
  local info = self.info
  if not info then return end
  local items = {}
  items[#items + 1] = { tag = L("SISTEMAS"), tagc = T.c.accent2, text = FB.SAVES,
    sub = kb(info.saves_kb) .. L(" no total  •  states: ") .. kb(info.states_kb) .. L(" (só entram em \"saves + states\")") }
  for _, p in ipairs(info.ports) do
    items[#items + 1] = { tag = L("PORT"), tagc = T.c.yellow, text = "/" .. p.rel, sub = kb(p.kb) }
  end
  for _, c in ipairs(info.configs) do
    items[#items + 1] = { tag = L("CONFIG"), tagc = T.c.dim, text = "/" .. c.rel,
      sub = kb(c.kb) .. (self.configs and "" or ("  •  " .. L("só com \"Incluir configurações\""))) }
  end
  App.push("infolist", { title = L("O que entra no backup"), sub = #items .. L(" item(ns)"), items = items })
end

function S:action(act)
  if FB.job then return end
  if act == "b" then App.pop(); return end
  if act == "y" then self:load_list(); self:rescan(); return end
  if act == "x" then self:show_items(); return end
  if act == "up" then self:move(-1)
  elseif act == "down" then self:move(1)
  elseif act == "a" then
    local r = self.rows[self.sel]
    if not r then return end
    if r.act == "configs" then self.configs = not self.configs; self:build()
    elseif r.act == "saves" or r.act == "states" then self:do_backup(r.act)
    elseif r.bk then self:backup_menu(r.bk) end
  end
end

return S
