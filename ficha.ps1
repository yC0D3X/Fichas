# =====================================================================
#  yCODEX - Ficha Tecnica (Windows)
#  Uso (o site monta esse comando sozinho, com o endereco certo):
#    $ycSite='https://SEU-SITE/'; irm https://raw.githubusercontent.com/yC0D3X/ficha/main/ficha.ps1 | iex
#  Coleta as informacoes da maquina e abre o site ja com a ficha preenchida.
#  Nada e enviado para servidor: os dados vao no proprio link (depois do #).
# =====================================================================

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Try-Get([scriptblock]$b) { try { & $b } catch { $null } }
function Tidy([string]$s) { if ($s) { ($s -replace '\s+', ' ').Trim() } else { '' } }
function Step([string]$t) { Write-Host "  > $t" -ForegroundColor DarkGray }

Write-Host ''
Write-Host '  yCODEX - Ficha Tecnica' -ForegroundColor White
Write-Host '  Coletando informacoes da maquina...' -ForegroundColor Gray

# ---------- Sistema / identificacao ----------
Step 'Sistema e identificacao'
$cs   = Try-Get { Get-CimInstance Win32_ComputerSystem }
$csp  = Try-Get { Get-CimInstance Win32_ComputerSystemProduct }
$bios = Try-Get { Get-CimInstance Win32_BIOS }
$enc  = Try-Get { Get-CimInstance Win32_SystemEnclosure }
$os   = Try-Get { Get-CimInstance Win32_OperatingSystem }

# ---------- CPU ----------
Step 'Processador'
$cpu = Try-Get { Get-CimInstance Win32_Processor | Select-Object -First 1 }

# ---------- Memoria ----------
Step 'Memoria'
$memTypes = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
$modules = @()
foreach ($m in @(Try-Get { Get-CimInstance Win32_PhysicalMemory })) {
    if (-not $m) { continue }
    $t = $memTypes[[int]$m.SMBIOSMemoryType]
    $spd = if ($m.ConfiguredClockSpeed) { $m.ConfiguredClockSpeed } else { $m.Speed }
    $modules += [ordered]@{
        gb    = [math]::Round($m.Capacity / 1GB, 1)
        type  = $t
        speed = $spd
        slot  = Tidy $m.DeviceLocator
        maker = Tidy $m.Manufacturer
    }
}
$slots = 0
foreach ($a in @(Try-Get { Get-CimInstance Win32_PhysicalMemoryArray })) { if ($a) { $slots += [int]$a.MemoryDevices } }

# ---------- Discos ----------
Step 'Armazenamento'
$disks = @()
$pd = @(Try-Get { Get-PhysicalDisk })
if ($pd.Count -and $pd[0]) {
    foreach ($d in $pd) {
        if ("$($d.BusType)" -match 'USB|Virtual|File Backed') { continue }
        $disks += [ordered]@{
            model  = Tidy $d.FriendlyName
            gb     = [math]::Round($d.Size / 1e9)
            type   = "$($d.MediaType)"      # SSD / HDD / Unspecified
            bus    = "$($d.BusType)"        # NVMe / SATA / RAID ...
            health = "$($d.HealthStatus)"
        }
    }
} else {
    foreach ($d in @(Try-Get { Get-CimInstance Win32_DiskDrive })) {
        if (-not $d -or "$($d.InterfaceType)" -eq 'USB') { continue }
        $disks += [ordered]@{ model = Tidy $d.Model; gb = [math]::Round($d.Size / 1e9); type = ''; bus = "$($d.InterfaceType)"; health = '' }
    }
}

# ---------- Placa de video (VRAM real pelo registro, o WMI limita a 4 GB) ----------
Step 'Placa de video'
$vram = @{}
$classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
foreach ($k in @(Try-Get { Get-ChildItem $classKey })) {
    $p = Try-Get { Get-ItemProperty $k.PSPath }
    if ($p -and $p.DriverDesc -and $p.'HardwareInformation.qwMemorySize') { $vram[$p.DriverDesc] = [math]::Round([double]$p.'HardwareInformation.qwMemorySize' / 1GB, 1) }
}
$gpus = @()
$res = ''
foreach ($g in @(Try-Get { Get-CimInstance Win32_VideoController })) {
    if (-not $g -or $g.Name -match 'Microsoft Basic|Remote|Virtual|Meta|Parsec|DisplayLink|Citrix') { continue }
    $gb = $vram[$g.Name]
    if (-not $gb -and $g.AdapterRAM -gt 0) { $gb = [math]::Round($g.AdapterRAM / 1GB, 1) }
    $gpus += [ordered]@{ name = Tidy $g.Name; vram = $gb }
    if (-not $res -and $g.CurrentHorizontalResolution) { $res = "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)" }
}

# ---------- Tela (tamanho em polegadas pelo EDID, preferindo o painel interno) ----------
Step 'Tela'
$inches = $null
$conn = @(Try-Get { Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams })
$internal = @($conn | Where-Object { $_.VideoOutputTechnology -eq 2147483648 -or $_.VideoOutputTechnology -eq -2147483648 } | ForEach-Object { $_.InstanceName })
foreach ($m in @(Try-Get { Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams })) {
    if (-not $m -or -not $m.MaxHorizontalImageSize) { continue }
    $d = [math]::Round([math]::Sqrt([math]::Pow($m.MaxHorizontalImageSize, 2) + [math]::Pow($m.MaxVerticalImageSize, 2)) / 2.54, 1)
    if ($internal -contains $m.InstanceName) { $inches = $d; break }
    if (-not $inches) { $inches = $d }
}

# ---------- Dispositivos (uma unica leitura do Gerenciador de Dispositivos) ----------
Step 'Dispositivos'
$pnp = @(Try-Get { Get-CimInstance Win32_PnPEntity | Select-Object Name, PNPClass, Status, DeviceID })
function Pnp-Names([string]$classRx, [string]$nameRx) {
    @($pnp | Where-Object {
        $_.Name -and (($classRx -and "$($_.PNPClass)" -match $classRx) -or ($nameRx -and $_.Name -match $nameRx))
    } | ForEach-Object { Tidy $_.Name } | Select-Object -Unique)
}
$webcam    = Pnp-Names '^(Camera|Image)$' ''
$bio       = Pnp-Names '^Biometric$' 'fingerprint|impress.o digital'
$bt        = Pnp-Names '^Bluetooth$' ''
$nfc       = Pnp-Names '^Proximity$' '\bNFC\b'
$reader    = Pnp-Names '' 'card ?reader|SD Host|SD Card|MMC|Memory Stick'
$optical   = @(Try-Get { Get-CimInstance Win32_CDROMDrive } | ForEach-Object { Tidy $_.Name })
$touchpad  = Pnp-Names '' 'touch ?pad|precision touchpad|clickpad|trackpad'
$trackpt   = Pnp-Names '' 'TrackPoint|Pointing ?Stick|Point ?stick|UltraNav'
# ThinkPad: o TrackPoint vem junto com o touchpad como 'Synaptics/Elan Pointing Device' (ACPI\LEN2xxx)
if (-not $trackpt.Count -and "$($csp.Version)" -match 'ThinkPad') {
    $trackpt = @($pnp | Where-Object { "$($_.PNPClass)" -eq 'Mouse' -and "$($_.DeviceID)" -match '^ACPI\\LEN2' } | ForEach-Object { Tidy $_.Name })
}
$touchscr  = Pnp-Names '' 'touch ?screen|tela touch|tela sens.vel ao toque'
$mics      = Pnp-Names '' 'microphone|microfone|mic array|matriz de microfones'
$audio     = @(Try-Get { Get-CimInstance Win32_SoundDevice } | ForEach-Object { Tidy $_.Name } | Select-Object -Unique)

# ---------- Rede ----------
Step 'Rede'
$net = @()
$na = @(Try-Get { Get-NetAdapter -Physical })
if ($na.Count -and $na[0]) {
    foreach ($a in $na) {
        $kind = if ("$($a.PhysicalMediaType)" -match '802\.11' -or $a.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11') { 'wifi' }
                elseif ($a.InterfaceDescription -match 'Bluetooth') { 'bt' } else { 'eth' }
        if ($kind -ne 'bt') { $net += [ordered]@{ kind = $kind; name = Tidy $a.InterfaceDescription } }
    }
} else {
    foreach ($a in @(Try-Get { Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=True' })) {
        if (-not $a -or $a.Name -match 'Bluetooth|Virtual') { continue }
        $kind = if ($a.Name -match 'Wi-?Fi|Wireless|WLAN|802\.11') { 'wifi' } else { 'eth' }
        $net += [ordered]@{ kind = $kind; name = Tidy $a.Name }
    }
}

# ---------- Bateria ----------
Step 'Bateria'
$batt = [ordered]@{ present = $false }
$wb = Try-Get { Get-CimInstance Win32_Battery | Select-Object -First 1 }
if ($wb) {
    $batt.present = $true
    $design = Try-Get { (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData | Select-Object -First 1).DesignedCapacity }
    $full   = Try-Get { (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity | Select-Object -First 1).FullChargedCapacity }
    $cycles = Try-Get { (Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount | Select-Object -First 1).CycleCount }
    # sem administrador o WMI acima costuma falhar: usa o relatorio de bateria do Windows
    if (-not ($design -gt 0 -and $full -gt 0)) {
        $xmlPath = Join-Path $env:TEMP 'ycodex-battery.xml'
        powercfg /batteryreport /xml /output $xmlPath | Out-Null
        $bx = Try-Get { ([xml](Get-Content $xmlPath -Raw)).BatteryReport.Batteries.Battery | Select-Object -First 1 }
        Remove-Item $xmlPath -Force
        if ($bx) { $design = [double]$bx.DesignCapacity; $full = [double]$bx.FullChargeCapacity; if (-not $cycles) { $cycles = $bx.CycleCount } }
    }
    if ($design -gt 0 -and $full -gt 0) { $batt.health = [math]::Min(100, [math]::Round($full / $design * 100)) }
    if ($cycles) { $batt.cycles = [int]$cycles }
    $batt.charge = $wb.EstimatedChargeRemaining
}

# ---------- Teclado (layout configurado) ----------
$kbd = Try-Get { ((Get-WinUserLanguageList)[0].InputMethodTips[0] -split ':')[1] }

# ---------- Monta e envia ----------
Step 'Montando a ficha'
$data = [ordered]@{
    v        = 1
    platform = 'windows'
    ts       = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    os       = Tidy "$($os.Caption) (build $($os.BuildNumber))"
    brand    = Tidy $cs.Manufacturer
    model    = Tidy $cs.Model
    family   = Tidy $csp.Version          # Lenovo guarda o nome comercial aqui (ex.: ThinkPad T480)
    sku      = Tidy $cs.SystemSKUNumber
    serial   = Tidy $bios.SerialNumber
    asset    = Tidy $enc.SMBIOSAssetTag
    cpu      = [ordered]@{ name = Tidy $cpu.Name; mhz = $cpu.MaxClockSpeed; cores = $cpu.NumberOfCores; threads = $cpu.NumberOfLogicalProcessors }
    ram      = [ordered]@{ totalGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1); slots = $slots; modules = $modules }
    disks    = $disks
    gpus     = $gpus
    screen   = [ordered]@{ res = $res; inches = $inches; touch = ($touchscr.Count -gt 0) }
    webcam   = $webcam
    bio      = $bio
    reader   = @($reader + $optical)
    net      = $net
    audio    = $audio
    mic      = $mics
    battery  = $batt
    bt       = ($bt.Count -gt 0)
    nfc      = ($nfc.Count -gt 0)
    touchpad = $touchpad
    trackpoint = ($trackpt.Count -gt 0)
    keyboard = $kbd
}

$json = $data | ConvertTo-Json -Depth 6 -Compress
$code = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')

if ($ycNoOpen) { $json; return }

if (-not $ycSite) {
    Write-Host ''
    Write-Host '  Endereco do site nao informado. Copie o codigo abaixo e cole em "Importar codigo" na ficha:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host $code
    return
}

# abre o site por um arquivo HTML temporario: assim o link com os dados nunca e cortado
$target = ($ycSite -split '#')[0] + '#ficha=' + $code
$launcher = Join-Path $env:TEMP 'ycodex-ficha.html'
$html = '<!doctype html><meta charset="utf-8"><title>yCODEX</title><script>location.replace(' + ($target | ConvertTo-Json) + ')</script>'
[IO.File]::WriteAllText($launcher, $html, (New-Object Text.UTF8Encoding $false))
Start-Process $launcher

Write-Host ''
Write-Host '  Pronto! A ficha foi aberta no navegador.' -ForegroundColor Green
Write-Host ''
