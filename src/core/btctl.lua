-- =============================================================================
--  Knulli: Bluetooth (controles, fones, caixas de som)
--  Usa exatamente o caminho do proprio Knulli (conferido num RG35XXH):
--   * /usr/bin/knulli-bluetooth ....... list | trust <MAC>|input | remove <MAC>
--                                       | connect/disconnect <MAC> | enable | disable
--   * /usr/bin/knulli-bluetooth-agent . agente (python/dbus) iniciado pelo
--     /etc/init.d/S32bluetooth; pid em /var/run/bluetooth-agent.pid.
--       SIGUSR1 = comeca a procurar (StartDiscovery); se /var/run/bt_listing
--                 existir, escreve nele cada aparelho visto:
--                 <device id="MAC" name="..." status="added|removed" type="..." />
--       SIGUSR2 = para de procurar.
--       /var/run/bt_device = MAC que o agente deve parear/confiar/conectar quando
--                 o aparelho aparecer na busca (vazio = so listar, nada e pareado)
--       /var/run/bt_status = ultima mensagem do agente ("Pairing X...", ...)
--       /var/run/bt_cancel = cancela o "trust" em andamento
--   * chave controllers.bluetooth.enabled (knulli.conf); o enable/disable do
--     knulli-bluetooth grava a chave e reinicia S31sixad + S32bluetooth.
--   * pareados = /var/lib/bluetooth/<adaptador>/<MAC>/info (Trusted=true),
--     guardados em /userdata/system/bluetooth/bluetooth.tar pelo "save".
--  E o mesmo fluxo do menu do EmulationStation: "start_live_devices" (busca com
--  lista) e, com a busca ligada, "trust <MAC>" (pareia o escolhido).
--  Tudo que espera roda em core/shjob (segundo plano). Somente no Knulli.
-- =============================================================================
local U = require("lib.util")

local M = {}

M.TOOL = "/usr/bin/knulli-bluetooth"
M.AGENT_PID = "/var/run/bluetooth-agent.pid"
M.LISTING = "/var/run/bt_listing"
M.DEVICE = "/var/run/bt_device"
M.STATUS = "/var/run/bt_status"
M.CANCEL = "/var/run/bt_cancel"
M.SCAN_SECS = 30                 -- a busca para sozinha depois disso

-- sem as bibliotecas do runtime do LOVE e com mensagens em ingles (o parse
-- depende delas); 2>&1 porque o shjob descarta o stderr
local PRE = "unset LD_LIBRARY_PATH; export LC_ALL=C; "
local function shc(cmd) return "sh -c " .. U.shq(PRE .. "{ " .. cmd .. "; } 2>&1") end

M.scanning = false
M.scan_t0 = nil
M.busy = nil                     -- "pair" | "power" | "connect" | ... enquanto um comando roda

--- endereco valido para o knulli-bluetooth (ele exige maiusculas)
function M.valid_mac(mac)
  return type(mac) == "string" and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end
local function norm(mac) return mac and mac:upper() or nil end

function M.available()
  return U.exists(M.TOOL) and U.exec_ok("command -v bluetoothctl >/dev/null 2>&1")
end

--- Bluetooth ligado nas configuracoes do Knulli?
function M.enabled()
  local v = require("core.knulli_hw").get("controllers.bluetooth.enabled")
  return v == "1"
end

--- pid do agente se estiver vivo
function M.agent_pid()
  local p = tonumber(U.trim(U.read_file(M.AGENT_PID) or ""))
  if p and U.exec_ok("kill -0 " .. p .. " 2>/dev/null") then return p end
end

--- servico rodando de fato (adaptador + agente)
function M.running()
  return M.agent_pid() ~= nil and U.exists("/sys/class/bluetooth/hci0")
end

-- ---------------------------------------------------------------------------
-- leitura (tudo em segundo plano)

local function attr(s, k) return s:match(k .. '="([^"]*)"') end

--- "<device id=.. name=.. type=.. connected=..>" do knulli-bluetooth list
local function parse_list(out)
  local t = {}
  for l in (out or ""):gmatch("[^\n]+") do
    local id = attr(l, "id")
    if id and M.valid_mac(id) then
      local name = attr(l, "name")
      t[#t + 1] = { mac = norm(id), name = (name and name ~= "" and name ~= "None") and name or nil,
        type = attr(l, "type") or "", connected = attr(l, "connected") == "yes" }
    end
  end
  return t
end

--- "Device MAC Nome" do bluetoothctl devices -> { [MAC] = nome }
local function parse_devices(out)
  local t = {}
  for l in (out or ""):gmatch("[^\n]+") do
    local mac, name = l:match("^Device%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s*(.*)$")
    if mac then
      name = U.trim(name or "")
      -- sem nome o bluetoothctl repete o endereco com tracos (1D-B8-...)
      if name ~= "" and not name:match("^%x%x%-%x%x%-%x%x%-%x%x%-%x%x%-%x%x$") then t[norm(mac)] = name end
    end
  end
  return t
end

--- tipo pelo Icon do bluez (input-gaming, audio-headset, ...)
local function parse_info(out)
  local i = {}
  i.icon = out:match("\n%s*Icon:%s*(%S+)")
  i.paired = out:match("\n%s*Paired:%s*yes") ~= nil
  i.trusted = out:match("\n%s*Trusted:%s*yes") ~= nil
  i.connected = out:match("\n%s*Connected:%s*yes") ~= nil
  i.battery = tonumber(out:match("Battery Percentage:%s*0x%x+%s*%((%d+)%)") or "")
  return i
end

--- tipo simplificado: joystick | audio | input | phone | computer | ""
function M.kind(t)
  t = tostring(t or "")
  if t == "joystick" or t == "input-gaming" then return "joystick" end
  if t == "audio" or t:match("^audio%-") then return "audio" end
  if t:match("^input") then return "input" end
  if t:match("phone") then return "phone" end
  if t:match("computer") then return "computer" end
  return ""
end

--- estado completo em segundo plano. cb(st) com:
---   st = { enabled, running, powered, name, addr, discovering,
---          paired = { {mac, name, type, kind, connected, battery} } }
function M.status(cb)
  local st = { enabled = M.enabled(), running = M.running(), paired = {} }
  if not st.running then
    if cb then cb(st) end
    return
  end
  local cmds = {
    shc("timeout 4 bluetoothctl show"),
    shc("timeout 8 " .. M.TOOL .. " list"),
    shc("timeout 4 bluetoothctl devices"),
  }
  require("core.shjob").start(cmds, function(res)
    local show = res and res[1] and res[1].out or ""
    st.addr = show:match("Controller%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
    st.name = show:match("\n%s*Alias:%s*([^\n]+)") or show:match("\n%s*Name:%s*([^\n]+)")
    st.powered = show:match("\n%s*Powered:%s*yes") ~= nil
    st.discovering = show:match("\n%s*Discovering:%s*yes") ~= nil
    st.paired = parse_list(res and res[2] and res[2].out)
    local names = parse_devices(res and res[3] and res[3].out)
    for _, d in ipairs(st.paired) do
      d.name = d.name or names[d.mac]
      d.kind = M.kind(d.type)
    end
    -- detalhes (tipo/bateria) dos pareados: um bluetoothctl info por aparelho
    if #st.paired == 0 then if cb then cb(st) end return end
    local ic = {}
    for _, d in ipairs(st.paired) do ic[#ic + 1] = shc("timeout 3 bluetoothctl -- info " .. d.mac) end
    require("core.shjob").start(ic, function(r2)
      for i, d in ipairs(st.paired) do
        local inf = parse_info("\n" .. (r2 and r2[i] and r2[i].out or ""))
        if inf.icon and d.kind == "" then d.kind = M.kind(inf.icon) end
        if r2 and r2[i] then d.connected = inf.connected end
        d.battery = inf.battery
      end
      if cb then cb(st) end
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- busca (o agente do Knulli procura e escreve a lista; nada e pareado)

--- comeca a procurar. true ou false, motivo ("off" | "agent")
function M.scan_start()
  local pid = M.agent_pid()
  if not pid then return false, "agent" end
  -- bt_device vazio = o agente so lista (connect_device sai em "No filter")
  if not U.write_file(M.DEVICE, "") then return false, "agent" end
  U.write_file(M.LISTING, "")
  if not U.exec_ok("kill -USR1 " .. pid .. " 2>/dev/null") then return false, "agent" end
  M.scanning = true
  M.scan_t0 = love and love.timer and love.timer.getTime() or os.time()
  M.seen = {}
  return true
end

--- para a busca (o mesmo que stop_bt_agent do knulli-bluetooth)
function M.scan_stop()
  if not M.scanning then return end
  M.scanning = false
  local pid = M.agent_pid()
  if pid then os.execute("kill -USR2 " .. pid .. " 2>/dev/null") end
  os.remove(M.DEVICE)
  os.remove(M.LISTING)
end

--- aparelhos vistos na busca, na ordem em que apareceram (leitura de um
--- arquivo pequeno; pode ser chamado a cada segundo).
--- { {mac, name, kind} } sem os ja removidos
function M.scan_list()
  local txt = U.read_file(M.LISTING)
  M.seen = M.seen or {}
  if txt then
    for l in txt:gmatch("[^\n]+") do
      local id = attr(l, "id")
      if id and M.valid_mac(id) then
        local mac = norm(id)
        local d = M.seen[mac]
        if not d then
          d = { mac = mac, order = 0 }
          M.seen[mac] = d
          M.seen_n = (M.seen_n or 0) + 1
          d.order = M.seen_n
        end
        local name = attr(l, "name")
        if name and name ~= "" and name ~= "None" then d.name = name end
        local ty = M.kind(attr(l, "type"))
        if ty ~= "" then d.kind = ty end
        d.gone = attr(l, "status") == "removed"
      end
    end
  end
  local out = {}
  for _, d in pairs(M.seen) do if not d.gone then out[#out + 1] = d end end
  -- com nome primeiro (os "sem nome" quase sempre sao anuncios BLE de outros aparelhos)
  table.sort(out, function(a, b)
    if (a.name ~= nil) ~= (b.name ~= nil) then return a.name ~= nil end
    return a.order < b.order
  end)
  return out
end

--- completa os nomes que o agente ainda nao tinha (bluetoothctl devices)
function M.fill_names(cb)
  require("core.shjob").start({ shc("timeout 4 bluetoothctl devices") }, function(res)
    local names = parse_devices(res and res[1] and res[1].out)
    for mac, n in pairs(names) do
      local d = M.seen and M.seen[mac]
      if d and not d.name then d.name = n end
    end
    if cb then cb() end
  end)
end

--- segundos desde o inicio da busca
function M.scan_elapsed()
  if not M.scanning or not M.scan_t0 then return 0 end
  local now = love and love.timer and love.timer.getTime() or os.time()
  return now - M.scan_t0
end

-- ---------------------------------------------------------------------------
-- acoes (cada uma num comando em segundo plano; cb(ok, mensagem))

local function last_line(s)
  local last
  for l in (s or ""):gmatch("[^\n]+") do if U.trim(l) ~= "" then last = U.trim(l) end end
  return last
end

local function job(kind, cmd, cb, check)
  if M.busy then if cb then cb(false, "busy") end return false end
  M.busy = kind
  require("core.shjob").start({ shc(cmd) }, function(res, err)
    M.busy = nil
    local r = res and res[1]
    local ok = r and r.rc == 0
    local msg = r and last_line(r.out) or err
    if ok and check then ok = check(r.out or "") end
    U.log("Bluetooth:", kind, ok and "ok" or "falhou", tostring(msg))
    if cb then cb(ok and true or false, msg) end
  end)
  return true
end

--- pareia/confia/conecta um aparelho visto na busca (o agente faz o pareamento
--- quando o aparelho aparece com a busca ligada; ate 60 s). A busca termina
--- junto (o knulli-bluetooth para o agente no fim).
function M.pair(mac, cb)
  mac = norm(mac)
  if not M.valid_mac(mac) then if cb then cb(false, "mac") end return false end
  if not M.scanning then
    local ok = M.scan_start()
    if not ok then if cb then cb(false, "agent") end return false end
  end
  return job("pair", "timeout 75 " .. M.TOOL .. " trust " .. mac, function(ok, msg)
    M.scanning = false
    -- sucesso de verdade = o aparelho ficou na lista de pareados (Trusted=true)
    require("core.shjob").start({ shc("timeout 8 " .. M.TOOL .. " list") }, function(res)
      local paired = false
      for _, d in ipairs(parse_list(res and res[1] and res[1].out)) do if d.mac == mac then paired = true end end
      if cb then cb(paired, msg) end
    end)
  end)
end

--- modo automatico do Knulli: pareia o primeiro CONTROLE (input-*) que entrar
--- em modo de pareamento (o agente mesmo comeca a procurar). Ate 60 s.
function M.pair_input(cb)
  M.scan_stop()
  return job("pair", "timeout 75 " .. M.TOOL .. " trust input", function(ok, msg)
    M.scanning = false
    if cb then cb(ok, msg) end
  end)
end

--- cancela o pareamento em andamento (o loop do knulli-bluetooth olha a cada 0,5 s)
function M.cancel_pair()
  U.write_file(M.CANCEL, "")
  os.execute("(sleep 1.2; rm -f " .. M.CANCEL .. ") >/dev/null 2>&1 &")
end

function M.connect(mac, cb)
  mac = norm(mac)
  if not M.valid_mac(mac) then if cb then cb(false, "mac") end return false end
  return job("connect", "timeout 25 " .. M.TOOL .. " connect " .. mac, cb)
end

function M.disconnect(mac, cb)
  mac = norm(mac)
  if not M.valid_mac(mac) then if cb then cb(false, "mac") end return false end
  return job("disconnect", "timeout 15 " .. M.TOOL .. " disconnect " .. mac, cb)
end

--- esquece (untrust + remove + apaga /var/lib/bluetooth/*/MAC + save)
function M.forget(mac, cb)
  mac = norm(mac)
  if not M.valid_mac(mac) then if cb then cb(false, "mac") end return false end
  return job("forget", "timeout 20 " .. M.TOOL .. " remove " .. mac, cb)
end

--- liga/desliga (grava controllers.bluetooth.enabled e reinicia os servicos)
function M.set_enabled(on, cb)
  M.scan_stop()
  return job("power", "timeout 40 " .. M.TOOL .. " " .. (on and "enable" or "disable"), function(ok, msg)
    if cb then cb(ok and (M.enabled() == (on and true or false)), msg) end
  end)
end

--- ultima mensagem do agente (para mostrar durante o pareamento)
function M.agent_status()
  local s = U.read_file(M.STATUS)
  return s and U.trim(s) ~= "" and U.trim(s) or nil
end

return M
