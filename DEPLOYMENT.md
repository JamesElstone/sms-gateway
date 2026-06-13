<!--
Copyright (c) 2026, James Elstone
SPDX-License-Identifier: BSD-3-Clause

This file is part of SMS Gateway:
https://github.com/JamesElstone/sms-gateway

See LICENSE for details.
-->
# FreeBSD Deployment Notes

These notes assume the SMS Gateway is deployed on a FreeBSD host reachable as
`<deployed_server_dns_name>`.

## PHP/Apache

Install the PHP pieces if they are not already present:

```sh
sudo pkg install -y apache24 php84 php84-curl php84-dom php84-mbstring php84-pdo php84-pdo_sqlite php84-simplexml php84-sqlite3 php84-xml mod_php84 sqlite3 usb_modeswitch
```

`php84-dom` is needed for generating XML requests to the Huawei API.
`php84-pdo`, `php84-pdo_sqlite`, and `php84-sqlite3` are needed for the local
SMS cache. `sqlite3` is installed so an administrator can inspect the cache.
`php84-simplexml` is useful for older local test scripts and ad-hoc API
inspection. `usb_modeswitch` is needed by the FreeBSD Huawei LTE installer to
switch/catch the USB dongle mode. After adding PHP extension packages, restart
Apache:

```sh
sudo service apache24 restart
```

Copy this repository to:

```text
/usr/local/sms-gateway
```

Copy the config:

```sh
cp /usr/local/sms-gateway/config/local.php.example /usr/local/sms-gateway/config/local.php
cp /usr/local/sms-gateway/config/tokens.json.example /usr/local/sms-gateway/config/tokens.json
```

Then adjust `config/local.php` if the LTE dongle is not at `http://192.168.8.1/`.
Add the approved caller tokens and IP rules to `config/tokens.json`. Token
entries must include `"enabled": true`; missing `enabled` means disabled.

Create a token hash with:

```sh
php -r 'echo hash("sha256", $argv[1]) . PHP_EOL;' 'your-long-secret-token'
```

Install the FreeBSD apache24 include into Apache's standard Includes directory,
then test and reload Apache:

```sh
sudo install -m 0644 /usr/local/sms-gateway/hw/FreeBSD/apache24/sms-gateway.conf /usr/local/etc/apache24/Includes/sms-gateway.conf
sudo apachectl configtest
sudo service apache24 reload
```

The include mounts the local PHP gateway API under the existing/default website:

```text
http://<deployed_server_dns_name>/sms-gateway/
http://<deployed_server_dns_name>/sms-gateway/send/{mobile-number}
```

It also reverse-proxies the LTE dongle web interface:

```text
http://<deployed_server_dns_name>/lte-device/
```

The `/lte-device/` route proxies to `http://192.168.8.1/`. The include loads
the Apache proxy/PHP modules it needs if they are not already loaded, binds
`.php` files below `/sms-gateway` to the PHP handler, and uses the deployed
server's existing `mod_rewrite`, so no `/usr/local/etc/apache24/httpd.conf`
edit is required.

## SMS Cache

The read API uses a local PDO database. SQLite is the default:

```php
'database_dsn' => 'sqlite:/var/db/sms-gateway/sms-gateway.sqlite3',
'database_username' => null,
'database_password' => null,
```

Create a persistent directory writable by the Apache/PHP user:

```sh
sudo mkdir -p /var/db/sms-gateway
sudo chown www:www /var/db/sms-gateway
sudo chmod 0750 /var/db/sms-gateway
```

Create the default service log directory:

```sh
sudo mkdir -p /var/log/sms-gateway
sudo chown root:www /var/log/sms-gateway
sudo chmod 0750 /var/log/sms-gateway
```

The `sms_gateway` rc.d service creates these log files as `www:www 0640` on
start:

```text
/var/log/sms-gateway/sync.log
/var/log/sms-gateway/read.log
/var/log/sms-gateway/send.log
```

The read and send log paths can be changed in `/etc/rc.conf`:

```sh
sms_gateway_read_logfile="/var/log/sms-gateway/read.log"
sms_gateway_send_logfile="/var/log/sms-gateway/send.log"
```

Then set `database_dsn` in `config/local.php` to the `/var/db/sms-gateway`
path. The application creates the schema automatically on first use.

Inspect the cache with:

```sh
sudo -u www sqlite3 /var/db/sms-gateway/sms-gateway.sqlite3 '.tables'
sudo -u www sqlite3 /var/db/sms-gateway/sms-gateway.sqlite3 'SELECT message_id, sender, device_date FROM sms_messages ORDER BY device_date DESC LIMIT 10;'
```

Run one sync pass:

```sh
cd /usr/local/sms-gateway
sudo -u www php src/Service/sms-gateway-sync.php --once
```

Run the poller in the foreground at 10 second intervals:

```sh
cd /usr/local/sms-gateway
sudo -u www php src/Service/sms-gateway-sync.php --interval 10
```

On FreeBSD, the `sms_gateway` rc.d service starts the sync poller after LTE
hardware setup. The sync service polls the LTE modem inbox count, caches inbox
messages in SQLite, marks cached modem messages read, and deletes modem copies
only when all enabled tokens have read them. If local or SIM storage reaches
the configured pressure threshold, it deletes the oldest cached modem-resident
messages in batches of 10.

The FreeBSD port installs a newsyslog policy at:

```text
/usr/local/etc/newsyslog.conf.d/sms-gateway.conf
```

It rotates `/var/log/sms-gateway/sync.log`, `/var/log/sms-gateway/read.log`,
and `/var/log/sms-gateway/send.log` daily and keeps 14 compressed archives.
After rotating `sync.log`, it calls `service sms_gateway logrotate` so the sync
poller reopens the log.

The storage pressure threshold is configured in `config/local.php`:

```php
'sms_storage_pressure_threshold' => 0.9,
```

SIM capacity comes from the modem's `SimUsed` and `SimMax` fields. Local modem
inbox pressure uses `LocalInbox` and `LocalMax`.

## LTE USB Dongle Setup

Use the FreeBSD installer script to detect the Huawei LTE dongle, switch it into
the expected network mode, configure the USB network interface, and install the
boot-time `sms_gateway` rc.d service:

```sh
cd /usr/local/sms-gateway/hw/FreeBSD
sudo ./install-huawei-lte.sh --target hilink --no-default-route
```

The default `hilink` target expects the dongle to expose its local API at
`http://192.168.8.1/`. The `--no-default-route` option keeps the LTE dongle from
replacing the host's normal default route.

Show current dongle and service status with:

```sh
sudo ./install-huawei-lte.sh --status
```

If the dongle should provide the host's default route, deliberately opt in:

```sh
sudo ./install-huawei-lte.sh --target hilink --default-route
```

Prepare the host so the dongle remains in storage mode after a full reboot:

```sh
sudo ./install-huawei-lte.sh --target storage
sudo reboot
sudo ./install-huawei-lte.sh --status
```

Use the older NCM/serial attach path only when needed:

```sh
sudo ./install-huawei-lte.sh --target ncm
```

After a successful HiLink setup, these checks should pass:

```sh
ifconfig ue0
ping -c 1 192.168.8.1
netstat -rn
```

The expected route state is a `192.168.8.0/24` route on the LTE interface, while
the host's default route remains on its primary network interface unless
`--default-route` was requested.

## Test Send

The example mobile number below is the E.164 form of `07700 900000`, from
Ofcom's drama range.

```sh
curl -i \
  -X POST \
  -H 'X-SMS-Gateway-Token: your-long-secret-token' \
  --data 'Hello from SMS Gateway' \
  http://<deployed_server_dns_name>/sms-gateway/send/+447700900000
```

Expected successful response:

```json
{
  "status": "sent",
  "mobile": "+447700900000",
  "message": "SMS sent"
}
```
