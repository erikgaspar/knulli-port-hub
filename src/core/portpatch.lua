-- Adaptacoes de launchers do catalogo R36S para o Knulli.
local M = {}

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
    -- O pacote inclui o driver do RK3326. No H700 usa o driver do sistema.
    patched = patched:gsub('\nif %[%s*%-f "%$GAMEDIR/libs%.aarch64/libmali%-bifrost%-g31%-rxp0%-gbm%.so" %]; then',
      '\nif [ -f "/usr/lib/libmali.so" ]; then\n  MALI_BLOB="/usr/lib/libmali.so"\nelif [ -f "$GAMEDIR/libs.aarch64/libmali-bifrost-g31-rxp0-gbm.so" ]; then')
  end
  return patched
end

return M
