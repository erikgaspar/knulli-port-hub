-- =============================================================================
--  Tema Premium: Apps do Knulli (Knulli App Store integrada)
--  KA.items(): cartoes largos da aba "Apps do Knulli" da Central.
--  Tela "kapp": pagina de detalhes de um app da loja. Faixa no topo com a
--  imagem de apresentacao do repositorio no GitHub (opengraph, baixada em
--  segundo plano pelo core/heroart.lua com cache; cor solida enquanto
--  carrega), nome, selos e resumo; embaixo a ficha (versoes, licenca,
--  tamanhos, dependencias, rede, o que cria, repositorio), o aviso de
--  instalacao e as notas da revisao.
--  Instalar/atualizar/reparar/remover usam as confirmacoes e a execucao de
--  ui/kstore_ui.lua (instalador da propria loja); nada e duplicado aqui.
--  "Abrir": apps instalados cujo launcher e um .sh dentro de ports (raiz ou
--  uma subpasta, ex.: RandomGamePicker/RandomGamePicker.sh).
--    direcional: botoes | B (acao "a"): confirmar | Y (acao "x"): opcoes
--    A (acao "b"): voltar | L1/R1: rolar as notas
-- =============================================================================
local L = require("lib.i18n").L
local C = require("config")
local U = require("lib.util")
local K = require("core.kstore")
local PS = require("ui.premium.style")
local PI = require("ui.premium.images")

local KA = {}
local lg = love.graphics

local BAND_H = 176
local LX, LW = 20, 248            -- ficha (coluna da esquerda)
local RX, RW = 284, 336           -- aviso, notas e botoes
local BTN_H = 42

-- icone por tipo (familia de linha de ui/icons)
KA.ICON = { game = "games", utility = "tools", integration = "network" }
local ORDER = { update = 1, installed = 2, none = 3 }

-- ---------------------------------------------------------------------------
-- dados (funcoes sem graficos)

--- "owner", "repo" de um link do GitHub (ou nil)
function KA.github(url)
  local o, r = tostring(url or ""):match("^https?://github%.com/([%w%-%._]+)/([%w%-%._]+)")
  if not o then return nil end
  r = r:gsub("%.git$", "")
  if r == "" then return nil end
  return o, r
end

--- pseudo-port para o core/heroart.lua (imagem de apresentacao do repositorio)
function KA.hero_ref(a)
  -- app do hub: imagem propria (capa do menu) no lugar da do repositorio
  if a and a.hub and type(a.image_url) == "string" and a.image_url:match("^https://") then
    a.hero_ref = a.hero_ref or { slug = "hubapp_" .. tostring(a.id):gsub("[^%w]", "_"), name = a.name, hero = a.image_url }
    return a.hero_ref
  end
  local o, r = KA.github(a and a.repository)
  if not o then return nil end
  a.hero_ref = a.hero_ref or { slug = "kapp_" .. tostring(a.id):gsub("[^%w]", "_"), name = a.name,
    hero = "https://opengraph.githubassets.com/1/" .. o .. "/" .. r }
  return a.hero_ref
end

local function nouser(p) return (tostring(p or ""):gsub("^/userdata", "")) end
local function same_dir(a, b) return nouser(a):gsub("/+$", "") == nouser(b):gsub("/+$", "") end
local function dirname(p) return (tostring(p or ""):match("^(.*)/[^/]*$")) or "" end
local function basename(p) return (tostring(p or ""):match("([^/]+)/*$")) or "" end

--- nome do sistema do menu do Knulli a partir do gamelist.xml (ports -> Ports)
function KA.menu_system(gamelist)
  local d = basename(dirname(gamelist))
  if d == "" then return nil end
  local nice = { ports = "Ports", tools = "Tools" }
  return nice[d] or U.upper(d)
end

--- caminho relativo aceito pelo launcher do hub: "App.sh" ou "Pasta/App.sh"
--- (um nivel de subpasta dentro de ports, sem "..", sem "/" inicial, so .sh)
function KA.safe_rel(n)
  n = tostring(n or "")
  if n == "" or n:find("%.%.") or n:sub(1, 1) == "/" or not n:lower():match("%.sh$") then return nil end
  if n:find("/") and not n:match("^[^/]+/[^/]+$") then return nil end
  if n:match("^%./") then return nil end
  return n
end

--- script .sh que o app declarou como launcher dentro da pasta de ports (na
--- raiz ou em uma subpasta: o launcher do hub entra na pasta do script antes de
--- rodar); nil quando o app nao pode ser aberto pelo hub
function KA.launch_script(a)
  if not a or a.status == "none" then return nil end
  local ins = (a.pkg and a.pkg.install) or {}
  local cands = {}
  local menu = type(ins.menu) == "table" and ins.menu or nil
  if menu and menu.gamelist and same_dir(dirname(menu.gamelist), C.PORTS_DIR) then
    cands[#cands + 1] = tostring(menu.path or ""):match("^%./(.+)$")
  end
  local dest, la = ins.destination, tostring(ins.launcher or "")
  if dest and la ~= "" and not la:find("/") then
    if same_dir(dest, C.PORTS_DIR) then cands[#cands + 1] = la
    elseif same_dir(dirname(dest), C.PORTS_DIR) then cands[#cands + 1] = basename(dest) .. "/" .. la end
  end
  for _, n in ipairs(cands) do
    n = KA.safe_rel(n)
    if n and U.file_size(C.PORTS_DIR .. "/" .. n) then return n end
  end
  return nil
end

--- o que o app cria (resumido): "Grout no menu Tools" / arquivo do launcher
function KA.creates(a)
  local ins = (a.pkg and a.pkg.install) or {}
  local menu = type(ins.menu) == "table" and ins.menu or nil
  if menu and menu.gamelist then
    local sys = KA.menu_system(menu.gamelist)
    if sys then return string.format(PS.tr(L("%s no menu %s")), tostring(menu.name or a.name), sys) end
  end
  if ins.launcher then return basename(ins.launcher) .. PS.tr(L(" (sem item no menu)")) end
  return nil
end

--- imagem que o app instalado declarou para o menu (arquivo local), ou nil
local IMG = {}
function KA.app_image(a)
  if not a or a.status == "none" then return nil end
  local menu = a.pkg and a.pkg.install and a.pkg.install.menu
  local rel = type(menu) == "table" and tostring(menu.image or ""):match("^%./(.+)$")
  if not rel or rel:find("%.%.") then return nil end
  local path = dirname(menu.gamelist) .. "/" .. rel
  if IMG[path] == nil then
    IMG[path] = false
    local n = U.file_size(path)
    if n and n > 0 and n < 2 * 1024 * 1024 then
      local ok, img = pcall(function()
        local fd = love.filesystem.newFileData(U.read_file(path), basename(path))
        return lg.newImage(love.image.newImageData(fd))
      end)
      if ok and img then img:setFilter("linear", "linear"); IMG[path] = img end
    end
  end
  return IMG[path] or nil
end

local function size_of(a, key)
  local r = a.pkg and a.pkg.release
  local n = r and tonumber(r[key])
  return n and n > 0 and U.format_bytes(n) or nil
end

--- etiquetas do cartao: tipo, situacao (ou tamanho do download), experimental
function KA.tags(a)
  local c = PS.c()
  local t = {}
  if K.TYPE[a.type] then t[#t + 1] = { K.TYPE[a.type], c.dim2 } end
  if a.status == "installed" then t[#t + 1] = { L("INSTALADO"), c.accent }
  elseif a.status == "update" then t[#t + 1] = { L("ATUALIZAÇÃO"), c.warn }
  else
    local s = size_of(a, "size")
    if s then t[#t + 1] = { s, c.dim } end
  end
  if a.review == "experimental" then t[#t + 1] = { L("EXPERIMENTAL"), c.warn } end
  return t
end

--- itens da aba (cartoes largos) e a contagem; nil + erro sem a loja
function KA.items()
  local missing = not K.available()
  -- sem a Knulli App Store: so os apps do hub (catalogo extra) + cartao "Preparar"
  if missing and #K.hub_list() == 0 then return nil, "missing" end
  local apps, err = K.list(true)
  if not apps then return nil, err end
  local list = {}
  for _, a in ipairs(apps) do list[#list + 1] = a end
  table.sort(list, function(x, y)
    local ox, oy = ORDER[x.status] or 3, ORDER[y.status] or 3
    if ox ~= oy then return ox < oy end
    return x.name:lower() < y.name:lower()
  end)
  local items, inst = {}, 0
  for _, a in ipairs(list) do
    if a.status ~= "none" then inst = inst + 1 end
    items[#items + 1] = { id = "kapp:" .. a.id, name = a.name, short = a.summary, app = a,
      card_icon = KA.ICON[a.type] or "generic", card_img = KA.app_image(a), card_tags = KA.tags(a) }
  end
  if missing then
    items[#items + 1] = { id = "kapp:prepare", name = L("Preparar os Apps do Knulli"), prepare = true,
      short = L("Baixa a lista de apps da Knulli App Store (comunidade) para instalar pelo hub."),
      card_icon = "store", card_tags = { { require("ui.kstore_ui").size_label(), PS.c().dim } } }
  end
  return items, nil, inst
end

--- abre a pagina do app (registra a tela na primeira vez)
function KA.open(a)
  App.screens.kapp = App.screens.kapp or KA
  App.push("kapp", { app = a })
end

--- a lista mudou (instalou/removeu): a Central refaz a aba ao voltar
local function touch_central()
  for _, s in ipairs(App.stack or {}) do
    if s.pc then require("ui.premium.central").invalidate(s) end
  end
end

-- ---------------------------------------------------------------------------
-- tela

function KA:enter(params)
  self.app = params.app
  self.focus = "main"
  self.note_scroll = 0
  self.loading = nil
end

--- le de novo o app (depois de instalar/atualizar/remover)
function KA:refresh()
  local apps = K.list(true) or {}
  for _, a in ipairs(apps) do
    if a.id == self.app.id then a.hero_ref = self.app.hero_ref; self.app = a; break end
  end
  touch_central()
end

function KA:resume() self:refresh() end

--- botao principal: "install" | "update" | "open" | nil (sem botao)
function KA:main_action()
  local a = self.app
  if a.status == "none" then return "install", L("Instalar") end
  if a.status == "update" then return "update", L("Atualizar") end
  if KA.launch_script(a) then return "open", L("Abrir") end
  return nil
end

function KA:update(dt)
  -- foco valido: sem botao principal, so Opcoes
  if not self:main_action() then self.focus = "opts" end
end

local PLACE = { "#22303A", "#2E2A36", "#24332C", "#36302A", "#2A2E3C" }

local function draw_band(self)
  local c = PS.c()
  local a = self.app
  local ref = KA.hero_ref(a)
  local img = ref and require("core.heroart").get(ref)
  -- fundo: imagem desfocada (pronta) ou cor solida
  local seed = 0
  for i = 1, #a.id do seed = seed + a.id:byte(i) end
  PS.rect(0, 0, 640, BAND_H, require("ui.theme").hex(PLACE[seed % #PLACE + 1]))
  if img then
    local cv = PI.blurred(img, ref.slug .. "|kband", 640, BAND_H, { dark = 0.35 })
    if cv then lg.setColor(1, 1, 1, 1); lg.draw(cv, 0, 0) end
  end
  PS.veil(0, 0, 640, BAND_H, 0.45)
  PS.rect(0, BAND_H - 1, 640, 1, c.text, 0.08)
  -- caminho
  local f, fb = PS.font("r", 13, true), PS.font("m", 13, true)
  local x, y = 20, 20 - f:getHeight() / 2
  for _, s in ipairs({ L("Central"), L("Apps do Knulli") }) do
    x = x + PS.text(f, s, x, y, c.dim2) + 8
    PS.text(f, "›", x, y, c.dim)
    x = x + f:getWidth("›") + 8
  end
  local clock = require("core.clock").time()
  local cw = fb:getWidth(clock)
  PS.text(fb, clock, 620 - cw, y, c.text)
  PS.fit(fb, a.name, x, y, 620 - cw - 16 - x, c.text)
  PS.rect(0, 39, 640, 1, c.text, 0.08)
  -- imagem de apresentacao (inteira, 2:1) ou o icone do tipo
  local tw = 600
  if ref then
    local iw, ih = 248, 124
    local ix, iy = 620 - iw, 46
    PS.shadow(ix, iy, iw, ih, 10, 6, 0.5)
    if img then
      PS.rect(ix, iy, iw, ih, c.surf2, 10)
      PS.draw_cover_fit(img, ix, iy, iw, ih)
      PS.fillet(ix, iy, iw, ih, 10, PS.VEIL)
    else
      PS.rect(ix, iy, iw, ih, c.surf2, 10, 0.9)
      require("ui.icons").draw(KA.ICON[a.type] or "generic", ix + iw / 2 - 22, iy + ih / 2 - 22, c.dim, 44 / 24)
      if App.animations and App.animations() then
        local k = 0.5 + 0.5 * math.sin((App.t or 0) * 3)
        PS.rect(ix, iy, iw, ih, c.text, 10, 0.03 + 0.04 * k)
      end
    end
    tw = ix - 20 - 20
  else
    local isz = 96
    local ix, iy = 620 - isz, 52
    PS.rect(ix, iy, isz, isz, c.surf2, 18, 0.9)
    require("ui.icons").draw(KA.ICON[a.type] or "generic", ix + 24, iy + 24, c.accent, 48 / 24)
    tw = ix - 20 - 20
  end
  -- nome, selos e resumo
  local nf = PS.font("x", 22)
  y = 50
  PS.fit(nf, a.name, 20, y, tw, c.text)
  y = y + nf:getHeight() + 8
  x = 20
  for _, b in ipairs(self:badges()) do
    local bf = PS.font("b", 11, true)
    local w = bf:getWidth(PS.tr(b[1])) + 18
    if x + w > 20 + tw then break end
    PS.pill(b[1], x, y, { font = bf, bg = b[2], fg = b[3], px = 9, h = 22 })
    x = x + w + 6
  end
  y = y + 22 + 10
  local sf = PS.font("r", 12)
  local slh = math.floor(sf:getHeight() * 1.3)
  local maxl = math.max(1, math.floor((BAND_H - 6 - y) / slh))
  for i, l in ipairs(PS.lines(sf, a.summary, tw, maxl)) do PS.text(sf, l, 20, y + (i - 1) * slh, c.light) end
end

function KA:badges()
  local c = PS.c()
  local a = self.app
  local out = {}
  if K.TYPE[a.type] then out[#out + 1] = { K.TYPE[a.type], c.surf2, c.dim2 } end
  if a.status == "installed" then out[#out + 1] = { L("INSTALADO"), { c.accent[1], c.accent[2], c.accent[3], 0.16 }, c.accent }
  elseif a.status == "update" then out[#out + 1] = { L("ATUALIZAÇÃO DISPONÍVEL"), PS.WARNBG, c.warn }
  else out[#out + 1] = { L("NÃO INSTALADO"), c.surf2, c.dim2 } end
  if a.review == "experimental" then out[#out + 1] = { L("EXPERIMENTAL"), PS.WARNBG, c.warn } end
  return out
end

--- linhas da ficha: { rotulo, valor }
function KA:rows()
  local a = self.app
  local p = a.pkg or {}
  local ins = p.install or {}
  local rows = {}
  rows[#rows + 1] = { L("Versão na loja"), a.version }
  if a.installed_version then rows[#rows + 1] = { L("Versão instalada"), a.installed_version } end
  rows[#rows + 1] = { L("Licença"), (a.license ~= "" and a.license) or PS.tr(L("não informada")) }
  local d, i = size_of(a, "size"), size_of(a, "installed_size")
  if d then rows[#rows + 1] = { L("Download"), d } end
  if i then rows[#rows + 1] = { L("Instalado ocupa"), i } end
  local deps = p.compatibility and p.compatibility.dependencies
  if type(deps) == "table" and #deps > 0 then rows[#rows + 1] = { L("Dependências"), table.concat(deps, ", ") } end
  if ins.network ~= nil then rows[#rows + 1] = { L("Internet"), ins.network and PS.tr(L("usa a rede")) or PS.tr(L("não usa")) } end
  local cr = KA.creates(a)
  if cr then rows[#rows + 1] = { L("Cria"), cr } end
  if a.repository ~= "" then rows[#rows + 1] = { L("Repositório"), (a.repository:gsub("^https?://", "")) } end
  if ins.destination then rows[#rows + 1] = { L("Pasta"), nouser(ins.destination) } end
  return rows
end

--- quebra em ate maxl linhas tambem no meio de caminhos/links (depois de "/",
--- ou por letra quando um pedaco nao cabe); a ultima linha leva "..."
local function wrap(font, s, w, maxl)
  s = PS.tr(tostring(s or ""))
  local parts = {}
  for p in s:gmatch("[^/%s]*[/%s]*") do if p ~= "" then parts[#parts + 1] = p end end
  local lines, cur = {}, ""
  local function push(t)
    lines[#lines + 1] = (t:gsub("%s+$", ""))
  end
  for _, p in ipairs(parts) do
    if font:getWidth(cur .. p) <= w then cur = cur .. p
    else
      if cur ~= "" then push(cur); cur = "" end
      -- pedaco maior que a linha: corta por letra (UTF-8)
      while font:getWidth(p) > w do
        local cut = ""
        for ch in p:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
          if font:getWidth(cut .. ch) > w then break end
          cut = cut .. ch
        end
        if cut == "" then break end
        push(cut)
        p = p:sub(#cut + 1)
      end
      cur = p
    end
  end
  if cur ~= "" then push(cur) end
  if #lines > maxl then
    local keep = {}
    for i = 1, maxl do keep[i] = lines[i] end
    keep[maxl] = U.ellipsize(font, keep[maxl] .. " …", w)
    lines = keep
  end
  return lines
end
KA.wrap = wrap

local function draw_rows(self)
  local c = PS.c()
  local lf, vf = PS.font("r", 11), PS.font("m", 12)
  local y = BAND_H + 12
  local lw = 108
  local vw = LW - lw
  for _, r in ipairs(self:rows()) do
    local lines = wrap(vf, r[2], vw, 2)
    local h = #lines * vf:getHeight()
    if y + h > PS.FOOT_Y - 8 then break end
    PS.fit(lf, r[1], LX, y + 1, lw - 8, c.dim)
    for k, l in ipairs(lines) do PS.text(vf, l, LX + lw, y + (k - 1) * vf:getHeight(), c.text) end
    y = y + h + 7
  end
end

local function draw_right(self)
  local c = PS.c()
  local a = self.app
  local ins = (a.pkg and a.pkg.install) or {}
  local y = BAND_H + 12
  local by = PS.FOOT_Y - 12 - BTN_H
  -- aviso de instalacao em destaque
  local warn = tostring(ins.warning or "")
  if warn ~= "" then
    local wf = PS.font("r", 11)
    local wl = PS.lines(wf, warn, RW - 40, 4)
    local wlh = wf:getHeight() + 1
    local h = 12 + #wl * wlh + 10
    PS.rect(RX, y, RW, h, PS.WARNBG, 10)
    PS.color(c.warn)
    lg.circle("fill", RX + 16, y + 17, 7, 16)
    local xf = PS.font("b", 11, true)
    PS.text(xf, "!", RX + 16 - xf:getWidth("!") / 2, y + 17 - xf:getHeight() / 2, PS.WARNBG)
    for i, l in ipairs(wl) do PS.text(wf, l, RX + 30, y + 10 + (i - 1) * wlh, c.warn) end
    y = y + h + 10
  end
  -- notas da revisao (2 primeiras; L1/R1 rolam)
  local notes = {}
  for i, n in ipairs(a.notes or {}) do
    if i > 2 then break end
    notes[#notes + 1] = tostring(n)
  end
  local hf = PS.font("b", 10, true)
  local nf = PS.font("r", 11)
  local nlh = nf:getHeight() + 2
  local bottom = by - 10
  if #notes > 0 and bottom - y > hf:getHeight() + nlh then
    PS.track(hf, L("NOTAS DA REVISÃO"), RX, y, c.dim, 0.08)
    y = y + hf:getHeight() + 6
    local all = {}
    for i, n in ipairs(notes) do
      local _, wl = nf:getWrap(n, RW)
      for _, l in ipairs(wl) do all[#all + 1] = l end
      if i < #notes then all[#all + 1] = "" end
    end
    local vis = math.max(1, math.floor((bottom - y) / nlh))
    self.note_max = math.max(0, #all - vis)
    self.note_vis = vis
    self.note_scroll = U.clamp(self.note_scroll or 0, 0, self.note_max)
    for i = 1, vis do
      local l = all[i + self.note_scroll]
      if not l then break end
      if i == vis and i + self.note_scroll < #all and l ~= "" then l = U.ellipsize(nf, l .. " …", RW) end
      PS.text(nf, l, RX, y + (i - 1) * nlh, c.dim2)
    end
    if self.note_max > 0 then
      local th = vis * nlh
      local h = math.max(12, th * vis / #all)
      PS.rect(RX + RW + 6, y, 2, th, c.line, 1, 0.5)
      PS.rect(RX + RW + 6, y + (th - h) * (self.note_scroll / self.note_max), 2, h, c.dim, 1)
    end
  else
    self.note_max, self.note_vis = 0, 1
  end
  -- botoes: principal (Instalar / Atualizar / Abrir) e Opcoes
  local act, label = self:main_action()
  local ow = 124
  local bf = PS.font("b", 15, true)
  if self.loading then
    -- andamento: barra indeterminada no lugar do botao principal
    local w1 = RW - 10 - ow
    PS.rect(RX, by, w1, BTN_H, c.surf2, 12)
    local t = (App.t or 0) * 0.8 % 1
    local seg = w1 * 0.3
    local G = require("ui.gfx")
    G.clip(RX, by, w1, BTN_H)
    PS.rect(RX - seg + (w1 + seg) * t, by + BTN_H - 4, seg, 4, c.accent, 2)
    G.unclip()
    local lf = PS.font("m", 13, true)
    PS.fit(lf, self.loading, RX + 14, by + BTN_H / 2 - lf:getHeight() / 2 - 1, w1 - 28, c.text, "center")
  elseif act then
    local w1 = RW - 10 - ow
    local on = self.focus == "main"
    local k = PS.fk("ka_main", on)
    local x1, y1, ww, hh = PS.grow(RX, by, w1, BTN_H, k, 0.02)
    PS.rect(x1, y1, ww, hh, c.accent, 12)
    if k > 0 then PS.frame(x1 - 3, y1 - 3, ww + 6, hh + 6, c.accent, 15, 2, k * 0.55) end
    local lbl = PS.tr(label)
    if act ~= "open" then
      local s = size_of(self.app, "size")
      if s then lbl = lbl .. "  •  " .. s end
    end
    local gw = 20 + 10 + bf:getWidth(lbl)
    local gx = x1 + (ww - gw) / 2
    PS.glyph("a", gx, y1 + hh / 2 - 10, 20, true)
    PS.text(bf, lbl, gx + 30, y1 + hh / 2 - bf:getHeight() / 2, c.bg)
  else
    -- instalado sem atalho que o hub abra: onde encontrar
    local w1 = RW - 10 - ow
    PS.rect(RX, by, w1, BTN_H, c.surf, 12, 0.85)
    local ins_menu = type(ins.menu) == "table" and ins.menu or nil
    local sys = ins_menu and KA.menu_system(ins_menu.gamelist)
    local f1, f2 = PS.font("m", 12), PS.font("r", 11)
    PS.color(c.accent)
    lg.circle("fill", RX + 16, by + BTN_H / 2, 3.5, 12)
    PS.fit(f1, L("Instalado"), RX + 28, by + 6, w1 - 40, c.text)
    local sub = sys and string.format(PS.tr(L("Menu do Knulli › %s")), sys) or PS.tr(L("Sem atalho no menu do Knulli"))
    PS.fit(f2, sub, RX + 28, by + 8 + f1:getHeight(), w1 - 40, c.dim)
  end
  local on2 = self.focus == "opts"
  local k2 = PS.fk("ka_opts", on2)
  local x2, y2, w2, h2 = PS.grow(RX + RW - ow, by, ow, BTN_H, k2, 0.02)
  PS.rect(x2, y2, w2, h2, c.surf2, 12)
  if k2 > 0 then PS.focus(x2, y2, w2, h2, 12, k2) end
  local of = PS.font("m", 14, true)
  local ol = PS.tr(L("Opções"))
  local ogw = 20 + 8 + of:getWidth(ol)
  local ogx = x2 + (w2 - ogw) / 2
  PS.glyph("x", ogx, y2 + h2 / 2 - 10, 20)
  PS.text(of, ol, ogx + 28, y2 + h2 / 2 - of:getHeight() / 2, c.text)
end

function KA:draw()
  local c = PS.c()
  PS.rect(0, 0, 640, 480, c.bg)
  draw_band(self)
  draw_rows(self)
  draw_right(self)
  local a = self.app
  local stxt, scol
  if self.loading then stxt, scol = L("Trabalhando…"), c.warn
  elseif a.status == "installed" then stxt, scol = L("Instalado"), c.accent
  elseif a.status == "update" then stxt, scol = L("Atualização disponível"), c.warn
  else stxt, scol = L("Não instalado"), c.dim end
  local hints = { { "b", L("Voltar") }, { "x", L("Opções") } }
  if (self.note_max or 0) > 0 then hints[#hints + 1] = { { "l1", "r1" }, L("Rolar notas") } end
  PS.footer(hints)
  local f = PS.font("r", 12)
  local tw = f:getWidth(PS.tr(stxt))
  PS.color(scol)
  lg.circle("fill", 620 - tw - 11, PS.FOOT_Y + 17, 3.5, 12)
  PS.text(f, stxt, 620 - tw, PS.FOOT_Y + 17 - f:getHeight() / 2, PS.DIM2)
end

-- ---------------------------------------------------------------------------
-- acoes

local function done(self) return function() self:refresh() end end

function KA:run_main()
  local act = self:main_action()
  local a = self.app
  if act == "open" then
    App.launch_port({ id = "kapp-" .. tostring(a.id):gsub("[^%w%-_]", "-"), name = a.name, script_override = KA.launch_script(a) })
  elseif act then
    require("ui.kstore_ui").confirm(self, a, act, done(self))
  end
end

--- dialogo "Opcoes": reparar, remover, loja completa
function KA:options()
  local a = self.app
  local KU = require("ui.kstore_ui")
  local btns = {}
  local act, label = self:main_action()
  if act and act ~= "open" then
    btns[#btns + 1] = { label = label, fn = function() self:run_main() end }
  end
  if a.status ~= "none" then
    btns[#btns + 1] = { label = L("Reparar"), sub = L("Confere e repõe os arquivos do app"),
      fn = function() KU.confirm(self, a, "repair", done(self)) end }
    btns[#btns + 1] = { label = L("Remover"), danger = true,
      fn = function() KU.confirm(self, a, "uninstall", done(self)) end }
  end
  -- so com a loja instalada em ports (sem ela o hub usa a propria copia do instalador)
  if K.store_installed() then
    btns[#btns + 1] = { label = L("Abrir a Knulli App Store completa"), sub = L("O hub fecha e abre de novo ao sair da loja"),
      fn = function() KU.open_store() end }
  end
  btns[#btns + 1] = { label = L("Voltar") }
  App.show_dialog({ title = a.name, kind = "info", list = true, body = L("O que você quer fazer?"), buttons = btns })
end

function KA:action(act)
  if act == "b" then App.pop(); return end
  if self.loading then
    if act == "a" or act == "x" then App.toast(L("Aguarde: a Knulli App Store está trabalhando."), "info") end
    return
  end
  if act == "l1" or act == "r1" then
    local d = (act == "l1" and -1 or 1) * math.max(1, (self.note_vis or 3) - 1)
    self.note_scroll = U.clamp((self.note_scroll or 0) + d, 0, self.note_max or 0)
    return
  end
  if act == "x" then self:options(); return end
  local has_main = self:main_action() ~= nil
  if act == "left" then if has_main then self.focus = "main" end
  elseif act == "right" then self.focus = "opts"
  elseif act == "up" then self.note_scroll = math.max(0, (self.note_scroll or 0) - 1)
  elseif act == "down" then self.note_scroll = math.min(self.note_max or 0, (self.note_scroll or 0) + 1)
  elseif act == "a" then
    if self.focus == "opts" or not has_main then self:options() else self:run_main() end
  end
end

return KA
