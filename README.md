<p align="center">
  <img src="src/assets/logo/knulli/logo_master.png" alt="Knulli Port Hub" width="420">
</p>

<h1 align="center">Knulli Port Hub</h1>

<p align="center">
  <b>Central de ports, ferramentas e temas para consoles com Knulli</b><br>
  Adaptação do <a href="https://github.com/liralflsti-wq/r36s-port-hub">R36S PORT HUB</a>, de <b>Lag do Lira</b>, feita com autorização do autor.
</p>

---

## O que é

O mesmo app do R36S PORT HUB (LÖVE 11.5, PT-BR / EN / RU), adaptado para o **Knulli** (base Batocera) e testado no **Anbernic RG35XXH** (Allwinner H700, 640×480).

Tudo o que muda só vale quando o app detecta o Knulli; no R36S/dArkOS o comportamento é o original.

### O que muda no Knulli
- **Ports:** instala em `/userdata/roms/ports`, esconde os scripts internos dos ports na lista do EmulationStation e recarrega a lista ao sair (API do EmulationStation, sem reiniciar).
- **Catálogo:** o catálogo oficial do R36S PORT HUB **+** um catálogo extra (`knulli-catalog.json`) com a situação de cada port no RG35XXH (testado / pesado / não funciona) e ports a mais. O app avisa antes de baixar um port pesado.
- **Wi-Fi:** connman e `knulli-wifi` (a rede fica salva nas configurações do Knulli).
- **Data, hora e fuso:** `knulli-timezone`, `ntpd` e `hwclock`.
- **Energia:** `knulli-shutdown`. **Temas do EmulationStation:** `/userdata/themes` + `ThemeSet` do `es_settings.cfg`.
- **BIOS:** `/userdata/bios`.
- **Botões do RG35XXH:** B (baixo) confirma, A (direita) volta, como no EmulationStation; ícones e textos mostram as letras certas.
- **Atualizações:** por este repositório (a atualização oficial é a do R36S e apagaria a adaptação).

## Instalação

1. Baixe `Knulli-Port-Hub.zip` em **[Releases](../../releases/latest)**.
2. Extraia na pasta `ports` do cartão (`/userdata/roms/ports`):
   ```
   /userdata/roms/ports/Knulli Port Hub.sh
   /userdata/roms/ports/r36sporthub/
   ```
3. Atualize a lista de jogos (menu do EmulationStation) e abra **Knulli Port Hub** em **Ports**.

**Requisitos:** PortMaster com o runtime `love_11.5` (o Knulli já traz o PortMaster).

## Catálogo extra

`knulli-catalog.json`, na raiz deste repositório, é lido pelo app a cada atualização do catálogo:

```json
{ "ports": [
  { "id": "<id do catálogo oficial>",
    "h700": { "status": "testado | pesado | nao_funciona", "note": "texto", "tested_on": "RG35XXH / Knulli" } }
] }
```

Itens com `download_url` e um `id` novo entram como ports normais (mesmo formato do catálogo oficial, veja `docs/CATALOGO.md`).

## Gerar o pacote

```sh
tools/build_knulli.sh      # -> build/Knulli-Port-Hub.zip
```

## Créditos e licença

- **R36S PORT HUB:** © 2026 Lag do Lira ([YouTube](https://www.youtube.com/@LagdoLira)). Licença própria (veja [LICENSE](LICENSE)); esta adaptação foi autorizada pelo autor.
- Documentação original: [README-R36S-PORT-HUB.md](README-R36S-PORT-HUB.md).
- Jogos, ports, BIOS e demais arquivos de terceiros pertencem aos seus autores e não fazem parte deste repositório.
