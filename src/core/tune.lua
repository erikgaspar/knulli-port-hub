-- =============================================================================
--  Knulli Port Hub: perfis recomendados por port (catalogo extra, h700.tune)
--
--  Formato (knulli-catalog.json, dentro de "h700" do port; tudo opcional):
--    "tune": {
--      "perf": true,      -- "sempre em modo desempenho" (tambem pelo EmulationStation)
--      "zram": true,      -- liga a memoria extra (zram) do Knulli
--      "cpu_max": true,   -- CPU no teto de fabrica (o modo desempenho ja faz)
--      "note": "texto curto",
--      "settings": [ { "file": "savedata/Settings.cfg",   -- relativo a pasta do port
--                      "format": "json" | "ini",
--                      "section": "Video",                  -- so ini (opcional)
--                      "set": { "ResolutionScale": 0.75 },
--                      "default": { "ResolutionScale": 1.0 },
--                      "only_if_missing_or_default": true } ] }
--  Settings: so arquivos DENTRO da pasta do port; troca so o valor das chaves
--  (o resto do arquivo fica igual, byte a byte); copia do arquivo antes da
--  primeira mudanca em conf/tune-backup/<id>/; com only_if_missing_or_default,
--  so muda se a chave nao existe ou ainda esta no valor "default" (o usuario
--  nao mexeu). Arquivo que ainda nao existe (o jogo cria na 1a vez): fica
--  pendente e e aplicado na proxima vez.
--  Estado: conf/tune.json { [id] = { date, perf_before, zram_on, settings = {
--    { file, key, before (nil = nao existia), after, backup } } } }
--  Preferencias: Prefs "tune_auto" ("0" = nao aplicar ao instalar),
--  "tune_asked" ("1" = ja perguntou uma vez).
-- =============================================================================
local C = require("config")
local U = require("lib.util")
local json = require("lib.json")
local Prefs = require("core.prefs")

local M = {}

M.FILE = C.APP_DIR .. "/conf/tune.json"
M.BACKUP = C.APP_DIR .. "/conf/tune-backup"

local function str(v) return type(v) == "string" and v or nil end
local function sid(id) return (tostring(id or ""):gsub("[^%w_%-]", "")) end

--- perfil do port (limpo) ou nil
function M.get(p)
  local t = p and p.h700 and p.h700.tune
  if type(t) ~= "table" then return nil end
  local out = { perf = t.perf == true, zram = t.zram == true, cpu_max = t.cpu_max == true,
    note = str(t.note), settings = {} }
  for _, s in ipairs(type(t.settings) == "table" and t.settings or {}) do
    local file = type(s) == "table" and str(s.file)
    local fmt = type(s) == "table" and (s.format == "ini" and "ini" or (s.format == "json" and "json" or nil))
    if file and fmt and type(s.set) == "table" and not file:find("%.%.") and file:sub(1, 1) ~= "/" then
      local set = {}
      for k, v in pairs(s.set) do
        if type(k) == "string" and k:match("^[%w_%.%-]+$") and (type(v) == "number" or type(v) == "boolean" or type(v) == "string") then
          set[k] = v
        end
      end
      out.settings[#out.settings + 1] = { file = file, format = fmt, section = str(s.section), set = set,
        default = type(s.default) == "table" and s.default or {}, safe = s.only_if_missing_or_default ~= false }
    end
  end
  if not out.perf and not out.zram and not out.cpu_max and #out.settings == 0 then return nil end
  return out
end

-- ---------------------------------------------------------------------------
-- estado
-- ---------------------------------------------------------------------------
local function load_state()
  local ok, d = pcall(json.decode, U.read_file(M.FILE) or "")
  return (ok and type(d) == "table") and d or {}
end
local function save_state(d)
  os.execute("mkdir -p " .. U.shq(C.APP_DIR .. "/conf") .. " 2>/dev/null")
  return U.write_file(M.FILE, json.encode(d, true))
end
M.load_state = load_state

function M.record(id) return load_state()[sid(id)] end

-- ---------------------------------------------------------------------------
-- pasta do port e caminhos seguros
-- ---------------------------------------------------------------------------
--- pasta do port na raiz de ports (das entradas que o hub registrou)
function M.port_dir(p)
  local ok, Manifest = pcall(require, "core.manifest")
  local found = ok and Manifest.found(p) or {}
  for _, n in ipairs(found or {}) do
    n = tostring(n)
    if not n:find("/") and not n:find("%.%.") and not n:lower():match("%.sh$") and U.is_dir(C.PORTS_DIR .. "/" .. n) then
      return C.PORTS_DIR .. "/" .. n
    end
  end
  return nil
end

local function realpath(p)
  local out = U.capture("readlink -f " .. U.shq(p) .. " 2>/dev/null")
  out = out and out:gsub("%s+$", "") or ""
  return out ~= "" and out or nil
end

--- caminho do arquivo de configuracao (so dentro da pasta do port) ou nil, erro
function M.safe_path(dir, file)
  if not dir or file:find("%.%.") or file:sub(1, 1) == "/" then return nil, "caminho inválido" end
  local path = dir .. "/" .. file
  local rd = realpath(dir)
  local rp = realpath(path)
  if not rd then return nil, "pasta do port não encontrada" end
  -- arquivo ainda nao existe: confere a pasta dele
  if not rp then
    local pd = realpath(path:match("^(.*)/[^/]*$"))
    if not pd or (pd ~= rd and pd:sub(1, #rd + 1) ~= rd .. "/") then return nil, "fora da pasta do port" end
    return path
  end
  if rp:sub(1, #rd + 1) ~= rd .. "/" then return nil, "fora da pasta do port" end
  return path
end

-- ---------------------------------------------------------------------------
-- leitura/escrita de valores (troca so o valor; o resto do arquivo fica igual)
-- ---------------------------------------------------------------------------
--- numero/booleano como texto; inteiro segue o estilo do valor antigo ("1.0" ou "1")
local function lit(v, old)
  if type(v) == "boolean" then return v and "true" or "false" end
  if type(v) == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then
      if old and not old:find("[%.eE]") then return string.format("%d", v) end
      return string.format("%.1f", v)
    end
    return (string.format("%.6g", v))
  end
  return nil
end

local function esc(k) return (k:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

--- JSON: valor atual de "key" (primeira ocorrencia; numero, booleano ou texto)
function M.json_get(text, key)
  local pat = '"' .. esc(key) .. '"%s*:%s*'
  local s, e = text:find(pat)
  if not s then return nil, false end
  local rest = text:sub(e + 1)
  local num = rest:match("^(%-?%d+%.?%d*[eE]?[%+%-]?%d*)")
  if num and num ~= "" then return tonumber(num), true end
  if rest:match("^true") then return true, true end
  if rest:match("^false") then return false, true end
  local sv = rest:match('^"(.-)"')
  if sv then return sv, true end
  return nil, true
end

--- JSON: troca (ou acrescenta no fim do objeto principal) "key": valor
function M.json_set(text, key, v)
  local pat = '("' .. esc(key) .. '"%s*:%s*)'
  local s, e, pre = text:find(pat)
  local function val_for(old)
    if type(v) == "string" then return '"' .. v:gsub('[\\"]', "\\%0") .. '"' end
    return lit(v, old)
  end
  local val
  if s then
    local rest = text:sub(e + 1)
    local old = rest:match("^(%-?%d+%.?%d*[eE]?[%+%-]?%d*)")
    if not old or old == "" then old = rest:match("^true") or rest:match("^false") or rest:match('^"[^"]*"') end
    if not old then return nil end
    return text:sub(1, e) .. val_for(old) .. rest:sub(#old + 1)
  end
  -- nao existe: antes do ultimo "}" (mesmo recuo da linha anterior)
  val = val_for(nil)
  local last = text:match(".*()}")
  if not last then return nil end
  local body = text:sub(1, last - 1):gsub("%s+$", "")
  local indent = body:match("\n([ \t]+)[^\n]*$") or "\t"
  local comma = body:sub(-1) == "{" and "" or ","
  return body .. comma .. "\n" .. indent .. '"' .. key .. '": ' .. val .. "\n" .. text:sub(last)
end

--- INI: valor (texto) de key em [section] (ou fora de secao)
function M.ini_get(text, section, key)
  local cur = nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local sec = line:match("^%s*%[(.-)%]")
    if sec then cur = sec
    elseif (section == nil or cur == section) then
      local k, v = line:match("^%s*([^=;#]-)%s*=%s*(.-)%s*\r?$")
      if k == key then return tonumber(v) or (v == "true" and true) or (v == "false" and false) or v, true end
    end
  end
  return nil, false
end

function M.ini_set(text, section, key, v)
  local val = type(v) == "string" and v or (type(v) == "boolean" and (v and "true" or "false") or lit(v, "0"))
  local out, cur, done, sec_end = {}, nil, false, nil
  local lines = {}
  for line in (text .. (text:sub(-1) == "\n" and "" or "\n")):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  for _, line in ipairs(lines) do
    local sec = line:match("^%s*%[(.-)%]")
    if sec then
      if cur == section and section and not done then sec_end = #out end
      cur = sec
    elseif not done and (section == nil or cur == section) then
      local pre, k = line:match("^(%s*)([^=;#]-)%s*=")
      if k == key then line = pre .. key .. "=" .. val; done = true end
    end
    out[#out + 1] = line
  end
  if not done then
    if section and cur == section then sec_end = #out end
    if section and sec_end then table.insert(out, sec_end + 1, key .. "=" .. val)
    elseif section then out[#out + 1] = "[" .. section .. "]"; out[#out + 1] = key .. "=" .. val
    else table.insert(out, 1, key .. "=" .. val) end
  end
  return table.concat(out, "\n") .. "\n"
end

local function getv(fmt, text, s, key)
  if fmt == "json" then return M.json_get(text, key) end
  return M.ini_get(text, s.section, key)
end
local function setv(fmt, text, s, key, v)
  if fmt == "json" then return M.json_set(text, key, v) end
  return M.ini_set(text, s.section, key, v)
end
local function same(a, b)
  if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-9 end
  return a == b
end

-- ---------------------------------------------------------------------------
-- aplicar / desfazer
-- ---------------------------------------------------------------------------
--- aplica so os settings. -> lista de resultados { file, key, status = applied|kept_user|pending|error, msg }
function M.apply_settings(p, t, rec)
  local res = {}
  local dir = M.port_dir(p)
  rec.settings = rec.settings or {}
  local function find(file, key)
    for _, r in ipairs(rec.settings) do if r.file == file and r.key == key then return r end end
  end
  for _, s in ipairs(t.settings) do
    local path, perr = dir and M.safe_path(dir, s.file)
    if not path then
      res[#res + 1] = { file = s.file, status = "error", msg = perr or "pasta do port não encontrada" }
    else
      local text = U.read_file(path)
      if not text then
        res[#res + 1] = { file = s.file, status = "pending", msg = "o arquivo ainda não existe (abra o jogo uma vez)" }
      else
        local changed = false
        for key, want in pairs(s.set) do
          local cur, has = getv(s.format, text, s, key)
          local prev = find(s.file, key)
          local def = s.default[key]
          local free = not has or (def ~= nil and same(cur, def)) or (prev and same(cur, prev.after))
          if same(cur, want) then
            res[#res + 1] = { file = s.file, key = key, status = "applied" }
            if not prev then rec.settings[#rec.settings + 1] = { file = s.file, key = key, before = cur, had = has, after = want } end
          elseif s.safe and not free then
            res[#res + 1] = { file = s.file, key = key, status = "kept_user", msg = tostring(cur) }
          else
            local nt = setv(s.format, text, s, key, want)
            if nt then
              text = nt; changed = true
              if not prev then
                rec.settings[#rec.settings + 1] = { file = s.file, key = key, before = cur, had = has, after = want }
              else
                prev.after = want
              end
              res[#res + 1] = { file = s.file, key = key, status = "applied" }
            else
              res[#res + 1] = { file = s.file, key = key, status = "error", msg = "formato não reconhecido" }
            end
          end
        end
        if changed then
          -- copia do arquivo antes da primeira mudanca
          local bdir = M.BACKUP .. "/" .. sid(p.id)
          local bfile = bdir .. "/" .. s.file:gsub("/", "__")
          if not U.exists(bfile) then
            os.execute("mkdir -p " .. U.shq(bdir) .. " 2>/dev/null")
            U.write_file(bfile, U.read_file(path) or "")
          end
          for _, r in ipairs(rec.settings) do if r.file == s.file then r.backup = bfile end end
          local f = io.open(path, "wb")
          if f then f:write(text); f:close()
          else res[#res + 1] = { file = s.file, status = "error", msg = "não foi possível gravar" } end
        end
      end
    end
  end
  return res
end

--- aplica o perfil todo. on_done(resumo) (o zram liga em segundo plano)
function M.apply(p, script, on_done)
  local t = M.get(p)
  if not t then if on_done then on_done(nil) end; return end
  local Perf = require("core.perf")
  local st = load_state()
  local k = sid(p.id)
  local rec = st[k] or { perf_before = Perf.always(p.id) }
  rec.date = os.date("%Y-%m-%d %H:%M")
  local sum = { perf = false, zram = nil, settings = {} }
  if t.perf and C.KNULLI then
    Perf.set_always_port(p, script, true)
    sum.perf = true
  end
  sum.settings = M.apply_settings(p, t, rec)
  st[k] = rec
  save_state(st)
  local Z = package.loaded["core.zram"] or (pcall(require, "core.zram") and require("core.zram"))
  if t.zram and Z and Z.available() and not Z.status().active then
    Z.set(true, function(ok)
      rec.zram_on = ok or nil
      local s2 = load_state(); if s2[k] then s2[k].zram_on = ok or nil; save_state(s2) end
      sum.zram = ok
      if on_done then on_done(sum) end
    end)
    return
  end
  sum.zram = t.zram and Z and Z.available() and Z.status().active or nil
  if on_done then on_done(sum) end
end

--- desfaz: tira "sempre em modo desempenho" (se o perfil ligou) e volta os valores
--- que o perfil mudou (so se o usuario nao mudou depois). A memoria extra fica.
function M.undo(p, script)
  local st = load_state()
  local k = sid(p.id)
  local rec = st[k]
  local Perf = require("core.perf")
  local t = M.get(p) or { settings = {} }
  if not rec then
    if Perf.always(p.id) then Perf.set_always_port(p, script, false) end
    return true
  end
  if not rec.perf_before then Perf.set_always_port(p, script, false) end
  local dir = M.port_dir(p)
  local fmt_of, sec_of = {}, {}
  for _, s in ipairs(t.settings) do fmt_of[s.file] = s.format; sec_of[s.file] = s end
  local by_file = {}
  for _, r in ipairs(rec.settings or {}) do
    by_file[r.file] = by_file[r.file] or {}
    table.insert(by_file[r.file], r)
  end
  for file, list in pairs(by_file) do
    local path = dir and M.safe_path(dir, file)
    local text = path and U.read_file(path)
    local fmt = fmt_of[file] or (file:lower():match("%.ini$") and "ini" or "json")
    if text then
      local changed = false
      for _, r in ipairs(list) do
        local cur = getv(fmt, text, sec_of[file] or {}, r.key)
        if same(cur, r.after) and r.before ~= nil and not same(r.before, r.after) then
          local nt = setv(fmt, text, sec_of[file] or {}, r.key, r.before)
          if nt then text = nt; changed = true end
        elseif same(cur, r.after) and not r.had and r.backup and U.exists(r.backup) then
          -- a chave nao existia: volta a copia do arquivo (se nada mais mudou nele)
          local orig = U.read_file(r.backup)
          if orig and M.json_get(orig, r.key) == nil then text = orig; changed = true end
        end
      end
      if changed then
        local f = io.open(path, "wb")
        if f then f:write(text); f:close() end
      end
    end
  end
  st[k] = nil
  save_state(st)
  return true
end

--- estado do perfil: "applied" | "partial" | "none"; e o texto do que o perfil faz
function M.state(p)
  local t = M.get(p)
  if not t then return nil end
  local rec = M.record(p.id)
  local Perf = require("core.perf")
  local ok = true
  if t.perf and not Perf.always(p.id) then ok = false end
  if #t.settings > 0 then
    local dir = M.port_dir(p)
    for _, s in ipairs(t.settings) do
      local path = dir and M.safe_path(dir, s.file)
      local text = path and U.read_file(path)
      for key, want in pairs(s.set) do
        local cur = text and getv(s.format, text, s, key)
        if not same(cur, want) then ok = false end
      end
    end
  end
  if ok then return "applied", t end
  if rec or (t.perf and Perf.always(p.id)) then return "partial", t end
  return "none", t
end

--- linhas do que o perfil faz (texto em PT; a tela traduz)
function M.describe(t)
  local L = require("lib.i18n").L
  local tr = require("lib.i18n").tr
  local out = {}
  if t.perf then out[#out + 1] = tr(L("Sempre em modo desempenho (CPU e GPU no máximo, também pelo menu do Knulli)")) end
  if t.zram then out[#out + 1] = tr(L("Memória extra (zram) ligada")) end
  for _, s in ipairs(t.settings) do
    for key, v in pairs(s.set) do
      out[#out + 1] = string.format(tr(L("%s: %s = %s")), s.file, key, tostring(v))
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- preferencias
-- ---------------------------------------------------------------------------
function M.auto() return Prefs.get("tune_auto") ~= "0" end
function M.set_auto(on) Prefs.set("tune_auto", on and "1" or "0") end
function M.asked() return Prefs.get("tune_asked") == "1" end
function M.set_asked() Prefs.set("tune_asked", "1") end

return M
