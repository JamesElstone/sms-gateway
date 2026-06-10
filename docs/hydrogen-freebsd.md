# Hydrogen FreeBSD Deployment Notes

Hydrogen is `FreeBSD 14.3-RELEASE-p9 arm64`.

## PHP/Apache

Install the PHP pieces if they are not already present:

```sh
sudo pkg install -y apache24 php84 php84-curl php84-mbstring php84-xml mod_php84
```

Copy this repository to:

```text
/usr/local/www/sms-gateway
```

Copy the config:

```sh
cp /usr/local/www/sms-gateway/config/example.php /usr/local/www/sms-gateway/config/local.php
cp /usr/local/www/sms-gateway/config/tokens.example.json /usr/local/www/sms-gateway/config/tokens.json
```

Then adjust `config/local.php` if the LTE dongle is not at `http://192.168.8.1/`.
Add the approved caller tokens and IP rules to `config/tokens.json`.

Create a token hash with:

```sh
php -r 'echo hash("sha256", $argv[1]) . PHP_EOL;' 'your-long-secret-token'
```

Install the FreeBSD apache24 include into Apache's standard Includes directory,
then test and reload Apache:

```sh
sudo install -m 0644 /usr/local/www/sms-gateway/hw/FreeBSD/apache24/sms-gateway.conf /usr/local/etc/apache24/Includes/sms-gateway.conf
sudo apachectl configtest
sudo service apache24 reload
```

The include mounts the local PHP gateway API under the existing/default website:

```text
http://hydrogen.int.elstone.net/sms-gateway/send/{mobile-number}
```

It also reverse-proxies the LTE dongle web interface:

```text
http://hydrogen.int.elstone.net/lte-device/
```

The `/lte-device/` route proxies to `http://192.168.8.1/`. The include loads the
needed Apache proxy modules if they are not already loaded, so no
`/usr/local/etc/apache24/httpd.conf` edit is required.

## LTE USB dongle mode

The dongle currently exposing an empty SD-card reader means it is probably still
in USB storage/install mode. It needs to switch to the HiLink network interface
mode before the PHP gateway can reach `192.168.8.1`.

Useful inspection commands:

```sh
usbconfig
usbconfig dump_device_desc
ifconfig
```

On FreeBSD, first try changing the active USB configuration. Replace `ugenX.Y`
with the LTE device shown by `usbconfig`:

```sh
sudo usbconfig -d ugenX.Y dump_curr_config_desc
sudo usbconfig -d ugenX.Y set_config 1
```

If that does not expose a network interface, install and use `usb_modeswitch`.
Many LTE sticks switch to a network-capable product after the mode-switch
message:

```sh
sudo pkg install -y usb_modeswitch
sudo usb_modeswitch -v 12d1 -p 1f01 -J
usbconfig
ifconfig
```

Once the interface appears, bring it up and let DHCP assign an address:

```sh
sudo service netif restart
sudo dhclient <interface>
ping -c 3 192.168.8.1
```

The old working Apache proxy used the dongle at `http://192.168.8.1/`, so that
is the expected success point before testing the PHP endpoint.

## Test send

```sh
curl -i \
  -X POST \
  -H 'X-SMS-Gateway-Token: your-long-secret-token' \
  --data 'Hello from Hydrogen' \
  http://hydrogen.int.elstone.net/sms-gateway/send/+447700900123
```

Expected successful response:

```json
{
  "status": "sent",
  "mobile": "+447700900123",
  "message": "SMS sent"
}
```
