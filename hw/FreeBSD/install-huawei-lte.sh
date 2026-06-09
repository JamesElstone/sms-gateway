#!/bin/sh
set -eu

MODE_VENDOR="0x12d1"
MODE_PRODUCT="0x1f01"
LTE_IFACE="ue0"
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
        awk -v field="$field" '$1 == field { print $3; exit }'
}

find_huawei_storage_device() {
    usbconfig |
        awk -F: '/^ugen[0-9]+\.[0-9]+:/ { print $1 }' |
        while IFS= read -r dev; do
            vendor="$(get_usb_field "$dev" idVendor || true)"
            product="$(get_usb_field "$dev" idProduct || true)"

            if [ "$vendor" = "$MODE_VENDOR" ] && [ "$product" = "$MODE_PRODUCT" ]; then
                printf '%s\n' "$dev"
                return 0
            fi
        done
}

find_huawei_device() {
    usbconfig |
        awk -F: '/^ugen[0-9]+\.[0-9]+:/ { print $1 }' |
        while IFS= read -r dev; do
            vendor="$(get_usb_field "$dev" idVendor || true)"

            if [ "$vendor" = "$MODE_VENDOR" ]; then
                printf '%s\n' "$dev"
                return 0
            fi
        done
}

lte_interface_is_present() {
    ifconfig "$LTE_IFACE" >/dev/null 2>&1
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

switch_huawei_lte_device() {
    huawei_dev="$(find_huawei_device || true)"
    if [ -n "$huawei_dev" ]; then
        log "Found Huawei USB device at $huawei_dev"
    fi

    if lte_interface_is_present; then
        log "$LTE_IFACE is already present; dongle appears to be in network mode"
        return 0
    fi

    storage_dev="$(find_huawei_storage_device || true)"
    if [ -z "$storage_dev" ]; then
        if [ -n "$huawei_dev" ]; then
            log "Found Huawei USB device $huawei_dev, but not storage-mode $MODE_VENDOR:$MODE_PRODUCT"
        else
            log "No Huawei $MODE_VENDOR USB device found"
        fi
        return 1
    fi

    log "Found Huawei storage-mode LTE device at $storage_dev"
    log "Sending Huawei mode-switch command"
    if ! usb_modeswitch -v "$MODE_VENDOR" -p "$MODE_PRODUCT" -J; then
        log "usb_modeswitch exited non-zero; checking whether the device re-enumerated anyway"
    fi

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
    if ! lte_interface_is_present; then
        log "$LTE_IFACE is not present; skipping DHCP renewal"
        return
    fi

    log "Renewing DHCP on $LTE_IFACE so ignore routers applies now"
    if service netif restart "$LTE_IFACE"; then
        return
    fi

    log "service netif restart failed for $LTE_IFACE; trying dhclient directly"
    dhclient -r "$LTE_IFACE" >/dev/null 2>&1 || true
    dhclient "$LTE_IFACE"
}

main() {
    require_root
    require_command pkg
    require_command usbconfig
    require_command ifconfig
    require_command sysrc
    require_command service

    ensure_dhclient_ignores_routers
    ensure_usb_modeswitch_package

    if switch_huawei_lte_device; then
        configure_freebsd_networking
        renew_lte_dhcp
        log "Huawei LTE setup complete"
        log "Check with: ifconfig $LTE_IFACE; netstat -rn"
        return 0
    fi

    die "mode switch was not confirmed; leaving sysrc/devd networking changes unapplied"
}

main "$@"
