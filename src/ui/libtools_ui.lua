-- =============================================================================
--  Biblioteca: manutencao (so Knulli) - telas
--  M.open() abre o menu com as 4 ferramentas (core/libtools.lua):
--    1. Faxina das listas de jogos   2. Imagens automaticas
--    3. Jogos de varios discos       4. Videos de previa
--  Tudo usa a lista generica (ui/screens/infolist.lua). As varreduras e as
--  alteracoes rodam em segundo plano (threads/libtools_thread.lua); da para
--  sair da tela: o aviso aparece quando terminar. Nada muda sem confirmacao.
-- =============================================================================
local L = require("lib.i18n").L
local I18N = require("lib.i18n")
local U = require("lib.util")
local C = require("config")
local T = require("ui.theme")
local LT = require("core.libtools")

local M = {}

local function tr(s) return I18N.tr(L(s)) end
local function fmt(s, ...) return string.format(tr(s), ...) end

local function setup()
  local root = os.getenv("PORTHUB_LIBTOOLS_ROOT") or require("core.spacemgr").roms_root()
  LT.setup({ root = root, backup_dir = C.APP_DIR .. "/backups/gamelists", cache_dir = C.APP_DIR .. "/cache/libtools" })
end

local OP_LABEL = {
  clean_scan = L("Procurando problemas nas listas"), clean_apply = L("Arrumando as listas"),
  images_scan = L("Procurando jogos sem imagem"), images_run = L("Baixando imagens"),
  multidisc_scan = L("Procurando jogos de vários discos"), multidisc_apply = L("Criando as listas .m3u"),
  video_scan = L("Verificando os vídeos"), video_clean = L("Limpando vídeos que não existem"),
  video_shrink = L("Reduzindo vídeos"),
}

local function status_line(job)
  local st = job.poll()
  local s = tr(OP_LABEL[job.op] or "Trabalhando")
  if (st.total or 0) > 0 then s = s .. string.format("  %d/%d", st.done or 0, st.total) end
  if job.cancelling then s = s .. "  •  " .. tr("cancelando...") end
  return s, st.text
end

--- mostra o progresso do job na lista (texto central + nome do item no topo)
local function attach(scr)
  scr.update = function(self)
    if LT.job and self.loading then
      local a, b = status_line(LT.job)
      self.loading = a
      self.p.sub = b ~= "" and b or nil
    end
  end
end

--- roda uma operacao com a lista em "carregando". on_ok(res) so se der certo.
local function run(scr, op, params, on_ok)
  if LT.job then
    App.toast(L("Espere a tarefa em andamento terminar."), "warn")
    return false
  end
  scr.loading = tr(OP_LABEL[op] or "Trabalhando")
  attach(scr)
  local job = LT.run(op, params, function(ok, res)
    scr.loading = nil
    if not ok then
      App.show_dialog({ title = L("A tarefa falhou"), kind = "error", body = tostring(res) })
      return
    end
    on_ok(res)
  end)
  if not job then scr.loading = nil; App.toast(L("Espere a tarefa em andamento terminar."), "warn"); return false end
  return true
end

local function errors_text(list)
  if not list or #list == 0 then return "" end
  local t = {}
  for i = 1, math.min(#list, 6) do t[#t + 1] = "• " .. tostring(list[i]) end
  if #list > 6 then t[#t + 1] = fmt("... e mais %d", #list - 6) end
  return "\n\n" .. tr("Problemas:") .. "\n" .. table.concat(t, "\n")
end

local function backup_note()
  return fmt("Antes de gravar, uma cópia de cada gamelist fica em %s.", LT.cfg.backup_dir .. "/" .. os.date("%Y-%m-%d"))
end

local function reload_es_note()
  return tr("O EmulationStation mostra as mudanças quando você sair do Port Hub (a lista de jogos é recarregada).")
end

-------------------------------------------------------------------------------
-- 1. Faxina
-------------------------------------------------------------------------------
local function clean_screen()
  local data
  local function kind_count(kind, only_on)
    local n = 0
    for _, it in ipairs(data and data.items or {}) do
      if it.kind == kind and (not only_on or not it.skip) then
        n = n + (kind == "scripts" and #it.scripts or 1)
      end
    end
    return n
  end
  local function to_items(scr)
    local items = {}
    for _, it in ipairs(data.items) do
      local tag, tagc, text, sub, detail
      if it.kind == "dead" then
        tag, tagc = L("SEM ARQUIVO"), T.c.red
        text = it.name
        sub = U.upper(it.sys) .. "  •  " .. it.path:gsub("^%./", "")
        if #it.media > 0 then sub = sub .. "  •  " .. fmt("%d imagem(ns), %s", #it.media, U.format_bytes(it.bytes)) end
        detail = tr("O arquivo não está mais no cartão:") .. "\n" .. LT.sys_dir(it.sys) .. "/" .. it.path:gsub("^%./", "")
          .. "\n\n" .. tr("A entrada sai da lista de jogos.")
          .. (#it.media > 0 and ("\n" .. tr("Também são apagados (só esta entrada usava):") .. "\n" .. table.concat(it.media, "\n")) or "")
      elseif it.kind == "scripts" then
        tag, tagc = L("SCRIPTS"), T.c.yellow
        text = U.upper(it.sys) .. " / " .. it.folder
        sub = fmt("%d script(s) interno(s) aparecendo na lista", #it.scripts)
          .. (it.hide_folder and ("  •  " .. tr("a pasta também fica oculta")) or "")
        detail = tr("Ficam ocultos (<hidden>) no EmulationStation; nenhum arquivo é apagado:") .. "\n"
          .. table.concat(it.scripts, "\n")
      else
        tag, tagc = L("PASTA ERRADA"), T.c.orange
        text = it.name
        sub = U.upper(it.sys) .. " → " .. U.upper(it.target) .. "  •  ." .. it.ext
        detail = fmt("A extensão .%s não é aceita pelo sistema %s (o EmulationStation pode nem mostrar este jogo). Ela é de: %s.",
          it.ext, it.sys, table.concat(it.targets, ", "))
          .. "\n\n" .. LT.sys_dir(it.sys) .. "/" .. it.file
          .. "\n\n" .. fmt("Se você incluir este item, o arquivo é movido para %s (com a entrada e as imagens).", LT.sys_dir(it.target))
      end
      if it.skip then
        tagc = T.c.faint
        sub = tr("IGNORADO") .. "  •  " .. sub
      end
      items[#items + 1] = { tag = tag, tagc = tagc, text = text, sub = sub, detail = detail, ref = it }
    end
    scr.items = items
    scr.sel = math.min(scr.sel or 1, math.max(1, #items))
    scr.p.sub = fmt("%d itens", #items)
  end
  local function summary()
    local st = data.stats
    local body = fmt("%d entradas sem arquivo (%d imagens, %s)", st.dead, st.media, U.format_bytes(st.media_bytes)) .. "\n"
      .. fmt("%d scripts internos de ports aparecendo na lista", st.scripts) .. "\n"
      .. fmt("%d ROMs com extensão de outro sistema", st.suspects)
    if #data.skipped > 0 then
      local t = {}
      for _, s in ipairs(data.skipped) do t[#t + 1] = string.format("%s (%d/%d)", s.sys, s.dead, s.total) end
      body = body .. "\n\n" .. tr("Ignorados (quase todos os arquivos sumiram; pasta não montada?):") .. " " .. table.concat(t, ", ")
    end
    if st.suspects > 0 then
      body = body .. "\n\n" .. tr("ROMs na pasta errada começam IGNORADAS: veja cada uma e inclua só as que quiser mover.")
    end
    return body
  end
  local function scan(scr)
    run(scr, "clean_scan", {}, function(res)
      data = res
      to_items(scr)
      if #data.items == 0 and #data.skipped == 0 then
        App.toast(L("Nenhum problema encontrado nas listas de jogos."), "ok")
      else
        App.show_dialog({ title = L("Resultado da faxina"), kind = "info", body = summary() })
      end
    end)
  end
  App.push("infolist", { title = L("Faxina das listas de jogos"), sub = "",
    empty = L("Nenhum problema encontrado."),
    load = scan,
    keys = {
      { key = "y", label = L("Ignorar/Incluir"), enabled = function(scr) return #scr.items > 0 end, fn = function(scr, item)
        if not item or not item.ref then return end
        item.ref.skip = not item.ref.skip
        to_items(scr)
      end },
      { key = "x", label = L("Aplicar"), enabled = function(scr) return #scr.items > 0 end, fn = function(scr)
        local nd, ns, nm = kind_count("dead", true), kind_count("scripts", true), kind_count("suspect", true)
        if nd + ns + nm == 0 then App.toast(L("Todos os itens estão ignorados."), "info"); return end
        local body = fmt("Remover %d entradas sem arquivo (e as imagens só delas)", nd) .. "\n"
          .. fmt("Ocultar %d scripts internos", ns) .. "\n"
          .. fmt("Mover %d ROMs para a pasta do sistema certo", nm)
          .. "\n\n" .. backup_note() .. "\n" .. reload_es_note()
        App.show_dialog({ title = L("Aplicar a faxina?"), kind = "warn", body = body,
          buttons = {
            { label = L("APLICAR"), fn = function()
              local list = {}
              for _, it in ipairs(data.items) do if not it.skip then list[#list + 1] = it end end
              run(scr, "clean_apply", { items = list }, function(r)
                local msg = fmt("%d entradas removidas, %d imagens apagadas (%s), %d scripts ocultos, %d ROMs movidas.",
                  r.removed, r.media, U.format_bytes(r.freed), r.hidden, r.moved)
                if #r.errors > 0 then
                  App.show_dialog({ title = L("Faxina concluída com avisos"), kind = "warn", body = msg .. errors_text(r.errors) })
                else
                  App.toast(msg, "ok")
                end
                App.update_free_space()
                if App.current() == scr then scan(scr) end
              end)
            end },
            { label = L("CANCELAR") },
          }, sel = 2 })
      end },
    } })
end

-------------------------------------------------------------------------------
-- 2. Imagens automaticas
-------------------------------------------------------------------------------
local function ports_covers()
  local map = {}
  local ok, Catalog = pcall(require, "core.catalog")
  if ok and Catalog and Catalog.ports and App.port_script then
    for _, p in ipairs(Catalog.ports) do
      if p.cover and p.cover ~= "" then
        local ok2, sh = pcall(App.port_script, p)
        if ok2 and sh then map[sh] = p.cover end
      end
    end
  end
  return map
end

local function images_screen()
  local data
  local function to_items(scr)
    local items = {}
    for _, s in ipairs(data.systems) do
      items[#items + 1] = { tag = U.upper(s.sys), tagc = s.ports and T.c.accent or T.c.accent2,
        text = s.ports and tr("Ports (capas do catálogo do Port Hub)") or s.libretro,
        sub = fmt("%d sem imagem", #s.games) .. "  •  " .. (function()
          local t = {}
          for i = 1, math.min(3, #s.games) do t[#t + 1] = s.games[i].name end
          return table.concat(t, ", ") .. (#s.games > 3 and "..." or "")
        end)(), ref = s }
    end
    scr.items = items
    scr.sel = math.min(scr.sel or 1, math.max(1, #items))
    scr.p.sub = fmt("%d jogos sem imagem", data.total)
  end
  local function scan(scr)
    run(scr, "images_scan", { ports_covers = ports_covers() }, function(res)
      data = res
      to_items(scr)
    end)
  end
  local function start(scr, systems, label)
    local st = require("core.net").current()
    if st and not st.connected then App.toast(L("Sem internet: conecte o Wi-Fi para baixar as imagens."), "warn"); return end
    local n = 0
    for _, s in ipairs(systems) do n = n + #s.games end
    local lim = math.min(n, LT.IMG_LIMIT)
    local free = LT.free_kb(LT.cfg.root)
    if free and free < LT.MIN_FREE_KB then
      App.show_dialog({ title = L("Pouco espaço livre"), kind = "error",
        body = fmt("Livre no cartão: %s. Libere espaço antes de baixar imagens.", U.format_bytes(free * 1024)) })
      return
    end
    local body = fmt("Busca imagens para %d de %d jogos (%s). Quem já tem imagem fica como está.", lim, n, label) .. "\n\n"
      .. tr("Fonte: libretro-thumbnails (pelo nome do arquivo e pelo nome do jogo). Cada imagem é reduzida para no máximo 400 px e fica em <sistema>/images; o gamelist é atualizado.")
      .. "\n\n" .. fmt("Livre no cartão: %s (cerca de 100 a 300 KB por jogo).", free and U.format_bytes(free * 1024) or "?")
      .. "\n" .. tr("CAPAS: imagem principal é a capa. PRINTS: imagem principal é uma tela do jogo.")
      .. "\n\n" .. backup_note()
    local function go(main)
      run(scr, "images_run", { systems = systems, limit = LT.IMG_LIMIT, main = main }, function(r)
        local msg = fmt("Imagens: %d jogos com imagem nova, %d só com parte, %d sem imagem na fonte (%s).",
          r.ok, r.partial, r.missing, U.format_bytes(r.bytes))
        if r.nospace then msg = tr("Pouco espaço livre: nada foi baixado.") end
        if r.cancelled then msg = tr("Download cancelado.") .. " " .. msg end
        if #r.errors > 0 then
          App.show_dialog({ title = L("Imagens: concluído com avisos"), kind = "warn", body = msg .. errors_text(r.errors) })
        else
          App.toast(msg, r.ok > 0 and "ok" or "info")
        end
        App.update_free_space()
        if App.current() == scr then scan(scr) end
      end)
    end
    App.show_dialog({ title = L("Buscar imagens?"), kind = "info", body = body,
      buttons = { { label = L("CAPAS"), fn = function() go("box") end },
        { label = L("PRINTS"), fn = function() go("snap") end },
        { label = L("CANCELAR") } }, sel = 1 })
  end
  App.push("infolist", { title = L("Imagens automáticas"), sub = "",
    empty = L("Todos os jogos já têm imagem."),
    load = scan,
    keys = {
      { key = "a", label = L("Buscar"), enabled = function(scr) return #scr.items > 0 end, fn = function(scr, item)
        if item and item.ref then start(scr, { item.ref }, item.ref.sys) end
      end },
      { key = "x", label = L("Todos"), enabled = function(scr) return #scr.items > 0 end, fn = function(scr)
        start(scr, data.systems, tr("todos os sistemas"))
      end },
    } })
end

-------------------------------------------------------------------------------
-- 3. Jogos de varios discos
-------------------------------------------------------------------------------
local function multidisc_screen()
  local data
  local function to_items(scr)
    local items = {}
    for _, g in ipairs(data.groups) do
      local what
      if g.status == "new" then what = fmt("cria %s", g.m3u)
      elseif g.status == "hide" then what = tr(".m3u já existe: só esconde os discos")
      else what = tr("este sistema não aceita .m3u no Knulli") end
      local sub = fmt("%d discos", #g.files) .. "  •  " .. what .. (g.gap and ("  •  " .. tr("falta um disco no meio")) or "")
      if g.skip then sub = tr("IGNORADO") .. "  •  " .. sub end
      items[#items + 1] = { tag = U.upper(g.sys), tagc = g.skip and T.c.faint or T.c.accent2, text = g.name, sub = sub, ref = g,
        detail = fmt("Arquivo %s (caminhos relativos):", LT.sys_dir(g.sys) .. "/" .. g.m3u) .. "\n" .. table.concat(g.files, "\n")
          .. "\n\n" .. tr("O .m3u entra na lista com o nome e as imagens do disco 1; os discos ficam ocultos (<hidden>). Nenhum disco é movido ou apagado.") }
    end
    scr.items = items
    scr.sel = math.min(scr.sel or 1, math.max(1, #items))
    scr.p.sub = fmt("%d jogos", #items)
  end
  local function scan(scr)
    run(scr, "multidisc_scan", {}, function(res)
      data = res
      table.sort(data.groups, function(a, b) return (a.sys .. a.base):lower() < (b.sys .. b.base):lower() end)
      to_items(scr)
    end)
  end
  App.push("infolist", { title = L("Jogos de vários discos"), sub = "",
    empty = L("Nenhum jogo de vários discos sem .m3u (psx, segacd, dreamcast, pcenginecd, saturn)."),
    load = scan,
    keys = {
      { key = "y", label = L("Ignorar/Incluir"), enabled = function(scr) return #scr.items > 0 end, fn = function(scr, item)
        if not item or not item.ref then return end
        if item.ref.status == "nom3u" then App.toast(L("Este sistema não aceita .m3u no Knulli."), "warn"); return end
        item.ref.skip = not item.ref.skip
        to_items(scr)
      end },
      { key = "x", label = L("Aplicar"), enabled = function(scr) return #scr.items > 0 end, fn = function(scr)
        local list, nf = {}, 0
        for _, g in ipairs(data.groups) do
          if not g.skip and g.status ~= "nom3u" then list[#list + 1] = g; nf = nf + #g.files end
        end
        if #list == 0 then App.toast(L("Todos os itens estão ignorados."), "info"); return end
        local t = {}
        for i = 1, math.min(5, #list) do t[#t + 1] = "• " .. list[i].m3u end
        if #list > 5 then t[#t + 1] = fmt("... e mais %d", #list - 5) end
        App.show_dialog({ title = L("Criar as listas .m3u?"), kind = "warn",
          body = fmt("%d jogos (%d discos ficam ocultos):", #list, nf) .. "\n" .. table.concat(t, "\n")
            .. "\n\n" .. backup_note() .. "\n" .. reload_es_note(),
          buttons = {
            { label = L("APLICAR"), fn = function()
              run(scr, "multidisc_apply", { groups = list }, function(r)
                local msg = fmt("%d listas .m3u criadas, %d discos ocultos.", r.created, r.hidden)
                if #r.errors > 0 then
                  App.show_dialog({ title = L("Concluído com avisos"), kind = "warn", body = msg .. errors_text(r.errors) })
                else
                  App.toast(msg, "ok")
                end
                if App.current() == scr then scan(scr) end
              end)
            end },
            { label = L("CANCELAR") },
          }, sel = 2 })
      end },
    } })
end

-------------------------------------------------------------------------------
-- 4. Videos de previa
-------------------------------------------------------------------------------
local function download_info(data)
  local acc = LT.scraper_account()
  local body = tr("Não existe fonte de vídeos de prévia aberta (sem conta): o libretro-thumbnails só tem imagens. Os vídeos vêm do ScreenScraper, que exige uma conta de usuário e uma chave de programa registrada — o Port Hub não tem essa chave.")
    .. "\n\n"
  if acc then
    body = body .. fmt("Sua conta do ScreenScraper (%s) já está no EmulationStation.", acc) .. " "
  else
    body = body .. tr("Nenhuma conta do ScreenScraper está configurada no EmulationStation.") .. " "
      .. tr("Crie uma conta grátis em screenscraper.fr e informe usuário e senha no menu do scraper do EmulationStation.") .. " "
  end
  body = body .. tr("Para baixar: no EmulationStation abra o menu (START) > Scraper, escolha ScreenScraper, ligue os vídeos e raspe só os sistemas que quiser.")
    .. "\n\n" .. tr("Depois volte aqui e use Reduzir vídeos: cada vídeo do ScreenScraper tem de 2 a 10 MB e fica com cerca de 0,5 MB.")
  local free = data and data.free_kb
  if free then body = body .. "\n\n" .. fmt("Livre no cartão agora: %s. Com menos de 1 GB livre, raspe poucos jogos por vez.", U.format_bytes(free * 1024)) end
  App.show_dialog({ title = L("Baixar vídeos de prévia"), kind = "info", body = body })
end

local function videos_screen()
  local data
  local function to_items(scr)
    local items = {
      { id = "clean", tag = L("LIMPAR"), tagc = data.dead > 0 and T.c.yellow or T.c.faint,
        text = tr("Limpar vídeos que não existem"),
        sub = fmt("%d entradas apontam para vídeos que não estão no cartão", data.dead) },
      { id = "shrink", tag = L("REDUZIR"), tagc = #data.videos > 0 and T.c.accent2 or T.c.faint,
        text = tr("Reduzir vídeos existentes"),
        sub = fmt("%d vídeos, %s no total (%d com mais de 1 MB)", #data.videos, U.format_bytes(data.bytes), data.big)
          .. (data.ffmpeg and "" or ("  •  " .. tr("ffmpeg não encontrado"))) },
      { id = "download", tag = L("BAIXAR"), tagc = T.c.accent,
        text = tr("Baixar vídeos"),
        sub = data.account and tr("Conta do ScreenScraper encontrada: use o scraper do EmulationStation")
          or tr("Precisa de conta no ScreenScraper: veja como") },
      { id = "free", tag = L("ESPAÇO"), tagc = T.c.green, text = tr("Livre no cartão"),
        sub = data.free_kb and U.format_bytes(data.free_kb * 1024) or "?" },
    }
    if data.dead > 0 then
      local t = {}
      for i = 1, math.min(6, #data.dead_sys) do t[#t + 1] = data.dead_sys[i].sys .. " (" .. data.dead_sys[i].n .. ")" end
      items[1].detail = table.concat(t, ", ")
    end
    scr.items = items
    scr.p.sub = ""
  end
  local function scan(scr)
    run(scr, "video_scan", {}, function(res) data = res; to_items(scr) end)
  end
  local function act(scr, item)
    if not item or not data then return end
    if item.id == "clean" then
      if data.dead == 0 then App.toast(L("Nenhum vídeo morto nas listas."), "info"); return end
      App.show_dialog({ title = L("Limpar vídeos que não existem?"), kind = "warn",
        body = fmt("A tag <video> sai de %d entradas cujo arquivo não está no cartão (nenhum arquivo é apagado). Os temas deixam de tentar tocar o vídeo e mostram a imagem.", data.dead)
          .. "\n\n" .. backup_note(),
        buttons = { { label = L("LIMPAR"), fn = function()
          run(scr, "video_clean", {}, function(r)
            if #r.errors > 0 then
              App.show_dialog({ title = L("Concluído com avisos"), kind = "warn",
                body = fmt("%d vídeos mortos retirados.", r.removed) .. errors_text(r.errors) })
            else
              App.toast(fmt("%d vídeos mortos retirados das listas.", r.removed), "ok")
            end
            if App.current() == scr then scan(scr) end
          end)
        end }, { label = L("CANCELAR") } }, sel = 2 })
    elseif item.id == "shrink" then
      if not data.ffmpeg then App.toast(L("ffmpeg não encontrado no console."), "error"); return end
      if #data.videos == 0 then App.toast(L("Nenhum vídeo no cartão para reduzir."), "info"); return end
      local V = LT.VIDEO
      local function go(audio)
        run(scr, "video_shrink", { videos = data.videos, audio = audio }, function(r)
          local msg = fmt("%d vídeos reduzidos (%s livres), %d já estavam leves, %d falharam.",
            r.done, U.format_bytes(r.saved), r.skipped, r.failed)
          if r.cancelled then msg = tr("Cancelado.") .. " " .. msg end
          if #r.errors > 0 then
            App.show_dialog({ title = L("Concluído com avisos"), kind = "warn", body = msg .. errors_text(r.errors) })
          else
            App.toast(msg, "ok")
          end
          App.update_free_space()
          if App.current() == scr then scan(scr) end
        end)
      end
      App.show_dialog({ title = L("Reduzir os vídeos?"), kind = "warn",
        body = fmt("%d vídeos (%s). Cada um vira %dx%d, cerca de %d kbps e no máximo %d segundos. O arquivo original é substituído (não dá para desfazer). Pode levar alguns minutos; dá para sair desta tela.",
          #data.videos, U.format_bytes(data.bytes), V.w, V.h, V.kbps, V.secs),
        buttons = { { label = L("SEM ÁUDIO"), fn = function() go(false) end },
          { label = L("ÁUDIO MONO"), fn = function() go(true) end },
          { label = L("CANCELAR") } }, sel = 1 })
    elseif item.id == "download" then
      download_info(data)
    end
  end
  App.push("infolist", { title = L("Vídeos de prévia"), sub = "", load = scan,
    keys = { { key = "a", label = L("Abrir"), fn = act } } })
end

-------------------------------------------------------------------------------
-- menu
-------------------------------------------------------------------------------
local TOOLS = {
  { id = "clean", text = L("Faxina das listas de jogos"),
    sub = L("Entradas sem arquivo, scripts internos de ports e ROMs na pasta errada"), fn = clean_screen },
  { id = "images", text = L("Imagens automáticas"),
    sub = L("Capa, print e logo do libretro-thumbnails para quem não tem imagem"), fn = images_screen },
  { id = "multidisc", text = L("Jogos de vários discos"),
    sub = L("Cria a lista .m3u e esconde os discos separados"), fn = multidisc_screen },
  { id = "videos", text = L("Vídeos de prévia"),
    sub = L("Limpa vídeos que não existem e reduz os que ocupam muito"), fn = videos_screen },
}

local function busy_dialog()
  local job = LT.job
  local a, b = status_line(job)
  App.show_dialog({ title = L("Tarefa em andamento"), kind = "info",
    body = a .. (b and b ~= "" and ("\n" .. b) or "") .. "\n\n" .. tr("Espere terminar ou cancele (o item em curso termina antes de parar)."),
    buttons = { { label = L("CANCELAR TAREFA"), danger = true, fn = function() if LT.job then LT.job.cancel() end end },
      { label = L("CONTINUAR") } }, sel = 2 })
end

function M.open()
  if not C.KNULLI then
    App.toast(L("Disponível só no Knulli."), "warn")
    return
  end
  setup()
  local items = {}
  for i, t in ipairs(TOOLS) do
    items[#items + 1] = { tag = tostring(i), tagc = T.c.accent2, text = t.text, sub = t.sub, ref = t }
  end
  App.push("infolist", { title = L("Biblioteca: manutenção"),
    sub = function()
      if LT.job then return (status_line(LT.job)) end
      return tr("só muda algo depois de confirmar")
    end,
    items = items,
    keys = { { key = "a", label = L("Abrir"), fn = function(scr, item)
      if not item or not item.ref then return end
      if LT.job then busy_dialog(); return end
      item.ref.fn()
    end } } })
end

return M
