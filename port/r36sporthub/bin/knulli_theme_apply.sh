#!/bin/bash
# Knulli: troca o tema do EmulationStation (ThemeSet no es_settings.cfg).
# Roda separado do hub (setsid): para o EmulationStation, grava e liga de novo.
THEME="$1"; CONFDIR="$2"
CFG=/userdata/system/configs/emulationstation/es_settings.cfg
LOG="$CONFDIR/es_theme.log"
{
  echo "$(date) tema: $THEME"
  sleep 1
  /etc/init.d/S31emulationstation stop
  for i in $(seq 1 40); do pidof emulationstation >/dev/null || break; sleep 1; done
  pidof emulationstation >/dev/null && kill -9 $(pidof emulationstation)
  cp -f "$CFG" "$CFG.porthub.bak"
  if grep -q '<string name="ThemeSet"' "$CFG"; then
    sed -i "s|<string name=\"ThemeSet\" value=\"[^\"]*\"|<string name=\"ThemeSet\" value=\"$THEME\"|" "$CFG"
  else
    sed -i "s|</config>|\t<string name=\"ThemeSet\" value=\"$THEME\" />\n</config>|" "$CFG"
  fi
  grep -q "<string name=\"ThemeSet\" value=\"$THEME\"" "$CFG" || { echo "falhou: voltando o original"; cp -f "$CFG.porthub.bak" "$CFG"; }
  . /etc/profile.d/xdg.sh 2>/dev/null; . /etc/profile.d/dbus.sh 2>/dev/null
  start-stop-daemon -S -b -x /usr/bin/emulationstation-standalone
  echo "ok"
} >> "$LOG" 2>&1
