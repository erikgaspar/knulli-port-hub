-- =============================================================================
--  Knulli (base Batocera): rede pelo connman (connmanctl) e configuracoes do
--  proprio sistema (knulli-settings-get/set, /userdata/system/knulli.conf).
--
--  Como o Knulli guarda o Wi-Fi (verificado em /usr/bin/knulli-wifi e
--  /etc/init.d/S08connman):
--   * redes salvas = "vagas" wifi.ssid/wifi.key, wifi2.*, wifi3.* do knulli.conf;
--   * ao iniciar/recarregar, o S08connman gera /var/lib/connman/knulli_wifi<X>.config
--     (servico "provisionado": Name + Passphrase + Autoconnect) para cada vaga;
--   * o menu do EmulationStation usa "knulli-wifi enable <ssid> <senha>", que grava
--     a vaga 1 e roda "/etc/init.d/S08connman reload". Fazemos o mesmo caminho,
--     entao a rede continua salva depois de reiniciar.
--  Senhas: nunca vao para logs, relatorios ou arquivos do hub (so para o
--  knulli.conf, que e onde o proprio sistema as guarda).
--
--  Usado por core/wifi.lua (Knulli) e core/net.lua (sinal/SSID). As funcoes que
--  esperam (conectar, pesquisar) rodam dentro de threads/wifi_thread.lua.
-- =============================================================================
local U = require("lib.util")

local K = {}

K.CONF_DIR = "/var/lib/connman"
K.CONNMAN_INIT = "/etc/init.d/S08connman"
K.SLOTS = { "", "2", "3" }        -- wifi.*, wifi2.*, wifi3.*

--- roda um comando e devolve saida, codigo de saida
local function run(cmd)
  local out = U.capture("{ " .. cmd .. "; } 2>&1; echo \"__EXIT:$?\"") or ""
  local code = tonumber(out:match("__EXIT:(%d+)%s*$"))
  out = out:gsub("__EXIT:%d+%s*$", "")
  return out, code
end
K.run = run

local function sleep(s)
  if love and love.timer then love.timer.sleep(s) else os.execute("sleep " .. s) end
end

local function lines(s)
  local t = {}
  for l in (s or ""):gmatch("[^\n]+") do t[#t + 1] = l end
  return t
end

function K.has_connman()
  return U.exec_ok("command -v connmanctl >/dev/null 2>&1")
end

--- o connmand esta respondendo?
function K.running()
  local out = run("connmanctl state")
  return out:find("State%s*=") ~= nil
end

-- ---------------------------------------------------------------------------
-- Configuracoes do Knulli (knulli.conf)
function K.get(key)
  local out, code = run("knulli-settings-get " .. U.shq(key))
  if code ~= 0 then return nil end
  out = U.trim(out)
  return out ~= "" and out or nil
end

--- grava pares chave/valor numa chamada so: K.set({ { "wifi.ssid", "x" }, ... })
function K.set(pairs_)
  local args = {}
  for _, kv in ipairs(pairs_) do args[#args + 1] = U.shq(kv[1]) .. " " .. U.shq(kv[2] or "") end
  if #args == 0 then return true end
  local _, code = run("knulli-settings-set " .. table.concat(args, " ") .. " >/dev/null")
  return code == 0
end

local function slot_key(x, what) return "wifi" .. x .. "." .. what end

--- vagas de Wi-Fi do knulli.conf: { { slot = "", ssid = "..." }, ... } (sem senha)
function K.slots()
  local t = {}
  for _, x in ipairs(K.SLOTS) do
    local ssid = K.get(slot_key(x, "ssid"))
    if ssid then t[#t + 1] = { slot = x, ssid = ssid } end
  end
  return t
end

-- ---------------------------------------------------------------------------
-- connmanctl

--- uma linha de "connmanctl services": "*AO Nome da rede      wifi_..._managed_psk"
function K.parse_services(txt)
  local list = {}
  for _, l in ipairs(lines(txt)) do
    local id = l:match("(%S+)%s*$")
    if id and (id:match("^wifi_") or id:match("^ethernet_")) then
      local flags = l:sub(1, 3)
      local name = U.trim(l:sub(5, #l - #id))
      local e = {
        id = id, name = name,
        favorite = flags:sub(1, 1) == "*",
        autoconnect = flags:sub(2, 2) == "A",
        online = flags:sub(3, 3) == "O",
        ready = flags:sub(3, 3) == "R",
        wifi = id:match("^wifi_") ~= nil,
        sec = id:match("_managed_(%w+)$") or id:match("_adhoc_(%w+)$") or "",
      }
      list[#list + 1] = e
    end
  end
  return list
end

function K.services()
  local out, code = run("connmanctl services")
  if code ~= 0 then return nil, U.trim(out) end
  return K.parse_services(out)
end

--- lista entre colchetes: "[ Method=dhcp, Address=1.2.3.4 ]" -> tabela (e lista)
local function bracket(v)
  local t, arr = {}, {}
  local inner = (v or ""):match("^%[%s*(.-)%s*%]$") or v or ""
  for item in inner:gmatch("[^,]+") do
    item = U.trim(item)
    local k, val = item:match("^([%w%.]+)=(.*)$")
    if k then t[k] = val elseif item ~= "" then arr[#arr + 1] = item end
  end
  return t, arr
end

--- detalhes de "connmanctl services <id>"
function K.parse_service(txt)
  local p = {}
  for _, l in ipairs(lines(txt)) do
    local k, v = l:match("^%s+([%w%.]+)%s=%s?(.*)$")
    if k then p[k] = v end
  end
  local s = {
    name = p.Name, state = p.State, error = p.Error, type = p.Type,
    strength = tonumber(p.Strength or ""), favorite = p.Favorite == "True",
    immutable = p.Immutable == "True",
  }
  local _, sec = bracket(p.Security)
  s.security = sec
  local eth = bracket(p.Ethernet)
  s.iface = eth.Interface
  local v4 = bracket(p.IPv4)
  s.ip = v4.Address
  s.gateway = v4.Gateway
  local _, dns = bracket(p.Nameservers)
  s.dns = dns
  return s
end

function K.service(id)
  local out, code = run("connmanctl services " .. U.shq(id))
  if code ~= 0 or not out:find("State", 1, true) then return nil end
  local s = K.parse_service(out)
  s.id = id
  return s
end

--- tecnologia Wi-Fi ligada? (true/false; nil se o connman nao informou)
function K.parse_powered(txt)
  local inwifi, powered = false, nil
  for _, l in ipairs(lines(txt)) do
    if l:match("^/net/connman/technology/") then inwifi = l:match("/wifi%s*$") ~= nil
    elseif inwifi then
      local v = l:match("^%s+Powered%s=%s(%a+)")
      if v then powered = v == "True" end
    end
  end
  return powered
end

function K.powered()
  return K.parse_powered((run("connmanctl technologies")))
end

--- servico Wi-Fi em uso (online/ready), com detalhes. list = K.services() opcional
function K.current(list)
  list = list or K.services() or {}
  for _, e in ipairs(list) do
    if e.wifi and (e.online or e.ready) then
      local s = K.service(e.id)
      if s then return s end
    end
  end
  -- coluna de estado vazia em algumas versoes: confere os favoritos
  for _, e in ipairs(list) do
    if e.wifi and e.favorite then
      local s = K.service(e.id)
      if s and (s.state == "online" or s.state == "ready") then return s end
    end
  end
  return nil
end

--- interface sem fio (prefere a que esta "up"; wlan1 do RG35XXH fica "down")
function K.wifi_iface()
  local out = U.capture("ls /sys/class/net 2>/dev/null") or ""
  local first
  for name in out:gmatch("%S+") do
    if name:match("^wl") and not name:match("^p2p") then
      first = first or name
      if U.trim(U.read_file("/sys/class/net/" .. name .. "/operstate") or "") == "up" then return name end
    end
  end
  return first
end

--- seguranca do id do connman -> texto parecido com o do NetworkManager
function K.sec_label(sec)
  if sec == "none" or sec == "" then return "" end
  if sec == "psk" then return "WPA/WPA2" end
  if sec == "wep" then return "WEP" end
  if sec == "ieee8021x" then return "802.1X" end
  return sec:upper()
end

--- sinal da rede em uso (0-100), nil se nao conectado
function K.signal()
  local s = K.current()
  return s and s.strength or nil, s
end

-- ---------------------------------------------------------------------------
-- Wi-Fi no formato de core/wifi.lua

local W = {}
K.wifi = W

function W.status()
  local st = {}
  if not K.has_connman() then st.nmcli = false; return st end
  st.nmcli, st.backend = true, "connman"
  st.nm_running = K.running()
  st.dns = {}
  if not st.nm_running then return st end
  st.radio = K.powered()
  st.enabled = K.get("wifi.enabled") == "1"
  local list = K.services() or {}
  local cur = K.current(list)
  st.iface = (cur and cur.iface) or K.wifi_iface()
  if cur then
    st.service_id = cur.id
    st.connection = cur.name
    st.signal = cur.strength
    st.ip = cur.ip
    st.gateway = cur.gateway
    st.dns = cur.dns or {}
    st.dev_state = cur.state
  end
  if st.ip and st.ip:match("^127%.") then st.ip = nil end
  st.connected = cur ~= nil and st.ip ~= nil
  return st
end

--- pesquisa redes; devolve { ssid, signal, security, in_use, id } (uma por SSID)
function W.scan()
  run("connmanctl scan wifi")
  local list, err = K.services()
  if not list then return nil, err end
  local named = 0
  for _, e in ipairs(list) do if e.wifi and e.name ~= "" then named = named + 1 end end
  if named <= 1 then
    -- resultado da pesquisa ainda chegando (o knulli-wifi tambem espera 1 s)
    sleep(1.5)
    list = K.services() or list
  end
  local by, res = {}, {}
  for _, e in ipairs(list) do
    if e.wifi and e.name ~= "" then
      local d = K.service(e.id) or {}
      local n = { ssid = e.name, signal = d.strength or 0, security = K.sec_label(e.sec),
        in_use = e.online or e.ready or d.state == "online" or d.state == "ready", id = e.id }
      local cur = by[n.ssid]
      if not cur then by[n.ssid] = n; res[#res + 1] = n
      else
        if n.signal > cur.signal then cur.signal, cur.id = n.signal, n.id end
        cur.in_use = cur.in_use or n.in_use
      end
    end
  end
  table.sort(res, function(a, b)
    if a.in_use ~= b.in_use then return a.in_use end
    return a.signal > b.signal
  end)
  return res
end

--- redes salvas: vagas do knulli.conf + favoritos do connman fora delas
function W.saved()
  if not K.has_connman() then return nil, "connmanctl" end
  local cur = K.current()
  local t, seen = {}, {}
  for _, s in ipairs(K.slots()) do
    if not seen[s.ssid] then
      seen[s.ssid] = true
      t[#t + 1] = { name = s.ssid, ssid = s.ssid, uuid = "knulli:" .. s.slot,
        active = cur ~= nil and cur.name == s.ssid }
    end
  end
  for _, e in ipairs(K.services() or {}) do
    if e.wifi and e.favorite and e.name ~= "" and not seen[e.name] then
      seen[e.name] = true
      t[#t + 1] = { name = e.name, ssid = e.name, uuid = "connman:" .. e.id,
        active = cur ~= nil and cur.id == e.id }
    end
  end
  return t
end

--- servico do connman com esse nome (pesquisa de novo enquanto nao aparece)
local function find_service(ssid, secs)
  for i = 1, math.max(1, secs) do
    local best
    for _, e in ipairs(K.services() or {}) do
      if e.wifi and e.name == ssid then
        if e.online or e.ready then return e.id end
        best = best or e.id
      end
    end
    if best then return best end
    if i % 3 == 1 then run("connmanctl scan wifi") else sleep(1) end
  end
  return nil
end

--- classifica a saida/erro de uma tentativa
local function failure(out, svc)
  local o = ((out or "") .. " " .. ((svc and svc.error) or "")):lower()
  if o:find("invalid%-key") or o:find("invalid key", 1, true) or o:find("auth", 1, true)
      or o:find("passphrase", 1, true) then
    return "auth"
  end
  if o:find("not found", 1, true) or o:find("not registered", 1, true) then return "unavailable" end
  if o:find("timeout", 1, true) or o:find("timed out", 1, true) then return "timeout" end
  if o:find("permission", 1, true) or o:find("not permitted", 1, true) then return "permission" end
  if o:find("aborted", 1, true) or o:find("canceled", 1, true) or o:find("cancelled", 1, true) then return "cancelled" end
  return "failed"
end

--- espera conectado (com IP) a essa rede
local function wait_connected(ssid, secs)
  for _ = 1, secs * 2 do
    local st = W.status()
    if st.connected and (not ssid or st.connection == ssid) then return st end
    sleep(0.5)
  end
  return nil
end

--- conecta num servico ja provisionado/salvo (o connman tem a senha)
local function connect_id(id, ssid)
  local cur = K.current()
  if cur and cur.id == id and cur.ip then return { ok = true, state = "connected", ip = cur.ip } end
  local out, code = run("timeout 45 connmanctl connect " .. U.shq(id))
  -- erro do connect (senha errada etc.): espera pouco; sucesso: espera o IP
  local st = wait_connected(ssid, code == 0 and 15 or 3)
  if st then return { ok = true, state = "connected", ip = st.ip } end
  local svc = K.service(id)
  local o = out:lower()
  if o:find("already connected", 1, true) then
    st = wait_connected(nil, 5)
    if st then return { ok = true, state = "connected", ip = st.ip } end
  end
  if code == 124 and not (svc and svc.error) then return { state = "timeout" } end
  return { state = failure(out, svc), detail = U.trim(out) }
end

--- recarrega o connman como o knulli-wifi (gera os .config das vagas)
local function reload()
  run(K.CONNMAN_INIT .. " reload >/dev/null 2>&1")
  -- o S08connman liga o Wi-Fi e pesquisa em segundo plano; espera responder
  for _ = 1, 20 do
    if K.running() and K.powered() then break end
    sleep(0.5)
  end
end

--- Conecta. net = { ssid, security }, opts = { psk, uuid }
--- Grava a rede numa vaga do knulli.conf (a vaga 1 e a que o menu do Knulli
--- mostra) e recarrega o connman. Se falhar, volta a configuracao anterior.
function W.connect(net, opts)
  local res = { ssid = net.ssid }
  local psk = opts.psk
  if opts.uuid and (not psk or psk == "") then return W.reconnect(opts.uuid) end
  local sec = (net.security or ""):upper()
  if sec:find("802.1X", 1, true) or sec:find("EAP", 1, true) then res.state = "enterprise"; return res end
  if sec:find("WEP", 1, true) then res.state = "wep"; return res end

  -- vaga: a que ja tem essa rede, senao a 1 (a anterior desce para uma vaga livre)
  local keys = {}
  for _, x in ipairs(K.SLOTS) do
    keys[#keys + 1] = slot_key(x, "ssid"); keys[#keys + 1] = slot_key(x, "key")
  end
  keys[#keys + 1] = "wifi.enabled"
  local old = {}
  for _, k in ipairs(keys) do old[k] = K.get(k) or "" end
  local slot
  for _, x in ipairs(K.SLOTS) do if old[slot_key(x, "ssid")] == net.ssid then slot = x; break end end
  local set = { { "wifi.enabled", "1" } }
  if not slot then
    slot = ""
    local prev = old["wifi.ssid"]
    if prev ~= "" and prev ~= old["wifi2.ssid"] and prev ~= old["wifi3.ssid"] then
      for _, x in ipairs({ "2", "3" }) do
        if old[slot_key(x, "ssid")] == "" then
          set[#set + 1] = { slot_key(x, "ssid"), prev }
          set[#set + 1] = { slot_key(x, "key"), old["wifi.key"] }
          break
        end
      end
    end
  end
  set[#set + 1] = { slot_key(slot, "ssid"), net.ssid }
  set[#set + 1] = { slot_key(slot, "key"), psk or "" }
  if not K.set(set) then res.state = "permission"; return res end

  reload()
  local id = find_service(net.ssid, 12)
  local r
  if not id then r = { state = "unavailable" } else r = connect_id(id, net.ssid) end
  if r.ok then
    res.ok, res.state, res.ip = true, "connected", r.ip
    return res
  end
  -- deu errado: devolve as vagas como estavam e reconecta a rede anterior
  local back = {}
  for _, k in ipairs(keys) do back[#back + 1] = { k, old[k] } end
  K.set(back)
  reload()
  res.state, res.detail = r.state, r.detail
  return res
end

--- id salvo ("knulli:<vaga>" ou "connman:<servico>") -> ssid, servico
local function resolve(uuid)
  local x = (uuid or ""):match("^knulli:(.*)$")
  if x then return K.get(slot_key(x, "ssid")), nil, x end
  local id = (uuid or ""):match("^connman:(.+)$")
  if id then
    local s = K.service(id)
    return s and s.name, id
  end
  return nil
end

function W.reconnect(uuid)
  local ssid, id = resolve(uuid)
  if not ssid and not id then return { state = "unavailable" } end
  if K.powered() == false then
    run("knulli-wifi enable >/dev/null 2>&1")
  end
  id = id or find_service(ssid, 9)
  if not id then return { state = "unavailable" } end
  return connect_id(id, ssid)
end

function W.disconnect()
  local cur = K.current()
  if not cur then return true, "" end
  local out, code = run("connmanctl disconnect " .. U.shq(cur.id))
  return code == 0, U.trim(out)
end

--- esquece: limpa a vaga do knulli.conf e o perfil do connman (nao reinicia a rede)
function W.forget(uuid)
  local ssid, id, x = resolve(uuid)
  if x then
    if not K.set({ { slot_key(x, "ssid"), "" }, { slot_key(x, "key"), "" } }) then return false, "knulli-settings-set" end
    os.remove(K.CONF_DIR .. "/knulli_wifi" .. x .. ".config")   -- o connman remove o servico provisionado
    sleep(0.5)
  end
  if not id and ssid then
    for _, e in ipairs(K.services() or {}) do if e.wifi and e.name == ssid then id = e.id; break end end
  end
  if id then
    local s = K.service(id)
    if s and s.favorite and not s.immutable then
      local out, code = run("connmanctl config " .. U.shq(id) .. " --remove")
      if code ~= 0 and not x then return false, U.trim(out) end
    end
  end
  return true, ""
end

--- liga/desliga o Wi-Fi como o menu do Knulli (grava wifi.enabled)
function W.radio(on)
  local out, code = run("knulli-wifi " .. (on and "enable" or "disable"))
  -- "enable" sem rede salva ou sem IP em 20 s tambem conta: o radio ligou
  if on and code ~= 0 and K.powered() then code = 0 end
  return code == 0, U.trim(out)
end

return K
