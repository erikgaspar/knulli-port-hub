-- =============================================================================
--  Hardware no Knulli (base Batocera): ferramentas do proprio sistema.
--  Usado so quando C.KNULLI (o launcher exporta PORTHUB_FW=knulli).
--
--   * brilho ............ knulli-brightness (le/grava em %) e a chave
--                         display.brightness (S27brightness reaplica no boot)
--   * LED de energia .... knulli-power-led power on|off (grava system.power.led,
--                         S25powerled reaplica no boot); so com a capacidade pwrled
--   * saida de audio .... knulli-audio list/set + audio.device (S27audioconfig)
--   * volume ............ knulli-audio getSystemVolume/setSystemVolume + audio.volume
--   * temperatura de cor  knulli-display-settings temperature N + system.display.temperature
--                         (S27displaysettings reaplica no boot)
--   * aparelho .......... /boot/boot/knulli.board, knulli.board.capability,
--                         /usr/share/knulli/knulli.arch, knulli-version, Device Tree
--  As chaves sao as mesmas que o menu do Knulli grava em /userdata/system/knulli.conf.
--  O Knulli roda como root (sem sudo, sem systemd).
-- =============================================================================
local U = require("lib.util")

local K = {}

-- sem as bibliotecas do runtime do LOVE (o launcher do PortMaster as poe no caminho)
-- e com LC_ALL=C: o Knulli exporta LC_ALL=pt_BR.UTF-8 e ai o pactl responde
-- traduzido ("Coletor padrao"), o knulli-audio nao acha a saida padrao e o
-- getSystemVolume volta vazio
local PRE = "LD_LIBRARY_PATH= LC_ALL=C "

--- roda um comando e devolve (saida sem espacos nas pontas, codigo de saida)
function K.run(cmd)
  local out = U.capture("{ " .. PRE .. cmd .. "; } 2>&1; echo \"__EXIT:$?\"") or ""
  local code = tonumber(out:match("__EXIT:(%d+)%s*$"))
  return U.trim((out:gsub("__EXIT:%d+%s*$", ""))), code
end

local HAS = {}
function K.has(cmd)
  if HAS[cmd] == nil then
    HAS[cmd] = U.exec_ok("command -v " .. cmd .. " >/dev/null 2>&1")
  end
  return HAS[cmd]
end

-- ---------------------------------------------------------------------------
-- configuracoes do Knulli (knulli.conf)

--- valor da chave ou nil (chave ausente/comentada)
function K.get(key)
  if not K.has("knulli-settings-get") then return nil end
  local out, code = K.run("knulli-settings-get " .. U.shq(key))
  if code ~= 0 or out == "" then return nil end
  return out
end

--- grava a chave (mesmo comando que os scripts do sistema usam). true/false
function K.set(key, value)
  if not K.has("knulli-settings-set") then return false end
  local _, code = K.run("knulli-settings-set " .. U.shq(key) .. " " .. U.shq(tostring(value)))
  return code == 0
end

--- capacidades da placa (knulli.board.capability: pwrled, rgb, hdmi, ...)
local CAPS
function K.caps()
  if not CAPS then
    CAPS = {}
    local txt = U.read_file("/boot/boot/knulli.board.capability") or ""
    for w in txt:gmatch("%S+") do CAPS[w] = true end
  end
  return CAPS
end
function K.cap(name) return K.caps()[name] == true end

-- ---------------------------------------------------------------------------
-- aparelho

local function line1(s) return s and U.trim(s:match("^[^\n]*") or "") or nil end
local function nz(s) if s and s ~= "" then return s end end

--- { model, board, arch, version, caps = {lista} } com o que o sistema informar
function K.device()
  local d = {}
  local m = U.read_file("/proc/device-tree/model")
  d.model = nz(m and U.trim((m:gsub("%z", ""))) or nil)
  d.board = nz(line1(U.read_file("/boot/boot/knulli.board")))
  d.arch = nz(line1(U.read_file("/usr/share/knulli/knulli.arch")))
  d.version = nz(line1(U.read_file("/usr/share/knulli/knulli.version")))
  if not d.version and K.has("knulli-version") then d.version = nz(line1((K.run("knulli-version")))) end
  local caps = {}
  for c in pairs(K.caps()) do if c ~= d.board then caps[#caps + 1] = c end end
  table.sort(caps)
  d.caps = caps
  return d
end

--- "Knulli scarab (2026/05/11)" a partir de "scarab 2026/05/11 00:09"
function K.version_label(v)
  if not v then return "Knulli" end
  local name, date = v:match("^(%S+)%s+(%d+/%d+/%d+)")
  if name then return "Knulli " .. name .. " (" .. date .. ")" end
  return "Knulli " .. v
end

-- ---------------------------------------------------------------------------
-- brilho (knulli-brightness: sem argumento le %, com um numero grava %)

function K.brightness_get()
  if not K.has("knulli-brightness") then return nil end
  local out, code = K.run("knulli-brightness")
  local v = code == 0 and tonumber(out:match("(%d+)%s*$")) or nil
  if v and v >= 0 and v <= 100 then return v end
end

function K.brightness_set(pct)
  pct = math.floor(tonumber(pct) or 0)
  if pct < 1 or pct > 100 then return false end
  local _, code = K.run("knulli-brightness " .. pct .. " >/dev/null")
  return code == 0
end

--- grava como o Knulli grava (S27brightness le display.brightness no boot)
function K.brightness_save(pct) return K.set("display.brightness", pct) end

-- ---------------------------------------------------------------------------
-- LED de energia

function K.power_led_get()
  local v = K.get("system.power.led")
  if v == "0" then return false end
  return true                                  -- padrao do Knulli: ligado
end

function K.power_led_set(on)
  if not K.cap("pwrled") or not K.has("knulli-power-led") then return false, "unsupported" end
  local _, code = K.run("knulli-power-led power " .. (on and "on" or "off"))
  if code ~= 0 then return false, "fail" end
  -- o proprio knulli-power-led grava system.power.led; confere
  if K.power_led_get() ~= (on and true or false) then K.set("system.power.led", on and "1" or "0") end
  return true
end

-- ---------------------------------------------------------------------------
-- audio

--- nome amigavel da saida (o pactl descreve as duas internas como "Built-in Audio Stereo")
local function sink_kind(id)
  if id == "auto" then return "auto" end
  local l = id:lower()
  if l:match("^bluez") then return "bt" end
  if l:match("hdmi") or l:match("ahub") then return "hdmi" end
  if l:match("codec") or l:match("internal") then return "internal" end
  return "other"
end
K.sink_kind = sink_kind

--- saidas: { {id, desc, kind}, ... } (a primeira e "auto")
function K.audio_list()
  local t = {}
  if not K.has("knulli-audio") then return t end
  local out = K.run("knulli-audio list")
  for l in (out .. "\n"):gmatch("([^\n]*)\n") do
    local id, desc = l:match("^([^\t]+)\t(.*)$")
    if id and id ~= "" and not id:find("[%s'\"]") then
      t[#t + 1] = { id = id, desc = desc, kind = sink_kind(id) }
    end
  end
  return t
end

function K.audio_get() return K.get("audio.device") or "auto" end

function K.audio_set(id)
  local ok_id = false
  for _, s in ipairs(K.audio_list()) do if s.id == id then ok_id = true end end
  if not ok_id then return false, "invalid" end
  local _, code = K.run("knulli-audio set " .. U.shq(id) .. " >/dev/null")
  if code ~= 0 then return false, "fail" end
  K.set("audio.device", id)
  -- a troca de saida pode voltar ao volume da saida nova: reaplica o volume salvo
  local v = tonumber(K.get("audio.volume") or "")
  if v then K.run("knulli-audio setSystemVolume " .. math.floor(v) .. " >/dev/null") end
  return true
end

function K.volume_max()
  local v = tonumber(K.get("audio.volume.boost") or "")
  return (v and v >= 100 and v <= 200) and v or 100
end

function K.volume_get()
  if not K.has("knulli-audio") then return nil end
  local out, code = K.run("knulli-audio getSystemVolume")
  local v = code == 0 and tonumber(out:match("(%d+)%s*$")) or nil
  return v
end

--- aplica agora e grava audio.volume (o S27audioconfig usa no boot)
function K.volume_set(v)
  v = tonumber(v)
  if not v or v < 0 or v > K.volume_max() or v % 1 ~= 0 then return false, "invalid" end
  local _, code = K.run("knulli-audio setSystemVolume " .. v .. " >/dev/null")
  if code ~= 0 then return false, "fail" end
  K.set("audio.volume", v)
  return true
end

-- ---------------------------------------------------------------------------
-- tela: temperatura de cor (0..100, 50 = neutro)

function K.display_caps()
  local t = {}
  if not K.has("knulli-display-settings") then return t end
  local out = K.run("knulli-display-settings --get-capabilities")
  for w in out:gmatch("%S+") do t[w] = true end
  return t
end

function K.temperature_get()
  local v = tonumber(K.get("system.display.temperature") or "")
  if v and v >= 0 and v <= 100 then return math.floor(v) end
  return 50
end

function K.temperature_set(v)
  v = tonumber(v)
  if not v or v < 0 or v > 100 or v % 1 ~= 0 then return false, "invalid" end
  local _, code = K.run("knulli-display-settings temperature " .. v .. " >/dev/null")
  if code ~= 0 then return false, "fail" end
  K.set("system.display.temperature", v)
  return true
end

-- ---------------------------------------------------------------------------
--- linhas do knulli.conf ligadas a estes ajustes (para "Ver configuracao atual")
function K.config_lines()
  local txt = U.read_file("/userdata/system/knulli.conf")
  if not txt then return nil end
  local t = {}
  for l in txt:gmatch("[^\n]+") do
    local k = l:match("^%s*([%w_.%-]+)%s*=")
    if k and (k:match("^audio%.") or k:match("^display%.") or k:match("^system%.display%.")
        or k:match("^system%.power%.") or k:match("^led%.") or k:match("^system%.cpu%.")) then
      t[#t + 1] = U.trim(l)
    end
  end
  return t
end

return K
