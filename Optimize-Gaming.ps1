<#
.SYNOPSIS
    Pos-instalacao do Windows 11 Pro para PC gamer AMD (Ryzen 7 5700X + Radeon RX 7600).

.DESCRIPTION
    Ordem de execucao (cada etapa e isolada: se uma falhar, as outras continuam):
      0. Pre-checagens (admin, Windows 11, internet, espaco em disco, reinicio pendente)
      1. Ponto de restauracao (verificado; se falhar, pergunta antes de continuar)
      2. Telemetria / privacidade / servicos / tarefas agendadas / perfil Default
      3. OneDrive
      4. Apps inuteis + gatilhos de reinstalacao do Windows Update
      5. Desempenho (somente ajustes com respaldo)
      6. Runtimes (Visual C++, DirectX) via winget
      7. Drivers AMD (chipset silencioso; Adrenalin baixado, verificado e aberto) - pula se ja atualizado
      8. Bloqueia drivers via Windows Update (DEPOIS dos drivers) e define o plano de energia
      9. Limpeza, resumo, diagnostico de BIOS (Resizable BAR, RAM) e arquivo de undo

    Nao mexe em: Windows Update, Defender, Microsoft Store, winget, Xbox/Gaming Services, Edge (so politicas).
    Use -DryRun para ver tudo SEM alterar nada. Use -Undo latest para desfazer registro/servicos/tarefas.

.EXAMPLE
    # Windows PowerShell como Administrador:
    irm https://raw.githubusercontent.com/zGuiOs/script-windows/main/Optimize-Gaming.ps1 | iex

.EXAMPLE
    # Com opcoes (iex nao aceita parametros, entao use scriptblock):
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/zGuiOs/script-windows/main/Optimize-Gaming.ps1))) -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DryRun,             # So mostra o que faria; nao altera nada
    [switch]$Yes,                # Nao pede confirmacoes
    [string]$Undo,               # Caminho do arquivo undo-*.json, ou 'latest'
    [switch]$SkipPrivacy,        # Pula telemetria/privacidade/servicos/tarefas
    [switch]$SkipOneDrive,       # Mantem o OneDrive
    [switch]$RestoreKnownFolders,# Move Desktop/Documentos/Imagens... de volta de dentro do OneDrive
    [switch]$SkipDebloat,        # Pula remocao de apps e recursos opcionais
    [switch]$SkipPerformance,    # Pula ajustes de desempenho
    [switch]$SkipRuntimes,       # Pula Visual C++ / DirectX
    [switch]$SkipDrivers,        # Pula drivers AMD
    [switch]$ForceDrivers,       # Reinstala drivers mesmo que ja estejam na versao mais nova
    [switch]$AllowWUDrivers,     # NAO bloqueia drivers via Windows Update
    [switch]$NoRestorePoint,     # Nao cria ponto de restauracao
    [switch]$IgnorePendingReboot,# Roda mesmo com reinicio pendente (nao recomendado)
    [switch]$KeepGameBar,        # Mantem a Xbox Game Bar (Win+G)
    [switch]$KeepHibernation,    # Mantem hibernacao/inicializacao rapida
    [switch]$DisableVBS,         # OPCIONAL: desliga Integridade de memoria/VBS (+FPS em jogos limitados por CPU, -seguranca)
    [switch]$Reboot,             # Reinicia sozinho no final
    [ValidateSet('Latest', 'Recommended')]
    [string]$GpuChannel = 'Latest',   # Latest = mais novo (pode ser "Optional"); Recommended = WHQL recomendado
    [ValidateSet('High', 'Ultimate', 'Balanced', 'Keep')]
    [string]$PowerPlan = 'High'
)

# NOTA: este arquivo e propositalmente ASCII puro (sem acentos). O console do Windows PowerShell 5.1
# quebra acentos e o "irm | iex" pode falhar com BOM/UTF-8. Nao adicione caracteres nao-ASCII.

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'     # Invoke-WebRequest fica MUITO mais rapido sem a barra
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:BoundParams  = $PSBoundParameters
$script:ScriptPath   = $PSCommandPath
$script:Stats        = @{ Ok = 0; Fail = 0 }
$script:NeedsReboot  = $false
$script:LogStarted   = $false
$script:Abort        = $false
$script:Offline      = $false
$script:PostCleanup  = New-Object System.Collections.Generic.List[string]
$script:UndoLog      = New-Object System.Collections.Generic.List[object]
$script:RemovedApps  = New-Object System.Collections.Generic.List[string]

$DataDir   = Join-Path $env:ProgramData 'GamingSetup'
$DriverDir = Join-Path $DataDir 'drivers'
$LogDir    = Join-Path $DataDir 'logs'
$BackupDir = Join-Path $DataDir 'backup'
$script:UndoFile = Join-Path $DataDir ("undo-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))

$AmdUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'
$AmdReferer   = 'https://www.amd.com/en/support/downloads/drivers.html'
$GpuPageUrl   = 'https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-7000-series/amd-radeon-rx-7600.html'
# O pacote "AMD Chipset Software" e o mesmo para todo AM4 (A520/B450/B550/X570); qualquer pagina serve.
$ChipsetPageUrls = @(
    'https://www.amd.com/en/support/downloads/drivers.html/chipsets/am4/b550.html',
    'https://www.amd.com/en/support/downloads/drivers.html/chipsets/am4/x570.html',
    'https://www.amd.com/en/support/downloads/drivers.html/chipsets/am4/b450.html'
)

# Pacotes que NUNCA sao removidos, mesmo que um padrao acidentalmente case com eles.
$ProtectedAppx = 'Store|DesktopAppInstaller|VCLibs|NET\.Native|UI\.Xaml|WindowsAppRuntime|GamingApp|GamingServices|XboxIdentityProvider|Xbox\.TCUI|XboxGameCallableUI|SecHealthUI|ShellExperience|StartMenuExperience|StartExperiencesApp|WidgetsPlatformRuntime|WindowsTerminal|WindowsCalculator|WindowsNotepad|Microsoft\.Paint|ScreenSketch|Windows\.Photos|VideoExtension|ImageExtension|WebMediaExtensions|MicrosoftEdge|\.CBS|Client\.(Core|CBS|FileExp|OOBE|Photon|AI)|CloudExperienceHost|LockApp|immersivecontrolpanel|PrintDialog|AAD\.BrokerPlugin|AccountsControl|CredDialogHost|BioEnrollment|AsyncTextService|Win32WebViewHost|AIFabric|ECApp|AdvancedMicroDevices'

# Valores anti-sugestao/anti-instalacao automatica (aplicados ao usuario atual E ao perfil Default).
$CdmPath   = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$CdmValues = 'ContentDeliveryAllowed', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled',
    'SilentInstalledAppsEnabled', 'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled', 'SubscribedContentEnabled',
    'SubscribedContent-310093Enabled', 'SubscribedContent-314563Enabled', 'SubscribedContent-338387Enabled',
    'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled',
    'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SubscribedContent-88000326Enabled',
    'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled', 'FeatureManagementEnabled'

# ----------------------------------------------------------------------------------------------
# Utilitarios de log / execucao / undo
# ----------------------------------------------------------------------------------------------
function Write-Info  { param([string]$m) Write-Host "[ .. ] $m" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "[ OK ] $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "[ !! ] $m" -ForegroundColor Yellow }
function Write-Skip  { param([string]$m) Write-Host "[ -- ] pulado: $m" -ForegroundColor DarkGray }
function Write-Title { param([string]$m) Write-Host ""; Write-Host "=== $m ===" -ForegroundColor Magenta }
function Write-Dry   { param([string]$m) Write-Host "  [DRY] $m" -ForegroundColor DarkYellow }

# Toda alteracao no sistema passa por aqui. Em -DryRun apenas descreve o que faria.
function Invoke-Change {
    param([string]$Desc, [scriptblock]$Action)
    if ($DryRun) { Write-Dry $Desc; return }
    try {
        & $Action
        $script:Stats.Ok++
    } catch {
        $script:Stats.Fail++
        Write-Warn2 "$Desc -> $($_.Exception.Message)"
    }
}

function Save-UndoLog {
    if ($DryRun -or $script:UndoLog.Count -eq 0) { return }
    try {
        if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
        # .ToArray(): no PS 5.1, @($lista) empacota a List inteira como 1 item e o ConvertTo-Json falha
        ConvertTo-Json -InputObject $script:UndoLog.ToArray() -Depth 5 | Set-Content -LiteralPath $script:UndoFile -Encoding UTF8
    } catch { Write-Warn2 "nao consegui gravar o arquivo de undo: $($_.Exception.Message)" }
}

function Save-RegState {
    param([string]$Path, [string]$Name)
    $existed = $false; $val = $null; $kind = $null
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.GetValueNames() -contains $Name) {
            $existed = $true
            $val  = $item.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            $kind = $item.GetValueKind($Name).ToString()
        }
    } catch { }
    $script:UndoLog.Add([pscustomobject]@{ Type = 'reg'; Path = $Path; Name = $Name; Existed = $existed; Value = $val; Kind = $kind })
}

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [switch]$OnlyIfExists)
    if ($OnlyIfExists -and -not (Test-Path -LiteralPath $Path)) { return }
    Invoke-Change "reg $Path : $Name = $Value" {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force | Out-Null
            $script:UndoLog.Add([pscustomobject]@{ Type = 'regkey'; Path = $Path })
        }
        Save-RegState $Path $Name
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    }
}

function Disable-Svc {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc -or ($svc.StartType -eq 'Disabled' -and $svc.Status -ne 'Running')) { return }
    Invoke-Change "desativar servico $Name" {
        $script:UndoLog.Add([pscustomobject]@{ Type = 'svc'; Name = $Name; StartType = $svc.StartType.ToString() })
        if ($svc.Status -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
    }
}

function Disable-Task {
    param([string]$Path, [string]$Name)
    $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $t -or $t.State -eq 'Disabled') { return }
    Invoke-Change "desativar tarefa $Path$Name" {
        $script:UndoLog.Add([pscustomobject]@{ Type = 'task'; Path = $Path; Name = $Name })
        $t | Disable-ScheduledTask -ErrorAction Stop | Out-Null
    }
}

# Roda um executavel com tempo limite, para o script nunca ficar preso num instalador que abriu um dialogo.
function Invoke-WithTimeout {
    param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSec = 900, [switch]$NoNewWindow, [switch]$Hidden)
    $sp = @{ FilePath = $FilePath; PassThru = $true }
    if ($ArgumentList) { $sp.ArgumentList = $ArgumentList }
    if ($NoNewWindow) { $sp.NoNewWindow = $true }
    if ($Hidden) { $sp.WindowStyle = 'Hidden' }
    $p = Start-Process @sp
    $null = $p.Handle      # sem isso o ExitCode pode vir vazio no Windows PowerShell 5.1
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        throw "tempo esgotado ($TimeoutSec s) esperando $(Split-Path $FilePath -Leaf); o processo continua rodando, verifique se ha uma janela aberta"
    }
    return $p.ExitCode
}

function Install-WingetPackage {
    param([string]$Id)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Warn2 "winget indisponivel; pulando $Id"; return }
    Invoke-Change "winget install $Id" {
        $code = Invoke-WithTimeout -FilePath 'winget' -NoNewWindow -TimeoutSec 600 -ArgumentList @(
            'install', '--id', $Id, '--exact', '--silent', '--source', 'winget',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        # -1978335189 = nada a atualizar ; -1978335135 = ja instalado
        if ($code -ne 0 -and $code -ne -1978335189 -and $code -ne -1978335135) { throw "winget retornou $code" }
    }
}

# ----------------------------------------------------------------------------------------------
# Descoberta e download dos drivers AMD
# ----------------------------------------------------------------------------------------------
function Get-AmdPage {
    param([string]$Url)
    for ($i = 1; $i -le 3; $i++) {
        try { return (Invoke-WebRequest -Uri $Url -UserAgent $AmdUserAgent -UseBasicParsing -TimeoutSec 60).Content }
        catch { if ($i -eq 3) { throw }; Start-Sleep -Seconds (2 * $i) }
    }
}

function Get-RemoteSize {
    # HEAD com Referer (sem ele a AMD devolve uma pagina HTML em vez do arquivo)
    param([string]$Url)
    $h = Invoke-WebRequest -Uri $Url -Method Head -UserAgent $AmdUserAgent -Headers @{ Referer = $AmdReferer } -UseBasicParsing -TimeoutSec 60
    if ($h.Headers['Content-Type'] -notmatch 'octet-stream|application/x-') { throw "a AMD nao devolveu um arquivo para $Url (Content-Type: $($h.Headers['Content-Type']))" }
    return [int64]($h.Headers['Content-Length'] | Select-Object -First 1)
}

function Get-AmdGpuDriver {
    param([string]$Channel)
    $html  = Get-AmdPage $GpuPageUrl
    $items = foreach ($a in [regex]::Matches($html, '(?s)<article[^>]*driver-download-details.*?</article>')) {
        $blk  = $a.Value
        $href = [regex]::Match($blk, 'href="(https://drivers\.amd\.com/drivers/[^"]+\.exe)"').Groups[1].Value
        if (-not $href -or $href -match 'minimalsetup|_web\.exe' -or $href -notmatch 'win11') { continue }
        $ver = [regex]::Match($href, 'edition-(\d+\.\d+\.\d+)').Groups[1].Value
        if (-not $ver) { continue }
        $rev = ([regex]::Match($blk, 'Revision Number</strong>\s*<p>(.*?)</p>').Groups[1].Value).Trim()
        [pscustomobject]@{
            Url         = $href
            Version     = [version]$ver
            Revision    = $rev
            Date        = [regex]::Match($blk, 'Release Date</strong>\s*<p>\s*([0-9-]+)').Groups[1].Value
            Recommended = ($rev -match 'Recommended')
        }
    }
    $items = @($items | Sort-Object Url -Unique | Sort-Object Version -Descending)
    if ($items.Count -eq 0) { return $null }
    if ($Channel -eq 'Recommended') {
        $rec = @($items | Where-Object Recommended)
        if ($rec.Count -gt 0) { return $rec[0] }
        Write-Warn2 'Nenhum driver "Recommended" listado; usando o mais novo.'
    }
    return $items[0]
}

function Get-AmdChipsetDriver {
    foreach ($u in $ChipsetPageUrls) {
        try { $html = Get-AmdPage $u } catch { continue }
        $found = foreach ($m in [regex]::Matches($html, 'https://drivers\.amd\.com/drivers/AMD_Chipset_Software_([0-9.]+)\.exe', 'IgnoreCase')) {
            [pscustomobject]@{ Url = $m.Value; Version = [version]$m.Groups[1].Value; Label = $m.Groups[1].Value }
        }
        $found = @($found | Sort-Object Url -Unique | Sort-Object Version -Descending)
        if ($found.Count -gt 0) { return $found[0] }
    }
    return $null
}

function Get-InstalledVersion {
    # Le a versao de um programa em "Programas e Recursos" (maior versao entre os que casam o nome).
    param([string]$NamePattern)
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $best = $null
    foreach ($i in @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $NamePattern -and $_.DisplayVersion })) {
        try { $v = [version]($i.DisplayVersion -replace '[^0-9.]', ''); if (-not $best -or $v -gt $best) { $best = $v } } catch { }
    }
    return $best
}

function Assert-AmdSigned {
    param([string]$Path)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') { throw "assinatura digital invalida ($($sig.Status)): $Path" }
    if ($sig.SignerCertificate.Subject -notmatch 'Advanced Micro Devices|O=AMD|CN=AMD') {
        throw "arquivo assinado por outro publicador: $($sig.SignerCertificate.Subject)"
    }
}

function Save-AmdFile {
    param([string]$Url, [string]$OutFile)
    if (-not (Test-Path $DriverDir)) { New-Item -ItemType Directory -Path $DriverDir -Force | Out-Null }
    $expected = Get-RemoteSize $Url
    $have = 0; if (Test-Path $OutFile) { $have = (Get-Item $OutFile).Length }
    if ($have -gt $expected) { Remove-Item $OutFile -Force; $have = 0 }
    if ($have -ne $expected) {
        Write-Info ("Baixando {0} ({1:N0} MB)..." -f (Split-Path $Url -Leaf), ($expected / 1MB))
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        & $curl -L --fail --retry 5 --retry-delay 3 -C - --progress-bar -A $AmdUserAgent -e $AmdReferer -o $OutFile $Url
        if ($LASTEXITCODE -ne 0) { throw "curl falhou (codigo $LASTEXITCODE)" }
    }
    if ((Get-Item $OutFile).Length -ne $expected) { throw 'tamanho do arquivo baixado difere do esperado' }
    Assert-AmdSigned $OutFile
    Write-Ok 'Download concluido e assinatura digital da AMD verificada.'
}

function Get-HardwareInfo {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpu = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        CpuName   = ($cpu.Name -replace '\s+', ' ').Trim()
        CpuIsAmd  = ($cpu.Manufacturer -eq 'AuthenticAMD')
        AmdGpu    = @($gpu | Where-Object { $_.InstanceId -match 'VEN_1002' })
        NvidiaGpu = @($gpu | Where-Object { $_.InstanceId -match 'VEN_10DE' })
        GpuNames  = (($gpu | ForEach-Object { $_.FriendlyName }) -join ', ')
    }
}

# ----------------------------------------------------------------------------------------------
# Perfil Default (novos usuarios) e gatilhos de reinstalacao
# ----------------------------------------------------------------------------------------------
function Set-DefaultUserValues {
    # Cada item: @(subchave, nome, valor, tipo) ; valor '__DELETE__' remove o valor. Nao entra no undo.
    param([object[]]$Values, [string]$Desc)
    $hive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path $hive)) { return }
    Invoke-Change "perfil Default (novos usuarios): $Desc" {
        & reg.exe load HKU\GamingSetupDefault $hive | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'nao foi possivel carregar o hive do perfil Default' }
        try {
            foreach ($v in $Values) {
                $p = 'Registry::HKEY_USERS\GamingSetupDefault\' + $v[0]
                if ($v[2] -eq '__DELETE__') { Remove-ItemProperty -Path $p -Name $v[1] -ErrorAction SilentlyContinue; continue }
                if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }
                New-ItemProperty -LiteralPath $p -Name $v[1] -Value $v[2] -PropertyType $v[3] -Force | Out-Null
            }
        } finally {
            for ($i = 0; $i -lt 6; $i++) {
                [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                & reg.exe unload HKU\GamingSetupDefault 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { break }
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Remove-UpdateWorker {
    # O Windows Update usa estas chaves para (re)instalar Outlook novo, Dev Home etc. depois do OOBE.
    # Melhor esforco: a Microsoft documenta que remover o pacote provisionado e o metodo oficial; isto e reforco.
    param([string]$Name)
    $sub = "SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\$Name"
    if (-not (Test-Path -LiteralPath "HKLM:\$sub")) { return }
    Invoke-Change "remover gatilho de reinstalacao do Windows Update: $Name (com backup .reg)" {
        if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
        $bak = Join-Path $BackupDir ("UScheduler_Oobe-{0}.reg" -f $Name)
        & reg.exe export "HKLM\$sub" $bak /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'nao consegui fazer o backup da chave; nada foi removido' }
        Remove-Item -LiteralPath "HKLM:\$sub" -Recurse -Force -ErrorAction Stop
        $script:UndoLog.Add([pscustomobject]@{ Type = 'regfile'; File = $bak })
    }
}

function Add-PostCleanup {
    param([string]$Path)
    if ($DryRun) { Write-Dry "apagar $Path (depois de reiniciar o Explorer)" } else { $script:PostCleanup.Add($Path) }
}

# ----------------------------------------------------------------------------------------------
# Diagnostico (somente leitura): o que o script nao muda
# ----------------------------------------------------------------------------------------------
function Get-ReBarState {
    # Sem Resizable BAR a janela de memoria da GPU para a CPU e de 256 MB; com ReBAR, e do tamanho da VRAM.
    $dev = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.PNPClass -eq 'Display' -and $_.DeviceID -match 'VEN_1002' } | Select-Object -First 1
    if (-not $dev) { return $null }
    $r = @(Get-CimAssociatedInstance -InputObject $dev -Association Win32_PnPAllocatedResource -ErrorAction SilentlyContinue |
        Where-Object { $_.CimClass.CimClassName -eq 'Win32_DeviceMemoryAddress' })
    if ($r.Count -eq 0) { return $null }
    $max = ($r | ForEach-Object { [double]($_.EndingAddress - $_.StartingAddress + 1) } | Measure-Object -Maximum).Maximum
    return [pscustomobject]@{ BarMB = [math]::Round($max / 1MB); Enabled = ($max -ge 1GB) }
}

function Show-Diagnostics {
    Write-Title 'Diagnostico: o que o script NAO muda (BIOS e hardware)'
    try {
        $rb = Get-ReBarState
        if ($null -eq $rb) { Write-Skip 'Resizable BAR: nao consegui determinar' }
        elseif ($rb.Enabled) { Write-Ok ("Resizable BAR ativo (janela de {0} MB)." -f $rb.BarMB) }
        else {
            Write-Warn2 ("Resizable BAR DESLIGADO (janela da GPU de {0} MB)." -f $rb.BarMB)
            Write-Warn2 '   Na BIOS: ligue "Above 4G Decoding" e "Re-Size BAR Support" (Smart Access Memory). Ganho: de nenhum a ~15% conforme o jogo.'
        }
    } catch { Write-Skip 'Resizable BAR: erro ao consultar' }
    try {
        $mods = @(Get-CimInstance Win32_PhysicalMemory)
        if ($mods.Count -gt 0) {
            $totalGB = [math]::Round((($mods | Measure-Object Capacity -Sum).Sum) / 1GB)
            $cfg   = ($mods | Measure-Object ConfiguredClockSpeed -Minimum).Minimum
            $rated = ($mods | Measure-Object Speed -Maximum).Maximum
            if ($cfg -and $rated -and $cfg -lt $rated) { Write-Warn2 "RAM rodando a $cfg MT/s, mas o kit e de $rated MT/s: ative o perfil XMP/DOCP/EXPO na BIOS." }
            else { Write-Ok "RAM: $($mods.Count) modulo(s), $totalGB GB, a $cfg MT/s." }
            if ($mods.Count -lt 2) { Write-Warn2 'Apenas 1 pente de RAM: single-channel reduz bastante o desempenho. Use 2 pentes em dual-channel.' }
            if ($totalGB -le 16) { Write-Info 'Com 16 GB e uma GPU de 8 GB, jogos recentes podem esgotar a RAM. Confira em Gerenciador de Tarefas > Desempenho > Memoria durante o jogo.' }
        }
    } catch { }
    try {
        $d = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
        $pct = $d.Free / ($d.Free + $d.Used)
        if ($pct -lt 0.15) { Write-Warn2 ("Disco do sistema com so {0:P0} livre: SSD cheio fica mais lento. Mantenha 15-20% livre." -f $pct) }
        else { Write-Ok ("Disco do sistema com {0:P0} livre." -f $pct) }
    } catch { }
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
        if (@($dg.SecurityServicesRunning) -contains 2) {
            Write-Info 'Integridade de memoria (HVCI/VBS) esta LIGADA. Medicoes publicadas em Ryzen 5000: ~3-8% em jogos limitados por CPU, menos se limitados por GPU.'
            Write-Info '   Se quiser desligar: rode com -DisableVBS (menos protecao contra malware de kernel). A Microsoft planeja ligar isso por padrao em mais PCs.'
        } else { Write-Info 'Integridade de memoria (HVCI) esta desligada.' }
    } catch { }
    try {
        $hw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
        $state = 'padrao do driver'; if ($hw -eq 2) { $state = 'LIGADO' } elseif ($hw -eq 1) { $state = 'desligado' }
        Write-Info "Agendamento de GPU por hardware (HAGS): $state."
    } catch { }
}

# ----------------------------------------------------------------------------------------------
# Etapas
# ----------------------------------------------------------------------------------------------
function Test-PendingReboot {
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        if (Test-Path $k) { return $true }
    }
    return $false
}

function Step-Preflight {
    Write-Title 'Pre-checagens'
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 22000) { Write-Warn2 "Este script e para Windows 11 (build >= 22000). Build atual: $build"; $script:Abort = $true; return }
    Write-Ok "Windows 11 build $build."

    if (Test-PendingReboot) {
        if ($IgnorePendingReboot -or $DryRun) { Write-Warn2 'Ha um reinicio pendente (ignorado).' }
        else {
            Write-Warn2 'Ha um reinicio pendente do Windows. Reinicie o PC e rode de novo (remocao de apps e instaladores falham com reinicio pendente). Use -IgnorePendingReboot para forcar.'
            $script:Abort = $true; return
        }
    } else { Write-Ok 'Nenhum reinicio pendente.' }

    try {
        $null = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 15
        Write-Ok 'Internet OK.'
    } catch {
        $script:Offline = $true
        Write-Warn2 'Sem internet: as etapas de runtimes (winget) e drivers serao puladas.'
    }

    try {
        $free = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free
        if ($free -lt 8GB) { Write-Warn2 ("Pouco espaco livre ({0:N1} GB). O instalador da GPU precisa de ~3 GB; libere pelo menos 8 GB." -f ($free / 1GB)) }
    } catch { }
}

function Step-RestorePoint {
    Write-Title 'Ponto de restauracao'
    if ($NoRestorePoint) { Write-Skip '-NoRestorePoint'; return }
    if ($DryRun) { Write-Dry 'criar e verificar o ponto de restauracao "Antes do Gaming Setup"'; return }
    $desc = 'Antes do Gaming Setup'
    $key  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $ok = $false
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        # Por padrao o Windows so permite 1 ponto a cada 24h; liberamos so durante a criacao
        New-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        $rp = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Where-Object { $_.Description -eq $desc } | Sort-Object SequenceNumber -Descending | Select-Object -First 1
        if ($rp -and ((Get-Date) - [Management.ManagementDateTimeConverter]::ToDateTime($rp.CreationTime)).TotalMinutes -lt 10) { $ok = $true }
    } catch { Write-Warn2 "Ponto de restauracao: $($_.Exception.Message)" }
    finally { Remove-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }

    if ($ok) { Write-Ok 'Ponto de restauracao criado e verificado.'; return }
    Write-Warn2 'Nao foi possivel confirmar o ponto de restauracao.'
    if ($Yes) { Write-Warn2 'Continuando por causa de -Yes. O arquivo de undo cobre registro, servicos e tarefas.'; return }
    $r = Read-Host 'Continuar mesmo assim? (S/N)'
    if ($r -notmatch '^[sSyY]') { $script:Abort = $true }
}

function Step-Privacy {
    Write-Title 'Telemetria, privacidade e sugestoes'
    if ($SkipPrivacy) { Write-Skip '-SkipPrivacy'; return }

    # Observacao: no Windows 11 Pro o nivel minimo de diagnostico ("Necessario") e imposto pelo sistema;
    # AllowTelemetry=0 + servico DiagTrack desativado + tarefas desativadas impedem o envio na pratica.
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
    Set-Reg "$pol\DataCollection" 'AllowTelemetry' 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
    Set-Reg "$pol\DataCollection" 'DoNotShowFeedbackNotifications' 1
    Set-Reg "$pol\DataCollection" 'DisableOneSettingsDownloads' 1
    Set-Reg "$pol\DataCollection" 'LimitDiagnosticLogCollection' 1
    Set-Reg "$pol\DataCollection" 'LimitDumpCollection' 1
    Set-Reg "$pol\DataCollection" 'AllowDeviceNameInTelemetry' 0
    Set-Reg "$pol\AppCompat" 'AITEnable' 0
    Set-Reg "$pol\AppCompat" 'DisableInventory' 1
    Set-Reg "$pol\AppCompat" 'DisableUAR' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
    Set-Reg "$pol\Windows Error Reporting" 'Disabled' 1
    Set-Reg "$pol\System" 'EnableActivityFeed' 0
    Set-Reg "$pol\System" 'PublishUserActivities' 0
    Set-Reg "$pol\System" 'UploadUserActivities' 0
    Set-Reg "$pol\AdvertisingInfo" 'DisabledByGroupPolicy' 1
    # Pela documentacao da Microsoft, DisableWindowsConsumerFeatures so e imposto em Enterprise/Education; no Pro
    # a protecao real contra apps "sugeridos" vem dos valores de ContentDeliveryManager abaixo + remocao dos pacotes.
    Set-Reg "$pol\CloudContent" 'DisableWindowsConsumerFeatures' 1
    Set-Reg "$pol\CloudContent" 'DisableSoftLanding' 1
    Set-Reg "$pol\CloudContent" 'DisableCloudOptimizedContent' 1
    Set-Reg "$pol\CloudContent" 'DisableTailoredExperiencesWithDiagnosticData' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Communications' 'ConfigureChatAutoInstall' 0
    Set-Reg "$pol\Windows Search" 'AllowCortana' 0
    Set-Reg "$pol\Windows Search" 'DisableWebSearch' 1
    Set-Reg "$pol\Windows Search" 'ConnectedSearchUseWeb' 0
    Set-Reg "$pol\Windows Search" 'AllowSearchToUseLocation' 0
    Set-Reg "$pol\WindowsAI" 'DisableAIDataAnalysis' 1          # Recall
    Set-Reg "$pol\WindowsAI" 'DisableClickToDo' 1
    Set-Reg "$pol\WindowsCopilot" 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0   # Widgets
    Set-Reg "$pol\Windows Feeds" 'EnableFeeds' 0
    Set-Reg "$pol\DeliveryOptimization" 'DODownloadMode' 0      # nao envia/recebe updates de outros PCs
    Set-Reg "$pol\WindowsUpdate\AU" 'NoAutoRebootWithLoggedOnUsers' 1  # updates continuam, mas sem reiniciar sozinho

    # Edge: nao pre-carrega, nao roda em segundo plano, sem coleta (o navegador continua funcionando)
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    foreach ($kv in @{
            StartupBoostEnabled = 0; BackgroundModeEnabled = 0; HideFirstRunExperience = 1
            EdgeShoppingAssistantEnabled = 0; PersonalizationReportingEnabled = 0; MetricsReportingEnabled = 0
            DiagnosticData = 0; ShowRecommendationsEnabled = 0; HubsSidebarEnabled = 0; EdgeFollowEnabled = 0
            UserFeedbackAllowed = 0; SpotlightExperiencesAndRecommendationsEnabled = 0 }.GetEnumerator()) {
        Set-Reg $edge $kv.Key $kv.Value
    }

    # Preferencias do usuario atual
    foreach ($n in $CdmValues) { Set-Reg "HKCU:\$CdmPath" $n 0 }
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    Set-Reg 'HKCU:\Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1
    Set-Reg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Input\TIPC' 'Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
    Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
    Set-Reg 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsAADCloudSearchEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsMSACloudSearchEnabled' 0
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1

    # Mesmos ajustes anti-sugestao para NOVOS usuarios (perfil Default), senao uma conta nova volta a receber apps sugeridos
    $def = @()
    foreach ($n in $CdmValues) { $def += , @($CdmPath, $n, 0, 'DWord') }
    $def += , @('Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo', 'Enabled', 0, 'DWord')
    $def += , @('Software\Microsoft\Windows\CurrentVersion\Search', 'BingSearchEnabled', 0, 'DWord')
    $def += , @('Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement', 'ScoobeSystemSettingEnabled', 0, 'DWord')
    $def += , @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'Start_IrisRecommendations', 0, 'DWord')
    $def += , @('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'ShowSyncProviderNotifications', 0, 'DWord')
    Set-DefaultUserValues -Values $def -Desc 'sem apps/sugestoes automaticos'

    # Servicos de telemetria/recursos que ninguem usa num PC de jogos
    foreach ($s in 'DiagTrack', 'dmwappushservice', 'MapsBroker', 'RetailDemo', 'WpcMonSvc', 'PhoneSvc', 'WerSvc', 'wisvc') { Disable-Svc $s }

    # Tarefas agendadas de telemetria
    $tasks = @(
        @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
        @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser Exp'),
        @('\Microsoft\Windows\Application Experience\', 'MareBackup'),
        @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
        @('\Microsoft\Windows\Application Experience\', 'StartupAppTask'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\', 'KernelCeipTask'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\', 'BthSQM'),
        @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector'),
        @('\Microsoft\Windows\Windows Error Reporting\', 'QueueReporting'),
        @('\Microsoft\Windows\Feedback\Siuf\', 'DmClient'),
        @('\Microsoft\Windows\Feedback\Siuf\', 'DmClientOnScenarioDownload'),
        @('\Microsoft\Windows\Autochk\', 'Proxy'),
        @('\Microsoft\Windows\NetTrace\', 'GatherNetworkInfo'),
        @('\Microsoft\Windows\Maps\', 'MapsToastTask'),
        @('\Microsoft\Windows\Maps\', 'MapsUpdateTask')
    )
    foreach ($t in $tasks) { Disable-Task $t[0] $t[1] }
}

function Restore-KnownFolders {
    # Devolve Desktop/Documentos/Imagens/Musicas/Videos/Downloads ao local padrao e MOVE os arquivos de volta.
    # Seguro por construcao: se houver arquivos "so na nuvem" (placeholders), aquela pasta e pulada, pois
    # sem o OneDrive eles nao podem mais ser baixados.
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $map = [ordered]@{
        'Desktop' = 'Desktop'; 'Personal' = 'Documents'; 'My Pictures' = 'Pictures'
        'My Music' = 'Music'; 'My Video' = 'Videos'; '{374DE290-123F-4565-9164-39C4925E467B}' = 'Downloads'
    }
    $props = Get-ItemProperty $key -ErrorAction SilentlyContinue
    foreach ($name in $map.Keys) {
        $cur = $props.$name
        if (-not $cur -or $cur -notmatch 'OneDrive') { continue }
        $src = [Environment]::ExpandEnvironmentVariables($cur)
        $dst = Join-Path $env:USERPROFILE $map[$name]
        $cloudOnly = 0
        if (Test-Path -LiteralPath $src) {
            $cloudOnly = @(Get-ChildItem -LiteralPath $src -Recurse -Force -File -ErrorAction SilentlyContinue |
                Where-Object { (([int]$_.Attributes) -band (0x400000 -bor 0x40000 -bor 0x1000)) -ne 0 }).Count   # RECALL_ON_DATA_ACCESS | RECALL_ON_OPEN | OFFLINE
        }
        if ($cloudOnly -gt 0) { Write-Warn2 "$($map[$name]): $cloudOnly arquivo(s) so na nuvem; pasta NAO movida (baixe-os antes pelo OneDrive)."; continue }
        Invoke-Change "mover $($map[$name]) de volta para $dst" {
            if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
            if (Test-Path -LiteralPath $src) {
                & robocopy.exe $src $dst /E /MOVE /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "robocopy falhou (codigo $LASTEXITCODE); registro mantido" }
            }
            Save-RegState $key $name
            New-ItemProperty -Path $key -Name $name -Value ('%USERPROFILE%\' + $map[$name]) -PropertyType ExpandString -Force | Out-Null
        }
    }
}

function Step-OneDrive {
    Write-Title 'Remover OneDrive'
    if ($SkipOneDrive) { Write-Skip '-SkipOneDrive'; return }

    # Se Desktop/Documentos/Imagens estiverem redirecionadas para o OneDrive, NAO apagamos a pasta.
    $usf = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
    $redirected = @()
    if ($usf) { $redirected = @($usf.PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Value -match 'OneDrive' } | ForEach-Object { $_.Name }) }
    if ($redirected.Count -gt 0) {
        if ($RestoreKnownFolders) {
            Restore-KnownFolders
            $usf = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
            $redirected = @($usf.PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Value -match 'OneDrive' } | ForEach-Object { $_.Name })
        }
        if ($redirected.Count -gt 0) {
            Write-Warn2 "Pastas do Windows apontam para o OneDrive ($($redirected -join ', ')). Elas continuam funcionando, mas ficam dentro da pasta OneDrive, que NAO sera apagada."
            if (-not $RestoreKnownFolders) { Write-Warn2 'Para devolve-las ao local normal (C:\Users\voce\Documentos etc.), rode de novo com -RestoreKnownFolders.' }
        }
    }

    Invoke-Change 'encerrar processos do OneDrive' { Stop-Process -Name OneDrive, OneDriveSetup, FileCoAuth -Force -ErrorAction SilentlyContinue }
    $setup = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($setup) {
        Invoke-Change "desinstalar OneDrive ($setup /uninstall)" { [void](Invoke-WithTimeout -FilePath $setup -ArgumentList '/uninstall' -TimeoutSec 180 -Hidden) }
    } else {
        Write-Info 'OneDriveSetup.exe nao encontrado (ja removido?).'
    }
    Invoke-Change 'remover pacote Microsoft.OneDriveSync (se existir)' {
        Get-AppxPackage -AllUsers -Name 'Microsoft.OneDriveSync' -ErrorAction SilentlyContinue | ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop }
    }

    # Sobras: o Explorer carrega a extensao do OneDrive, entao a limpeza roda DEPOIS de reiniciar o Explorer (Step-Finish)
    foreach ($d in "$env:LOCALAPPDATA\Microsoft\OneDrive", "$env:ProgramData\Microsoft OneDrive", "$env:SystemDrive\OneDriveTemp") {
        if (Test-Path $d) { Add-PostCleanup $d }
    }
    $odUser = Join-Path $env:USERPROFILE 'OneDrive'
    if ((Test-Path $odUser) -and $redirected.Count -eq 0) {
        if (@(Get-ChildItem $odUser -Force -ErrorAction SilentlyContinue).Count -eq 0) { Add-PostCleanup $odUser }
        else { Write-Warn2 "$odUser tem arquivos; mantida. Apague manualmente se nao precisar." }
    }
    # Tira o icone do OneDrive do painel de navegacao do Explorer e impede auto-start
    foreach ($k in 'Registry::HKEY_CLASSES_ROOT\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
        'Registry::HKEY_CLASSES_ROOT\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}') {
        Set-Reg $k 'System.IsPinnedToNameSpaceTree' 0 -OnlyIfExists
    }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
    Invoke-Change 'remover OneDrive do auto-start do usuario' {
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive' -ErrorAction SilentlyContinue
    }
    Set-DefaultUserValues -Values @(, @('Software\Microsoft\Windows\CurrentVersion\Run', 'OneDriveSetup', '__DELETE__', 'String')) -Desc 'sem auto-start do OneDrive'
    Invoke-Change 'remover tarefas agendadas do OneDrive' {
        Get-ScheduledTask -TaskName 'OneDrive*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Info 'Limite: OneDriveSetup.exe continua em System32/SysWOW64 e uma atualizacao de versao do Windows pode recolocar o OneDrive; rode o script de novo apos elas.'
}

function Step-Debloat {
    Write-Title 'Remover bloatware e gatilhos de reinstalacao'
    if ($SkipDebloat) { Write-Skip '-SkipDebloat'; return }

    $remove = @(
        'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.BingFinance',
        'Microsoft.BingSports', 'Microsoft.BingTranslator', 'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MicrosoftStickyNotes', 'Microsoft.Todos',
        'Microsoft.PowerAutomateDesktop', 'Microsoft.WindowsFeedbackHub', 'Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice',
        'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'Microsoft.WindowsMaps', 'Microsoft.People', 'Microsoft.Windows.DevHome',
        'Microsoft.OutlookForWindows', 'microsoft.windowscommunicationsapps', 'Microsoft.Copilot', 'Microsoft.Windows.Copilot',
        'Microsoft.Windows.Ai.Copilot.Provider', 'Microsoft.549981C3F5F10', 'Microsoft.Office.OneNote', 'Microsoft.Office.Sway',
        'Microsoft.SkypeApp', 'MSTeams', 'MicrosoftTeams', 'Microsoft.MixedReality.Portal', 'Microsoft.Microsoft3DViewer',
        'Microsoft.Print3D', 'Microsoft.Whiteboard', 'Microsoft.NetworkSpeedTest', 'Microsoft.OneConnect', 'Microsoft.PCManager',
        'MicrosoftCorporationII.MicrosoftFamily', 'MicrosoftCorporationII.QuickAssist', 'Microsoft.Wallet', 'Microsoft.WindowsAlarms',
        'Microsoft.WindowsSoundRecorder', 'Microsoft.WindowsCamera', 'Microsoft.MicrosoftJournal', 'Microsoft.XboxSpeechToTextOverlay',
        # promocionais de terceiros (aparecem em instalacoes OEM / contas novas)
        '*CandyCrush*', '*king.com*', '*Spotify*', '*Disney*', '*TikTok*', '*Facebook*', '*Instagram*', '*Twitter*',
        '*Netflix*', '*PrimeVideo*', '*LinkedIn*', '*Duolingo*', '*Pinterest*', '*McAfee*', '*Norton*'
    )
    if (-not $KeepGameBar) { $remove += 'Microsoft.XboxGamingOverlay' }   # Xbox Game Bar (Radeon Software tem captura propria)

    # Le as listas uma vez (cada chamada demora)
    $installed = @()
    try { $installed = @(Get-AppxPackage -AllUsers -ErrorAction Stop) } catch { try { $installed = @(Get-AppxPackage -ErrorAction Stop) } catch { Write-Warn2 'Nao consegui listar os apps (execute como Administrador).' } }
    $prov = @()
    try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { }

    foreach ($pat in $remove) {
        foreach ($p in @($installed | Where-Object { $_.Name -like $pat } | Sort-Object PackageFullName -Unique)) {
            if ($p.Name -match $ProtectedAppx) { Write-Skip "protegido: $($p.Name)"; continue }
            if ($p.NonRemovable) { Write-Skip "nao removivel pelo Windows: $($p.Name)"; continue }
            Invoke-Change "remover app $($p.Name)" { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; $script:RemovedApps.Add($p.Name) }
        }
        foreach ($p in @($prov | Where-Object { $_.DisplayName -like $pat })) {
            if ($p.DisplayName -match $ProtectedAppx) { continue }
            Invoke-Change "remover pacote provisionado $($p.DisplayName) (impede reinstalar em contas novas)" { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null }
        }
    }

    # Gatilhos do Windows Update que reinstalam apps depois do OOBE (so existem em algumas builds)
    foreach ($w in 'OutlookUpdate', 'DevHomeUpdate', 'CrossDeviceUpdate') { Remove-UpdateWorker $w }

    if (-not $KeepGameBar) {
        # Sem o app da Game Bar, alguns jogos/controles disparam o aviso "preciso de um novo app para abrir ms-gamingoverlay".
        foreach ($proto in 'ms-gamingoverlay', 'ms-gamebar') {
            $kp = "Registry::HKEY_CLASSES_ROOT\$proto"
            if (Test-Path -LiteralPath $kp) { continue }
            Invoke-Change "registrar protocolo vazio $proto (evita aviso de app ausente)" {
                [Microsoft.Win32.Registry]::SetValue("HKEY_CLASSES_ROOT\$proto", '', "URL:$proto")      # valor padrao
                [Microsoft.Win32.Registry]::SetValue("HKEY_CLASSES_ROOT\$proto", 'URL Protocol', '')
                $script:UndoLog.Add([pscustomobject]@{ Type = 'regkey'; Path = $kp })
            }
        }
    }

    # Recursos opcionais legados / sem uso (lista lida uma vez; a consulta e lenta)
    $capsInstalled = @()
    try { $capsInstalled = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { $_.State -eq 'Installed' }) }
    catch { Write-Warn2 "nao consegui consultar recursos opcionais: $($_.Exception.Message)" }
    foreach ($cap in 'App.StepsRecorder*', 'Browser.InternetExplorer*', 'MathRecognizer*', 'Media.WindowsMediaPlayer*', 'Microsoft.Windows.WordPad*') {
        foreach ($c in @($capsInstalled | Where-Object { $_.Name -like $cap })) {
            Invoke-Change "remover recurso $($c.Name)" { Remove-WindowsCapability -Online -Name $c.Name -ErrorAction Stop | Out-Null }
        }
    }
    foreach ($f in 'MicrosoftWindowsPowerShellV2Root', 'MicrosoftWindowsPowerShellV2', 'Recall', 'WorkFolders-Client', 'Internet-Explorer-Optional-amd64') {
        $feat = $null
        try { $feat = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop } catch { }   # sem elevacao lanca COMException
        if ($feat -and $feat.State -eq 'Enabled') {
            Invoke-Change "desativar recurso do Windows $f" { Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -ErrorAction Stop | Out-Null }
        }
    }
}

function Step-Performance {
    Write-Title 'Desempenho para jogos'
    if ($SkipPerformance) { Write-Skip '-SkipPerformance'; return }

    # Game Mode ligado; captura em segundo plano (Game DVR) desligada
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    # Agendamento de GPU por hardware: a AMD recomenda para FSR 3 Frame Generation em RX 7000 no Windows 11.
    # O ganho de FPS em si e pequeno/variavel. Requer reinicio.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2

    # Entrada: sem aceleracao do mouse, sem janelas de Sticky Keys no meio do jogo
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
    Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
    Set-Reg 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'
    Set-Reg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String'

    # Interface enxuta (conforto, nao FPS)
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg $adv 'HideFileExt' 0
    Set-Reg $adv 'LaunchTo' 1                       # Explorer abre em "Este Computador"
    Set-Reg $adv 'ShowSyncProviderNotifications' 0  # anuncios do OneDrive/Microsoft 365 no Explorer
    Set-Reg $adv 'Start_TrackProgs' 0
    Set-Reg $adv 'Start_IrisRecommendations' 0
    Set-Reg $adv 'Start_AccountNotifications' 0
    Set-Reg $adv 'ShowTaskViewButton' 0
    Set-Reg $adv 'TaskbarMn' 0
    Set-Reg $adv 'TaskbarDa' 0                      # pode ser bloqueado pelo Windows; se falhar, desligue em Configuracoes
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0

    if (-not $KeepHibernation) {
        # Libera ~6-8 GB (hiberfil.sys) e evita problemas de "inicializacao rapida" com drivers de video
        $hibWas = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
        Invoke-Change 'desativar hibernacao e inicializacao rapida' {
            if ($hibWas -eq 1) { $script:UndoLog.Add([pscustomobject]@{ Type = 'hibernate' }) }
            & powercfg.exe /hibernate off | Out-Null
        }
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
    }

    if ($DisableVBS) {
        Write-Warn2 'Desligando VBS/Integridade de memoria (-DisableVBS): mais FPS em jogos limitados por CPU, menos protecao contra malware de kernel.'
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
    }
}

function Step-Runtimes {
    Write-Title 'Runtimes para jogos (winget)'
    if ($SkipRuntimes) { Write-Skip '-SkipRuntimes'; return }
    if ($script:Offline) { Write-Skip 'sem internet'; return }
    foreach ($id in 'Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.x86', 'Microsoft.DirectX') { Install-WingetPackage $id }
}

function Step-Drivers {
    Write-Title 'Drivers AMD (chipset + Radeon)'
    if ($SkipDrivers) { Write-Skip '-SkipDrivers'; return }
    if ($script:Offline) { Write-Skip 'sem internet'; return }

    $hw = Get-HardwareInfo
    Write-Info "CPU: $($hw.CpuName)"
    Write-Info "GPU: $($hw.GpuNames)"

    # ---- Chipset (instalacao silenciosa: /S) ----
    if ($hw.CpuIsAmd) {
        try {
            $chip = Get-AmdChipsetDriver
            if (-not $chip) { throw 'nao achei o link do chipset na pagina da AMD' }
            $have = Get-InstalledVersion 'AMD Chipset Software'
            if ($have -and $have -ge $chip.Version -and -not $ForceDrivers) {
                Write-Ok "Chipset ja esta atualizado (instalado $have, mais recente $($chip.Label))."
            } else {
                $size = Get-RemoteSize $chip.Url
                Write-Ok ("Chipset AMD mais recente: {0}  ({1:N0} MB)" -f $chip.Label, ($size / 1MB))
                $file = Join-Path $DriverDir (Split-Path $chip.Url -Leaf)
                Invoke-Change "baixar e instalar chipset $($chip.Label) em modo silencioso" {
                    Save-AmdFile -Url $chip.Url -OutFile $file
                    Write-Info 'Instalando chipset (1-3 min)...'
                    $code = Invoke-WithTimeout -FilePath $file -ArgumentList '/S' -TimeoutSec 900
                    # 0/2 = ok, 3010 = ok (precisa reiniciar), 1641 = ok (reinicio iniciado)
                    if ($code -notin 0, 2, 3010, 1641) { throw "instalador do chipset retornou codigo $code" }
                    $script:NeedsReboot = $true
                    Remove-Item $file -Force -ErrorAction SilentlyContinue
                    Write-Ok 'Chipset instalado.'
                }
            }
        } catch { Write-Warn2 "Chipset: $($_.Exception.Message). Baixe manualmente em https://www.amd.com/en/support/downloads/drivers.html/chipsets/am4/b550.html" }
    } else {
        Write-Skip 'CPU nao e AMD; chipset nao instalado'
    }

    # ---- GPU ----
    if ($hw.AmdGpu.Count -gt 0) {
        try {
            $gpu = Get-AmdGpuDriver -Channel $GpuChannel
            if (-not $gpu) { throw 'nao achei o link do Adrenalin na pagina da AMD' }
            $have = Get-InstalledVersion 'AMD Software*'
            if ($have -and $have -ge $gpu.Version -and -not $ForceDrivers) {
                Write-Ok "Adrenalin ja esta atualizado (instalado $have, canal $GpuChannel = $($gpu.Version))."
            } else {
                $size = Get-RemoteSize $gpu.Url
                Write-Ok ("Adrenalin ({0}): {1} - {2}  ({3:N0} MB, lancado em {4})" -f $GpuChannel, $gpu.Version, $gpu.Revision, ($size / 1MB), $gpu.Date)
                $file = Join-Path $DriverDir (Split-Path $gpu.Url -Leaf)
                Invoke-Change "baixar Adrenalin $($gpu.Version) e abrir o instalador" {
                    Save-AmdFile -Url $gpu.Url -OutFile $file
                    Write-Info 'Abrindo o instalador da AMD. Conclua o assistente (a tela pode piscar durante a instalacao).'
                    Write-Info 'Dica: escolha "Somente driver" se quiser o minimo de software extra.'
                    Start-Process -FilePath $file -Wait
                    if ([Environment]::UserInteractive) { [void](Read-Host 'Quando o instalador da AMD terminar, pressione ENTER para continuar') }
                    $script:NeedsReboot = $true
                    Remove-Item $file -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { Write-Warn2 "GPU: $($_.Exception.Message). Baixe manualmente em $GpuPageUrl" }
    } elseif ($hw.NvidiaGpu.Count -gt 0) {
        Write-Warn2 'GPU NVIDIA detectada: este script so baixa drivers AMD. Use GeForce Experience / nvidia.com.'
    } else {
        Write-Warn2 'Nenhuma GPU AMD detectada; driver de video nao instalado.'
    }
}

function Step-WUDriverPolicy {
    # Fica DEPOIS dos drivers: bloquear antes poderia impedir o Windows de trazer audio/rede/Bluetooth num PC recem-instalado.
    Write-Title 'Windows Update nao sobrescreve drivers'
    if ($AllowWUDrivers) { Write-Skip '-AllowWUDrivers'; return }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1
    Write-Info 'Drivers deixam de vir junto das atualizacoes de qualidade. Para reverter: -Undo latest, ou rode com -AllowWUDrivers.'
}

function Step-PowerPlan {
    Write-Title 'Plano de energia'
    if ($PowerPlan -eq 'Keep') { Write-Skip '-PowerPlan Keep'; return }
    # Roda DEPOIS do chipset, pois o instalador da AMD pode alterar/criar planos.
    # Obs.: nao ha benchmark independente mostrando ganho de Ultimate/High sobre Balanced no Ryzen 5000 (a AMD
    # recomenda o Balanced do Windows para esse chip). High tem custo so em consumo/calor em idle. Teste e compare.
    $ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    $high     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    $balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $prev = [regex]::Match((& powercfg.exe /getactivescheme | Out-String), '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}').Value
    $note = { if ($prev) { $script:UndoLog.Add([pscustomobject]@{ Type = 'power'; Guid = $prev }) } }
    switch ($PowerPlan) {
        'Ultimate' {
            Invoke-Change 'ativar plano Desempenho Maximo (fallback: Alto Desempenho)' {
                & $note
                # Passar o GUID de destino torna a operacao idempotente (nao cria copias a cada execucao)
                & powercfg.exe -duplicatescheme $ultimate $ultimate | Out-Null
                & powercfg.exe -setactive $ultimate
                if ($LASTEXITCODE -ne 0) { & powercfg.exe -setactive $high; if ($LASTEXITCODE -ne 0) { throw 'powercfg falhou' } }
            }
        }
        'High'     { Invoke-Change 'ativar plano Alto Desempenho' { & $note; & powercfg.exe -setactive $high; if ($LASTEXITCODE -ne 0) { throw 'powercfg falhou' } } }
        'Balanced' { Invoke-Change 'ativar plano Equilibrado' { & $note; & powercfg.exe -setactive $balanced; if ($LASTEXITCODE -ne 0) { throw 'powercfg falhou' } } }
    }
}

function Step-Finish {
    Write-Title 'Resumo'
    if ($DryRun) {
        Show-Diagnostics
        Write-Host ''
        Write-Host 'DryRun concluido: NADA foi alterado. Rode sem -DryRun para aplicar.' -ForegroundColor Yellow
        return
    }
    # Reinicia o Explorer (aplica barra de tarefas e solta a extensao do OneDrive) e so entao apaga as sobras
    Invoke-Change 'reiniciar o Explorer' { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3 }
    foreach ($d in $script:PostCleanup) {
        if (Test-Path -LiteralPath $d) { Invoke-Change "apagar $d" { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop } }
    }
    Save-UndoLog
    Write-Host ("Alteracoes aplicadas: {0}   Avisos/falhas: {1}" -f $script:Stats.Ok, $script:Stats.Fail)
    Write-Host "Logs:   $LogDir"
    if ($script:UndoLog.Count -gt 0) { Write-Host "Undo:   $($script:UndoFile)   (desfaz registro, servicos, tarefas; use: -Undo latest)" }
    if ($script:RemovedApps.Count -gt 0) { Write-Host ("Apps removidos (reinstale pela Microsoft Store/winget se precisar): {0}" -f (($script:RemovedApps | Sort-Object -Unique) -join ', ')) }
    Show-Diagnostics
    Write-Host ''
    Write-Host 'Reinicie o PC para concluir (HAGS, drivers, servicos).' -ForegroundColor Green
    if ($Reboot) {
        Write-Info 'Reiniciando em 15 segundos (-Reboot)...'
        if ($script:LogStarted) { Stop-Transcript | Out-Null; $script:LogStarted = $false }
        & shutdown.exe /r /t 15 /c "Gaming Setup concluido"
    } elseif ([Environment]::UserInteractive -and -not $Yes) {
        $r = Read-Host 'Reiniciar agora? (S/N)'
        if ($r -match '^[sSyY]') {
            if ($script:LogStarted) { Stop-Transcript | Out-Null; $script:LogStarted = $false }
            Restart-Computer -Force
        }
    }
}

function Invoke-Undo {
    param([string]$File)
    Write-Title 'Desfazer'
    if ($File -eq 'latest') {
        $f = Get-ChildItem -LiteralPath $DataDir -Filter 'undo-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($f) { $File = $f.FullName }
    }
    if (-not $File -or -not (Test-Path -LiteralPath $File)) { Write-Warn2 "arquivo de undo nao encontrado em $DataDir"; return }
    Write-Info "Usando $File"
    # No PS 5.1 o ConvertFrom-Json entrega o array inteiro como 1 objeto; o ForEach-Object o desempacota.
    $entries = @(Get-Content -Raw -LiteralPath $File | ConvertFrom-Json | ForEach-Object { $_ })
    [array]::Reverse($entries)
    foreach ($e in $entries) {
        switch ($e.Type) {
            'reg' {
                Invoke-Change "restaurar $($e.Path) : $($e.Name)" {
                    if ($e.Existed) {
                        if (-not (Test-Path -LiteralPath $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
                        New-ItemProperty -LiteralPath $e.Path -Name $e.Name -Value $e.Value -PropertyType $e.Kind -Force | Out-Null
                    } else {
                        Remove-ItemProperty -LiteralPath $e.Path -Name $e.Name -ErrorAction SilentlyContinue
                    }
                }
            }
            'regkey'  { Invoke-Change "remover chave criada $($e.Path)" { if (Test-Path -LiteralPath $e.Path) { Remove-Item -LiteralPath $e.Path -Recurse -Force } } }
            'regfile' { Invoke-Change "importar backup $($e.File)" { & reg.exe import $e.File | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'reg import falhou' } } }
            'svc'     { Invoke-Change "restaurar servico $($e.Name) ($($e.StartType))" { Set-Service -Name $e.Name -StartupType $e.StartType -ErrorAction Stop } }
            'task'    { Invoke-Change "reativar tarefa $($e.Path)$($e.Name)" { Enable-ScheduledTask -TaskPath $e.Path -TaskName $e.Name -ErrorAction Stop | Out-Null } }
            'power'   { Invoke-Change "restaurar plano de energia $($e.Guid)" { & powercfg.exe -setactive $e.Guid; if ($LASTEXITCODE -ne 0) { throw 'powercfg falhou' } } }
            'hibernate' { Invoke-Change 'reativar hibernacao' { & powercfg.exe /hibernate on | Out-Null } }
        }
    }
    Write-Host ''
    Write-Host 'Desfeito: registro, servicos, tarefas, energia e hibernacao. NAO desfeito: apps removidos, OneDrive, perfil Default, drivers.' -ForegroundColor Yellow
    Write-Host 'Reinicie o PC para concluir.'
}

# ----------------------------------------------------------------------------------------------
# Principal
# ----------------------------------------------------------------------------------------------
function Invoke-Main {
    Write-Host ''
    Write-Host '  Windows 11 Gaming Setup  (Ryzen 7 5700X + RX 7600)' -ForegroundColor White
    if ($DryRun) { Write-Host '  MODO DRY-RUN: nada sera alterado' -ForegroundColor Yellow }

    if ($PSVersionTable.PSEdition -eq 'Core') {
        Write-Warn2 'Voce esta no PowerShell 7+. Abra o "Windows PowerShell" (powershell.exe) como Administrador e rode de novo.'
        return
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $DryRun) {
        if ($script:ScriptPath) {
            Write-Info 'Pedindo permissao de Administrador...'
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($script:ScriptPath)`"")
            foreach ($k in $script:BoundParams.Keys) {
                $v = $script:BoundParams[$k]
                if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } } else { $argList += "-$k"; $argList += "`"$v`"" }
            }
            Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList $argList
        } else {
            Write-Warn2 'Execute em um PowerShell como Administrador (clique direito > Executar como administrador) e rode o comando novamente.'
        }
        return
    }
    if (-not $isAdmin) { Write-Warn2 'DryRun sem Administrador: a lista de apps instalados pode ficar incompleta.' }

    if ($Undo) { Invoke-Undo -File $Undo; return }

    if (-not $DryRun -and -not $Yes) {
        Write-Host ''
        Write-Host 'Isto vai alterar configuracoes do Windows, remover apps e instalar drivers.' -ForegroundColor Yellow
        Write-Host 'Um ponto de restauracao e um arquivo de undo serao criados. Use -DryRun para so visualizar.'
        $r = Read-Host 'Continuar? (S/N)'
        if ($r -notmatch '^[sSyY]') { Write-Host 'Cancelado.'; return }
    }

    if (-not $DryRun) {
        try {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
            Start-Transcript -Path (Join-Path $LogDir ("setup-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null
            $script:LogStarted = $true
        } catch { Write-Warn2 "Nao consegui iniciar o log: $($_.Exception.Message)" }
    }

    try {
        # Cada etapa e isolada: se uma falhar, as demais continuam. Abort so ocorre antes de qualquer alteracao.
        foreach ($step in 'Step-Preflight', 'Step-RestorePoint', 'Step-Privacy', 'Step-OneDrive', 'Step-Debloat', 'Step-Performance',
            'Step-Runtimes', 'Step-Drivers', 'Step-WUDriverPolicy', 'Step-PowerPlan') {
            if ($script:Abort) { Write-Warn2 'Execucao interrompida antes de qualquer alteracao.'; break }
            try { & $step }
            catch { $script:Stats.Fail++; Write-Warn2 "$step falhou: $($_.Exception.Message)" }
        }
        if (-not $script:Abort) {
            try { Step-Finish } catch { Write-Warn2 "Step-Finish falhou: $($_.Exception.Message)" }
        }
    } finally {
        Save-UndoLog
        if ($script:LogStarted) { try { Stop-Transcript | Out-Null } catch { } }
    }
}

Invoke-Main
