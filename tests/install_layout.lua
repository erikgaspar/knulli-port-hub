local source = arg[1] or 'src'
package.path = source .. '/?.lua;' .. package.path
package.preload['love.timer'] = function() return {} end
package.preload['love.filesystem'] = function() return {} end
package.loaded['lib.i18n'] = {set=function() end, L=function(s) return s end}
local messages = {}
love = {thread={getChannel=function(name)
  if name == 'out' then return {push=function(_,m) messages[#messages+1]=m end} end
  return {pop=function() return nil end}
end}}
local base = '/tmp/porthub-layout-cases-' .. os.time()
local function write(path, content)
  local f=assert(io.open(path,'wb')); f:write(content); f:close()
end
local function exists(path) local f=io.open(path,'rb'); if f then f:close(); return true end; return false end
local function run(command)
  local result=os.execute(command)
  return result==0 or result==true
end
local function test(name, prefix, mode, expected, multi, backup_fail)
  local dir=base..'/'..name
  assert(run('mkdir -p '..dir..'/input/'..prefix..'game '..dir..'/dest'))
  write(dir..'/input/'..prefix..'Game.sh', '#!/bin/sh\nGAMEDIR="/roms/ports/game"\nexit 0\n')
  write(dir..'/input/'..prefix..'game/data', 'fixture')
  if multi then
    assert(run('mkdir -p '..dir..'/input/other'))
    write(dir..'/input/other/Other.sh', '#!/bin/sh\n')
  end
  assert(run('cd '..dir..'/input && zip -qr '..dir..'/fixture.zip .'))
  local backup=base..'/backups'
  if backup_fail then backup=dir..'/notdir'; write(backup,'fixture') end
  messages={}
  assert(loadfile(source .. '/threads/install_thread.lua'))({
    name=name, slug=name, tmp_dir=base..'/work', ports_dir=dir..'/dest',
    local_file=dir..'/fixture.zip', mode=mode, margin=0, protected={}, knulli=true, script_backup_dir=backup,
    out_channel='out', in_channel='in', passwords={}
  })
  local last=messages[#messages]
  assert(last and (last.code or last.t)==expected, name..': '..tostring(last and (last.code or last.t)))
  if expected=='done' then
    local path=mode=='extract' and prefix..'Game.sh' or 'Game.sh'
    assert(exists(dir..'/dest/'..path), name..': script ausente')
    assert(exists(dir..'/dest/'..(mode=='extract' and prefix or '')..'game/data'))
    local f=assert(io.open(dir..'/dest/'..path,'rb'))
    local content=f:read('*a'); f:close()
    local expected_path=mode=='extract' and '/roms/ports/game' or dir..'/dest/game'
    assert(content=='#!/bin/sh\nGAMEDIR="'..expected_path..'"\nexit 0\n', name..': launcher alterado incorretamente')
  end
  print('PASS '..name)
end
test('root', '', 'port', 'done')
test('nested', 'wrapper/wrapper/', 'port', 'done')
test('roms', 'roms/ports/', 'port', 'done')
test('ambiguous', 'wrapper/', 'port', 'no_script', true)
test('extract', 'wrapper/wrapper/', 'extract', 'done')
test('backup_refused', '', 'port', 'no_write', false, true)
local patch = require('core.portpatch')
local original = [[#!/bin/bash
GAMEDIR="/roms/ports/strikers"
if [ -f "$GAMEDIR/libs.aarch64/libmali-bifrost-g31-rxp0-gbm.so" ]; then
  MALI_BLOB="$GAMEDIR/libs.aarch64/libmali-bifrost-g31-rxp0-gbm.so"
fi
]]
local patched=patch.apply(original,'/userdata/roms/ports','super-mario-strikers')
assert(patched:find('GAMEDIR="/userdata/roms/ports/strikers"',1,true))
assert(patched:find('MALI_BLOB="/usr/lib/libmali.so"',1,true))
assert(patch.apply(patched,'/userdata/roms/ports','super-mario-strikers')==patched)
assert(patch.apply('GAMEDIR="/userdata/roms/ports/game"','/userdata/roms/ports','game')=='GAMEDIR="/userdata/roms/ports/game"')
assert(patch.apply('GAMEDIR="/roms/ports2/game"','/userdata/roms/ports','game')=='GAMEDIR="/roms/ports2/game"')
local v7="NXV7_PORT='ducktales'\nfor root in /userdata/roms/ports /roms/ports; do :; done\n"
assert(patch.apply(v7,'/userdata/roms/ports','ducktales-remastered')==v7)
assert(patch.apply(original,'/userdata/roms/ports','other'):find('if [ -f "$GAMEDIR/libs.aarch64/libmali',1,true))
write('/tmp/strikers-patched.sh',patched)
assert(run('bash -n /tmp/strikers-patched.sh'))
print('PASS launcher Strikers, caminhos, idempotencia e bash -n')

-- Quem tentou instalar antes da correcao deve poder tentar novamente.
package.loaded.config={KNULLI=true}
package.loaded['lib.util']={safe_utf8=function(s)return s end,log=function()end}
package.loaded['core.prefs']={get=function()return '0' end}
love.filesystem={write=function()return true end}
local broken=require('core.broken')
local url='https://archive.org/download/silent-hill-4-the-room.-7z/super%20Mario%20strikers.rar'
local port={id='super-mario-strikers',name='Super Mario Strikers',download_url=url}
broken.data={items={[port.id]={code='no_script',url=url,size=888549548}},ok={}}
assert(broken.mark(port)==nil and broken.data.items[port.id]==nil)
broken.probe_list=function()end
assert(broken.on_install_error(port,'no_script','',{size=888549548}))
assert(broken.mark(port)~=nil, 'falha nova nao deve ser apagada pela migracao')
local other={id='outro',download_url=url}
broken.data={items={[other.id]={code='no_script',url=url}},ok={}}
assert(broken.mark(other)~=nil, 'outros pacotes devem continuar escondidos')
broken.data={items={},ok={}}
port.broken={reason='package',code='no_script',url=url,size=888549548,since='2026-11-25'}
assert(broken.mark(port)==nil and broken.data.ok[port.id].by=='installer')
print('PASS migracao das marcas antigas sem apagar falhas novas')

print('TODOS OS TESTES PASSARAM')
