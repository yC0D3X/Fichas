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

# =====================================================================
#  Impressao na rede, sem instalar impressora
#  O Windows so imprime em impressora instalada. Para nao instalar nada, esta janela vira uma ponte:
#  o botao "Imprimir na rede" da ficha manda a folha para http://127.0.0.1:8631 (so esta maquina
#  enxerga), o Edge que ja vem no Windows transforma em PDF (ou imagem) e o script entrega direto na
#  impressora pela rede, por IPP (porta 631) - o mesmo protocolo do AirPrint e do Mopria.
#  Serve para qualquer impressora de rede: a pagina lista as que responderem, pelo nome delas.
#  Opcoes (antes do comando):  $ycPrinter='10.16.0.50'   (inclui este IP, ex.: impressora em outra faixa de rede)
#                              $ycPrinterMatch='M3170'    (ja deixa marcada a impressora com este nome/modelo)
#                              $ycNoPrint=1               (nao abre a ponte)
# =====================================================================
if ($ycNoPrint) { return }
$ycPort = 8631
$ycList = $null
[Net.ServicePointManager]::Expect100Continue = $false
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Add16($l, [int]$x) { $l.Add([byte](($x -shr 8) -band 255)); $l.Add([byte]($x -band 255)) }
function Add32($l, [int]$x) { Add16 $l (($x -shr 16) -band 65535); Add16 $l ($x -band 65535) }

# grupo de atributos IPP: nome -> @(tag do valor, valor ou lista de valores)
function Add-Attrs($l, [byte]$group, $attrs) {
    if (-not $attrs -or -not $attrs.Count) { return }
    $l.Add($group)
    foreach ($k in $attrs.Keys) {
        $first = $true
        foreach ($v in @($attrs[$k][1])) {
            $l.Add([byte]$attrs[$k][0])
            if ($first) { $nb = [Text.Encoding]::ASCII.GetBytes($k); Add16 $l $nb.Length; $l.AddRange($nb) } else { Add16 $l 0 }
            if ($v -is [int]) { Add16 $l 4; Add32 $l $v }
            else { $vb = [Text.Encoding]::UTF8.GetBytes([string]$v); Add16 $l $vb.Length; $l.AddRange($vb) }
            $first = $false
        }
    }
}

function Ipp-Parse([byte[]]$r) {
    $o = @{ status = [int]$r[2] * 256 + $r[3] }
    $i = 8; $last = $null
    while ($i -lt $r.Length) {
        $tag = $r[$i]; $i++
        if ($tag -eq 3) { break }
        if ($tag -lt 0x10) { continue }
        # resposta cortada: fica com o que ja leu
        if ($i + 2 -gt $r.Length) { break }
        $nl = [int]$r[$i] * 256 + $r[$i + 1]; $i += 2
        if ($i + $nl + 2 -gt $r.Length) { break }
        $name = [Text.Encoding]::ASCII.GetString($r, $i, $nl); $i += $nl
        $vl = [int]$r[$i] * 256 + $r[$i + 1]; $i += 2
        if ($i + $vl -gt $r.Length) { break }
        # resolucao (0x32) vem em binario: 4 bytes x, 4 bytes y, 1 byte unidade -> "300x300"
        $val = if ($tag -eq 0x32 -and $vl -eq 9) { '{0}x{1}' -f ([BitConverter]::ToInt32(@($r[($i + 3)..$i]), 0)), ([BitConverter]::ToInt32(@($r[($i + 7)..($i + 4)]), 0)) }
               else { [Text.Encoding]::UTF8.GetString($r, $i, $vl) }
        $i += $vl
        if ($nl) { $last = $name; if (-not $o.ContainsKey($name)) { $o[$name] = @() } }
        if ($last) { $o[$last] += $val }
    }
    $o
}

# $url = "http://IP:631" ou "https://IP:443" (IPP seguro: o certificado da impressora e sempre autoassinado)
function Ipp-Call([string]$url, [string]$path, [int]$op, $opAttrs, $jobAttrs, [byte[]]$doc, [int]$timeout) {
    $l = New-Object 'Collections.Generic.List[byte]'
    $l.Add(2); $l.Add(0); Add16 $l $op; Add32 $l 1
    $base = [ordered]@{
        'attributes-charset'          = @(0x47, 'utf-8')
        'attributes-natural-language' = @(0x48, 'en')
        'printer-uri'                 = @(0x45, (($url -replace '^http', 'ipp') + $path))
        'requesting-user-name'        = @(0x42, 'ycodex')
    }
    if ($opAttrs) { foreach ($k in $opAttrs.Keys) { $base[$k] = $opAttrs[$k] } }
    Add-Attrs $l 1 $base
    Add-Attrs $l 2 $jobAttrs
    $l.Add(3)
    if ($doc) { $l.AddRange($doc) }
    $body = $l.ToArray()
    $rq = [Net.HttpWebRequest]::Create("$url$path")
    $rq.Method = 'POST'; $rq.ContentType = 'application/ipp'; $rq.Timeout = $timeout; $rq.ReadWriteTimeout = $timeout
    $rq.Proxy = $null   # impressora e local: proxy da empresa so atrapalha
    $rq.KeepAlive = $false   # servidor embutido de impressora costuma se perder com conexao reaproveitada
    if ($url -like 'https*') { Load-Cs; $rq.ServerCertificateValidationCallback = [YcTls]::Any }
    $rq.ContentLength = $body.Length
    $s = $rq.GetRequestStream(); $s.Write($body, 0, $body.Length); $s.Close()
    $rs = $rq.GetResponse(); $ms = New-Object IO.MemoryStream; $rs.GetResponseStream().CopyTo($ms); $rs.Close()
    Ipp-Parse $ms.ToArray()
}

# pergunta para a impressora quem ela e (nome, modelo, local) e quais formatos aceita
# formatos que o script sabe gerar, na ordem de preferencia (raster = Mopria/IPP Everywhere e AirPrint)
$ycFormats = 'application/pdf', 'image/pwg-raster', 'image/urf', 'image/jpeg'
$ycWhy = @{}

function Printer-Info([string]$ip, [bool]$http = $true) {
    $want = @('printer-name', 'printer-info', 'printer-location', 'printer-make-and-model', 'document-format-supported',
              'pwg-raster-document-resolution-supported', 'pwg-raster-document-type-supported', 'urf-supported')
    # 631 sem e com criptografia (muitas impressoras exigem ipps na propria 631), depois 443 e 80
    $urls = @(); if ($http) { $urls += "http://${ip}:631", "https://${ip}:631" }; $urls += "https://${ip}:443", "http://${ip}:80"
    $why = @()
    foreach ($url in $urls) {
        $retry = $true; $lab = $url -replace '://[^:]+:', ':'   # "http:631"
        foreach ($path in '/ipp/print', '/ipp', '/ipp/printer', '/') {
            $a = $null
            try { $a = Ipp-Call $url $path 0x000B ([ordered]@{ 'requested-attributes' = @(0x44, $want) }) $null $null 8000 }
            catch {
                # motivo curto: codigo HTTP, falha de rede (Timeout, ConnectFailure, TrustFailure...) ou erro ao ler a resposta
                $e = $_.Exception; while ($e.InnerException -and $e -isnot [Net.WebException]) { $e = $e.InnerException }
                $st = if ($e -is [Net.WebException]) { if ($e.Response) { "HTTP $([int]$e.Response.StatusCode)" } else { "$($e.Status)" } } else { "erro: $($e.Message)" }
                $why += "$lab$path=$st"
                # impressora em Wi-Fi acordando: tenta o mesmo caminho mais uma vez
                if ($st -eq 'Timeout' -and $retry) {
                    $retry = $false
                    try { $a = Ipp-Call $url $path 0x000B ([ordered]@{ 'requested-attributes' = @(0x44, $want) }) $null $null 8000 } catch { }
                }
                # porta fechada / sem resposta / TLS recusado: nao adianta tentar outros caminhos nela
                if (-not $a -and $st -match '^(Timeout|ConnectFailure|ConnectionClosed|ReceiveFailure|SendFailure|SecureChannelFailure|TrustFailure)$') { break }
                if (-not $a) { continue }
            }
            if (-not $a -or $a.status -ge 0x100) { $why += "$lab$path=IPP 0x{0:x4}" -f $a.status; continue }
            $model = Tidy "$($a['printer-make-and-model'])"
            # printer-info costuma ser o nome amigavel ("EPSON ET-M3170 Series"); printer-name as vezes e um codigo
            $name = Tidy "$($a['printer-info'])"
            if (-not $name) { $name = Tidy "$($a['printer-name'])" }
            if (-not $name) { $name = $model }
            if (-not $name) { $name = $ip }
            $formats = @($a['document-format-supported'])
            return [pscustomobject]@{
                ip = $ip; url = $url; path = $path; name = $name; model = $model; location = Tidy "$($a['printer-location'])"
                formats = $formats; ok = [bool](@($ycFormats | Where-Object { $formats -contains $_ }).Count)
                pwgRes = @($a['pwg-raster-document-resolution-supported']); pwgTypes = @($a['pwg-raster-document-type-supported'])
                urf = @($a['urf-supported'])
            }
        }
    }
    $script:ycWhy[$ip] = $why -join '  '
}

function To-IPv4([string]$h) {
    if (-not $h) { return }
    if ($h -match '^\d{1,3}(\.\d{1,3}){3}$') { return $h }
    Try-Get { [Net.Dns]::GetHostAddresses($h) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString } | Select-Object -First 1 }
}

# impressoras fisicas ja instaladas no Windows (tira PDF, XPS, OneNote, fax), com o IP quando der para saber
function Installed-Printers {
    # WSD (ex.: "EPSONA9C00A (M3170 Series)"): o endereco fica no LocationInformation do dispositivo
    $wsd = @{}
    foreach ($k in @(Try-Get { Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\SWD\DAFWSDProvider' -ErrorAction SilentlyContinue })) {
        $v = Try-Get { Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue }
        if ("$($v.LocationInformation)" -match '//(\d{1,3}(\.\d{1,3}){3})') { $wsd["$($v.FriendlyName)"] = $Matches[1] }
    }
    $ports = @{}
    foreach ($p in @(Try-Get { Get-PrinterPort })) { if ($p.PrinterHostAddress) { $ports[$p.Name] = $p.PrinterHostAddress } }
    foreach ($p in @(Try-Get { Get-Printer })) {
        if ("$($p.DriverName) $($p.PortName) $($p.Name)" -match 'PDF|XPS|OneNote|Fax|PORTPROMPT|^nul:|FILE:') { continue }
        $ip = $null
        if ($ports[$p.PortName]) { $ip = To-IPv4 $ports[$p.PortName] }
        elseif ($wsd[$p.Name]) { $ip = $wsd[$p.Name] }
        elseif ($p.PortName -match '^IP_(\d{1,3}(\.\d{1,3}){3})') { $ip = $Matches[1] }
        [pscustomobject]@{ name = $p.Name; driver = $p.DriverName; ip = $ip }
    }
    # WSD sem impressora com o mesmo nome: o IP ainda serve para procurar por IPP
    foreach ($n in $wsd.Keys) { [pscustomobject]@{ name = $null; driver = $null; ip = $wsd[$n] } }
}

function Ip-Num([string]$ip) { $b = ([Net.IPAddress]$ip).GetAddressBytes(); [uint32]$b[0] * 16777216 + [uint32]$b[1] * 65536 + [uint32]$b[2] * 256 + $b[3] }
function Num-Ip([uint32]$n) { '{0}.{1}.{2}.{3}' -f ($n -shr 24), (($n -shr 16) -band 255), (($n -shr 8) -band 255), ($n -band 255) }

# IPs de todas as faixas de rede desta maquina (faixa maior que /22 fica so na /22 em volta do IP)
function Lan-Hosts {
    $mine = @(); $all = @()
    foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169\.254)\.' -and $_.PrefixLength -le 30 })) {
        $mine += $a.IPAddress
        $pl = [Math]::Max([int]$a.PrefixLength, 22)
        $mask = [uint32]([Math]::Pow(2, 32) - [Math]::Pow(2, 32 - $pl))
        $net = (Ip-Num $a.IPAddress) -band $mask
        for ($n = $net + 1; $n -lt $net + [Math]::Pow(2, 32 - $pl) - 1; $n++) { $all += Num-Ip $n }
    }
    @($all | Select-Object -Unique | Where-Object { $mine -notcontains $_ })
}

# WS-Discovery: o mesmo "quem e impressora ai?" que o Windows grita na rede (acha as WSD, ex.: EPSONA9C00A)
function Wsd-Probe {
    $xml = '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:wprt="http://schemas.microsoft.com/windows/2006/08/wdp/print"><soap:Header><wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To><wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action><wsa:MessageID>urn:uuid:' + [guid]::NewGuid() + '</wsa:MessageID></soap:Header><soap:Body><wsd:Probe><wsd:Types>wprt:PrintDeviceType</wsd:Types></wsd:Probe></soap:Body></soap:Envelope>'
    $b = [Text.Encoding]::UTF8.GetBytes($xml)
    $dst = New-Object Net.IPEndPoint ([Net.IPAddress]::Parse('239.255.255.250'), 3702)
    # um socket por placa, senao o multicast so sai pela placa padrao
    foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169\.254)\.' })) {
        $u = Try-Get { New-Object Net.Sockets.UdpClient (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($a.IPAddress), 0)) }
        if ($u) { [void](Try-Get { $u.Send($b, $b.Length, $dst) }); $u }
    }
}

function Wsd-Read($socks) {
    foreach ($u in $socks) {
        while ($u.Available -gt 0) {
            $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any, 0)
            $d = Try-Get { $u.Receive([ref]$ep) }
            if (-not $d) { break }
            $t = [Text.Encoding]::UTF8.GetString($d)
            if ($t -notmatch 'ProbeMatch') { continue }
            [regex]::Matches($t, 'https?://(\d{1,3}(\.\d{1,3}){3})') | ForEach-Object { $_.Groups[1].Value }
            $ep.Address.ToString()
        }
    }
}

# nome do aparelho por SNMP (hrDeviceDescr.1, comunidade public) - serve para quem nao fala IPP
function Snmp-Names([string[]]$ips) {
    $names = @{}
    if (-not $ips) { return $names }
    $oid = [byte[]](0x06, 0x0b, 0x2b, 6, 1, 2, 1, 0x19, 3, 2, 1, 3, 1)
    $pkt = [byte[]](0x30, 0x29, 2, 1, 0, 4, 6) + [Text.Encoding]::ASCII.GetBytes('public') +
           [byte[]](0xa0, 0x1c, 2, 1, 1, 2, 1, 0, 2, 1, 0, 0x30, 0x11, 0x30, 0x0f) + $oid + [byte[]](5, 0)
    $pkt = [byte[]]$pkt
    $u = New-Object Net.Sockets.UdpClient 0
    # sem isso, um "porta fechada" (ICMP) de um IP derruba a leitura dos outros
    [void](Try-Get { $u.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null) })
    foreach ($ip in $ips) { [void](Try-Get { $u.Send($pkt, $pkt.Length, $ip, 161) }) }
    $end = (Get-Date).AddMilliseconds(1500)
    while ((Get-Date) -lt $end -and $names.Count -lt $ips.Count) {
        if ($u.Available -le 0) { Start-Sleep -Milliseconds 50; continue }
        $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any, 0)
        $d = Try-Get { $u.Receive([ref]$ep) }
        if (-not $d) { continue }
        # acha o OID na resposta e le o texto (OCTET STRING) logo depois
        for ($i = 0; $i -le $d.Length - $oid.Length - 2; $i++) {
            $hit = $true
            for ($j = 0; $j -lt $oid.Length; $j++) { if ($d[$i + $j] -ne $oid[$j]) { $hit = $false; break } }
            if (-not $hit) { continue }
            $k = $i + $oid.Length
            if ($d[$k] -ne 4) { break }
            $len = [int]$d[$k + 1]; $k += 2
            if ($len -band 0x80) { $nb = $len -band 0x7f; $len = 0; for ($j = 0; $j -lt $nb; $j++) { $len = $len * 256 + $d[$k + $j] }; $k += $nb }
            $s = Tidy ([Text.Encoding]::UTF8.GetString($d, $k, [Math]::Min($len, $d.Length - $k)))
            if ($s) { $names[$ep.Address.ToString()] = $s }
            break
        }
    }
    $u.Close()
    $names
}

# procura toda e qualquer impressora na rede desta maquina:
#  - varre a faixa inteira nas portas de impressora: 631 (IPP), 9100 (RAW/JetDirect) e 515 (LPD)
#  - pergunta por WS-Discovery (impressoras WSD respondem mesmo com a varredura bloqueada)
#  - soma as impressoras ja instaladas no Windows (podem estar em outra faixa)
# Quem aceita IPP recebe PDF/imagem; quem so tem a 9100 recebe a ficha em PCL; o resto vai pela fila do Windows.
function Find-Printers {
    $inst = @(Installed-Printers)
    $hosts = Lan-Hosts
    $wsd = @(Wsd-Probe)
    $socks = New-Object Collections.ArrayList
    foreach ($port in 631, 9100, 515) {
        foreach ($ip in $hosts) {
            $c = New-Object Net.Sockets.TcpClient
            [void]$socks.Add([pscustomobject]@{ ip = $ip; port = $port; c = $c; t = $c.ConnectAsync($ip, $port) })
        }
    }
    # impressora em Wi-Fi as vezes demora para acordar
    $found = @()
    $end = (Get-Date).AddMilliseconds(3000)
    while ((Get-Date) -lt $end) {
        $found += @(Wsd-Read $wsd)
        if (-not @($socks | Where-Object { -not $_.t.IsCompleted }).Count) { break }
        Start-Sleep -Milliseconds 100
    }
    $found += @(Wsd-Read $wsd)
    foreach ($u in $wsd) { $u.Close() }
    $ports = @{}
    foreach ($s in $socks) {
        if ($s.t.Status -eq 'RanToCompletion') { $ports[$s.ip] = @(@($ports[$s.ip] | Where-Object { $_ }) + $s.port) }
        $s.c.Close()
    }
    # quem esta fora da faixa varrida (WSD, instalada, $ycPrinter): testa as portas so dele
    $extra = @(@($ycPrinter) + $found + @($inst | ForEach-Object { $_.ip }) | Where-Object { $_ -and $hosts -notcontains $_ } | Select-Object -Unique)
    foreach ($ip in $extra) {
        $ports[$ip] = @(foreach ($port in 631, 9100) {
            $c = New-Object Net.Sockets.TcpClient
            if ((Try-Get { $c.ConnectAsync($ip, $port).Wait(1500) }) -and $c.Connected) { $port }
            $c.Close()
        })
    }
    $cands = @($ports.Keys | Where-Object { @($ports[$_]).Count -or $found -contains $_ })
    $snmp = Snmp-Names $cands
    $net = @(foreach ($ip in $cands) {
        $p = @($ports[$ip])
        $i = Printer-Info $ip ($p -contains 631 -or -not $p.Count)
        # diagnostico: o que cada aparelho respondeu
        $diag = "    $ip  portas: $(if ($p.Count) { $p -join ',' } else { '-' })"
        if ($snmp[$ip]) { $diag += "  snmp: $($snmp[$ip])" }
        if ($i) { $diag += "  IPP ($($i.url)$($i.path)): $($i.formats -join ' ')" } elseif ($ycWhy[$ip]) { $diag += "  IPP falhou: $($ycWhy[$ip])" }
        Write-Host $diag -ForegroundColor DarkGray
        # IPP respondeu: e por ele (mesmo que nao aceite nada, nao manda nada as cegas na 9100)
        if ($i) { if ($i.name -eq $ip -and $snmp[$ip]) { $i.name = $snmp[$ip] }; $i; continue }
        # sem IPP, a 9100 recebe PCL - linguagem de laser. Jato de tinta (Epson, Canon...) imprimiria os comandos como texto
        $n = if ($snmp[$ip]) { $snmp[$ip] } else { "Impressora $ip" }
        if ($p -contains 9100 -and $n -notmatch 'epson|canon|ecotank|inkjet|deskjet|officejet|pixma|stylus') {
            [pscustomobject]@{ ip = $ip; path = $null; name = $n; model = ''; location = 'porta 9100 (PCL)'; formats = @(); ok = $true; raw = $true }
        } elseif ($snmp[$ip] -or $p.Count) {
            # e impressora, mas nao deu para conversar: aparece na lista (desabilitada) com o motivo
            [pscustomobject]@{ ip = $ip; path = $null; name = $n; model = ''; location = "IPP n$([char]0xe3)o respondeu"; formats = @(); ok = $false; why = $ycWhy[$ip] }
        }
    })
    $net
    # o que a rede nao achou, imprime pela fila do Windows
    foreach ($p in $inst) {
        if (-not $p.name -or ($p.ip -and @($net | Where-Object { $_ -and $_.ip -eq $p.ip }).Count)) { continue }
        [pscustomobject]@{
            ip = "win:$($p.name)"; path = $null; name = $p.name; model = $p.driver
            location = $(if ($p.ip) { "$($p.ip) - pelo Windows" } else { 'instalada no Windows' })
            formats = @(); ok = $true; win = $true
        }
    }
}

# lista de impressoras da rede (guardada; $fresh = procura de novo)
function Get-Printers([bool]$fresh) {
    if ($fresh -or $null -eq $script:ycList) { $script:ycList = @(Find-Printers | Where-Object { $_ } | Sort-Object name) }
    $script:ycList
}

function Find-Browser {
    foreach ($p in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
                     "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                     "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")) { if ($p -and (Test-Path $p)) { return $p } }
}

# o Edge (sem janela) desenha a ficha: PDF igual ao Ctrl+P, ou uma imagem A4 em 300 dpi
function Render([string]$html, [bool]$pdf, [bool]$land) {
    $browser = Find-Browser
    if (-not $browser) { throw 'navegador' }
    $dir = Join-Path $env:TEMP 'ycodex-print'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $in = Join-Path $dir 'ficha.html'
    $out = Join-Path $dir $(if ($pdf) { 'ficha.pdf' } else { 'ficha.png' })
    Remove-Item $out -Force
    if (-not $pdf) {
        $css = '<style>html,body{background:#fff!important;margin:0!important;padding:0!important}.sheet{margin:0!important;box-shadow:none!important}</style>'
        $html = $html -replace '</head>', ($css + '</head>')
    }
    [IO.File]::WriteAllText($in, $html, (New-Object Text.UTF8Encoding $false))
    $a = @('--headless', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--hide-scrollbars', "--user-data-dir=`"$dir\perfil`"")
    if ($pdf) { $a += @('--no-pdf-header-footer', '--print-to-pdf-no-header', "--print-to-pdf=`"$out`"") }
    else { $a += @($(if ($land) { '--window-size=1123,794' } else { '--window-size=794,1123' }), '--force-device-scale-factor=3.125', "--screenshot=`"$out`"") }
    $a += ([Uri]$in).AbsoluteUri
    $proc = Start-Process $browser -ArgumentList $a -PassThru -WindowStyle Hidden
    $null = $proc.WaitForExit(45000)
    if (-not (Test-Path $out)) { throw 'navegador' }
    if ($pdf) { return , [IO.File]::ReadAllBytes($out) }
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object Drawing.Bitmap $out
    $bmp.SetResolution(300, 300)
    $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
    $ep = New-Object Drawing.Imaging.EncoderParameters 1
    $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality, [long]92)
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, $enc, $ep); $bmp.Dispose()
    , $ms.ToArray()
}

# impressora instalada no Windows: desenha a imagem A4 da ficha e manda pela fila dela, sem dialogo
function Print-Windows([string]$printer, [byte[]]$jpg, [bool]$land) {
    Add-Type -AssemblyName System.Drawing
    $ms = New-Object IO.MemoryStream (, $jpg)
    $script:ycImg = [Drawing.Image]::FromStream($ms)
    $pd = New-Object Drawing.Printing.PrintDocument
    try {
        $pd.PrinterSettings.PrinterName = $printer
        if (-not $pd.PrinterSettings.IsValid) { throw "impressora '$printer' nao encontrada no Windows" }
        $pd.DocumentName = 'Ficha Tecnica'
        $pd.PrintController = New-Object Drawing.Printing.StandardPrintController
        $pd.DefaultPageSettings.Landscape = $land
        $a4 = $pd.PrinterSettings.PaperSizes | Where-Object { $_.Kind -eq 'A4' } | Select-Object -First 1
        if ($a4) { $pd.DefaultPageSettings.PaperSize = $a4 }
        $pd.add_PrintPage({
            param($s, $e)
            # origem ja fica na area imprimivel; encaixa a folha nela sem distorcer
            $w = $e.PageBounds.Width - 2 * $e.PageSettings.HardMarginX
            $h = $e.PageBounds.Height - 2 * $e.PageSettings.HardMarginY
            $img = $script:ycImg
            $k = [Math]::Min($w / $img.Width, $h / $img.Height)
            $dw = $img.Width * $k; $dh = $img.Height * $k
            $e.Graphics.InterpolationMode = 'HighQualityBicubic'
            $e.Graphics.DrawImage($img, [float](($w - $dw) / 2), [float](($h - $dh) / 2), [float]$dw, [float]$dh)
            $e.HasMorePages = $false
        })
        $pd.Print()
    } finally { $pd.Dispose(); $script:ycImg.Dispose(); $ms.Dispose() }
}

# impressora so com a porta 9100: a imagem da ficha vira PCL (preto e branco, 300 dpi, meio-tom pontilhado)
$ycPcl = @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.IO; using System.Text;
public static class YcPcl {
    static void W(Stream o, string s) { byte[] b = Encoding.ASCII.GetBytes(s); o.Write(b, 0, b.Length); }
    public static byte[] Make(byte[] img, bool land) {
        using (MemoryStream ms = new MemoryStream(img)) using (Bitmap src = new Bitmap(ms)) {
            if (land) src.RotateFlip(RotateFlipType.Rotate90FlipNone);
            // area que cabe na folha A4 de qualquer impressora (margem ~5 mm)
            int w = 2304, h = 3300;
            double k = Math.Min((double)w / src.Width, (double)h / src.Height);
            int dw = (int)(src.Width * k), dh = (int)(src.Height * k);
            using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb)) {
                using (Graphics g = Graphics.FromImage(bmp)) {
                    g.Clear(Color.White);
                    g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    g.DrawImage(src, (w - dw) / 2, 0, dw, dh);
                }
                BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
                byte[] px = new byte[d.Stride * h];
                System.Runtime.InteropServices.Marshal.Copy(d.Scan0, px, 0, px.Length);
                int stride = d.Stride;
                bmp.UnlockBits(d);
                int[] bayer = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
                MemoryStream o = new MemoryStream();
                W(o, "\u001b%-12345X@PJL JOB NAME=\"Ficha Tecnica\"\r\n@PJL ENTER LANGUAGE=PCL\r\n");
                W(o, "\u001bE\u001b&l26A\u001b&l0O\u001b&l0E\u001b*t300R\u001b*p0x60Y\u001b*r0F\u001b*r" + w + "S\u001b*r1A\u001b*b0M");
                int rb = w / 8; byte[] row = new byte[rb];
                for (int y = 0; y < h; y++) {
                    Array.Clear(row, 0, rb);
                    int off = y * stride;
                    for (int x = 0; x < w; x++) {
                        int i = off + x * 3;
                        int lum = (px[i] * 29 + px[i + 1] * 150 + px[i + 2] * 77) >> 8;
                        if (lum < bayer[(y & 3) * 4 + (x & 3)] * 16 + 8) row[x >> 3] |= (byte)(0x80 >> (x & 7));
                    }
                    int n = rb; while (n > 0 && row[n - 1] == 0) n--;
                    W(o, "\u001b*b" + n + "W"); o.Write(row, 0, n);
                }
                W(o, "\u001b*rC\u001bE\u001b%-12345X@PJL EOJ\r\n\u001b%-12345X");
                return o.ToArray();
            }
        }
    }
}

// IPP seguro (porta 443): o certificado da impressora e autoassinado, aceita qualquer um (so rede local)
public static class YcTls {
    static bool Ok(object s, System.Security.Cryptography.X509Certificates.X509Certificate c,
                   System.Security.Cryptography.X509Certificates.X509Chain ch, System.Net.Security.SslPolicyErrors e) { return true; }
    public static readonly System.Net.Security.RemoteCertificateValidationCallback Any = Ok;
}

// PWG-raster (Mopria / IPP Everywhere) e URF (AirPrint): pagina A4 inteira em pixels, que qualquer
// impressora com esses selos imprime sem driver. Mesma compressao nos dois: linhas repetidas + PackBits.
public static class YcRaster {
    static void Be(byte[] b, int at, int v) { b[at] = (byte)(v >> 24); b[at + 1] = (byte)(v >> 16); b[at + 2] = (byte)(v >> 8); b[at + 3] = (byte)v; }
    static void Str(byte[] b, int at, string s) { byte[] t = Encoding.ASCII.GetBytes(s); Array.Copy(t, 0, b, at, t.Length); }
    static bool Same(byte[] l, int a, int b, int bpp) { for (int k = 0; k < bpp; k++) if (l[a * bpp + k] != l[b * bpp + k]) return false; return true; }

    public static byte[] Make(byte[] img, bool land, bool urf, int res, bool gray) {
        int w = (int)Math.Round(210 / 25.4 * res), h = (int)Math.Round(297 / 25.4 * res), bpp = gray ? 1 : 3;
        byte[] px; int stride;
        using (MemoryStream ms = new MemoryStream(img)) using (Bitmap src = new Bitmap(ms)) using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb)) {
            if (land) src.RotateFlip(RotateFlipType.Rotate90FlipNone);
            using (Graphics g = Graphics.FromImage(bmp)) {
                g.Clear(Color.White);
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                double k = Math.Min((double)w / src.Width, (double)h / src.Height);
                int dw = (int)(src.Width * k), dh = (int)(src.Height * k);
                g.DrawImage(src, (w - dw) / 2, (h - dh) / 2, dw, dh);
            }
            BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            stride = d.Stride; px = new byte[stride * h];
            System.Runtime.InteropServices.Marshal.Copy(d.Scan0, px, 0, px.Length);
            bmp.UnlockBits(d);
        }
        MemoryStream o = new MemoryStream();
        if (urf) {
            byte[] f = new byte[12]; Str(f, 0, "UNIRAST"); Be(f, 8, 1); o.Write(f, 0, 12);
            byte[] hd = new byte[32];
            hd[0] = (byte)(bpp * 8); hd[1] = (byte)(gray ? 0 : 1); hd[2] = 1; hd[3] = 4;   // bits, sGray/sRGB, simplex, normal
            Be(hd, 12, w); Be(hd, 16, h); Be(hd, 20, res);
            o.Write(hd, 0, 32);
        } else {
            o.Write(Encoding.ASCII.GetBytes("RaS2"), 0, 4);
            byte[] hd = new byte[1796];
            Str(hd, 0, "PwgRaster");
            Be(hd, 276, res); Be(hd, 280, res);           // HWResolution
            Be(hd, 340, 1);                                 // NumCopies
            Be(hd, 352, 595); Be(hd, 356, 842);             // PageSize em pontos (A4)
            Be(hd, 372, w); Be(hd, 376, h);                 // largura/altura em pixels
            Be(hd, 384, 8); Be(hd, 388, bpp * 8); Be(hd, 392, w * bpp);
            Be(hd, 400, gray ? 18 : 19);                    // sGray / sRGB
            Be(hd, 420, bpp);                               // NumColors
            Be(hd, 452, 1); Be(hd, 456, 1); Be(hd, 460, 1); // TotalPageCount, CrossFeed/FeedTransform
            Be(hd, 472, w); Be(hd, 476, h);                 // ImageBox
            Be(hd, 480, 0xffffff);                          // AlternatePrimary
            Str(hd, 1732, "iso_a4_210x297mm");
            o.Write(hd, 0, hd.Length);
        }
        byte[] prev = null, line = new byte[w * bpp];
        int rep = 0;
        for (int y = 0; y <= h; y++) {
            byte[] cur = null;
            if (y < h) {
                cur = new byte[w * bpp]; int off = y * stride;
                for (int x = 0; x < w; x++) {
                    int i = off + x * 3;   // Bitmap guarda BGR
                    if (gray) cur[x] = (byte)((px[i] * 29 + px[i + 1] * 150 + px[i + 2] * 77) >> 8);
                    else { cur[x * 3] = px[i + 2]; cur[x * 3 + 1] = px[i + 1]; cur[x * 3 + 2] = px[i]; }
                }
                if (prev != null && rep < 255 && System.Linq.Enumerable.SequenceEqual(cur, prev)) { rep++; continue; }
            }
            if (prev != null) {
                o.WriteByte((byte)rep);
                // ate onde a linha tem algo que nao e branco; o resto vira um 0x80 ("preenche de branco")
                int end = w; while (end > 0) { bool white = true; for (int k = 0; k < bpp; k++) if (prev[(end - 1) * bpp + k] != 255) white = false; if (!white) break; end--; }
                int x = 0;
                while (x < end) {
                    int run = 1; while (x + run < end && run < 128 && Same(prev, x, x + run, bpp)) run++;
                    if (run > 1) { o.WriteByte((byte)(run - 1)); o.Write(prev, x * bpp, bpp); x += run; continue; }
                    int start = x, cnt = 1; x++;
                    while (x < end && cnt < 128 && !(x + 1 < end && Same(prev, x, x + 1, bpp))) { cnt++; x++; }
                    o.WriteByte((byte)(cnt == 1 ? 0 : 257 - cnt)); o.Write(prev, start * bpp, cnt * bpp);
                }
                if (end < w) o.WriteByte(0x80);
            }
            prev = cur; rep = 0;
        }
        return o.ToArray();
    }
}
'@

function Load-Cs {
    if ('YcPcl' -as [type]) { return }
    Add-Type -AssemblyName System.Drawing
    $refs = if ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7: usar um Bitmap carrega as partes do GDI+, que tambem precisam ser referenciadas
        (New-Object Drawing.Bitmap 1, 1).Dispose()
        @('System.Drawing', 'System.Drawing.Primitives', 'System.Drawing.Common', 'System.Linq', 'System.Net.Security', 'System.Net.Primitives',
          'System.Security.Cryptography.X509Certificates', 'System.Security.Cryptography') +
        @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.Location -and $_.GetName().Name -match '^System\.Private\.Windows' } | ForEach-Object { $_.Location })
    } else { 'System.Drawing', 'System.Core' }
    Add-Type -TypeDefinition $ycPcl -ReferencedAssemblies $refs -ErrorAction Stop
}

function Send-Raw([string]$ip, [byte[]]$jpg, [bool]$land) {
    Load-Cs
    $data = [YcPcl]::Make($jpg, $land)
    $c = New-Object Net.Sockets.TcpClient
    try {
        $c.SendTimeout = 60000
        if (-not $c.ConnectAsync($ip, 9100).Wait(5000)) { throw "a impressora $ip nao atendeu na porta 9100" }
        $s = $c.GetStream(); $s.Write($data, 0, $data.Length); $s.Flush()
    } finally { $c.Close() }
}

function Send-Ficha([string]$html, [bool]$land, [string]$ip) {
    # so imprime numa impressora que a busca encontrou (a pagina nao escolhe um IP qualquer)
    $t = Get-Printers $false | Where-Object { $_.ip -eq $ip } | Select-Object -First 1
    if (-not $t) { return @{ ok = $false; code = 'sem-impressora'; detail = $ip } }
    if ($t.win) {
        Print-Windows $t.name (Render $html $false $land) $land
        Write-Host ("  Ficha enviada para {0} (pelo Windows)" -f $t.name) -ForegroundColor Green
        return @{ ok = $true; detail = $t.name }
    }
    if ($t.raw) {
        Send-Raw $t.ip (Render $html $false $land) $land
        Write-Host ("  Ficha enviada para {0} ({1}, porta 9100)" -f $t.name, $t.ip) -ForegroundColor Green
        return @{ ok = $true; detail = $t.name }
    }
    if (-not $t.ok) { return @{ ok = $false; code = 'formato'; detail = "$($t.name): $($t.formats -join ', ')" } }
    $fmt = $ycFormats | Where-Object { $t.formats -contains $_ } | Select-Object -First 1
    $job = [ordered]@{ 'media' = @(0x44, 'iso_a4_210x297mm') }
    if ($fmt -eq 'application/pdf') { $doc = Render $html $true $land }
    elseif ($fmt -eq 'image/jpeg') {
        $doc = Render $html $false $land
        $job['print-scaling'] = @(0x44, 'fit'); $job['orientation-requested'] = @(0x23, $(if ($land) { 4 } else { 3 }))
    } else {
        # raster: escolhe resolucao (300 dpi se tiver, senao a menor oferecida) e cor (sRGB se tiver, senao cinza)
        $urf = $fmt -eq 'image/urf'
        if ($urf) {
            $rs = @(($t.urf | Where-Object { $_ -match '^RS' }) -replace '^RS' -split '-' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
            $gray = -not ($t.urf -match '^SRGB24$')
        } else {
            $rs = @($t.pwgRes | ForEach-Object { [int](($_ -split 'x')[0]) })
            $gray = $t.pwgTypes -notcontains 'srgb_8'
        }
        $res = if ($rs -contains 300) { 300 } elseif ($rs.Count) { ($rs | Sort-Object)[0] } else { 300 }
        Load-Cs
        $doc = [YcRaster]::Make((Render $html $false $land), $land, $urf, $res, $gray)
    }
    # impressora ocupada (0x0507, outro trabalho em andamento): espera e tenta de novo por ate ~1 minuto
    for ($n = 0; $n -lt 12; $n++) {
        $r = Ipp-Call $t.url $t.path 0x0002 ([ordered]@{ 'job-name' = @(0x42, 'Ficha Tecnica'); 'document-format' = @(0x49, $fmt) }) $job $doc 60000
        if ($r.status -ne 0x0507) { break }
        Start-Sleep -Seconds 5
    }
    if ($r.status -ge 0x100) { return @{ ok = $false; code = 'recusou'; detail = ('{0} (codigo 0x{1:x4})' -f $t.name, $r.status) } }
    Write-Host ("  Ficha enviada para {0} ({1})" -f $t.name, $t.ip) -ForegroundColor Green
    @{ ok = $true; detail = $t.name }
}

# ---------- mini servidor HTTP so para esta maquina (127.0.0.1) ----------
$ycPage = @'
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Imprimir ficha</title>
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#111;color:#eee;font:15px/1.45 Arial,Helvetica,sans-serif}
.box{width:100%;max-width:480px;padding:28px 16px;box-sizing:border-box;text-align:center}
h1{font-size:20px;margin:0 0 12px}
#msg{margin:0 0 14px}
.ok{color:#7ee787}.err{color:#ff7b72}
#msg small{display:block;opacity:.7;margin-top:6px}
#list{text-align:left;margin:0 0 16px}
.p{display:flex;gap:10px;align-items:flex-start;padding:10px 12px;margin:0 0 8px;border:1px solid #333;border-radius:8px;cursor:pointer}
.p:has(input:checked){border-color:#2f81f7;background:#16233a}
.p.off{opacity:.45;cursor:not-allowed}
.p input{margin:3px 0 0}
.p b{display:block}
.p small{display:block;opacity:.7;overflow-wrap:anywhere}
.acts{display:flex;gap:8px;justify-content:center;flex-wrap:wrap}
button{font:inherit;background:#fff;color:#000;border:0;border-radius:6px;padding:8px 18px;cursor:pointer}
button.sec{background:none;color:#eee;border:1px solid #555}
button:disabled{opacity:.5;cursor:wait}
button[hidden]{display:none}
</style></head><body><div class="box"><h1>Ficha T&eacute;cnica</h1><p id="msg"></p><div id="list"></div>
<div class="acts"><button id="go" hidden>Imprimir</button><button id="scan" class="sec" hidden>Procurar de novo</button></div></div>
<script>
var MSG = {
  'sem-impressora': 'Nenhuma impressora encontrada na rede. Confira se ela est\u00e1 ligada e na mesma rede desta m\u00e1quina.',
  'formato': 'Esta impressora n\u00e3o aceita nenhum formato que a ficha gera (PDF, PWG, URF ou JPEG).',
  'recusou': 'A impressora recusou a ficha.',
  'navegador': 'N\u00e3o foi poss\u00edvel gerar a ficha (Edge n\u00e3o encontrado).',
  'erro': 'Erro ao enviar para a impressora.'
};
var KEY = 'yc-impressora';
var msg = document.getElementById('msg'), list = document.getElementById('list');
var go = document.getElementById('go'), scan = document.getElementById('scan');
var raw = location.hash.slice(1), land = raw.charAt(0) === 'L', html = '', byIp = {};
try {
  var b = atob(raw.slice(1).replace(/-/g, '+').replace(/_/g, '/')), u = new Uint8Array(b.length);
  for (var i = 0; i < b.length; i++) u[i] = b.charCodeAt(i);
  html = new TextDecoder().decode(u);
} catch (e) {}
// tira os dados do endereco: recarregar a pagina nao reenvia nada
history.replaceState(null, '', location.pathname);
function show(t, c, d) { msg.className = c || ''; msg.textContent = t; if (d) { var s = document.createElement('small'); s.textContent = d; msg.appendChild(s); } }
function closed() { show('A janela do comando foi fechada. Rode o comando da ficha de novo nesta m\u00e1quina e clique outra vez em \u201cImprimir na rede\u201d.', 'err'); }
function el(tag, text) { var e = document.createElement(tag); if (text) e.textContent = text; return e; }
function load(fresh) {
  go.hidden = true; scan.hidden = true; list.innerHTML = '';
  show('Procurando impressoras na rede\u2026');
  fetch('/impressoras' + (fresh ? '?novo=1' : '')).then(function (r) { return r.json(); }).then(function (r) {
    var ps = r.printers || [], last = null;
    try { last = localStorage.getItem(KEY); } catch (e) {}
    scan.hidden = false;
    if (!ps.length) { show(MSG['sem-impressora'], 'err'); return; }
    // ja marcada: a ultima usada nesta maquina, a pedida no comando ou a primeira que aceita a ficha
    var ok = ps.filter(function (p) { return p.ok; });
    var sel = ok.filter(function (p) { return p.name === last; })[0] || ok.filter(function (p) { return p.pre; })[0] || ok[0];
    byIp = {};
    ps.forEach(function (p) {
      byIp[p.ip] = p;
      var row = el('label'), inp = el('input'), txt = el('span');
      row.className = 'p' + (p.ok ? '' : ' off');
      inp.type = 'radio'; inp.name = 'p'; inp.value = p.ip; inp.disabled = !p.ok; inp.checked = p === sel;
      txt.appendChild(el('b', p.name));
      txt.appendChild(el('small', [p.model !== p.name ? p.model : '', p.location, p.ip.indexOf('win:') ? p.ip : ''].filter(Boolean).join(' \u00b7 ') + (p.ok || p.why ? '' : ' \u2014 formato n\u00e3o suportado')));
      row.appendChild(inp); row.appendChild(txt); list.appendChild(row);
    });
    show(ps.length === 1 ? 'Impressora encontrada:' : 'Escolha a impressora:');
    go.textContent = 'Imprimir'; go.hidden = !sel;
  }).catch(closed);
}
function send() {
  var c = document.querySelector('input[name=p]:checked');
  if (!c) return;
  var p = byIp[c.value];
  try { localStorage.setItem(KEY, p.name); } catch (e) {}
  go.disabled = true; scan.disabled = true;
  show('Enviando para ' + p.name + '\u2026');
  fetch('/imprimir', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ html: html, land: land, ip: p.ip }) })
    .then(function (r) { return r.json(); })
    .then(function (r) {
      if (r.ok) { show('\u2713 Ficha enviada para ' + r.detail + '. Pode fechar esta aba.', 'ok'); go.textContent = 'Imprimir de novo'; }
      else show(MSG[r.code] || MSG.erro, 'err', r.detail ? 'Detalhe: ' + r.detail : '');
    })
    .catch(closed)
    .then(function () { go.disabled = false; scan.disabled = false; });
}
go.onclick = send;
scan.onclick = function () { load(true); };
if (html.indexOf('<html') < 0) show('Nada para imprimir. Volte \u00e0 ficha e clique em \u201cImprimir na rede\u201d.', 'err');
else load(false);
</script></body></html>
'@

function Send-Resp($stream, [int]$code, [string]$type, [string]$body) {
    $b = [Text.Encoding]::UTF8.GetBytes($body)
    $h = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $code X`r`nContent-Type: $type; charset=utf-8`r`nContent-Length: $($b.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
    $stream.Write($h, 0, $h.Length); $stream.Write($b, 0, $b.Length)
}

function Handle-Client($client) {
    $st = $client.GetStream(); $st.ReadTimeout = 10000
    $buf = New-Object byte[] 65536; $ms = New-Object IO.MemoryStream; $end = -1
    while ($end -lt 0) {
        $n = $st.Read($buf, 0, $buf.Length); if ($n -le 0) { return }
        $ms.Write($buf, 0, $n)
        $end = [Text.Encoding]::ASCII.GetString($ms.ToArray()).IndexOf("`r`n`r`n")
        if ($end -lt 0 -and $ms.Length -gt 65536) { return }
    }
    $lines = [Text.Encoding]::ASCII.GetString($ms.ToArray(), 0, $end) -split "`r`n"
    $req = $lines[0] -split ' '
    $hd = @{}
    foreach ($ln in ($lines | Select-Object -Skip 1)) { $p = $ln.IndexOf(':'); if ($p -gt 0) { $hd[$ln.Substring(0, $p).Trim().ToLower()] = $ln.Substring($p + 1).Trim() } }
    $path = ($req[1] -split '\?')[0]
    $self = "http://127.0.0.1:$ycPort"
    if ($req[0] -eq 'GET' -and $path -eq '/imprimir') { Send-Resp $st 200 'text/html' $ycPage; return }
    if ($req[0] -eq 'GET' -and $path -eq '/impressoras') {
        if ($hd['origin'] -and $hd['origin'] -ne $self) { Send-Resp $st 403 'text/plain' 'proibido'; return }
        $ps = @(Get-Printers ($req[1] -match 'novo=1') | ForEach-Object {
            [ordered]@{ ip = $_.ip; name = $_.name; model = $_.model; location = $_.location; ok = $_.ok; why = [bool]$_.why
                        pre = [bool]($ycPrinterMatch -and "$($_.name) $($_.model)" -match [regex]::Escape($ycPrinterMatch)) }
        })
        Send-Resp $st 200 'application/json' (@{ printers = $ps } | ConvertTo-Json -Depth 4 -Compress)
        return
    }
    if ($req[0] -ne 'POST' -or $path -ne '/imprimir') { Send-Resp $st 404 'text/plain' 'nao encontrado'; return }
    # so aceita a pagina servida aqui mesmo: outro site aberto no navegador nao consegue mandar impressao
    if ($hd['origin'] -ne $self -or "$($hd['content-type'])" -notmatch '^application/json') { Send-Resp $st 403 'text/plain' 'proibido'; return }
    $len = [int]$hd['content-length']
    if ($len -le 0 -or $len -gt 20MB) { Send-Resp $st 413 'text/plain' 'grande demais'; return }
    while ($ms.Length - ($end + 4) -lt $len) { $n = $st.Read($buf, 0, $buf.Length); if ($n -le 0) { return }; $ms.Write($buf, 0, $n) }
    $res = try {
        $j = [Text.Encoding]::UTF8.GetString($ms.ToArray(), $end + 4, $len) | ConvertFrom-Json
        Send-Ficha ([string]$j.html) ([bool]$j.land) ([string]$j.ip)
    } catch {
        $code = if ("$_" -eq 'navegador') { 'navegador' } else { 'erro' }
        @{ ok = $false; code = $code; detail = "$($_.Exception.Message)" }
    }
    Send-Resp $st 200 'application/json' ($res | ConvertTo-Json -Compress)
}

$listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, $ycPort)
try { $listener.Start() } catch {
    Write-Host '  Impressao na rede: outra janela do comando ja esta cuidando disso.' -ForegroundColor DarkGray
    Write-Host ''
    return
}

Write-Host '  Impressao na rede: procurando impressoras...' -ForegroundColor Gray
$found = @(Get-Printers $true)
foreach ($p in $found) {
    if ($p.win) { Write-Host ("  - {0} ({1})" -f $p.name, $p.location) -ForegroundColor Green }
    elseif ($p.ok) { Write-Host ("  - {0} ({1})" -f $p.name, $p.ip) -ForegroundColor Green }
    elseif ($p.why) { Write-Host ("  - {0} ({1}) - IPP nao respondeu" -f $p.name, $p.ip) -ForegroundColor Yellow }
    else { Write-Host ("  - {0} ({1}) - formato nao suportado: {2}" -f $p.name, $p.ip, ($p.formats -join ' ')) -ForegroundColor DarkGray }
}
if (-not $found.Count) { Write-Host '  Nenhuma impressora encontrada agora (da para procurar de novo na hora de imprimir).' -ForegroundColor Yellow }
Write-Host ''
Write-Host '  Deixe esta janela aberta para usar "Imprimir na rede" na ficha. Para sair, feche a janela.' -ForegroundColor White
Write-Host ''
try {
    while ($true) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 150; continue }
        $client = $listener.AcceptTcpClient()
        try { Handle-Client $client } catch { } finally { $client.Close() }
    }
} finally { $listener.Stop() }
