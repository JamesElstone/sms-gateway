#!/bin/sh
set -eu

USB_DEVICE_NAME="huaweimobile"
LTE_IFACE="ue0"
LTE_APN="${LTE_APN:-}"
LTE_AT_PORT="${LTE_AT_PORT:-}"
DHCPCONF="/etc/dhclient.conf"

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

dhclient_has_ignore_routers() {
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
    if [ ! -f "$DHCPCONF" ]; then
        log "Creating $DHCPCONF"
        : > "$DHCPCONF"
    fi

    if dhclient_has_ignore_routers; then
        log "$DHCPCONF already contains an ignore routers setting"
        return
    fi

    log "Adding DHCP router suppression for $LTE_IFACE to $DHCPCONF"
    cat >> "$DHCPCONF" <<EOF

# Added by install-huawei-lte.sh for the Huawei LTE HiLink interface.
interface "$LTE_IFACE" {
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

lte_interface_is_present() {
    ifconfig "$LTE_IFACE" >/dev/null 2>&1
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
    while [ "$n" -lt 15 ]; do
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
    while [ "$n" -lt 30 ]; do
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
    while [ "$n" -lt 30 ]; do
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

    for port in "$LTE_AT_PORT" /dev/cuaU1 /dev/cuaU0 /dev/cuaU2 /dev/cuaU3 /dev/cuaU4; do
        [ -n "$port" ] || continue
        [ -c "$port" ] || continue

        case "$emitted" in
            *" $port "*) continue ;;
        esac

        emitted="$emitted$port "
        printf '%s\n' "$port"
    done
}

build_huawei_ndis_command() {
    if [ -n "$LTE_APN" ]; then
        printf 'AT^NDISDUP=1,1,"%s"\n' "$LTE_APN"
    else
        printf '%s\n' "AT^NDISDUP=1,1"
    fi
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

    ndis_command="$(build_huawei_ndis_command)"
    sent=1

    for port in $ports; do
        log "Trying serial AT init on $port"
        stty -f "$port" 115200 cs8 -parenb -cstopb -echo >/dev/null 2>&1 || true

        if ! printf 'AT\r\n' > "$port"; then
            log "Could not write AT probe to $port"
            continue
        fi
        sleep 1

        printf 'ATZ\r\n' > "$port" || true
        sleep 1
        printf 'ATQ0 V1 E1\r\n' > "$port" || true
        sleep 1

        if [ -n "$LTE_APN" ]; then
            printf 'AT+CGDCONT=1,"IP","%s"\r\n' "$LTE_APN" > "$port" || true
            sleep 1
        fi

        printf '%s\r\n' "$ndis_command" > "$port" || true
        sent=0
        sleep 3

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
        ndis_command="AT^NDISDUP=1,1,\"$LTE_APN\""
        log "Sending Huawei NDIS connect command using APN from LTE_APN"
    else
        ndis_command="AT^NDISDUP=1,1"
        log "Sending Huawei NDIS connect command without explicit APN"
    fi

    encoded="$(at_command_to_usb_bytes "$ndis_command")"
    byte_args="$(printf '%s\n' "$encoded" | sed -n '1p')"
    byte_count="$(printf '%s\n' "$encoded" | sed -n '2p')"
    ncm_iface="$(get_ncm_control_interface "$lte_dev" || true)"
    tried=" "
    accepted=0

    ifconfig "$LTE_IFACE" up 2>/dev/null || true

    for request_index in 2 $ncm_iface 3 0; do
        case "$tried" in
            *" $request_index "*) continue ;;
        esac
        tried="$tried$request_index "

        log "Trying NDIS connect control request on USB interface index $request_index"
        # shellcheck disable=SC2086
        if usbconfig -d "$lte_dev" -i 0 do_request 0x21 0 0 "$request_index" "$byte_count" $byte_args >/dev/null 2>&1; then
            log "NDIS connect request accepted on USB interface index $request_index"
            accepted=1
            if wait_for_lte_carrier; then
                log "$LTE_IFACE got carrier after NDIS connect on USB interface index $request_index"
                return 0
            fi
            log "$LTE_IFACE still has status: $(lte_interface_status)"
        fi
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
    sysrc usb_modeswitch_enable=YES
    sysrc ifconfig_"$LTE_IFACE"="DHCP"
    service devd restart
}

renew_lte_dhcp() {
    lte_dev="$(find_lte_device || true)"
    if ! lte_interface_is_present; then
        log "$LTE_IFACE is not present; skipping DHCP renewal"
        return 1
    fi

    if [ -n "$lte_dev" ] && lte_usb_uses_ncm "$lte_dev"; then
        send_huawei_serial_connect || true
        send_huawei_ndis_connect "$lte_dev" || true
        sleep 3
    fi

    log "Bringing $LTE_IFACE up"
    ifconfig "$LTE_IFACE" up

    if ! lte_interface_has_carrier; then
        log "$LTE_IFACE status is $(lte_interface_status); trying DHCP anyway"
    fi

    log "Requesting DHCP lease on $LTE_IFACE so ignore routers applies now"
    pidfile="/var/run/dhclient/dhclient.$LTE_IFACE.pid"
    if [ -f "$pidfile" ]; then
        dhclient -r "$LTE_IFACE" >/dev/null 2>&1 || true
    fi
    dhclient "$LTE_IFACE"

    if ! wait_for_lte_ipv4; then
        log "$LTE_IFACE has carrier but did not get an IPv4 DHCP lease"
        return 1
    fi

    return 0
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

    ensure_dhclient_ignores_routers
    ensure_usb_modeswitch_package

    if switch_huawei_lte_device; then
        configure_freebsd_networking
        if ! renew_lte_dhcp; then
            die "$LTE_IFACE is not ready after configuration"
        fi
        log "Huawei LTE setup complete"
        log "Check with: ifconfig $LTE_IFACE; netstat -rn"
        return 0
    fi

    die "mode switch was not confirmed; leaving sysrc/devd networking changes unapplied"
}

main "$@"
