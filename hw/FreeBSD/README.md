# FreeBSD Huawei LTE Setup

This directory contains the FreeBSD hardware setup for the SMS Gateway LTE
dongle.

The main entry point is:

```sh
/usr/local/freebsd-sms-gateway/hw/FreeBSD/install-huawei-lte.sh
```

The boot-time wrapper is:

```sh
/usr/local/etc/rc.d/sms_gateway
```

The repository copy of that wrapper lives at:

```sh
hw/FreeBSD/rc.d/sms_gateway
```

## What The Installer Does

`install-huawei-lte.sh` detects a Huawei USB LTE dongle, works out its current
USB product mode, switches it where possible, and configures the FreeBSD network
side.

For the Huawei dongle tested on `hydrogen`, the important USB IDs are:

```text
12d1:1f01  Huawei mass storage mode
12d1:14dc  Huawei HiLink modem/network-card mode
12d1:14db  Huawei HiLink modem/network-card mode
12d1:155e  Huawei NCM/composite mode
```

The preferred target is HiLink mode. In HiLink mode the dongle acts like a small
router on `192.168.8.1`, and FreeBSD sees a USB Ethernet interface such as
`ue0`.

The installer also ensures `/etc/dhclient.conf` contains a `ue0` block with:

```text
ignore routers;
```

This allows DHCP on `ue0` without letting the LTE dongle replace the system
default route. On `hydrogen`, the default route should remain on `dwc0`.

## Commands

Show help:

```sh
./install-huawei-lte.sh --help
```

Show current status. This is intended to work without root:

```sh
./install-huawei-lte.sh --status
```

Switch/configure the dongle for HiLink mode:

```sh
sudo ./install-huawei-lte.sh --target hilink
```

When this is run from a terminal, the installer prints the final `ifconfig`,
`ping -c 1 192.168.8.1`, and `netstat -rn` checks after a successful HiLink
setup.

Prepare the host so the dongle can remain in storage mode after a full host
reboot:

```sh
sudo ./install-huawei-lte.sh --target storage
```

Use the older NCM/serial attach path:

```sh
sudo ./install-huawei-lte.sh --target ncm
```

Supported targets are:

```text
hilink   Default. Switch storage-mode Huawei dongles to 12d1:14db/14dc and
         test that 192.168.8.1 is reachable through ue0.
storage  Disable automatic usb_modeswitch handling and prepare/catch
         12d1:1f01 storage mode. On this dongle, returning from a switched
         network mode to true storage mode usually requires a full host reboot.
ncm      Older NCM/composite mode path for 12d1:155e.
```

## Boot Persistence

Persistence is handled by the `sms_gateway` rc.d service, not by the
`usb_modeswitch_enable` rc.conf knob.

When a target run succeeds, the installer copies:

```sh
hw/FreeBSD/rc.d/sms_gateway
```

to:

```sh
/usr/local/etc/rc.d/sms_gateway
```

and writes rc.conf settings like:

```sh
sms_gateway_enable="YES"
sms_gateway_device_type="huawei-lte"
sms_gateway_target="hilink"
```

It also removes the legacy `usb_modeswitch_enable` rc.conf knob if present.

At boot, the rc.d service builds the installer path from the platform and device
type:

```text
/usr/local/freebsd-sms-gateway/hw/{uname}/install-{sms_gateway_device_type}.sh
```

For the default FreeBSD Huawei LTE setup, that resolves to:

```sh
/usr/local/freebsd-sms-gateway/hw/FreeBSD/install-huawei-lte.sh
```

The rc.d service then runs:

```sh
install-huawei-lte.sh --service --target "$sms_gateway_target"
```

The default rc.d settings are:

```sh
sms_gateway_root="/usr/local/freebsd-sms-gateway"
sms_gateway_platform="$(uname -s)"
sms_gateway_device_type="huawei-lte"
sms_gateway_target="hilink"
sms_gateway_start_delay="8"
```

`sms_gateway_start_delay` gives USB and `devd` a short window to settle before
the installer tries to detect and switch the dongle.

## Expected HiLink State

After a successful HiLink setup:

```sh
./install-huawei-lte.sh --status
```

should report something like:

```text
ugen2.2 = Huawei HiLink mode
id = 12d1:14dc
interfaces = dwc0 lo0 ue0
ue0 = present, status: active
sms_gateway_enable = YES
sms_gateway_device_type = huawei-lte
sms_gateway_target = hilink
usb_modeswitch_disable_switching = 0
```

These checks should also pass:

```sh
ifconfig ue0
ping -c 1 192.168.8.1
netstat -rn
```

The routing table should show the `192.168.8.0/24` route on `ue0`, while the
default route remains on the primary network interface.

## Storage Mode Caveat

On the tested Huawei dongle, switching from HiLink or NCM back to true storage
mode is not reliably completed by a USB detach/reattach alone. The repeatable
path found during testing was:

```sh
sudo ./install-huawei-lte.sh --target storage
sudo reboot
./install-huawei-lte.sh --status
```

Storage mode is confirmed when status shows:

```text
id = 12d1:1f01
```

If the dongle comes back as `12d1:155e`, it is in NCM/composite mode rather than
storage mode.

## Logging

The installer appends to:

```sh
/tmp/install-huawei-lte.log
```

Log lines are timestamped. The log is intentionally appended rather than
truncated so mode-change attempts can be compared across reboots and physical
reattach cycles.
