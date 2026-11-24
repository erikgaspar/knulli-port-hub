-- =============================================================================
--  Knulli (base Batocera): caminhos e leituras do sistema usados por varias
--  funcoes do hub (Biblioteca, Temas do EmulationStation, PortMaster...).
--  Tudo aqui e somente leitura. Conferido num RG35XXH com Knulli (Batocera 42):
--   - sistemas: /usr/share/emulationstation/es_systems.cfg + overrides
--     /userdata/system/configs/emulationstation/es_systems_<nome>.cfg
--   - jogos: /userdata/roms/<sistema> (+ gamelist.xml de cada pasta)
--   - temas: /userdata/themes e /usr/share/emulationstation/themes; tema ativo =
--     ThemeSet do es_settings.cfg; lista da loja do ES em updates.knulli.org
--   - PortMaster: /userdata/system/.local/share/PortMaster (iniciador em
--     /userdata/roms/ports/PortMaster.sh), como o instalador oficial faz
--   - jogos abrem pelo emulatorlauncher (configgen do Batocera)
-- =============================================================================
local U = require("lib.util")

local K = {}

K.ROMS = "/userdata/roms"
K.BIOS = "/userdata/bios"
K.ES_CFG_DIR = "/userdata/system/configs/emulationstation"
K.ES_SETTINGS = K.ES_CFG_DIR .. "/es_settings.cfg"
K.ES_SYSTEMS = "/usr/share/emulationstation/es_systems.cfg"
K.THEMES = "/userdata/themes"
K.SYS_THEMES = "/usr/share/emulationstation/themes"
K.COMPAT_THEMES = "/usr/share/emulationstation/knulli-compatible-themes.txt"
-- lista de temas que o proprio EmulationStation do Knulli baixa (mesmo formato
-- do Batocera); a segunda e a do Batocera, usada se a primeira nao responder
K.THEMES_URLS = { "https://updates.knulli.org/themes.json", "https://updates.batocera.org/themes.json" }
-- "screenshot": "themes/<nome>.jpg" e relativo a este endereco
K.THEMES_IMG_BASE = "https://updates.batocera.org/"
K.PM_BASE = "/userdata/system/.local/share"
K.PM_DIR = K.PM_BASE .. "/PortMaster"
K.CONF = "/userdata/system/knulli.conf"
K.ES_API = "http://127.0.0.1:1234"

--- arquivos de sistemas do EmulationStation: base e overrides (es_systems_*.cfg),
--- na ordem em que o ES le (o override com o mesmo <name> substitui o sistema)
function K.es_systems_files()
  local base = U.exists(K.ES_CFG_DIR .. "/es_systems.cfg") and (K.ES_CFG_DIR .. "/es_systems.cfg") or K.ES_SYSTEMS
  local over = {}
  local out = U.capture("ls -1 " .. U.shq(K.ES_CFG_DIR) .. " 2>/dev/null") or ""
  for name in out:gmatch("[^\n]+") do
    if name:match("^es_systems_.+%.cfg$") then over[#over + 1] = K.ES_CFG_DIR .. "/" .. name end
  end
  table.sort(over)
  return base, over
end

--- valor de uma chave do knulli.conf (ex.: "snes.core"), ou nil
local conf_cache, conf_time = nil, -100
function K.conf_get(key)
  -- lido no maximo a cada 10 s (a Biblioteca consulta ao desenhar a tela)
  if os.time() - conf_time > 10 then
    conf_cache = U.read_file(K.CONF) or U.read_file("/userdata/system/batocera.conf") or ""
    conf_time = os.time()
  end
  local s = conf_cache
  if s == "" then return nil end
  local v
  for line in s:gmatch("[^\n]+") do
    local k, val = line:match("^%s*([^#=%s][^=]-)%s*=%s*(.-)%s*$")
    if k == key then v = val end
  end
  return v ~= "" and v or nil
end

--- tema em uso (ThemeSet do es_settings.cfg do Knulli)
function K.active_theme()
  local s = U.read_file(K.ES_SETTINGS) or ""
  local v = s:match('name="ThemeSet"%s+value="([^"]*)"')
  return v ~= "" and v or nil
end

--- temas marcados como compativeis pelo proprio Knulli (nomes em minusculas)
function K.compatible_themes()
  local set = {}
  local s = U.read_file(K.COMPAT_THEMES) or ""
  for n in s:gmatch("[^,\r\n]+") do
    n = U.trim(n)
    if n ~= "" then set[n:lower()] = true end
  end
  return set
end

-- ---------------------------------------------------------------------------
-- Controles para o emulatorlauncher (o mesmo que o EmulationStation passa em
-- %CONTROLLERSCONFIG%: -pNindex -pNguid -pNname -pNdevicepath -pNnbbuttons
-- -pNnbhats -pNnbaxes). Sem isso o configgen nao configura os botoes do jogo.

--- /proc/bus/input/devices: nome -> /dev/input/eventN (primeiro de cada nome)
local function event_paths()
  local t = {}
  local s = U.read_file("/proc/bus/input/devices") or ""
  for block in (s .. "\n\n"):gmatch("(.-)\n\n") do
    local name = block:match('N: Name="([^"]*)"')
    local ev = block:match("H: Handlers=[^\n]-(event%d+)")
    if name and ev and not t[name] then t[name] = "/dev/input/" .. ev end
  end
  return t
end

--- lista de controles { index, guid, name, path, buttons, hats, axes }
function K.controllers()
  local list = {}
  -- 1) sdl2-jstest (vem no Knulli; usa o mesmo SDL do EmulationStation)
  local out = U.capture("timeout 4 sdl2-jstest --list 2>/dev/null") or ""
  local cur
  for line in out:gmatch("[^\n]+") do
    local name = line:match("^Joystick Name:%s*'(.*)'%s*$")
    if name then cur = { name = name }; list[#list + 1] = cur
    elseif cur then
      local v
      v = line:match("^Joystick Path:%s*'(.*)'%s*$"); if v then cur.path = v end
      v = line:match("^Joystick GUID:%s*(%x+)"); if v then cur.guid = v end
      v = line:match("^Joystick Number:%s*(%d+)"); if v then cur.index = tonumber(v) end
      v = line:match("^Number of Axes:%s*(%d+)"); if v then cur.axes = tonumber(v) end
      v = line:match("^Number of Buttons:%s*(%d+)"); if v then cur.buttons = tonumber(v) end
      v = line:match("^Number of Hats:%s*(%d+)"); if v then cur.hats = tonumber(v) end
    end
  end
  for i = #list, 1, -1 do if not (list[i].guid and list[i].index) then table.remove(list, i) end end
  if #list > 0 then return list end
  -- 2) os controles que o proprio LOVE enxerga
  if love and love.joystick then
    local paths = event_paths()
    for i, j in ipairs(love.joystick.getJoysticks()) do
      local okg, guid = pcall(j.getGUID, j)
      local name = j:getName()
      if okg and guid then
        list[#list + 1] = { index = i - 1, guid = guid, name = name, path = paths[name],
          buttons = j:getButtonCount(), hats = j:getHatCount(), axes = j:getAxisCount() }
      end
    end
  end
  return list
end

--- argumentos de controles prontos para a linha de comando (pode ser "")
function K.controllers_args()
  local t = {}
  for p, c in ipairs(K.controllers()) do
    if p > 8 then break end
    local pre = " -p" .. p
    t[#t + 1] = pre .. "index " .. c.index .. pre .. "guid " .. c.guid .. pre .. "name " .. U.shq(c.name or "")
      .. (c.path and (pre .. "devicepath " .. U.shq(c.path)) or "")
      .. pre .. "nbbuttons " .. (c.buttons or 0) .. pre .. "nbhats " .. (c.hats or 0) .. pre .. "nbaxes " .. (c.axes or 0)
  end
  return table.concat(t)
end

return K
