# script-windows

Script de pós-instalação do **Windows 11 Pro** para PC gamer **AMD** (feito para Ryzen 7 5700X + Radeon RX 7600).
Reduz telemetria e bloatware, remove o OneDrive, aplica só ajustes de desempenho com respaldo e mantém os drivers AMD em dia.

> **Expectativa realista:** remover bloatware e telemetria quase não muda o FPS médio (testes publicados mostram 0 a ~3%). O ganho é menos RAM/processos em segundo plano e menos engasgos. O que mais mexe em FPS no seu hardware está na BIOS (veja o diagnóstico no fim da execução).

## Antes de rodar (instalação nova)

1. Termine o OOBE e **recuse o "backup de pastas do OneDrive"**.
2. Rode o **Windows Update até não sobrar nada** e reinicie. Isso deixa o Windows trazer áudio/rede/Bluetooth antes de o script bloquear drivers via Windows Update, e evita falhas por reinício pendente (o script recusa rodar com reinício pendente).
3. Rode o script **com a sua conta de administrador** (parte dos ajustes é por usuário).

## Como usar

Num PowerShell comum, cole **uma linha** (abre o UAC e roda como administrador):

```powershell
Start-Process powershell -Verb RunAs -ArgumentList '-NoExit -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/zGuiOs/script-windows/main/Optimize-Gaming.ps1 | iex"'
```

Use o **Windows PowerShell** (`powershell.exe`), não o PowerShell 7.

**Primeiro veja o que ele faria** (não altera nada, funciona até sem admin):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/zGuiOs/script-windows/main/Optimize-Gaming.ps1))) -DryRun
```

> Leia o script antes de rodar qualquer `irm | iex`, inclusive este. Para travar numa versão que você já revisou, troque `main` pelo hash do commit na URL.

## Ordem de execução

Cada etapa é isolada: se uma falhar, as outras continuam. Só as pré-checagens e a confirmação do ponto de restauração podem interromper, e **antes de qualquer alteração**.

| # | Etapa | O que faz |
|---|---|---|
| 0 | Pré-checagens | Windows 11, reinício pendente (aborta), internet, espaço em disco |
| 1 | Ponto de restauração | Cria e **verifica** que foi criado; se falhar, pergunta antes de continuar |
| 2 | Telemetria/privacidade | Políticas de diagnóstico, serviço `DiagTrack` e ~17 tarefas de coleta, anúncios, sugestões, Bing na busca, Widgets, Copilot, Recall. Aplica o anti-sugestão também ao **perfil Default** (contas novas) |
| 3 | OneDrive | Desinstala, remove auto-start (usuário atual e Default), bloqueia uso por política. Sobras são apagadas só depois de reiniciar o Explorer |
| 4 | Bloatware | Remove apps (inclusive o pacote **provisionado**, para não voltar em contas novas) e os gatilhos do Windows Update que reinstalam Outlook/Dev Home/Phone Link (com backup `.reg`) |
| 5 | Desempenho | Game Mode, Game DVR off, HAGS, mouse sem aceleração, sem Sticky Keys, hibernação off, interface enxuta |
| 6 | Runtimes | Visual C++ e DirectX via `winget` (com tempo limite) |
| 7 | Drivers AMD | Chipset silencioso e Adrenalin (baixa, valida assinatura, abre o instalador). **Pula se já está na versão mais nova** |
| 8 | Drivers via Windows Update | Bloqueia o Windows Update de empurrar drivers — **depois** dos drivers instalados |
| 9 | Plano de energia, limpeza, resumo | Plano de energia (depois do chipset, que pode mexer nele), diagnóstico de BIOS, arquivo de undo |

## O que ele não mexe (de propósito)

Windows Update (continua atualizando), Defender, Microsoft Store, `winget`, Xbox Identity / Gaming App / Gaming Services (necessários para Game Pass e jogos da Store), Edge (só desliga coleta e inicialização em segundo plano; passa a mostrar "gerenciado pela sua organização"), Pesquisa do Windows, SysMain, arquivo de paginação, mitigações de CPU.

## Limites (leia)

- **Não há garantia de que nada volte.** O que o script faz: remove o app e o pacote provisionado, apaga os gatilhos de reinstalação do Windows Update, zera os valores de "apps sugeridos" no usuário atual e no perfil Default, desativa o OneDrive por política. O que ele **não** consegue: impedir que uma **atualização de versão do Windows** recoloque alguns apps ou o OneDrive (`OneDriveSetup.exe` continua em `System32`). Depois de cada atualização grande, rode o script de novo (é idempotente). A política oficial "remover pacotes padrão da Store" é documentada só para Enterprise/Education e não é usada.
- **Não dá para remover o Edge** nem o essencial do Windows. Alguns apps do sistema são marcados como não removíveis e são pulados.
- **Telemetria no Pro:** o Windows 11 Pro não permite desligar 100% o nível "Necessário"; o script zera a política e desativa o serviço e as tarefas de envio.
- **Instalador da GPU:** a AMD não documenta instalação silenciosa estável do Adrenalin, então o script baixa, verifica e **abre o instalador** (escolha "Somente driver" para o mínimo).
- **Bloqueio de drivers no Windows Update:** a política `ExcludeWUDriversInQualityUpdate` afeta atualizações de qualidade; não foi verificado se "Atualizações opcionais" continuam oferecendo drivers. Reverta com `-Undo latest` ou rode com `-AllowWUDrivers`.

## Desfazer

Logs: `C:\ProgramData\GamingSetup\logs`. Cada execução grava `C:\ProgramData\GamingSetup\undo-*.json`:

```powershell
& ([scriptblock]::Create((irm <url>))) -Undo latest
```

Desfaz **registro, serviços, tarefas agendadas, plano de energia e hibernação**. **Não** desfaz: apps removidos (o resumo lista quais; reinstale pela Microsoft Store/`winget`), OneDrive, perfil Default e drivers. O ponto de restauração do Windows também não traz apps removidos de volta.

## Opções

| Parâmetro | Efeito |
|---|---|
| `-DryRun` | Só mostra o que faria |
| `-Yes` | Não pede confirmações |
| `-Undo latest` | Desfaz a última execução (ou passe o caminho do `undo-*.json`) |
| `-GpuChannel Recommended` | Usa o driver "WHQL Recommended" em vez do mais novo (que pode ser "Optional") |
| `-ForceDrivers` | Reinstala drivers mesmo que já estejam atualizados |
| `-AllowWUDrivers` | Não bloqueia drivers pelo Windows Update |
| `-PowerPlan High\|Ultimate\|Balanced\|Keep` | Plano de energia (padrão `High`; veja a nota abaixo) |
| `-RestoreKnownFolders` | Move Desktop/Documentos/Imagens de volta de dentro do OneDrive para `C:\Users\você` (pula pastas com arquivos só na nuvem) |
| `-DisableVBS` | **Opcional**: desliga a Integridade de memória (+FPS em jogos limitados por CPU, −proteção) |
| `-KeepGameBar`, `-KeepHibernation` | Mantém a Game Bar / a hibernação |
| `-SkipPrivacy`, `-SkipOneDrive`, `-SkipDebloat`, `-SkipPerformance`, `-SkipRuntimes`, `-SkipDrivers`, `-NoRestorePoint`, `-IgnorePendingReboot` | Pulam etapas/checagens |
| `-Reboot` | Reinicia sozinho no final |

## Desempenho: o que tem respaldo e o que não tem

| Item | Evidência | No script |
|---|---|---|
| **Resizable BAR / Smart Access Memory** | Sem ganho a ~15% conforme o jogo | **Diagnóstico** (BIOS) |
| Integridade de memória (HVCI/VBS) off | ~3-8% em jogos limitados por CPU em Ryzen 5000; menos se limitado por GPU | `-DisableVBS` (opt-in) |
| HAGS | AMD recomenda para FSR 3 Frame Generation; ganho de FPS pequeno | Ligado |
| RAM em dual-channel na velocidade do kit | Real | **Diagnóstico** |
| Mouse sem aceleração, sem Sticky Keys | Real (para jogos que não usam raw input) | Ligado |
| Plano de energia Alto/Máximo | **Sem benchmark independente** no Ryzen 5000; a AMD indica o Balanced | `High` por padrão; teste e compare |
| Debloat/telemetria | 0-3% de FPS médio; melhora RAM ociosa e engasgos | Ligado |
| MMCSS, Nagle, `bcdedit` de timer, desligar mitigações de CPU | Folclore ou sem evidência | **Não incluído** |
| Exclusões do Defender para pastas de jogos | Evidência fraca, troca segurança por pouco | Não incluído |

## Fontes dos drivers

- GPU: [AMD Radeon RX 7600, Drivers and Downloads](https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-7000-series/amd-radeon-rx-7600.html)
- Chipset: [AMD Chipset Drivers (AM4)](https://www.amd.com/en/support/downloads/drivers.html/chipsets/am4/b550.html)

Os downloads da AMD exigem o cabeçalho `Referer` (sem ele o servidor devolve uma página HTML); o script já envia.
