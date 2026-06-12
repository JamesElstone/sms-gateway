# FreeBSD Huawei LTE Setup

This directory contains the FreeBSD hardware setup for the SMS Gateway LTE
dongle.

The main entry point is:

```sh
/usr/local/sms-gateway/hw/FreeBSD/install-huawei-lte.sh
```

The boot-time wrapper is:

```sh
/usr/local/etc/rc.d/sms_gateway
```

The repository copy of that wrapper lives at:

```sh
hw/FreeBSD/rc.d/sms_gateway
```

The Apache include for exposing the SMS endpoint and reverse-proxying the LTE
dongle web interface through the existing apache24 site lives at:

```sh
hw/FreeBSD/apache24/sms-gateway.conf
```

Install it on the deployed server as:

```sh
sudo install -m 0644 /usr/local/sms-gateway/hw/FreeBSD/apache24/sms-gateway.conf /usr/local/etc/apache24/Includes/sms-gateway.conf
sudo apachectl configtest
sudo service apache24 reload
```

After installation, the expected routes are:

```text
http://<deployed_server_dns_name>/sms-gateway/
http://<deployed_server_dns_name>/sms-gateway/send/{mobile-number}
http://<deployed_server_dns_name>/lte-device/
```

## What The Installer Does

`install-huawei-lte.sh` detects a Huawei USB LTE dongle, works out its current
USB product mode, switches it where possible, and configures the FreeBSD network
side.

For Huawei dongles supported by this setup, the important USB IDs are:

```text
12d1:1f01  Huawei mass storage mode
12d1:14dc  Huawei HiLink modem/network-card mode
12d1:14db  Huawei HiLink modem/network-card mode
12d1:155e  Huawei NCM/composite mode
```

The preferred target is HiLink mode. In HiLink mode the dongle acts like a small
router on `192.168.8.1`, and FreeBSD sees a USB Ethernet interface such as
`ue0`.

By default, the installer ensures `/etc/dhclient.conf` contains a `ue0` block
with:

```text
ignore routers;
```

This allows DHCP on `ue0` without letting the LTE dongle replace the system
default route. On the deployed server, the default route should remain on the
primary network interface.

That is the intended default for this project: the device is primarily an SMS
gateway, not the host's general-purpose LTE router. Leave LTE default-route
installation disabled unless this machine should deliberately send normal
outbound traffic through the modem.

To allow the LTE DHCP server to install a default route, use
`--default-route` for a manual run or set this in `/etc/rc.conf`:

```sh
lte_route_enable="YES"
```

## Commands

Show help:

```sh
./install-huawei-lte.sh --help
```

Show current status. This requires root so the script can read USB descriptors:

```sh
sudo ./install-huawei-lte.sh --status
```

Switch/configure the dongle for HiLink mode:

```sh
sudo ./install-huawei-lte.sh --target hilink
```

When this is run from a terminal, the installer prints the final `ifconfig`,
`ping -c 1 192.168.8.1`, and `netstat -rn` checks after a successful HiLink
setup.

The default route is suppressed unless `--default-route` is passed:

```sh
sudo ./install-huawei-lte.sh --target hilink --default-route
```

The explicit protected form is:

```sh
sudo ./install-huawei-lte.sh --target hilink --no-default-route
```

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
         12d1:1f01 storage mode. Returning from a switched network mode to
         true storage mode may require a full host reboot.
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
lte_route_enable="NO"
```

It also removes the legacy `usb_modeswitch_enable` rc.conf knob if present.

At boot, the rc.d service builds the installer path from the platform and device
type:

```text
/usr/local/sms-gateway/hw/{uname}/install-{sms_gateway_device_type}.sh
```

For the default FreeBSD Huawei LTE setup, that resolves to:

```sh
/usr/local/sms-gateway/hw/FreeBSD/install-huawei-lte.sh
```

The rc.d service then runs:

```sh
install-huawei-lte.sh --service --target "$sms_gateway_target" --no-default-route
```

If `lte_route_enable="YES"` is set in `/etc/rc.conf`, the service passes
`--default-route` instead.

The default rc.d settings are:

```sh
sms_gateway_root="/usr/local/sms-gateway"
sms_gateway_platform="$(uname -s)"
sms_gateway_device_type="huawei-lte"
sms_gateway_target="hilink"
sms_gateway_start_delay="8"
lte_route_enable="NO"
```

`sms_gateway_start_delay` gives USB and `devd` a short window to settle before
the installer tries to detect and switch the dongle.

## Expected HiLink State

After a successful HiLink setup:

```sh
sudo ./install-huawei-lte.sh --status
```

should report something like:

```text
ugen2.2 = Huawei HiLink mode
id = 12d1:14dc
interfaces = <primary_interface> lo0 ue0
ue0 = present, status: active
sms_gateway_enable = YES
sms_gateway_device_type = huawei-lte
sms_gateway_target = hilink
lte_route_enable = NO
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

Switching from HiLink or NCM back to true storage mode is not always completed
by a USB detach/reattach alone. The recommended path is:

```sh
sudo ./install-huawei-lte.sh --target storage
sudo reboot
sudo ./install-huawei-lte.sh --status
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
