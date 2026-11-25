-- Adaptacoes de launchers do catalogo R36S para o Knulli.
local M = {}

function M.overlay(slug)
  if slug ~= "ducktales-remastered" then return nil end
  return { name = "ducktales-1.1.11.zip", label = "DuckTales 1.1.11", size = 14502402,
    url = "https://github.com/NextOs-Ports/nextos-universal-ports/releases/download/ducktales-v1.1.11/ducktales.zip",
    sha256 = "9922ea45a9c409089f9ba1bf97fbf96240746d5e138e691246a5db68243257c0" }
end

function M.version_at_least(current, minimum)
  if type(current) ~= "string" or type(minimum) ~= "string"
      or not current:match("^%d[%d%.]*$") or not minimum:match("^%d[%d%.]*$") then return false end
  local a, b = {}, {}
  for n in current:gmatch("%d+") do a[#a + 1] = tonumber(n) end
  for n in minimum:gmatch("%d+") do b[#b + 1] = tonumber(n) end
  for i = 1, math.max(#a, #b) do
    if (a[i] or 0) ~= (b[i] or 0) then return (a[i] or 0) > (b[i] or 0) end
  end
  return true
end

function M.apply(text, ports_dir, slug)
  -- Somente scripts de texto; nunca modifica dados ou executaveis do port.
  if not text or text:find("\0", 1, true) then return text end
  -- Launchers V7 ja encontram o Knulli e podem ter integridade verificada.
  if text:find("NXV7_PORT=", 1, true) and text:find("/userdata/roms/ports", 1, true) then return text end
  local patched = text:gsub("([\"'%s=])/roms/ports()", function(prefix, after)
    local next_char = text:sub(after, after)
    if next_char ~= "" and not next_char:match("[/\"'%s;)]") then return prefix .. "/roms/ports" end
    return prefix .. ports_dir
  end)
  if slug == "super-mario-strikers" then
    patched = patched:gsub('SDL3SHIM_SDL2_VIDEODRIVER="kmsdrm"', 'SDL3SHIM_SDL2_VIDEODRIVER="mali"')
    if not patched:find('export SDL_VIDEO_EGL_DRIVER=', 1, true) then
      patched = patched:gsub('export SDL_VIDEODRIVER="sdl2"',
        'export SDL_VIDEO_EGL_DRIVER="/usr/lib/libmali.so"\nexport SDL_VIDEO_GL_DRIVER="/usr/lib/libmali.so"\nexport SDL_VIDEODRIVER="sdl2"', 1)
    end
    -- O pacote inclui o driver do RK3326. No H700 usa o driver do sistema.
    patched = patched:gsub('\nif %[%s*%-f "%$GAMEDIR/libs%.aarch64/libmali%-bifrost%-g31%-rxp0%-gbm%.so" %]; then',
      '\nif [ -f "/usr/lib/libmali.so" ]; then\n  MALI_BLOB="/usr/lib/libmali.so"\nelif [ -f "$GAMEDIR/libs.aarch64/libmali-bifrost-g31-rxp0-gbm.so" ]; then')
  end
  return patched
end

function M.duplicate_strikers(root_text, nested_text, ports_dir)
  if not root_text or not nested_text then return false end
  return M.apply(root_text, ports_dir, "super-mario-strikers"):gsub("\r\n", "\n")
    == M.apply(nested_text, ports_dir, "super-mario-strikers"):gsub("\r\n", "\n")
end

return M
