#!/usr/bin/env bash
# =====================================================================
#  yCODEX - Ficha Tecnica (macOS e Linux)
#  Uso (o site monta esse comando sozinho, com o endereco certo):
#    curl -fsSL https://raw.githubusercontent.com/yC0D3X/ficha/main/ficha.sh | bash -s -- 'https://SEU-SITE/'
#  Coleta as informacoes da maquina e abre o site ja com a ficha preenchida.
#  Nada e enviado para servidor: os dados vao no proprio link (depois do #).
#  Compativel com o bash 3.2 do macOS (sem arrays associativos, sem ${x,,} etc.).
# =====================================================================

SITE="${1:-$YC_SITE}"
OS_KIND="$(uname -s)"

step() { printf '  \033[90m> %s\033[0m\n' "$1" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------- helpers de JSON ----------
esc() { printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\t\n' '  ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'; }
q()   { printf '"%s"' "$(esc "$1")"; }
num() { case "$1" in ''|*[!0-9.]*|.*|*.*.*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
bool() { if [ -n "$1" ] && [ "$1" != "0" ] && [ "$1" != "false" ]; then printf 'true'; else printf 'false'; fi; }
# lista (uma por linha) -> array JSON de strings, sem repetidos e sem linhas vazias
jarr() {
    local out="" line
    while IFS= read -r line; do
        line="$(esc "$line")"
        [ -z "$line" ] && continue
        out="$out\"$line\","
    done <<EOF
$(printf '%s\n' "$1" | awk 'NF && !seen[$0]++')
EOF
    printf '[%s]' "${out%,}"
}
# valor de "Chave: valor" num texto (system_profiler, diskutil, lscpu...)
kv() { printf '%s\n' "$1" | awk -v k="$2" '{ l=$0; sub(/^[ \t]+/, "", l); if (index(l, k ":") == 1) { v = substr(l, length(k) + 2); sub(/^[ \t]+/, "", v); print v; exit } }'; }
# igual ao kv, mas tenta varias chaves (o macOS pode mostrar em ingles ou em portugues)
kvx() { local t="$1" k v; shift; for k in "$@"; do v="$(kv "$t" "$k")"; [ -n "$v" ] && { printf '%s' "$v"; return; }; done; }
kv_all() { printf '%s\n' "$1" | awk -v k="$2" '{ l=$0; sub(/^[ \t]+/, "", l); if (index(l, k ":") == 1) { v = substr(l, length(k) + 2); sub(/^[ \t]+/, "", v); print v } }'; }
digits() { printf '%s' "$1" | sed 's/[^0-9.].*//'; }
gb_from_bytes() { awk -v b="$1" 'BEGIN { if (b > 0) printf "%.0f", b / 1e9 }'; }
# polegadas a partir do EDID (texto hexadecimal). Usa o tamanho em MILIMETROS do bloco de timing
# detalhado (bytes 66-68), que e mais preciso que os cm inteiros dos bytes 21 e 22; mas alguns
# fabricantes gravam mm errados, entao o mm so vale se bater com os cm (diferenca de ate 1,5 cm).
# Duas casas decimais: o site arredonda para o tamanho comercial (15,55 -> 15,6" e nao 15,4").
# Descarta valores sem sentido (0, proporcao no lugar do tamanho, telas < 7" ou > 100").
edid_inches() {
    local h="$1" cw=0 cv=0 mw=0 mv=0
    b() { printf '%d' "0x${h:$(($1 * 2)):2}"; }
    [ ${#h} -ge 46 ] && { cw=$(b 21); cv=$(b 22); }
    if [ ${#h} -ge 138 ] && [ "$(b 54)$(b 55)" != "00" ]; then
        mw=$(( $(b 66) + (($(b 68) >> 4) << 8) )); mv=$(( $(b 67) + (($(b 68) & 15) << 8) ))
    fi
    awk -v cw="$cw" -v cv="$cv" -v mw="$mw" -v mv="$mv" 'function abs(x) { return x < 0 ? -x : x }
        BEGIN {
            mm = mw > 50 && mv > 50; cm = cw > 0 && cv > 0
            if (mm && cm && (abs(mw - cw * 10) > 15 || abs(mv - cv * 10) > 15)) mm = 0
            if (mm) r = sqrt(mw * mw + mv * mv) / 25.4; else if (cm) r = sqrt(cw * cw + cv * cv) / 2.54; else exit
            if (r >= 7 && r <= 100) printf "%.2f\n", r
        }'
}

printf '\n  \033[1myCODEX - Ficha Tecnica\033[0m\n  Coletando informacoes da maquina...\n' >&2

PLATFORM="" OSNAME="" BRAND="" MODEL="" FAMILY="" SKU="" SERIAL="" ASSET=""
CPU_NAME="" CPU_MHZ="" CPU_CORES="" CPU_THREADS=""
RAM_GB="" RAM_TYPE="" RAM_SPEED="" RAM_SLOTS="" RAM_MODULES="[]"
DISKS="[]" GPUS="[]" RES="" INCHES="" TOUCH=""
WEBCAM="" BIO="" READER="" NET="[]" AUDIO="" MIC=""
BATT_PRESENT="" BATT_HEALTH="" BATT_CYCLES="" BATT_CHARGE="" BATT_COND=""
BT="" NFC="" TOUCHPAD="" TRACKPOINT="" KEYBOARD=""

# =====================================================================
if [ "$OS_KIND" = "Darwin" ]; then
# =====================================================================
    PLATFORM="mac"
    step "Sistema e identificacao"
    HW="$(system_profiler SPHardwareDataType 2>/dev/null)"
    OSNAME="macOS $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
    BRAND="Apple"
    MODEL="$(kvx "$HW" 'Model Name' 'Nome do Modelo')"
    SKU="$(kvx "$HW" 'Model Identifier' 'Identificador do Modelo')"
    SERIAL="$(kvx "$HW" 'Serial Number (system)' 'Número de Série (sistema)' 'Numero de Serie (sistema)')"
    IOREG="$(ioreg -l -w0 2>/dev/null)"
    # nome comercial completo, ex.: "MacBook Pro (16-inch, 2019)"
    #  1) Apple Silicon: product-name do ioreg (nos Intel ali vem so o identificador, ex.: MacBookPro16,1 -> ignorado)
    FAMILY="$(printf '%s' "$IOREG" | sed -n 's/.*"product-name" = <"\(.*\)">.*/\1/p' | head -1)"
    case "$FAMILY" in *" "*) ;; *) FAMILY="" ;; esac
    #  2) tabela de modelos do proprio macOS
    SIMA=/System/Library/PrivateFrameworks/ServerInformation.framework/Versions/A/Resources/en.lproj/SIMachineAttributes.plist
    [ -z "$FAMILY" ] && [ -n "$SKU" ] && [ -f "$SIMA" ] && FAMILY="$(/usr/libexec/PlistBuddy -c "Print :$SKU:_LOCALIZABLE_:marketingModel" "$SIMA" 2>/dev/null)"
    #  3) cache do "Sobre Este Mac"
    [ -z "$FAMILY" ] && FAMILY="$(defaults read com.apple.SystemProfiler 'CPU Names' 2>/dev/null | sed -n 's/.*= "\(.*\)";/\1/p' | head -1)"

    step "Processador e memoria"
    CPU_NAME="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    [ -z "$CPU_NAME" ] && CPU_NAME="$(kv "$HW" 'Chip')"
    HZ="$(sysctl -n hw.cpufrequency_max 2>/dev/null)"
    [ -n "$HZ" ] && CPU_MHZ="$(awk -v h="$HZ" 'BEGIN { printf "%.0f", h / 1e6 }')"
    CPU_CORES="$(sysctl -n hw.physicalcpu 2>/dev/null)"
    CPU_THREADS="$(sysctl -n hw.logicalcpu 2>/dev/null)"
    RAM_GB="$(awk -v b="$(sysctl -n hw.memsize 2>/dev/null)" 'BEGIN { if (b > 0) printf "%.0f", b / 1073741824 }')"
    MEM="$(system_profiler SPMemoryDataType 2>/dev/null)"
    RAM_TYPE="$(kv "$MEM" 'Type')"
    RAM_SPEED="$(digits "$(kv "$MEM" 'Speed')")"
    # Macs Intel listam cada pente (BANK x/...); Apple Silicon so tem o total
    RAM_SLOTS="$(printf '%s\n' "$MEM" | grep -c 'BANK ')"
    [ "$RAM_SLOTS" = "0" ] && RAM_SLOTS=""
    RAM_MODULES="[$(printf '%s\n' "$MEM" | awk '
        function flush() { if (sz != "" && sz !~ /Empty/) { gsub(/[^0-9]/, "", sz); printf "%s{\"gb\":%s,\"type\":\"%s\",\"speed\":%s,\"slot\":\"%s\",\"maker\":\"%s\"}", sep, sz, ty, (sp == "" ? "null" : sp), sl, mk; sep = "," } sz = ""; ty = ""; sp = ""; mk = "" }
        /BANK / { flush(); sl = $0; sub(/^[ \t]+/, "", sl); sub(/:$/, "", sl) }
        /^[ \t]+Size:/ { sz = $0; sub(/.*Size: /, "", sz) }
        /^[ \t]+Type:/ { ty = $0; sub(/.*Type: /, "", ty) }
        /^[ \t]+Speed:/ { sp = $0; sub(/.*Speed: /, "", sp); gsub(/[^0-9]/, "", sp) }
        /^[ \t]+Manufacturer:/ { mk = $0; sub(/.*Manufacturer: /, "", mk) }
        END { flush() }')]"

    step "Armazenamento"
    DU="$(diskutil info disk0 2>/dev/null)"
    D_NAME="$(kv "$DU" 'Device / Media Name')"
    D_BYTES="$(kv "$DU" 'Disk Size' | sed -n 's/.*(\([0-9]*\) Bytes).*/\1/p')"
    D_SSD="$(kv "$DU" 'Solid State')"
    D_PROTO="$(kv "$DU" 'Protocol')"
    D_TYPE="HDD"; [ "$D_SSD" = "Yes" ] && D_TYPE="SSD"
    case "$D_PROTO" in *PCI*|*Fabric*) D_BUS="NVMe" ;; *) D_BUS="$D_PROTO" ;; esac
    [ -n "$D_NAME" ] && DISKS="[{\"model\":$(q "$D_NAME"),\"gb\":$(num "$(gb_from_bytes "$D_BYTES")"),\"type\":\"$D_TYPE\",\"bus\":$(q "$D_BUS"),\"health\":$(q "$(kv "$DU" 'SMART Status')")}]"

    step "Video e tela"
    DSP="$(system_profiler SPDisplaysDataType 2>/dev/null)"
    VRAM="$(kv "$DSP" 'VRAM (Total)')"; [ -z "$VRAM" ] && VRAM="$(kv "$DSP" 'VRAM (Dynamic, Max)')"
    VRAM_GB="$(printf '%s' "$VRAM" | awk '/GB/ { printf "%s", $1 } /MB/ { printf "%.1f", $1 / 1024 }')"
    GPUS="["; SEP=""
    while IFS= read -r g; do
        [ -z "$g" ] && continue
        GPUS="$GPUS$SEP{\"name\":$(q "$g"),\"vram\":$(num "$VRAM_GB")}"; SEP=","
    done <<EOF
$(kv_all "$DSP" 'Chipset Model')
EOF
    GPUS="$GPUS]"
    RES="$(kv "$DSP" 'Resolution' | awk '{ print $1 "x" $3 }')"
    # polegadas, do mais exato para o menos:
    #  (o site ainda confere o identificador no banco macs.json, que prevalece sobre a medida)
    #  1) nome comercial ("MacBook Pro (16-inch, 2019)", "13-inch MacBook Pro") - o espaco no comeco
    #     garante que o numero no inicio do nome tambem seja achado
    INCHES="$(printf ' %s %s' "$FAMILY" "$MODEL" | sed -En 's/.*[^0-9.]([0-9][0-9.]*)[- ]?(inch|"|polegadas|pol).*/\1/p' | head -1)" && SRC="nome do modelo"
    #  2) tamanho fisico da tela embutida, perguntado ao proprio macOS (CoreGraphics, em mm):
    #     vale para qualquer Mac com tela embutida
    if [ -z "$INCHES" ]; then
        INCHES="$(osascript -l JavaScript -e '
            ObjC.import("AppKit"); ObjC.import("CoreGraphics");
            var r = "", s = $.NSScreen.screens;
            for (var i = 0; i < s.count; i++) {
                var id = ObjC.unwrap(s.objectAtIndex(i).deviceDescription.objectForKey("NSScreenNumber"));
                if ($.CGDisplayIsBuiltin(id)) { var z = $.CGDisplayScreenSize(id); r = (Math.sqrt(z.width * z.width + z.height * z.height) / 25.4).toFixed(2); }
            }
            r' 2>/dev/null)"
        INCHES="$(awk -v r="$INCHES" 'BEGIN { if (r != "" && r >= 7 && r <= 100) print r }')"; SRC="macOS (CoreGraphics)"
    fi
    #  3) EDID do painel interno (Intel: AppleBacklightDisplay) ou, por ultimo, de qualquer tela
    if [ -z "$INCHES" ]; then
        EDID="$(ioreg -l -w0 -r -c AppleBacklightDisplay 2>/dev/null | sed -n 's/.*"IODisplayEDID" = <\([0-9a-fA-F]*\)>.*/\1/p' | head -1)"
        [ -z "$EDID" ] && EDID="$(printf '%s' "$IOREG" | sed -n 's/.*"IODisplayEDID" = <\([0-9a-fA-F]*\)>.*/\1/p' | head -1)"
        [ -n "$EDID" ] && INCHES="$(edid_inches "$EDID")"; SRC="EDID da tela"
    fi
    if [ -n "$INCHES" ]; then step "Tela: $INCHES pol. (via $SRC)"; else step "Tela: tamanho nao encontrado (preencha na ficha)"; fi
    TOUCH=""

    step "Dispositivos"
    # webcam: nomes listados pelo system_profiler (linhas "Nome:" que nao sao o titulo da secao)
    WEBCAM="$(system_profiler SPCameraDataType 2>/dev/null | awk '/^ +[^ ].*:$/ && !/(Camera|Câmera|Cameras|Câmeras):$/ { sub(/^ +/, ""); sub(/:$/, ""); print }' | grep -viE 'model id|unique id|id do modelo|id exclusivo')"
    # reserva: alguns macOS so listam a camera com permissao; procura no registro de hardware
    if [ -z "$WEBCAM" ]; then
        WEBCAM="$(printf '%s' "$IOREG" | grep -oE 'FaceTime[ A-Za-z0-9]*Camera[ A-Za-z()]*' | head -1)"
        [ -z "$WEBCAM" ] && printf '%s' "$IOREG" | grep -qE 'AppleH1[0-9]CamIn|AppleCamIn|AppleH[0-9]+CamIn|AppleISP' && WEBCAM="Camera FaceTime"
    fi
    printf '%s' "$IOREG" | grep -qiE 'AppleBiometricSensor|AppleMesaSEPDriver|AppleMesaResourceManager|BiometricKit' && BIO="Touch ID"
    system_profiler SPCardReaderDataType 2>/dev/null | grep -q '[A-Za-z]' && READER="Leitor de cartao SD"
    AIR="$(system_profiler SPAirPortDataType 2>/dev/null)"
    WIFI_PHY="$(kvx "$AIR" 'Supported PHY Modes' 'Modos PHY Compatíveis' 'Modos PHY Compativeis')"
    # "Tipo de Placa: Wi-Fi (0x14E4, 0x7BF)" -> "Broadcom (0x14E4, 0x7BF)"
    WIFI_CARD="$(kvx "$AIR" 'Card Type' 'Tipo de Placa' | sed -E 's/^(Wi-Fi|AirPort[^(]*)[[:space:]]*//')"
    case "$WIFI_CARD" in
        *0x14E4*|*0x14e4*) WIFI_CARD="Broadcom $WIFI_CARD" ;;
        *0x8086*) WIFI_CARD="Intel $WIFI_CARD" ;;
        *0x168C*|*0x168c*) WIFI_CARD="Atheros $WIFI_CARD" ;;
        *0x106B*|*0x106b*) WIFI_CARD="Apple $WIFI_CARD" ;;
    esac
    WIFI_NAME="$(printf '%s' "$WIFI_CARD${WIFI_CARD:+ · }$WIFI_PHY")"
    NET="["; SEP=""
    while IFS= read -r port; do
        case "$port" in
            Wi-Fi|AirPort) NET="$NET$SEP{\"kind\":\"wifi\",\"name\":$(q "${WIFI_NAME:-Wi-Fi}")}"; SEP="," ;;
            *Ethernet*) case "$port" in *Bridge*|*Thunderbolt*) ;; *) NET="$NET$SEP{\"kind\":\"eth\",\"name\":$(q "$port")}"; SEP="," ;; esac ;;
        esac
    done <<EOF
$(networksetup -listallhardwareports 2>/dev/null | sed -n 's/^Hardware Port: //p')
EOF
    NET="$NET]"
    AUD="$(system_profiler SPAudioDataType 2>/dev/null)"
    AUDIO="$(printf '%s\n' "$AUD" | awk '/^        [^ ].*:$/ { sub(/^ +/, ""); sub(/:$/, ""); print }')"
    MIC="$(printf '%s\n' "$AUDIO" | grep -i 'micro')"
    PWR="$(system_profiler SPPowerDataType 2>/dev/null)"
    # bateria: ciclos e condicao como a Apple informa (Normal / Manutencao recomendada...);
    # a % so entra quando o proprio macOS mostra "Capacidade Maxima" (Macs com chip M)
    BATT_CYCLES="$(digits "$(kvx "$PWR" 'Cycle Count' 'Número de Ciclos' 'Numero de Ciclos')")"
    BATT_COND="$(kvx "$PWR" 'Condition' 'Condição' 'Condicao')"
    if [ -n "$BATT_CYCLES" ] || [ -n "$BATT_COND" ]; then
        BATT_PRESENT=1
        BATT_HEALTH="$(digits "$(kvx "$PWR" 'Maximum Capacity' 'Capacidade Máxima' 'Capacidade Maxima')")"
        BATT_CHARGE="$(digits "$(kvx "$PWR" 'State of Charge (%)' 'Estado da Carga (%)')")"
    fi
    system_profiler SPBluetoothDataType 2>/dev/null | grep -qiE 'Address|Chipset' && BT=1
    case "$MODEL" in *MacBook*) TOUCHPAD="Trackpad Force Touch (Apple)" ;; esac
    KEYBOARD="$(defaults read com.apple.HIToolbox AppleSelectedInputSources 2>/dev/null | sed -n 's/.*"KeyboardLayout Name" = "\{0,1\}\([^";]*\)"\{0,1\};.*/\1/p' | head -1)"

# =====================================================================
else
# =====================================================================
    PLATFORM="linux"
    dmi() { cat "/sys/class/dmi/id/$1" 2>/dev/null; }
    step "Sistema e identificacao"
    OSNAME="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Linux}") (kernel $(uname -r))"
    BRAND="$(dmi sys_vendor)"; MODEL="$(dmi product_name)"; FAMILY="$(dmi product_version)"; SKU="$(dmi product_sku)"
    SERIAL="$(dmi product_serial)"; ASSET="$(dmi chassis_asset_tag)"
    DMI_MEM=""
    # numero de serie e detalhes da memoria exigem root no Linux: pergunta antes de usar sudo
    if { [ -z "$SERIAL" ] || have dmidecode; } && have sudo && [ -r /dev/tty ] && [ "$(id -u)" != "0" ]; then
        printf '  Ler numero de serie e detalhes da memoria? Precisa da senha (sudo). [s/N] ' >&2
        read -r ANS </dev/tty
        case "$ANS" in
            s|S|y|Y)
                [ -z "$SERIAL" ] && SERIAL="$(sudo cat /sys/class/dmi/id/product_serial 2>/dev/null </dev/tty)"
                have dmidecode && DMI_MEM="$(sudo dmidecode -t 17 2>/dev/null </dev/tty)" ;;
        esac
    elif [ "$(id -u)" = "0" ]; then
        have dmidecode && DMI_MEM="$(dmidecode -t 17 2>/dev/null)"
    fi

    step "Processador e memoria"
    CPU_NAME="$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
    KHZ="$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)"
    [ -n "$KHZ" ] && CPU_MHZ=$((KHZ / 1000))
    CPU_THREADS="$(getconf _NPROCESSORS_ONLN 2>/dev/null)"
    have lscpu && CPU_CORES="$(lscpu -p=CORE,SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l | tr -d ' ')"
    RAM_GB="$(awk '/^MemTotal:/ { printf "%.1f", $2 / 1048576 }' /proc/meminfo)"
    if [ -n "$DMI_MEM" ]; then
        RAM_SLOTS="$(printf '%s\n' "$DMI_MEM" | grep -c '^Memory Device')"
        RAM_MODULES="[$(printf '%s\n' "$DMI_MEM" | awk -F': ' '
            function flush() { if (inb && sz ~ /[0-9]/) { n = sz; gsub(/[^0-9]/, "", n); if (sz ~ /MB/) n = n / 1024; printf "%s{\"gb\":%s,\"type\":\"%s\",\"speed\":%s,\"slot\":\"%s\",\"maker\":\"%s\"}", sep, n, ty, (sp == "" ? "null" : sp), sl, mk; sep = "," } sz = ""; ty = ""; sp = ""; sl = ""; mk = ""; inb = 0 }
            /^Memory Device/ { flush(); inb = 1 }
            inb && /^\tSize:/ { sz = $2 }
            inb && /^\tType:/ { ty = $2 }
            inb && /^\t(Configured Memory|Configured Clock) Speed:/ { sp = $2; gsub(/[^0-9]/, "", sp) }
            inb && /^\tSpeed:/ && sp == "" { sp = $2; gsub(/[^0-9]/, "", sp) }
            inb && /^\tLocator:/ { sl = $2 }
            inb && /^\tManufacturer:/ { mk = $2 }
            END { flush() }')]"
    fi

    step "Armazenamento"
    if have lsblk; then
        DISKS="["; SEP=""
        while read -r NAME SIZE ROTA TRAN MODELD; do
            case "$NAME" in loop*|zram*|sr*|ram*|fd*|*boot*|*rpmb*) continue ;; esac
            [ "$TRAN" = "usb" ] && continue
            T="SSD"; [ "$ROTA" = "1" ] && T="HDD"
            case "$TRAN" in nvme) B="NVMe" ;; sata) B="SATA" ;; mmc) B="eMMC" ;; *) case "$NAME" in nvme*) B="NVMe" ;; mmcblk*) B="eMMC" ;; *) B="$TRAN" ;; esac ;; esac
            DISKS="$DISKS$SEP{\"model\":$(q "$MODELD"),\"gb\":$(num "$(gb_from_bytes "$SIZE")"),\"type\":\"$T\",\"bus\":$(q "$B"),\"health\":\"\"}"; SEP=","
        done <<EOF
$(lsblk -d -b -n -o NAME,SIZE,ROTA,TRAN,MODEL 2>/dev/null)
EOF
        DISKS="$DISKS]"
    fi

    step "Video e tela"
    PCI=""; have lspci && PCI="$(lspci 2>/dev/null)"
    GPUS="["; SEP=""
    while IFS= read -r g; do
        [ -z "$g" ] && continue
        GPUS="$GPUS$SEP{\"name\":$(q "$g"),\"vram\":null}"; SEP=","
    done <<EOF
$(printf '%s\n' "$PCI" | grep -iE 'vga compatible|3d controller|display controller' | sed 's/^[^:]*:[^:]*: //')
EOF
    GPUS="$GPUS]"
    # tela: primeiro o painel interno (eDP/LVDS/DSI); se nao houver (desktop), a primeira tela conectada.
    # Em PCs com 2 placas de video existem 2 saidas internas e uma delas tem o EDID VAZIO: pula essas.
    for c in /sys/class/drm/card*-eDP-* /sys/class/drm/card*-LVDS-* /sys/class/drm/card*-DSI-* /sys/class/drm/card*-*; do
        [ -s "$c/edid" ] || continue
        [ "$(cat "$c/status" 2>/dev/null)" = "disconnected" ] && continue
        I="$(edid_inches "$(od -An -tx1 -v "$c/edid" 2>/dev/null | tr -d ' \n')")"
        R="$(head -1 "$c/modes" 2>/dev/null)"
        [ -z "$I" ] && [ -z "$R" ] && continue
        INCHES="$I"; RES="$R"
        break
    done
    if [ -n "$INCHES" ]; then step "Tela: $INCHES pol. (via EDID de ${c##*/})"; else step "Tela: tamanho nao encontrado (preencha na ficha)"; fi
    if [ -z "$RES" ] && have xrandr; then RES="$(xrandr --current 2>/dev/null | awk '/ connected/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+/) { sub(/\+.*/, "", $i); print $i; exit } }')"; fi
    INPUTS="$(sed -n 's/^N: Name="\(.*\)"$/\1/p' /proc/bus/input/devices 2>/dev/null)"
    printf '%s\n' "$INPUTS" | grep -qiE 'touch ?screen|wacom.*finger|elan.*touchscreen' && TOUCH=1

    step "Dispositivos"
    USBN=""; have lsusb && USBN="$(lsusb 2>/dev/null | sed 's/^.*ID [0-9a-f:]* //')"
    USBN="$USBN
$(cat /sys/bus/usb/devices/*/product 2>/dev/null)"
    WEBCAM="$(cat /sys/class/video4linux/video*/name 2>/dev/null)"
    BIO="$(printf '%s\n' "$USBN" | grep -iE 'fingerprint|finger print|fprint|validity|goodix.*(fp|finger)|synaptics.*(fs[0-9]|metallica|prometheus|finger)|elan.*(finger|fp)|FPC' | head -2)"
    READER="$( { printf '%s\n%s\n' "$PCI" "$USBN" | grep -iE 'card ?reader|sd host|sdxc|mmc host' | sed 's/^[^:]*:[^:]*: //'; for s in /sys/block/sr*; do [ -e "$s" ] && cat "$s/device/model" 2>/dev/null; done; } )"
    NET="["; SEP=""
    for n in /sys/class/net/*; do
        [ -e "$n/device" ] || continue
        IFN="$(basename "$n")"
        K="eth"; { [ -d "$n/wireless" ] || [ -e "$n/phy80211" ]; } && K="wifi"
        SLOT="$(basename "$(readlink -f "$n/device" 2>/dev/null)")"
        NN=""; [ -n "$PCI" ] && NN="$(lspci -s "$SLOT" 2>/dev/null | sed 's/^[^:]*:[^:]*: //')"
        [ -z "$NN" ] && NN="$IFN ($(basename "$(readlink -f "$n/device/driver" 2>/dev/null)"))"
        NET="$NET$SEP{\"kind\":\"$K\",\"name\":$(q "$NN")}"; SEP=","
    done
    NET="$NET]"
    AUDIO="$(sed -n 's/^ *[0-9]* \[[^]]*\]: *//p' /proc/asound/cards 2>/dev/null)"
    if have arecord; then MIC="$(arecord -l 2>/dev/null | sed -n 's/^card [0-9]*: [^ ]* \[\([^]]*\)\].*/\1/p' | head -2)"
    elif ls /proc/asound/card*/pcm*c >/dev/null 2>&1; then MIC="Entrada de audio (microfone)"; fi
    for B in /sys/class/power_supply/BAT*; do
        [ -e "$B" ] || continue
        BATT_PRESENT=1
        F="$(cat "$B/energy_full" 2>/dev/null || cat "$B/charge_full" 2>/dev/null)"
        D="$(cat "$B/energy_full_design" 2>/dev/null || cat "$B/charge_full_design" 2>/dev/null)"
        [ -n "$F" ] && [ -n "$D" ] && BATT_HEALTH="$(awk -v f="$F" -v d="$D" 'BEGIN { if (d > 0) { h = f / d * 100; if (h > 100) h = 100; printf "%.0f", h } }')"
        BATT_CYCLES="$(cat "$B/cycle_count" 2>/dev/null)"; [ "$BATT_CYCLES" = "0" ] && BATT_CYCLES=""
        BATT_CHARGE="$(cat "$B/capacity" 2>/dev/null)"
        break
    done
    ls /sys/class/bluetooth/hci* >/dev/null 2>&1 && BT=1
    { ls /sys/class/nfc/* >/dev/null 2>&1 || printf '%s\n' "$USBN" | grep -qiE '\bnfc\b'; } && NFC=1
    TOUCHPAD="$(printf '%s\n' "$INPUTS" | grep -iE 'touch ?pad|trackpad|clickpad|glidepoint' | head -1)"
    printf '%s\n' "$INPUTS" | grep -qiE 'trackpoint|pointing ?stick|point ?stick|dualpoint stick' && TRACKPOINT=1
    if have localectl; then KEYBOARD="$(localectl status 2>/dev/null | sed -n 's/.*X11 Layout: //p')"; V="$(localectl status 2>/dev/null | sed -n 's/.*X11 Variant: //p')"; [ -n "$V" ] && KEYBOARD="$KEYBOARD $V"; fi
    [ -z "$KEYBOARD" ] && have setxkbmap && KEYBOARD="$(setxkbmap -query 2>/dev/null | sed -n 's/^layout: *//p')"
    [ -z "$KEYBOARD" ] && KEYBOARD="$(sed -n 's/^XKBLAYOUT="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' /etc/default/keyboard 2>/dev/null)"
fi

# ---------- monta o JSON (mesmo formato do script de Windows) ----------
step "Montando a ficha"
TS="$(date '+%Y-%m-%dT%H:%M:%S')"
JSON="{\"v\":1,\"platform\":\"$PLATFORM\",\"ts\":\"$TS\",\"os\":$(q "$OSNAME"),\
\"brand\":$(q "$BRAND"),\"model\":$(q "$MODEL"),\"family\":$(q "$FAMILY"),\"sku\":$(q "$SKU"),\
\"serial\":$(q "$SERIAL"),\"asset\":$(q "$ASSET"),\
\"cpu\":{\"name\":$(q "$CPU_NAME"),\"mhz\":$(num "$CPU_MHZ"),\"cores\":$(num "$CPU_CORES"),\"threads\":$(num "$CPU_THREADS")},\
\"ram\":{\"totalGB\":$(num "$RAM_GB"),\"type\":$(q "$RAM_TYPE"),\"speed\":$(num "$RAM_SPEED"),\"slots\":$(num "$RAM_SLOTS"),\"modules\":$RAM_MODULES},\
\"disks\":$DISKS,\"gpus\":$GPUS,\
\"screen\":{\"res\":$(q "$RES"),\"inches\":$(num "$INCHES"),\"touch\":$(bool "$TOUCH")},\
\"webcam\":$(jarr "$WEBCAM"),\"bio\":$(jarr "$BIO"),\"reader\":$(jarr "$READER"),\"net\":$NET,\
\"audio\":$(jarr "$AUDIO"),\"mic\":$(jarr "$MIC"),\
\"battery\":{\"present\":$(bool "$BATT_PRESENT"),\"health\":$(num "$BATT_HEALTH"),\"cycles\":$(num "$BATT_CYCLES"),\"charge\":$(num "$BATT_CHARGE"),\"condition\":$(q "$BATT_COND")},\
\"bt\":$(bool "$BT"),\"nfc\":$(bool "$NFC"),\"touchpad\":$(jarr "$TOUCHPAD"),\"trackpoint\":$(bool "$TRACKPOINT"),\
\"keyboard\":$(q "$KEYBOARD")}"

if [ -n "$YC_NOOPEN" ]; then printf '%s\n' "$JSON"; exit 0; fi

CODE="$(printf '%s' "$JSON" | base64 | tr -d '\n=' | tr '+/' '-_')"

if [ -z "$SITE" ]; then
    printf '\n  Endereco do site nao informado. Copie o codigo abaixo e cole em "Importar codigo" na ficha:\n\n%s\n\n' "$CODE" >&2
    exit 0
fi

# abre o site por um arquivo HTML temporario: assim o link com os dados nunca e cortado
SITE_JS="$(printf '%s' "${SITE%%#*}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
LAUNCHER="${TMPDIR:-/tmp}/ycodex-ficha.html"
printf '<!doctype html><meta charset="utf-8"><title>yCODEX</title><script>location.replace("%s#ficha=%s")</script>' "$SITE_JS" "$CODE" > "$LAUNCHER"
if [ "$PLATFORM" = "mac" ]; then open "$LAUNCHER"
elif have xdg-open; then xdg-open "$LAUNCHER" >/dev/null 2>&1 &
else printf '  Abra este arquivo no navegador: %s\n' "$LAUNCHER" >&2; fi

printf '\n  \033[32mPronto! A ficha foi aberta no navegador.\033[0m\n\n' >&2
