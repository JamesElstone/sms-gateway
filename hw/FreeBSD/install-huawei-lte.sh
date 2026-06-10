#!/bin/sh
set -eu

USB_DEVICE_NAME="huaweimobile"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
LTE_TARGET_MODE="${LTE_TARGET_MODE:-hilink}"
LTE_IFACE="${LTE_IFACE:-ue0}"
LTE_APN="${LTE_APN:-}"
LTE_AT_PORT="${LTE_AT_PORT:-}"
LTE_MAX_ATTEMPTS="${LTE_MAX_ATTEMPTS:-1}"
LTE_ENABLE_SERIAL_FALLBACK="${LTE_ENABLE_SERIAL_FALLBACK:-0}"
LTE_ENABLE_AT_STATUS="${LTE_ENABLE_AT_STATUS:-0}"
LTE_AT_READ_TIMEOUT="${LTE_AT_READ_TIMEOUT:-1}"
LTE_NDIS_INDEXES="${LTE_NDIS_INDEXES:-2}"
LTE_NDIS_DISCONNECT_FIRST="${LTE_NDIS_DISCONNECT_FIRST:-1}"
LTE_REGISTRATION_WAIT="${LTE_REGISTRATION_WAIT:-30}"
LTE_APN_CANDIDATES="${LTE_APN_CANDIDATES:-internet}"
LTE_OPERATOR_SCAN="${LTE_OPERATOR_SCAN:-0}"
LTE_OPERATOR_SCAN_TIMEOUT="${LTE_OPERATOR_SCAN_TIMEOUT:-70}"
LTE_RADIO_RESET_FIRST="${LTE_RADIO_RESET_FIRST:-1}"
LTE_POST_RADIO_RESET_WAIT="${LTE_POST_RADIO_RESET_WAIT:-5}"
LTE_CONFIGURE_PDP_CONTEXT="${LTE_CONFIGURE_PDP_CONTEXT:-1}"
LTE_DEREGISTER_FIRST="${LTE_DEREGISTER_FIRST:-1}"
LTE_SYSCFGEX_MODE="${LTE_SYSCFGEX_MODE:-03}"
LTE_SYSCFGEX_BAND="${LTE_SYSCFGEX_BAND:-3FFFFFFF}"
LTE_SYSCFGEX_LTE_BAND="${LTE_SYSCFGEX_LTE_BAND:-7FFFFFFFFFFFFFFF}"
LTE_STORAGE_AT_RECOVERY="${LTE_STORAGE_AT_RECOVERY:-1}"
LTE_STORAGE_SETPORT_VALUE="${LTE_STORAGE_SETPORT_VALUE:-A1,A2;10,12,13,16}"
LTE_STORAGE_U2DIAG_VALUE="${LTE_STORAGE_U2DIAG_VALUE:-255}"
LTE_LOG_FILE="${LTE_LOG_FILE:-/tmp/install-huawei-lte.log}"
USB_MODESWITCH_CONF="${USB_MODESWITCH_CONF:-/usr/local/etc/usb_modeswitch.conf}"
SMS_GATEWAY_DEVICE_TYPE="${SMS_GATEWAY_DEVICE_TYPE:-huawei-lte}"
SMS_GATEWAY_RC_SOURCE="${SMS_GATEWAY_RC_SOURCE:-$SCRIPT_DIR/rc.d/sms_gateway}"
SMS_GATEWAY_RC_DEST="${SMS_GATEWAY_RC_DEST:-/usr/local/etc/rc.d/sms_gateway}"
HUAWEI_VENDOR_ID="0x12d1"
HUAWEI_STORAGE_PRODUCT_ID="0x1f01"
HUAWEI_NCM_PRODUCT_ID="0x155e"
HUAWEI_HILINK_PRODUCT_IDS="0x14db 0x14dc"
HUAWEI_HILINK_MODESWITCH_CONFIG="/usr/local/share/usb_modeswitch/12d1:1f01"
DHCPCONF="/etc/dhclient.conf"
NETWORKING_CONFIGURED_IFACE=""
RADIO_RESET_DONE=0
PDP_CONTEXT_DONE=0
RADIO_PROFILE_DONE=0
STATUS_ONLY=0
STORAGE_REBOOT_REQUIRED=0

log_file() {
    timestamp="$(date '+[%d/%m/%Y %H:%M]' 2>/dev/null || printf '[unknown time]')"
    printf '%s %s\n' "$timestamp" "$*" 2>/dev/null >> "$LTE_LOG_FILE" || true
}

log() {
    printf '%s\n' "$*"
    log_file "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    log_file "ERROR: $*"
    exit 1
}

usage() {
    prog="${0##*/}"

    cat <<EOF
Usage:
  $prog [--target storage|hilink|ncm] [options]
  $prog storage|hilink|ncm [options]

Targets:
  hilink   Switch storage-mode Huawei dongles to HiLink 14db/14dc and test ue0.
           This is the default.
  storage  Disable automatic usb_modeswitch and switch/catch 12d1:1f01 storage mode.
           If the dongle is already switched, reboot hydrogen after running this.
  ncm      Use the older NCM/serial attach path for 12d1:155e.

Common options:
  -h, --help                       Show this help text.
      --status                     Show current Huawei USB/network state and exit.
      --target MODE                Set target mode: storage, hilink, or ncm.
      --iface IFACE                USB ethernet interface name. Default: $LTE_IFACE.
      --max-attempts N             Discovery attempts. Default: $LTE_MAX_ATTEMPTS.
      --log-file PATH              Log file. Default: $LTE_LOG_FILE.

Persistence:
  Successful target runs install rc.d/sms_gateway and persist:
      sms_gateway_enable=YES
      sms_gateway_device_type=$SMS_GATEWAY_DEVICE_TYPE
      sms_gateway_target=<target>

NCM/radio options:
      --apn APN                    APN for NCM attach.
      --apn-candidates LIST        Space-separated APN fallback list. Default: $LTE_APN_CANDIDATES.
      --at-port PATH               Prefer a specific /dev/cuaU* AT command port.
      --at-read-timeout SECONDS    AT read timeout. Default: $LTE_AT_READ_TIMEOUT.
      --registration-wait SECONDS  Registration wait. Default: $LTE_REGISTRATION_WAIT.
      --ndis-indexes LIST          USB interface indexes for NDIS control. Default: $LTE_NDIS_INDEXES.
      --ndis-disconnect-first      Send NDIS disconnect before connect.
      --no-ndis-disconnect-first   Skip NDIS disconnect before connect.
      --enable-serial-fallback     Try serial AT NDIS fallback.
      --disable-serial-fallback    Do not try serial AT NDIS fallback.
      --enable-at-status           Log extended AT modem status.
      --disable-at-status          Do not log extended AT modem status.
      --operator-scan              Run AT+COPS=? operator scan.
      --no-operator-scan           Do not run AT+COPS=? operator scan.
      --operator-scan-timeout N    Operator scan timeout. Default: $LTE_OPERATOR_SCAN_TIMEOUT.
      --radio-reset                Reset modem radio before NCM attach.
      --no-radio-reset             Skip modem radio reset.
      --post-radio-reset-wait N    Wait after radio reset. Default: $LTE_POST_RADIO_RESET_WAIT.
      --pdp-context                Configure PDP context before NCM attach.
      --no-pdp-context             Skip PDP context configuration.
      --deregister-first           Deregister before automatic registration.
      --no-deregister-first        Skip deregistration.
      --syscfgex-mode MODE         Huawei SYSCFGEX mode. Default: $LTE_SYSCFGEX_MODE.
      --syscfgex-band MASK         Huawei SYSCFGEX band mask. Default: $LTE_SYSCFGEX_BAND.
      --syscfgex-lte-band MASK     Huawei SYSCFGEX LTE band mask. Default: $LTE_SYSCFGEX_LTE_BAND.

Storage recovery options:
      --storage-at-recovery        Try Huawei AT storage recovery commands.
      --no-storage-at-recovery     Skip Huawei AT storage recovery commands.
      --storage-setport VALUE      SETPORT value. Default: $LTE_STORAGE_SETPORT_VALUE.
      --storage-u2diag VALUE       U2DIAG value. Default: $LTE_STORAGE_U2DIAG_VALUE.

Environment:
  LTE_* environment variables are still supported as defaults. Command-line
  options override environment values.
EOF
}

usage_error() {
    printf 'ERROR: %s\n\n' "$*" >&2
    usage >&2
    exit 2
}

parse_args() {
    cli_target_seen=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --status)
                STATUS_ONLY=1
                shift
                ;;
            --target)
                [ "$#" -ge 2 ] || usage_error "missing value for --target"
                LTE_TARGET_MODE="$2"
                cli_target_seen=1
                shift 2
                ;;
            --target=*)
                LTE_TARGET_MODE="${1#--target=}"
                cli_target_seen=1
                shift
                ;;
            --iface)
                [ "$#" -ge 2 ] || usage_error "missing value for --iface"
                LTE_IFACE="$2"
                shift 2
                ;;
            --iface=*)
                LTE_IFACE="${1#--iface=}"
                shift
                ;;
            --max-attempts)
                [ "$#" -ge 2 ] || usage_error "missing value for --max-attempts"
                LTE_MAX_ATTEMPTS="$2"
                shift 2
                ;;
            --max-attempts=*)
                LTE_MAX_ATTEMPTS="${1#--max-attempts=}"
                shift
                ;;
            --log-file)
                [ "$#" -ge 2 ] || usage_error "missing value for --log-file"
                LTE_LOG_FILE="$2"
                shift 2
                ;;
            --log-file=*)
                LTE_LOG_FILE="${1#--log-file=}"
                shift
                ;;
            --apn)
                [ "$#" -ge 2 ] || usage_error "missing value for --apn"
                LTE_APN="$2"
                shift 2
                ;;
            --apn=*)
                LTE_APN="${1#--apn=}"
                shift
                ;;
            --apn-candidates)
                [ "$#" -ge 2 ] || usage_error "missing value for --apn-candidates"
                LTE_APN_CANDIDATES="$2"
                shift 2
                ;;
            --apn-candidates=*)
                LTE_APN_CANDIDATES="${1#--apn-candidates=}"
                shift
                ;;
            --at-port)
                [ "$#" -ge 2 ] || usage_error "missing value for --at-port"
                LTE_AT_PORT="$2"
                shift 2
                ;;
            --at-port=*)
                LTE_AT_PORT="${1#--at-port=}"
                shift
                ;;
            --at-read-timeout)
                [ "$#" -ge 2 ] || usage_error "missing value for --at-read-timeout"
                LTE_AT_READ_TIMEOUT="$2"
                shift 2
                ;;
            --at-read-timeout=*)
                LTE_AT_READ_TIMEOUT="${1#--at-read-timeout=}"
                shift
                ;;
            --registration-wait)
                [ "$#" -ge 2 ] || usage_error "missing value for --registration-wait"
                LTE_REGISTRATION_WAIT="$2"
                shift 2
                ;;
            --registration-wait=*)
                LTE_REGISTRATION_WAIT="${1#--registration-wait=}"
                shift
                ;;
            --ndis-indexes)
                [ "$#" -ge 2 ] || usage_error "missing value for --ndis-indexes"
                LTE_NDIS_INDEXES="$2"
                shift 2
                ;;
            --ndis-indexes=*)
                LTE_NDIS_INDEXES="${1#--ndis-indexes=}"
                shift
                ;;
            --ndis-disconnect-first)
                LTE_NDIS_DISCONNECT_FIRST=1
                shift
                ;;
            --no-ndis-disconnect-first)
                LTE_NDIS_DISCONNECT_FIRST=0
                shift
                ;;
            --enable-serial-fallback)
                LTE_ENABLE_SERIAL_FALLBACK=1
                shift
                ;;
            --disable-serial-fallback)
                LTE_ENABLE_SERIAL_FALLBACK=0
                shift
                ;;
            --enable-at-status)
                LTE_ENABLE_AT_STATUS=1
                shift
                ;;
            --disable-at-status)
                LTE_ENABLE_AT_STATUS=0
                shift
                ;;
            --operator-scan)
                LTE_OPERATOR_SCAN=1
                shift
                ;;
            --no-operator-scan)
                LTE_OPERATOR_SCAN=0
                shift
                ;;
            --operator-scan-timeout)
                [ "$#" -ge 2 ] || usage_error "missing value for --operator-scan-timeout"
                LTE_OPERATOR_SCAN_TIMEOUT="$2"
                shift 2
                ;;
            --operator-scan-timeout=*)
                LTE_OPERATOR_SCAN_TIMEOUT="${1#--operator-scan-timeout=}"
                shift
                ;;
            --radio-reset)
                LTE_RADIO_RESET_FIRST=1
                shift
                ;;
            --no-radio-reset)
                LTE_RADIO_RESET_FIRST=0
                shift
                ;;
            --post-radio-reset-wait)
                [ "$#" -ge 2 ] || usage_error "missing value for --post-radio-reset-wait"
                LTE_POST_RADIO_RESET_WAIT="$2"
                shift 2
                ;;
            --post-radio-reset-wait=*)
                LTE_POST_RADIO_RESET_WAIT="${1#--post-radio-reset-wait=}"
                shift
                ;;
            --pdp-context)
                LTE_CONFIGURE_PDP_CONTEXT=1
                shift
                ;;
            --no-pdp-context)
                LTE_CONFIGURE_PDP_CONTEXT=0
                shift
                ;;
            --deregister-first)
                LTE_DEREGISTER_FIRST=1
                shift
                ;;
            --no-deregister-first)
                LTE_DEREGISTER_FIRST=0
                shift
                ;;
            --syscfgex-mode)
                [ "$#" -ge 2 ] || usage_error "missing value for --syscfgex-mode"
                LTE_SYSCFGEX_MODE="$2"
                shift 2
                ;;
            --syscfgex-mode=*)
                LTE_SYSCFGEX_MODE="${1#--syscfgex-mode=}"
                shift
                ;;
            --syscfgex-band)
                [ "$#" -ge 2 ] || usage_error "missing value for --syscfgex-band"
                LTE_SYSCFGEX_BAND="$2"
                shift 2
                ;;
            --syscfgex-band=*)
                LTE_SYSCFGEX_BAND="${1#--syscfgex-band=}"
                shift
                ;;
            --syscfgex-lte-band)
                [ "$#" -ge 2 ] || usage_error "missing value for --syscfgex-lte-band"
                LTE_SYSCFGEX_LTE_BAND="$2"
                shift 2
                ;;
            --syscfgex-lte-band=*)
                LTE_SYSCFGEX_LTE_BAND="${1#--syscfgex-lte-band=}"
                shift
                ;;
            --storage-at-recovery)
                LTE_STORAGE_AT_RECOVERY=1
                shift
                ;;
            --no-storage-at-recovery)
                LTE_STORAGE_AT_RECOVERY=0
                shift
                ;;
            --storage-setport)
                [ "$#" -ge 2 ] || usage_error "missing value for --storage-setport"
                LTE_STORAGE_SETPORT_VALUE="$2"
                shift 2
                ;;
            --storage-setport=*)
                LTE_STORAGE_SETPORT_VALUE="${1#--storage-setport=}"
                shift
                ;;
            --storage-u2diag)
                [ "$#" -ge 2 ] || usage_error "missing value for --storage-u2diag"
                LTE_STORAGE_U2DIAG_VALUE="$2"
                shift 2
                ;;
            --storage-u2diag=*)
                LTE_STORAGE_U2DIAG_VALUE="${1#--storage-u2diag=}"
                shift
                ;;
            storage|hilink|ncm)
                [ "$cli_target_seen" -eq 0 ] || usage_error "target specified more than once"
                LTE_TARGET_MODE="$1"
                cli_target_seen=1
                shift
                ;;
            --)
                shift
                [ "$#" -eq 0 ] || usage_error "unexpected argument after --: $1"
                ;;
            -*)
                usage_error "unknown option: $1"
                ;;
            *)
                usage_error "unexpected argument: $1"
                ;;
        esac
    done

    case "$LTE_TARGET_MODE" in
        storage|hilink|ncm) ;;
        *)
            usage_error "unsupported target: $LTE_TARGET_MODE (expected storage, hilink, or ncm)"
            ;;
    esac
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "run this script as root"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

run_usbconfig() {
    if [ "$(id -u)" -eq 0 ]; then
        usbconfig "$@"
        return "$?"
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo -n /usr/sbin/usbconfig "$@" 2>/dev/null && return 0
    fi

    usbconfig "$@"
}

run_sysrc_read() {
    if [ "$(id -u)" -eq 0 ]; then
        sysrc "$@"
        return "$?"
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo -n /usr/sbin/sysrc "$@" 2>/dev/null && return 0
    fi

    sysrc "$@"
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

    run_usbconfig -d "$dev" dump_device_desc 2>/dev/null |
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

    run_usbconfig |
        awk -F: -v dev="$dev" '$1 == dev { print; exit }'
}

get_usb_description() {
    dev="$1"

    get_usb_summary "$dev" |
        sed -n 's/^[^<]*\(<.*>\) at .*/\1/p'
}

get_usb_config_desc() {
    dev="$1"

    run_usbconfig -d "$dev" dump_curr_config_desc 2>/dev/null ||
        run_usbconfig -d "$dev" dump_all_config_desc 2>/dev/null ||
        true
}

list_usb_devices() {
    run_usbconfig | awk -F: '$1 ~ /^ugen[0-9][0-9]*\.[0-9][0-9]*$/ { print $1 }'
}

find_lte_device_from_summary() {
    run_usbconfig |
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

    run_usbconfig -d "$dev" dump_device_desc 2>/dev/null |
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

find_lte_device_from_vendor_id() {
    list_usb_devices |
        while IFS= read -r dev; do
            if [ "$(get_usb_field "$dev" idVendor || true)" = "$HUAWEI_VENDOR_ID" ]; then
                printf '%s\n' "$dev"
                return 0
            fi
        done
}

find_lte_device() {
    find_lte_device_from_summary ||
        find_lte_device_from_descriptors ||
        find_lte_device_from_vendor_id
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
    usb_devices="$(run_usbconfig | awk -v name="$USB_DEVICE_NAME" 'tolower($0) ~ name { printf "%s%s", sep, $1; sep = " " }')"
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
        if [ "$LTE_DEREGISTER_FIRST" != "0" ]; then
            query_at_port "$port" "AT+COPS=2" || true
            sleep 2
        fi
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

usb_product_is_hilink() {
    product="$1"

    for hilink_product in $HUAWEI_HILINK_PRODUCT_IDS; do
        if [ "$product" = "$hilink_product" ]; then
            return 0
        fi
    done

    return 1
}

usb_product_is_storage() {
    [ "$1" = "$HUAWEI_STORAGE_PRODUCT_ID" ]
}

format_usb_id() {
    vendor="$1"
    product="$2"

    printf '%s:%s\n' "${vendor#0x}" "${product#0x}"
}

describe_huawei_product() {
    product="$1"

    if usb_product_is_storage "$product"; then
        printf '%s\n' "Huawei storage mode"
        return
    fi

    if usb_product_is_hilink "$product"; then
        printf '%s\n' "Huawei HiLink mode"
        return
    fi

    if [ "$product" = "$HUAWEI_NCM_PRODUCT_ID" ]; then
        printf '%s\n' "Huawei NCM/composite mode"
        return
    fi

    printf '%s\n' "Huawei unknown mode"
}

lte_iface_brief_status() {
    iface="$1"

    if ! ifconfig "$iface" >/dev/null 2>&1; then
        printf '%s\n' "not present"
        return
    fi

    status="$(ifconfig "$iface" |
        awk -F: '
            /^[[:space:]]*status:/ {
                sub(/^[[:space:]]+/, "", $2)
                print $2
                found = 1
                exit
            }
            END {
                if (!found) {
                    print "present"
                }
            }
        ')"

    if [ "$status" = "present" ]; then
        printf '%s\n' "present"
    else
        printf 'present, status: %s\n' "$status"
    fi
}

read_usb_modeswitch_disable_switching() {
    if [ ! -f "$USB_MODESWITCH_CONF" ]; then
        printf '%s\n' "missing"
        return
    fi

    value="$(
        awk -F= '
            /^[[:space:]]*DisableSwitching[[:space:]]*=/ {
                value = $2
                gsub(/[[:space:]]/, "", value)
                found = 1
            }
            END {
                if (found) {
                    print value
                }
            }
        ' "$USB_MODESWITCH_CONF"
    )"

    [ -n "$value" ] || value="unset"
    printf '%s\n' "$value"
}

set_usb_modeswitch_disable_switching() {
    value="$1"

    if [ ! -f "$USB_MODESWITCH_CONF" ]; then
        log "Creating $USB_MODESWITCH_CONF"
        : > "$USB_MODESWITCH_CONF"
    fi

    current_value="$(read_usb_modeswitch_disable_switching)"
    if [ "$current_value" = "$value" ]; then
        log "$USB_MODESWITCH_CONF already has DisableSwitching=$value"
        return 0
    fi

    tmp_file="${TMPDIR:-/tmp}/install-huawei-lte.usb_modeswitch.$$"
    if ! awk -v value="$value" '
        BEGIN { replaced = 0 }
        /^[[:space:]]*DisableSwitching[[:space:]]*=/ && replaced == 0 {
            print "DisableSwitching=" value
            replaced = 1
            next
        }
        { print }
        END {
            if (replaced == 0) {
                print ""
                print "DisableSwitching=" value
            }
        }
    ' "$USB_MODESWITCH_CONF" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    if ! cat "$tmp_file" > "$USB_MODESWITCH_CONF"; then
        rm -f "$tmp_file"
        return 1
    fi

    rm -f "$tmp_file"
    log "Set $USB_MODESWITCH_CONF DisableSwitching=$value"
}

install_sms_gateway_rc_service() {
    if [ ! -f "$SMS_GATEWAY_RC_SOURCE" ]; then
        log "Missing sms_gateway rc.d source: $SMS_GATEWAY_RC_SOURCE"
        return 1
    fi

    if [ -f "$SMS_GATEWAY_RC_DEST" ] && cmp -s "$SMS_GATEWAY_RC_SOURCE" "$SMS_GATEWAY_RC_DEST"; then
        chmod 555 "$SMS_GATEWAY_RC_DEST" 2>/dev/null || true
        log "$SMS_GATEWAY_RC_DEST is already installed"
        return 0
    fi

    log "Installing sms_gateway rc.d service to $SMS_GATEWAY_RC_DEST"
    cp "$SMS_GATEWAY_RC_SOURCE" "$SMS_GATEWAY_RC_DEST"
    chmod 555 "$SMS_GATEWAY_RC_DEST"
}

remove_legacy_usb_modeswitch_rc_knob() {
    if sysrc -n usb_modeswitch_enable >/dev/null 2>&1; then
        log "Removing legacy usb_modeswitch_enable rc.conf knob"
        sysrc -x usb_modeswitch_enable >/dev/null 2>&1 || true
    fi
}

persist_sms_gateway_target() {
    target="$1"

    install_sms_gateway_rc_service || return 1
    sysrc sms_gateway_enable=YES
    sysrc sms_gateway_device_type="$SMS_GATEWAY_DEVICE_TYPE"
    sysrc sms_gateway_target="$target"
    remove_legacy_usb_modeswitch_rc_knob
}

report_status() {
    lte_dev="$(find_lte_device || true)"

    if [ -n "$lte_dev" ]; then
        mode_vendor="$(get_usb_field "$lte_dev" idVendor || true)"
        mode_product="$(get_usb_field "$lte_dev" idProduct || true)"
        description="$(get_usb_description "$lte_dev")"
        [ -n "$description" ] || description="unknown"

        if [ -n "$mode_vendor" ] && [ -n "$mode_product" ]; then
            mode_label="$(describe_huawei_product "$mode_product")"
            id="$(format_usb_id "$mode_vendor" "$mode_product")"
        else
            mode_label="Huawei USB device"
            id="unknown"
        fi

        printf '%s = %s\n' "$lte_dev" "$mode_label"
        printf 'description = %s\n' "$description"
        printf 'id = %s\n' "$id"
    else
        printf 'device = not found\n'
        printf 'description = none\n'
        printf 'id = none\n'
    fi

    interfaces="$(ifconfig -l 2>/dev/null || true)"
    [ -n "$interfaces" ] || interfaces="none"
    printf 'interfaces = %s\n' "$interfaces"
    printf '%s = %s\n' "$LTE_IFACE" "$(lte_iface_brief_status "$LTE_IFACE")"

    sms_gateway_value="$(run_sysrc_read -n sms_gateway_enable 2>/dev/null || true)"
    [ -n "$sms_gateway_value" ] || sms_gateway_value="unknown"
    printf 'sms_gateway_enable = %s\n' "$sms_gateway_value"
    sms_gateway_type="$(run_sysrc_read -n sms_gateway_device_type 2>/dev/null || true)"
    [ -n "$sms_gateway_type" ] || sms_gateway_type="unknown"
    printf 'sms_gateway_device_type = %s\n' "$sms_gateway_type"
    sms_gateway_target_value="$(run_sysrc_read -n sms_gateway_target 2>/dev/null || true)"
    [ -n "$sms_gateway_target_value" ] || sms_gateway_target_value="unknown"
    printf 'sms_gateway_target = %s\n' "$sms_gateway_target_value"
    printf 'usb_modeswitch_disable_switching = %s\n' "$(read_usb_modeswitch_disable_switching)"
}

read_huawei_usb_ids() {
    lte_dev="$1"

    mode_vendor="$(get_usb_field "$lte_dev" idVendor || true)"
    mode_product="$(get_usb_field "$lte_dev" idProduct || true)"
    if [ -z "$mode_vendor" ] || [ -z "$mode_product" ]; then
        log "Could not read USB vendor/product IDs for $lte_dev"
        return 1
    fi

    log "Current Huawei USB ID is ${mode_vendor}:${mode_product}"
    return 0
}

wait_for_huawei_device_after_usb_change() {
    n=0
    while [ "$n" -lt 15 ]; do
        lte_dev="$(find_lte_device || true)"
        if [ -n "$lte_dev" ] && read_huawei_usb_ids "$lte_dev"; then
            return 0
        fi

        n=$((n + 1))
        sleep 1
    done

    return 1
}

wait_for_huawei_hilink_after_usb_change() {
    n=0
    seen_id=""

    while [ "$n" -lt 20 ]; do
        lte_dev="$(find_lte_device || true)"
        if [ -n "$lte_dev" ] && read_huawei_usb_ids "$lte_dev"; then
            seen_id="${mode_vendor}:${mode_product}"
            if usb_product_is_hilink "$mode_product"; then
                return 0
            fi
        fi

        n=$((n + 1))
        sleep 1
    done

    if [ -n "$seen_id" ]; then
        log "Last Huawei USB ID seen while waiting for HiLink: $seen_id"
    fi
    return 1
}

wait_for_huawei_storage_after_usb_change() {
    n=0
    seen_id=""

    while [ "$n" -lt 20 ]; do
        lte_dev="$(find_lte_device || true)"
        if [ -n "$lte_dev" ] && read_huawei_usb_ids "$lte_dev"; then
            seen_id="${mode_vendor}:${mode_product}"
            if usb_product_is_storage "$mode_product"; then
                return 0
            fi
        fi

        n=$((n + 1))
        sleep 1
    done

    if [ -n "$seen_id" ]; then
        log "Last Huawei USB ID seen while waiting for storage mode: $seen_id"
    fi
    return 1
}

disable_usb_modeswitch_autoswitch() {
    log "Setting usb_modeswitch DisableSwitching=1 so the dongle stays in storage mode on attach"
    set_usb_modeswitch_disable_switching 1
    service devd restart
}

enable_usb_modeswitch_autoswitch() {
    log "Setting usb_modeswitch DisableSwitching=0 so the dongle can switch to HiLink mode"
    set_usb_modeswitch_disable_switching 0
    service devd restart
}

reset_huawei_usb_device() {
    product="$1"

    log "Resetting Huawei USB device ${HUAWEI_VENDOR_ID}:${product}"
    /usr/local/sbin/usb_modeswitch -v "$HUAWEI_VENDOR_ID" -p "$product" -R || true
}

try_huawei_storage_at_recovery() {
    [ "$LTE_STORAGE_AT_RECOVERY" != "0" ] || return 1

    ports="$(find_lte_serial_ports)"
    if [ -z "$ports" ]; then
        log "No /dev/cuaU* modem command ports found for storage-mode AT recovery"
        return 1
    fi

    for port in $ports; do
        log "Trying Huawei storage-mode AT recovery on $port"
        stty -f "$port" 115200 cs8 -parenb -cstopb -echo >/dev/null 2>&1 || true

        if ! query_at_port "$port" "AT"; then
            log "Could not write AT probe to $port for storage-mode recovery"
            continue
        fi

        query_at_port "$port" "ATE0" || true
        query_at_port "$port" "AT+CMEE=2" || true
        query_at_port "$port" "ATI" || true
        query_at_port "$port" "AT^SETPORT?" || true

        if query_at_port "$port" "AT^SETPORT=\"$LTE_STORAGE_SETPORT_VALUE\""; then
            log "Huawei SETPORT storage composition was accepted on $port"
            query_at_port "$port" "AT^RESET" || true
            sleep 5
            return 0
        fi

        if query_at_port "$port" "AT^U2DIAG=$LTE_STORAGE_U2DIAG_VALUE"; then
            log "Huawei U2DIAG storage composition was accepted on $port"
            query_at_port "$port" "AT^RESET" || true
            sleep 5
            return 0
        fi
    done

    log "Huawei storage-mode AT recovery commands were not accepted"
    return 1
}

log_storage_reboot_instructions() {
    STORAGE_REBOOT_REQUIRED=1
    log "Host is prepared to keep the dongle in storage mode on the next hydrogen boot"
    log "Reboot hydrogen, then run: ./install-huawei-lte.sh --status"
    log "Storage mode is confirmed when --status shows id = 12d1:1f01"
    log "Physical reattach alone may come back as 12d1:14dc or 12d1:155e on this dongle"
}

log_hilink_storage_reboot_instructions() {
    log_storage_reboot_instructions
}

prepare_huawei_storage_mode_from_ncm() {
    disable_usb_modeswitch_autoswitch
    try_huawei_storage_at_recovery || true
    reset_huawei_usb_device "$HUAWEI_NCM_PRODUCT_ID"
    sleep 5

    if wait_for_huawei_storage_after_usb_change; then
        log "Huawei dongle is now visible in storage mode (${mode_vendor}:${mode_product})"
        return 0
    fi

    if wait_for_huawei_device_after_usb_change; then
        if usb_product_is_hilink "$mode_product"; then
            log "Huawei dongle entered HiLink mode while preparing storage (${mode_vendor}:${mode_product})"
            return 0
        fi

        log "Huawei dongle is still ${mode_vendor}:${mode_product}"
    else
        log "Huawei device did not reappear after storage-mode preparation"
    fi

    log_storage_reboot_instructions
    return 1
}

run_hilink_modeswitch_from_storage() {
    log "Sending HuaweiNewMode usb_modeswitch command for ${HUAWEI_VENDOR_ID}:${HUAWEI_STORAGE_PRODUCT_ID}"
    if [ ! -f "$HUAWEI_HILINK_MODESWITCH_CONFIG" ]; then
        log "Missing usb_modeswitch config: $HUAWEI_HILINK_MODESWITCH_CONFIG"
        return 1
    fi

    set_usb_modeswitch_disable_switching 0

    if ! /usr/local/sbin/usb_modeswitch -v 0x12d1 -p 0x1f01 -c /usr/local/share/usb_modeswitch/12d1:1f01; then
        log "usb_modeswitch exited non-zero while switching from storage mode"
    fi

    sleep 3
    if wait_for_huawei_hilink_after_usb_change; then
        log "Huawei dongle is now in HiLink mode (${mode_vendor}:${mode_product})"
        wait_for_lte_interface || true
        return 0
    fi

    log "Huawei dongle did not reappear as expected HiLink 14db/14dc after storage-mode usb_modeswitch"
    return 1
}

recover_hilink_from_ncm() {
    log "Huawei dongle is in NCM/composite mode (${mode_vendor}:${mode_product}); trying USB reset before storage-mode switch"
    enable_usb_modeswitch_autoswitch
    reset_huawei_usb_device "$HUAWEI_NCM_PRODUCT_ID"
    sleep 3

    if ! wait_for_huawei_device_after_usb_change; then
        log "Huawei device did not reappear after USB reset"
        return 1
    fi

    if usb_product_is_hilink "$mode_product"; then
        log "Huawei dongle entered HiLink mode after USB reset (${mode_vendor}:${mode_product})"
        wait_for_lte_interface || true
        return 0
    fi

    if usb_product_is_storage "$mode_product"; then
        run_hilink_modeswitch_from_storage
        return "$?"
    fi

    log "Huawei dongle stayed in ${mode_vendor}:${mode_product}; power-cycle/unplug dongle, then rerun"
    return 1
}

switch_huawei_hilink_device() {
    lte_dev="$(find_lte_device || true)"
    if [ -z "$lte_dev" ]; then
        log "No Huawei USB device found"
        return 1
    fi

    log "Found Huawei USB device at $lte_dev"
    if ! read_huawei_usb_ids "$lte_dev"; then
        return 1
    fi

    if [ "$mode_vendor" != "$HUAWEI_VENDOR_ID" ]; then
        log "Device at $lte_dev is not Huawei vendor $HUAWEI_VENDOR_ID"
        return 1
    fi

    if usb_product_is_hilink "$mode_product"; then
        log "Huawei dongle is already in HiLink mode (${mode_vendor}:${mode_product})"
        wait_for_lte_interface || true
        return 0
    fi

    if [ "$mode_product" = "$HUAWEI_STORAGE_PRODUCT_ID" ]; then
        run_hilink_modeswitch_from_storage
        return "$?"
    fi

    if [ "$mode_product" = "$HUAWEI_NCM_PRODUCT_ID" ]; then
        recover_hilink_from_ncm
        return "$?"
    fi

    log "Huawei dongle is in unsupported mode ${mode_vendor}:${mode_product}; expected 1f01, 14db, 14dc, or 155e"
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
    log "Persisting LTE DHCP interface settings"
    choose_lte_interface || log "No ue* interface is visible yet; configuring expected interface $LTE_IFACE"
    ensure_dhclient_ignores_routers "$LTE_IFACE"
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

    if lte_interface_has_dhcp_ipv4; then
        log "$LTE_IFACE already has an IPv4 DHCP lease; not starting another dhclient"
        return 0
    fi

    pidfile="/var/run/dhclient/dhclient.$LTE_IFACE.pid"
    if [ -f "$pidfile" ]; then
        dhclient_pid="$(sed -n '1p' "$pidfile" 2>/dev/null || true)"
        if [ -n "$dhclient_pid" ] && kill -0 "$dhclient_pid" >/dev/null 2>&1; then
            log "dhclient is already running for $LTE_IFACE; waiting for an IPv4 lease"
            n=0
            while [ "$n" -lt 10 ]; do
                if lte_interface_has_dhcp_ipv4; then
                    return 0
                fi

                n=$((n + 1))
                sleep 1
            done
            return 1
        fi

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

ping_hilink_gateway() {
    ping -c 1 192.168.8.1 >/dev/null 2>&1
}

bring_hilink_network_up() {
    if ! wait_for_lte_interface; then
        log "$LTE_IFACE is not present; HiLink network interface is not ready"
        return 1
    fi

    log "Bringing $LTE_IFACE up for HiLink"
    if ! ifconfig "$LTE_IFACE" up; then
        log "Could not bring $LTE_IFACE up"
        return 1
    fi

    log "Requesting DHCP lease on $LTE_IFACE so ignore routers applies now"
    if run_dhclient_once; then
        log "$LTE_IFACE received an IPv4 DHCP lease"
        if ping_hilink_gateway; then
            log "HiLink gateway 192.168.8.1 is pingable via DHCP"
            return 0
        fi
        log "DHCP lease was obtained, but 192.168.8.1 did not answer ping"
    else
        log "$LTE_IFACE did not get an IPv4 DHCP lease"
    fi

    if try_lte_static_ping; then
        log "Static 192.168.8.2/24 ping to 192.168.8.1 succeeded"
        return 0
    fi

    log "Static 192.168.8.2/24 ping to 192.168.8.1 failed"
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

attempt_storage_setup() {
    log "Huawei storage-mode discovery"
    log_lte_snapshot
    disable_usb_modeswitch_autoswitch

    lte_dev="$(find_lte_device || true)"
    if [ -z "$lte_dev" ]; then
        log "No Huawei USB device found"
        return 1
    fi

    log "Found Huawei USB device at $lte_dev"
    if ! read_huawei_usb_ids "$lte_dev"; then
        return 1
    fi

    if [ "$mode_vendor" != "$HUAWEI_VENDOR_ID" ]; then
        log "Device at $lte_dev is not Huawei vendor $HUAWEI_VENDOR_ID"
        return 1
    fi

    if usb_product_is_storage "$mode_product"; then
        log "Huawei dongle is in storage mode (${mode_vendor}:${mode_product})"
        return 0
    fi

    if [ "$mode_product" = "$HUAWEI_NCM_PRODUCT_ID" ]; then
        log "Huawei dongle is in NCM/composite mode (${mode_vendor}:${mode_product})"
        log "Storage mode cannot be switched in-place from NCM on this dongle"
        log_storage_reboot_instructions
        return 0
    fi

    if usb_product_is_hilink "$mode_product"; then
        log "Huawei dongle is in HiLink mode (${mode_vendor}:${mode_product})"
        log_hilink_storage_reboot_instructions
        return 0
    fi

    log "Huawei dongle is in unsupported mode ${mode_vendor}:${mode_product}; expected 1f01, 14db, 14dc, or 155e"
    return 1
}

attempt_hilink_setup() {
    attempt=1

    while [ "$attempt" -le "$LTE_MAX_ATTEMPTS" ]; do
        log "HiLink discovery attempt $attempt of $LTE_MAX_ATTEMPTS"
        clear_lte_static_test_address
        log_lte_snapshot

        if ! switch_huawei_hilink_device; then
            log "HiLink mode preparation did not complete on attempt $attempt"
            return 1
        fi

        configure_freebsd_networking

        if bring_hilink_network_up; then
            return 0
        fi

        log "HiLink attempt $attempt did not make 192.168.8.1 pingable"
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$LTE_MAX_ATTEMPTS" ]; then
            log "Rediscovering after USB/modem state settles"
            sleep 3
        fi
    done

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
    parse_args "$@"

    if [ "$STATUS_ONLY" -eq 1 ]; then
        require_command usbconfig
        require_command ifconfig
        require_command sysrc
        report_status
        return 0
    fi

    require_root
    log_file "----- run start: target=$LTE_TARGET_MODE iface=$LTE_IFACE -----"
    require_command pkg
    require_command usbconfig
    require_command ifconfig
    require_command sysrc
    require_command service
    require_command od
    require_command stty
    require_command ping
    require_command timeout

    ensure_usb_modeswitch_package

    case "$LTE_TARGET_MODE" in
        storage)
            if attempt_storage_setup; then
                persist_sms_gateway_target storage
                if [ "$STORAGE_REBOOT_REQUIRED" -eq 1 ]; then
                    log "Huawei storage-mode host preparation complete"
                    log "Storage mode should be active after a full hydrogen reboot"
                else
                    log "Huawei storage-mode setup complete"
                    log "Check with: usbconfig; usbconfig -d <ugenX.Y> dump_device_desc"
                fi
                return 0
            fi
            die "Huawei storage mode is not ready"
            ;;
        hilink)
            if attempt_hilink_setup; then
                persist_sms_gateway_target hilink
                log "Huawei HiLink setup complete"
                log "Check with: ifconfig $LTE_IFACE; ping -c 1 192.168.8.1; netstat -rn"
                return 0
            fi
            die "Huawei HiLink mode is not ready after $LTE_MAX_ATTEMPTS discovery attempts"
            ;;
        ncm)
            if attempt_lte_setup; then
                persist_sms_gateway_target ncm
                log "Huawei NCM LTE setup complete"
                log "Check with: ifconfig $LTE_IFACE; netstat -rn"
                return 0
            fi
            die "$LTE_IFACE is not ready after $LTE_MAX_ATTEMPTS NCM discovery attempts"
            ;;
        *)
            die "unsupported LTE_TARGET_MODE '$LTE_TARGET_MODE' (expected storage, hilink, or ncm)"
            ;;
    esac
}

main "$@"
