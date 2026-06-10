#!/bin/sh
set -eu

USB_DEVICE_NAME="huaweimobile"
LTE_IFACE="${LTE_IFACE:-ue0}"
LTE_APN="${LTE_APN:-}"
LTE_AT_PORT="${LTE_AT_PORT:-}"
LTE_MAX_ATTEMPTS="${LTE_MAX_ATTEMPTS:-1}"
LTE_ENABLE_SERIAL_FALLBACK="${LTE_ENABLE_SERIAL_FALLBACK:-0}"
LTE_ENABLE_AT_STATUS="${LTE_ENABLE_AT_STATUS:-0}"
LTE_AT_READ_TIMEOUT="${LTE_AT_READ_TIMEOUT:-1}"
LTE_NDIS_INDEXES="${LTE_NDIS_INDEXES:-2}"
LTE_NDIS_DISCONNECT_FIRST="${LTE_NDIS_DISCONNECT_FIRST:-1}"
LTE_REGISTRATION_WAIT="${LTE_REGISTRATION_WAIT:-45}"
LTE_APN_CANDIDATES="${LTE_APN_CANDIDATES:-internet}"
LTE_OPERATOR_SCAN="${LTE_OPERATOR_SCAN:-0}"
LTE_OPERATOR_SCAN_TIMEOUT="${LTE_OPERATOR_SCAN_TIMEOUT:-70}"
LTE_RADIO_RESET_FIRST="${LTE_RADIO_RESET_FIRST:-1}"
LTE_POST_RADIO_RESET_WAIT="${LTE_POST_RADIO_RESET_WAIT:-5}"
LTE_CONFIGURE_PDP_CONTEXT="${LTE_CONFIGURE_PDP_CONTEXT:-1}"
LTE_SYSCFGEX_MODE="${LTE_SYSCFGEX_MODE:-03}"
LTE_SYSCFGEX_BAND="${LTE_SYSCFGEX_BAND:-3FFFFFFF}"
LTE_SYSCFGEX_LTE_BAND="${LTE_SYSCFGEX_LTE_BAND:-7FFFFFFFFFFFFFFF}"
DHCPCONF="/etc/dhclient.conf"
NETWORKING_CONFIGURED_IFACE=""
RADIO_RESET_DONE=0
PDP_CONTEXT_DONE=0
RADIO_PROFILE_DONE=0

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "run this script as root"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

ensure_usb_modeswitch_package() {
    if pkg info -e usb_modeswitch >/dev/null 2>&1; then
        log "usb_modeswitch package is already installed"
        return
    fi

    log "Installing usb_modeswitch package"
    pkg install -y usb_modeswitch
}

dhclient_has_ignore_routers_for_iface() {
    iface="$1"

    [ -f "$DHCPCONF" ] || return 1

    awk -v iface="$iface" '
        {
            sub(/#.*/, "")
        }
        $0 ~ "^[[:space:]]*interface[[:space:]]+\"" iface "\"[[:space:]]*\\{" {
            in_block = 1
        }
        in_block && /(^|[[:space:]])ignore[[:space:]]+routers[[:space:]]*;/ {
            found = 1
        }
        in_block && /\}/ {
            in_block = 0
        }
        END { exit(found ? 0 : 1) }
    ' "$DHCPCONF"
}

dhclient_has_any_ignore_routers() {
    [ -f "$DHCPCONF" ] || return 1

    awk '
        {
            sub(/#.*/, "")
            if ($0 ~ /(^|[[:space:]])ignore[[:space:]]+routers[[:space:]]*;/) {
                found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$DHCPCONF"
}

ensure_dhclient_ignores_routers() {
    iface="$1"

    if [ ! -f "$DHCPCONF" ]; then
        log "Creating $DHCPCONF"
        : > "$DHCPCONF"
    fi

    if dhclient_has_ignore_routers_for_iface "$iface"; then
        log "$DHCPCONF already contains ignore routers for $iface"
        return
    fi

    if dhclient_has_any_ignore_routers; then
        log "$DHCPCONF contains ignore routers, but not yet for $iface"
    fi

    log "Adding DHCP router suppression for $iface to $DHCPCONF"
    cat >> "$DHCPCONF" <<EOF

# Added by install-huawei-lte.sh for the Huawei LTE HiLink interface.
interface "$iface" {
    ignore routers;
}
EOF
}

get_usb_field() {
    dev="$1"
    field="$2"

    usbconfig -d "$dev" dump_device_desc 2>/dev/null |
        awk -v field="$field" '
            $1 == field {
                value = tolower($3)
                print value
                exit
            }
        '
}

get_usb_summary() {
    dev="$1"

    usbconfig |
        awk -F: -v dev="$dev" '$1 == dev { print; exit }'
}

get_usb_config_desc() {
    dev="$1"

    usbconfig -d "$dev" dump_curr_config_desc 2>/dev/null ||
        usbconfig -d "$dev" dump_all_config_desc 2>/dev/null ||
        true
}

list_usb_devices() {
    usbconfig | awk -F: '$1 ~ /^ugen[0-9][0-9]*\.[0-9][0-9]*$/ { print $1 }'
}

find_lte_device_from_summary() {
    usbconfig |
        awk -F: -v name="$USB_DEVICE_NAME" '
            tolower($0) ~ name && $1 ~ /^ugen[0-9][0-9]*\.[0-9][0-9]*$/ {
                print $1
                found = 1
                exit 0
            }
            END { exit(found ? 0 : 1) }
        '
}

descriptor_contains_lte_name() {
    dev="$1"

    usbconfig -d "$dev" dump_device_desc 2>/dev/null |
        awk -v name="$USB_DEVICE_NAME" '
            {
                line = tolower($0)
                gsub(/[^a-z0-9]/, "", line)
                if (line ~ name) {
                    found = 1
                }
            }
            END { exit(found ? 0 : 1) }
        '
}

find_lte_device_from_descriptors() {
    list_usb_devices |
        while IFS= read -r dev; do
            if descriptor_contains_lte_name "$dev"; then
                printf '%s\n' "$dev"
                return 0
            fi
        done
}

find_lte_device() {
    find_lte_device_from_summary ||
        find_lte_device_from_descriptors
}

list_lte_interfaces() {
    ifconfig -l 2>/dev/null |
        tr ' ' '\n' |
        awk '/^ue[0-9][0-9]*$/ { print }'
}

choose_lte_interface() {
    iface=""

    if [ -n "$LTE_IFACE" ] && ifconfig "$LTE_IFACE" >/dev/null 2>&1; then
        return 0
    fi

    iface="$(list_lte_interfaces | sed -n '1p')"
    if [ -n "$iface" ]; then
        if [ "$LTE_IFACE" != "$iface" ]; then
            log "Using discovered LTE interface $iface"
        fi
        LTE_IFACE="$iface"
        return 0
    fi

    return 1
}

lte_interface_is_present() {
    choose_lte_interface >/dev/null 2>&1
}

lte_interface_status() {
    if ! lte_interface_is_present; then
        printf '%s\n' "missing"
        return
    fi

    ifconfig "$LTE_IFACE" |
        awk -F: '
            /^[[:space:]]*status:/ {
                sub(/^[[:space:]]+/, "", $2)
                print $2
                found = 1
                exit
            }
            END {
                if (!found) {
                    print "unknown"
                }
            }
        '
}

lte_interface_has_carrier() {
    [ "$(lte_interface_status)" = "active" ]
}

lte_interface_has_ipv4() {
    ifconfig "$LTE_IFACE" 2>/dev/null |
        awk '$1 == "inet" { found = 1 } END { exit(found ? 0 : 1) }'
}

lte_interface_has_dhcp_ipv4() {
    ifconfig "$LTE_IFACE" 2>/dev/null |
        awk '$1 == "inet" && $2 != "192.168.8.2" { found = 1 } END { exit(found ? 0 : 1) }'
}

clear_lte_static_test_address() {
    if lte_interface_is_present; then
        ifconfig "$LTE_IFACE" inet 192.168.8.2 -alias >/dev/null 2>&1 || true
    fi
}

lte_usb_uses_ncm() {
    dev="$1"

    get_usb_config_desc "$dev" |
        tr '[:upper:]' '[:lower:]' |
        grep -Eq 'ncm|network control model'
}

get_ncm_control_interface() {
    dev="$1"

    get_usb_config_desc "$dev" |
        awk '
            /^[[:space:]]*Interface [0-9][0-9]*$/ {
                iface = $2
            }
            /NCM Network Control Model/ && iface != "" {
                print iface
                found = 1
                exit
            }
            END { exit(found ? 0 : 1) }
        '
}

detect_lte_usb_mode() {
    dev="$1"

    if lte_interface_is_present; then
        if lte_usb_uses_ncm "$dev"; then
            if lte_interface_has_carrier; then
                printf '%s\n' "ncm-active"
            else
                printf '%s\n' "ncm-no-carrier"
            fi
            return
        fi

        if lte_interface_has_carrier; then
            printf '%s\n' "ethernet-active"
        else
            printf '%s\n' "ethernet-no-carrier"
        fi
        return
    fi

    summary="$(get_usb_summary "$dev" | tr '[:upper:]' '[:lower:]')"
    config_desc="$(get_usb_config_desc "$dev" | tr '[:upper:]' '[:lower:]')"

    if printf '%s\n%s\n' "$summary" "$config_desc" | grep -q 'mass storage'; then
        if ! printf '%s\n' "$config_desc" | grep -Eq 'communications|cdc|network|ethernet'; then
            printf '%s\n' "storage"
            return
        fi
    fi

    if printf '%s\n' "$config_desc" | grep -Eq 'communications|cdc|network|ethernet'; then
        if printf '%s\n' "$config_desc" | grep -Eq 'ncm|network control model'; then
            printf '%s\n' "ncm"
            return
        fi

        printf '%s\n' "interface"
        return
    fi

    printf '%s\n' "unknown"
}

wait_for_lte_interface() {
    n=0
    while [ "$n" -lt 10 ]; do
        if lte_interface_is_present; then
            return 0
        fi

        n=$((n + 1))
        sleep 1
    done

    return 1
}

wait_for_lte_carrier() {
    n=0
    while [ "$n" -lt 2 ]; do
        if lte_interface_has_carrier; then
            return 0
        fi

        n=$((n + 1))
        sleep 1
    done

    return 1
}

wait_for_lte_ipv4() {
    n=0
    while [ "$n" -lt 10 ]; do
        if lte_interface_has_ipv4; then
            return 0
        fi

        n=$((n + 1))
        sleep 1
    done

    return 1
}

find_lte_serial_ports() {
    emitted=" "

    for port in "$LTE_AT_PORT" /dev/cuaU0.0 /dev/cuaU0.2 /dev/cuaU0.1 /dev/cuaU1 /dev/cuaU0 /dev/cuaU2 /dev/cuaU3 /dev/cuaU4 /dev/cuaU*; do
        [ -n "$port" ] || continue
        case "$port" in
            *.init|*.lock) continue ;;
        esac
        [ -c "$port" ] || continue

        case "$emitted" in
            *" $port "*) continue ;;
        esac

        emitted="$emitted$port "
        printf '%s\n' "$port"
    done
}

log_lte_snapshot() {
    usb_devices="$(usbconfig | awk -v name="$USB_DEVICE_NAME" 'tolower($0) ~ name { printf "%s%s", sep, $1; sep = " " }')"
    interfaces="$(list_lte_interfaces | awk '{ printf "%s%s", sep, $1; sep = " " }')"
    ports="$(find_lte_serial_ports | awk '{ printf "%s%s", sep, $1; sep = " " }')"

    [ -n "$usb_devices" ] || usb_devices="none"
    [ -n "$interfaces" ] || interfaces="none"
    [ -n "$ports" ] || ports="none"

    log "Visible Huawei USB devices: $usb_devices"
    log "Visible USB ethernet interfaces: $interfaces"
    log "Visible USB modem command ports: $ports"
}

build_huawei_ndis_command() {
    apn="$1"

    if [ -n "$apn" ]; then
        printf 'AT^NDISDUP=1,1,"%s"\n' "$apn"
    else
        printf '%s\n' "AT^NDISDUP=1,1"
    fi
}

write_at_port() {
    port="$1"
    command="$2"

    { printf '%s\r\n' "$command" > "$port"; } 2>/dev/null
}

at_port_response() {
    port="$1"
    command="$2"
    read_timeout="${3:-$LTE_AT_READ_TIMEOUT}"
    open_timeout=$((read_timeout + 3))

    timeout "$open_timeout" sh -c '
            port="$1"
            command="$2"
            read_timeout="$3"
            exec 3<> "$port" || exit 1
            timeout "$read_timeout" dd bs=1 count=1024 <&3 >/dev/null 2>&1 || true
            printf "%s\r\n" "$command" >&3 || exit 1
            timeout "$read_timeout" dd bs=1 count=1024 <&3 2>/dev/null
        ' at-query "$port" "$command" "$read_timeout" |
        tr '\r' '\n' |
        awk 'NF { print }'
}

response_has_ok() {
    awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "OK") {
                    found = 1
                }
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

query_at_port() {
    port="$1"
    command="$2"

    response="$(at_port_response "$port" "$command")"

    if [ -n "$response" ]; then
        log "$port $command -> $(printf '%s' "$response" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
        printf '%s\n' "$response" | response_has_ok
        return "$?"
    fi

    log "$port $command -> no response"
    return 1
}

query_at_port_with_timeout() {
    port="$1"
    command="$2"
    read_timeout="$3"

    response="$(at_port_response "$port" "$command" "$read_timeout")"
    log_at_response "$port" "$command" "$response"

    if [ -n "$response" ]; then
        printf '%s\n' "$response" | response_has_ok
        return "$?"
    fi

    return 1
}

response_shows_registration() {
    grep -Eq '\+(CEREG|CREG|CGREG):[[:space:]]*[0-9]+,[[:space:]]*(1|5)([^0-9]|$)'
}

response_shows_attachment() {
    grep -Eq '\+CGATT:[[:space:]]*1([^0-9]|$)'
}

log_at_response() {
    port="$1"
    command="$2"
    response="$3"

    if [ -n "$response" ]; then
        log "$port $command -> $(printf '%s' "$response" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
    else
        log "$port $command -> no response"
    fi
}

wait_for_modem_registration() {
    port="$1"
    waited=0

    while [ "$waited" -le "$LTE_REGISTRATION_WAIT" ]; do
        cereg_response="$(at_port_response "$port" "AT+CEREG?")"
        log_at_response "$port" "AT+CEREG?" "$cereg_response"
        if printf '%s\n' "$cereg_response" | response_shows_registration; then
            log "Modem reports EPS/LTE registration on $port"
            return 0
        fi

        cgatt_response="$(at_port_response "$port" "AT+CGATT?")"
        log_at_response "$port" "AT+CGATT?" "$cgatt_response"
        if printf '%s\n' "$cgatt_response" | response_shows_attachment; then
            log "Modem reports packet attachment on $port"
            return 0
        fi

        waited=$((waited + 5))
        if [ "$waited" -le "$LTE_REGISTRATION_WAIT" ]; then
            sleep 5
        fi
    done

    log "Modem did not report network registration within ${LTE_REGISTRATION_WAIT}s"
    return 1
}

log_huawei_at_status() {
    ports="$(find_lte_serial_ports)"
    [ -n "$ports" ] || return 1

    for port in $ports; do
        log "Probing AT status on $port"
        stty -f "$port" 115200 cs8 -parenb -cstopb -echo >/dev/null 2>&1 || true
        query_at_port "$port" "AT" || continue
        write_at_port "$port" "ATE0" || true
        query_at_port "$port" "AT+CMEE=2" || true
        query_at_port "$port" "AT+CREG=2" || true
        query_at_port "$port" "AT+CGREG=2" || true
        query_at_port "$port" "AT+CEREG=2" || true
        query_at_port "$port" "AT+CPIN?" || true
        query_at_port "$port" "AT^SIMST?" || true
        query_at_port "$port" "AT^CARDLOCK?" || true
        query_at_port "$port" "AT+CFUN?" || true
        query_at_port "$port" "AT+CSQ" || true
        query_at_port "$port" "AT^HCSQ?" || true
        query_at_port "$port" "AT+CGDCONT?" || true
        query_at_port "$port" "AT+CGATT?" || true
        query_at_port "$port" "AT+CREG?" || true
        query_at_port "$port" "AT+CGREG?" || true
        query_at_port "$port" "AT+CEREG?" || true
        query_at_port "$port" "AT+COPS?" || true
        query_at_port "$port" "AT^SYSCFG?" || true
        query_at_port "$port" "AT^SYSCFGEX?" || true
        if [ "$LTE_OPERATOR_SCAN" != "0" ]; then
            query_at_port_with_timeout "$port" "AT+COPS=?" "$LTE_OPERATOR_SCAN_TIMEOUT" || true
        fi
        query_at_port "$port" "AT^SYSINFOEX" || true
        query_at_port "$port" "AT^NDISSTATQRY?" || true
        query_at_port "$port" "AT+CEER" || true
        return 0
    done

    return 1
}

configure_huawei_radio_profile_once() {
    [ -n "$LTE_SYSCFGEX_MODE" ] || return 0
    [ "$RADIO_PROFILE_DONE" -eq 0 ] || return 0

    ports="$(find_lte_serial_ports)"
    if [ -z "$ports" ]; then
        log "No /dev/cuaU* modem command ports found for radio profile setup"
        return 1
    fi

    for port in $ports; do
        log "Trying Huawei radio profile setup on $port"
        stty -f "$port" 115200 cs8 -parenb -cstopb -echo >/dev/null 2>&1 || true

        if ! query_at_port "$port" "AT"; then
            log "Could not write AT probe to $port for radio profile setup"
            continue
        fi

        query_at_port "$port" "AT+CMEE=2" || true
        query_at_port "$port" "AT^SYSCFGEX?" || true
        log "Setting Huawei SYSCFGEX mode '$LTE_SYSCFGEX_MODE' with broad band masks"
        query_at_port "$port" "AT^SYSCFGEX=\"$LTE_SYSCFGEX_MODE\",$LTE_SYSCFGEX_BAND,1,2,$LTE_SYSCFGEX_LTE_BAND,," || true
        query_at_port "$port" "AT^SYSCFGEX?" || true

        RADIO_PROFILE_DONE=1
        return 0
    done

    return 1
}

reset_huawei_radio_once() {
    [ "$LTE_RADIO_RESET_FIRST" != "0" ] || return 0
    [ "$RADIO_RESET_DONE" -eq 0 ] || return 0

    ports="$(find_lte_serial_ports)"
    if [ -z "$ports" ]; then
        log "No /dev/cuaU* modem command ports found for radio reset"
        return 1
    fi

    for port in $ports; do
        log "Trying Huawei radio reset on $port"
        stty -f "$port" 115200 cs8 -parenb -cstopb -echo >/dev/null 2>&1 || true

        if ! query_at_port "$port" "AT"; then
            log "Could not write AT probe to $port for radio reset"
            continue
        fi

        query_at_port "$port" "AT+CMEE=2" || true
        query_at_port "$port" "AT+CREG=2" || true
        query_at_port "$port" "AT+CGREG=2" || true
        query_at_port "$port" "AT+CEREG=2" || true
        query_at_port "$port" "AT+CFUN=0" || true
        sleep 3
        query_at_port "$port" "AT+CFUN=1" || true
        sleep 3
        query_at_port "$port" "AT+COPS=0" || true
        query_at_port "$port" "AT+COPS=0,2" || true
        log "Waiting ${LTE_POST_RADIO_RESET_WAIT}s after radio reset"
        sleep "$LTE_POST_RADIO_RESET_WAIT"

        query_at_port "$port" "AT+CSQ" || true
        query_at_port "$port" "AT^HCSQ?" || true
        wait_for_modem_registration "$port" || true
        query_at_port "$port" "AT+CEER" || true

        RADIO_RESET_DONE=1
        return 0
    done

    return 1
}

configure_huawei_pdp_context_once() {
    [ "$LTE_CONFIGURE_PDP_CONTEXT" != "0" ] || return 0
    [ "$PDP_CONTEXT_DONE" -eq 0 ] || return 0

    if [ -n "$LTE_APN" ]; then
        apn_list="$LTE_APN"
    else
        apn_list="$LTE_APN_CANDIDATES"
    fi

    [ -n "$apn_list" ] || return 0

    ports="$(find_lte_serial_ports)"
    if [ -z "$ports" ]; then
        log "No /dev/cuaU* modem command ports found for PDP context setup"
        return 1
    fi

    for port in $ports; do
        log "Trying Huawei PDP context setup on $port"
        stty -f "$port" 115200 cs8 -parenb -cstopb -echo >/dev/null 2>&1 || true

        if ! query_at_port "$port" "AT"; then
            log "Could not write AT probe to $port for PDP context setup"
            continue
        fi

        query_at_port "$port" "AT+CMEE=2" || true
        for apn in $apn_list; do
            log "Setting PDP context 1 APN to '$apn'"
            query_at_port "$port" "AT+CGDCONT=1,\"IP\",\"$apn\"" || true
            query_at_port "$port" "AT+CGDCONT?" || true
            query_at_port "$port" "AT+CGATT=1" || true
            query_at_port "$port" "AT+CEER" || true
            sleep 3
            query_at_port "$port" "AT+CGATT?" || true
            query_at_port "$port" "AT+CEREG?" || true
            query_at_port "$port" "AT+CEER" || true
            break
        done

        PDP_CONTEXT_DONE=1
        return 0
    done

    return 1
}

send_huawei_serial_connect() {
    ports="$(find_lte_serial_ports)"
    if [ -z "$ports" ]; then
        log "No /dev/cuaU* modem command ports found for serial AT init"
        return 1
    fi

    if [ -n "$LTE_APN" ]; then
        log "Sending Huawei serial AT connect commands using APN from LTE_APN"
    else
        log "Sending Huawei serial AT connect commands without explicit APN"
        log "Set LTE_APN if the SIM requires a provider APN"
    fi

    ndis_command="$(build_huawei_ndis_command "$LTE_APN")"
    sent=1

    for port in $ports; do
        log "Trying serial AT init on $port"
        stty -f "$port" 115200 cs8 -parenb -cstopb -echo >/dev/null 2>&1 || true

        if ! query_at_port "$port" "AT"; then
            log "Could not write AT probe to $port"
            continue
        fi

        write_at_port "$port" "ATE0" || true
        sleep 1
        write_at_port "$port" "ATZ" || true
        sleep 1
        write_at_port "$port" "ATQ0 V1 E1" || true
        sleep 1
        write_at_port "$port" "AT+CFUN=1" || true
        sleep 1
        write_at_port "$port" "AT+COPS=0" || true
        sleep 1
        wait_for_modem_registration "$port" || true

        if [ -n "$LTE_APN" ]; then
            write_at_port "$port" "AT+CGDCONT=1,\"IP\",\"$LTE_APN\"" || true
            sleep 1
        fi

        write_at_port "$port" "AT+CGATT=1" || true
        sleep 1
        write_at_port "$port" "$ndis_command" || true
        sent=0
        sleep 1

        query_at_port "$port" "AT+CGATT?" || true
        query_at_port "$port" "AT+CREG?" || true
        query_at_port "$port" "AT+CEREG?" || true
        query_at_port "$port" "AT^NDISSTATQRY?" || true

        if lte_interface_has_carrier || lte_interface_has_ipv4; then
            log "$LTE_IFACE responded after serial AT init on $port"
            return 0
        fi
    done

    return "$sent"
}

at_command_to_usb_bytes() {
    command="$1"

    printf '%s\r\n' "$command" |
        od -An -tx1 -v |
        awk '
            {
                for (i = 1; i <= NF; i++) {
                    printf " 0x%s", $i
                    count++
                }
            }
            END {
                printf "\n%d\n", count
            }
        '
}

send_huawei_ndis_connect() {
    lte_dev="$1"

    if [ -n "$LTE_APN" ]; then
        apn_list="$LTE_APN"
        log "Sending Huawei NDIS connect command using APN from LTE_APN"
    else
        apn_list="__none__ $LTE_APN_CANDIDATES"
        log "Sending Huawei NDIS connect commands without APN, then APN candidates: $LTE_APN_CANDIDATES"
    fi

    tried=" "
    accepted=0

    ifconfig "$LTE_IFACE" up 2>/dev/null || true

    if [ "$LTE_NDIS_DISCONNECT_FIRST" != "0" ]; then
        disconnect_command="AT^NDISDUP=1,0"
        encoded="$(at_command_to_usb_bytes "$disconnect_command")"
        byte_args="$(printf '%s\n' "$encoded" | sed -n '1p')"
        byte_count="$(printf '%s\n' "$encoded" | sed -n '2p')"

        for request_index in $LTE_NDIS_INDEXES; do
            log "Sending NDIS disconnect on USB interface index $request_index"
            # shellcheck disable=SC2086
            usbconfig -d "$lte_dev" -i 0 do_request 0x21 0 0 "$request_index" "$byte_count" $byte_args >/dev/null 2>&1 || true
        done
        sleep 1
    fi

    for apn in $apn_list; do
        if [ "$apn" = "__none__" ]; then
            ndis_command="$(build_huawei_ndis_command "")"
            ndis_label="without explicit APN"
        else
            ndis_command="$(build_huawei_ndis_command "$apn")"
            ndis_label="with APN '$apn'"
        fi

        encoded="$(at_command_to_usb_bytes "$ndis_command")"
        byte_args="$(printf '%s\n' "$encoded" | sed -n '1p')"
        byte_count="$(printf '%s\n' "$encoded" | sed -n '2p')"

        for request_index in $LTE_NDIS_INDEXES; do
            case "$tried" in
                *" $request_index:$apn "*) continue ;;
            esac
            tried="$tried$request_index:$apn "

            log "Trying NDIS connect control request on USB interface index $request_index $ndis_label"
            # shellcheck disable=SC2086
            if usbconfig -d "$lte_dev" -i 0 do_request 0x21 0 0 "$request_index" "$byte_count" $byte_args >/dev/null 2>&1; then
                log "NDIS connect request accepted on USB interface index $request_index $ndis_label"
                accepted=1
                if wait_for_lte_carrier; then
                    log "$LTE_IFACE got carrier after NDIS connect on USB interface index $request_index $ndis_label"
                    return 0
                fi
                log "$LTE_IFACE still has status: $(lte_interface_status)"
            fi
        done
    done

    if [ "$accepted" -eq 1 ]; then
        log "NDIS connect was accepted but $LTE_IFACE did not report carrier"
        return 0
    fi

    log "NDIS connect control request was not accepted"
    return 1
}

switch_huawei_lte_device() {
    lte_dev="$(find_lte_device || true)"
    if [ -n "$lte_dev" ]; then
        log "Found HUAWEIMOBILE USB device at $lte_dev"
        mode_vendor="$(get_usb_field "$lte_dev" idVendor || true)"
        mode_product="$(get_usb_field "$lte_dev" idProduct || true)"
        if [ -n "$mode_vendor" ] && [ -n "$mode_product" ]; then
            log "Current Huawei USB ID is ${mode_vendor}:${mode_product}"
        fi
    fi

    if [ -z "$lte_dev" ]; then
        log "No HUAWEIMOBILE USB device found"
        return 1
    fi

    lte_mode="$(detect_lte_usb_mode "$lte_dev")"
    log "Current LTE USB mode appears to be: $lte_mode"
    if [ "$lte_mode" = "ethernet-active" ] || [ "$lte_mode" = "ncm-active" ]; then
        log "$LTE_IFACE is already active; dongle is in network mode"
        return 0
    fi

    if [ "$lte_mode" = "ethernet-no-carrier" ] || [ "$lte_mode" = "ncm-no-carrier" ]; then
        log "$LTE_IFACE already exists but has status: $(lte_interface_status)"
        if [ "$lte_mode" = "ncm-no-carrier" ]; then
            log "Skipping usb_modeswitch because the device is already in NCM mode"
            return 0
        fi
        log "Will try the Huawei mode-switch command again before DHCP"
    fi

    if [ "$lte_mode" = "interface" ] || [ "$lte_mode" = "ncm" ]; then
        log "USB device already exposes a network-style interface; waiting for $LTE_IFACE"
        if wait_for_lte_interface; then
            log "$LTE_IFACE is present; dongle is in network mode"
            return 0
        fi
        log "$LTE_IFACE did not appear even though the USB device looks interface-capable"
    fi

    mode_vendor="$(get_usb_field "$lte_dev" idVendor || true)"
    mode_product="$(get_usb_field "$lte_dev" idProduct || true)"
    if [ -z "$mode_vendor" ] || [ -z "$mode_product" ]; then
        log "Could not read USB vendor/product IDs for $lte_dev"
        return 1
    fi

    log "Sending Huawei mode-switch command for $lte_dev ($mode_vendor:$mode_product)"
    if ! usb_modeswitch -v "$mode_vendor" -p "$mode_product" -J; then
        log "usb_modeswitch exited non-zero; checking whether the device re-enumerated anyway"
    fi

    sleep 3
    if wait_for_lte_interface; then
        log "$LTE_IFACE appeared after mode switch"
        return 0
    fi

    log "$LTE_IFACE did not appear after mode switch"
    return 1
}

configure_freebsd_networking() {
    log "Persisting LTE mode-switch and DHCP interface settings"
    choose_lte_interface || log "No ue* interface is visible yet; configuring expected interface $LTE_IFACE"
    ensure_dhclient_ignores_routers "$LTE_IFACE"
    sysrc usb_modeswitch_enable=YES
    sysrc ifconfig_"$LTE_IFACE"="DHCP"

    if [ "$NETWORKING_CONFIGURED_IFACE" = "$LTE_IFACE" ]; then
        log "devd has already been restarted for $LTE_IFACE in this run"
        return
    fi

    service devd restart
    NETWORKING_CONFIGURED_IFACE="$LTE_IFACE"
}

run_dhclient_once() {
    clear_lte_static_test_address

    pidfile="/var/run/dhclient/dhclient.$LTE_IFACE.pid"
    if [ -f "$pidfile" ]; then
        dhclient -r "$LTE_IFACE" >/dev/null 2>&1 || true
    fi

    dhclient "$LTE_IFACE" &
    dhclient_pid="$!"
    n=0
    while kill -0 "$dhclient_pid" >/dev/null 2>&1; do
        if lte_interface_has_dhcp_ipv4; then
            wait "$dhclient_pid" >/dev/null 2>&1 || true
            return 0
        fi

        n=$((n + 1))
        if [ "$n" -ge 8 ]; then
            kill "$dhclient_pid" >/dev/null 2>&1 || true
            wait "$dhclient_pid" >/dev/null 2>&1 || true
            return 1
        fi
        sleep 1
    done

    wait "$dhclient_pid" >/dev/null 2>&1 || true
    n=0
    while [ "$n" -lt 5 ]; do
        if lte_interface_has_dhcp_ipv4; then
            return 0
        fi
        n=$((n + 1))
        sleep 1
    done
    return 1
}

try_lte_static_ping() {
    if ! wait_for_lte_interface; then
        return 1
    fi

    log "Trying static test address 192.168.8.2/24 on $LTE_IFACE"
    clear_lte_static_test_address
    ifconfig "$LTE_IFACE" inet 192.168.8.2 netmask 255.255.255.0 alias >/dev/null 2>&1 ||
        ifconfig "$LTE_IFACE" inet 192.168.8.2 netmask 255.255.255.0 >/dev/null 2>&1 ||
        return 1

    if ping -c 1 -S 192.168.8.2 192.168.8.1 >/dev/null 2>&1; then
        return 0
    fi

    clear_lte_static_test_address
    return 1
}

bring_lte_network_up() {
    lte_dev="$(find_lte_device || true)"
    if ! lte_interface_is_present; then
        log "$LTE_IFACE is not present; skipping network bring-up"
        return 1
    fi

    if [ -n "$lte_dev" ] && lte_usb_uses_ncm "$lte_dev"; then
        configure_huawei_radio_profile_once || true
        reset_huawei_radio_once || true
        configure_huawei_pdp_context_once || true
        send_huawei_ndis_connect "$lte_dev" || true
        sleep 1
        lte_dev="$(find_lte_device || true)"

        if [ "$LTE_ENABLE_AT_STATUS" != "0" ]; then
            log_huawei_at_status || true
        fi

        if [ "$LTE_ENABLE_SERIAL_FALLBACK" != "0" ]; then
            send_huawei_serial_connect || true
            sleep 1
            lte_dev="$(find_lte_device || true)"
            if [ -n "$lte_dev" ]; then
                send_huawei_ndis_connect "$lte_dev" || true
            else
                log "Huawei USB device is not visible after serial init; will rediscover on next attempt"
            fi
        fi
        sleep 1
    fi

    if ! wait_for_lte_interface; then
        log "No ue* interface is present after modem init"
        return 1
    fi

    log "Bringing $LTE_IFACE up"
    if ! ifconfig "$LTE_IFACE" up; then
        log "Could not bring $LTE_IFACE up"
        return 1
    fi

    if ! lte_interface_has_carrier; then
        log "$LTE_IFACE status is $(lte_interface_status); trying DHCP anyway"
    fi

    log "Requesting DHCP lease on $LTE_IFACE so ignore routers applies now"
    if run_dhclient_once; then
        log "$LTE_IFACE received an IPv4 DHCP lease"
        return 0
    fi

    log "$LTE_IFACE did not get an IPv4 DHCP lease"
    if try_lte_static_ping; then
        log "Static 192.168.8.2/24 ping to 192.168.8.1 succeeded"
        return 0
    fi

    log "Static 192.168.8.2/24 ping to 192.168.8.1 failed"
    return 1
}

attempt_lte_setup() {
    attempt=1

    while [ "$attempt" -le "$LTE_MAX_ATTEMPTS" ]; do
        log "LTE discovery attempt $attempt of $LTE_MAX_ATTEMPTS"
        clear_lte_static_test_address
        log_lte_snapshot

        if ! switch_huawei_lte_device; then
            log "Mode/session preparation did not complete on attempt $attempt"
        fi

        configure_freebsd_networking

        if bring_lte_network_up; then
            return 0
        fi

        log "LTE attempt $attempt did not produce a usable DHCP lease"
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$LTE_MAX_ATTEMPTS" ]; then
            log "Rediscovering after USB/modem state settles"
            sleep 3
        fi
    done

    return 1
}

main() {
    require_root
    require_command pkg
    require_command usbconfig
    require_command ifconfig
    require_command sysrc
    require_command service
    require_command od
    require_command stty
    require_command timeout

    ensure_usb_modeswitch_package

    if attempt_lte_setup; then
        log "Huawei LTE setup complete"
        log "Check with: ifconfig $LTE_IFACE; netstat -rn"
        return 0
    fi

    die "$LTE_IFACE is not ready after $LTE_MAX_ATTEMPTS discovery attempts"
}

main "$@"
