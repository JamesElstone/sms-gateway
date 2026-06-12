<!--
Copyright (c) 2026, James Elstone
SPDX-License-Identifier: BSD-3-Clause

This file is part of SMS Gateway:
https://github.com/JamesElstone/sms-gateway

See LICENSE for details.
-->
# SMS Gateway

Small PHP gateway for sending SMS through an LTE USB dongle exposing a local
XML web API, normally at `http://192.168.8.1/`.

## API

```text
GET http://<deployed_server_dns_name>/sms-gateway/
```

Returns decoded LTE dongle status JSON, including an interpreted summary and
raw decoded read-only Huawei API responses from `http://192.168.8.1/`.

Example:

```json
{
  "general": {
    "status": "no_service",
    "health": "bad",
    "ok": false,
    "message": "E3372 reachable; SIM pin_ready; modem reports no service; signal 0/5",
    "connection": "disconnected",
    "connected": false,
    "sms_send": {
      "blocked": true,
      "status": "no_service",
      "http_status": 503,
      "message": "LTE device has no mobile network service"
    },
    "signal": {
      "quality": "bad",
      "label": "No signal",
      "percent": 0
    },
    "rssi": {
      "value": null,
      "unit": "dBm",
      "quality": "not_reported",
      "label": "RSSI not reported by modem"
    },
    "problems": [
      "Mobile network service is unavailable or limited",
      "Data connection is not connected",
      "No usable radio signal is reported",
      "No mobile operator/PLMN is reported",
      "No WAN IP address is assigned"
    ]
  },
  "status": "no_service",
  "message": "E3372 reachable; SIM pin_ready; modem reports no service; signal 0/5",
  "device": {
    "name": "E3372",
    "imei": "510563996265102"
  },
  "network": {
    "connection": {
      "code": "902",
      "label": "disconnected"
    }
  }
}
```

```text
GET http://<deployed_server_dns_name>/sms-gateway/carriers/
```

Runs the Huawei network operator search and returns the available PLMNs as JSON.
The dongle may take around a minute to complete this scan.
Successful scan responses are cached for 15 minutes in the system temporary
directory. Requests during that cache window return the cached scan response
instead of starting another modem scan.

Only one scan is allowed at a time. If another request arrives while a scan is
running, the endpoint returns the cached scan response, even if it has expired.
If no cached scan exists yet, concurrent requests return HTTP 409:

```json
{
  "status": "scan_in_progress",
  "message": "A carrier scan is already in progress; try again shortly"
}
```

Use `?force` to bypass a fresh cache and start a new scan:

```text
GET http://<deployed_server_dns_name>/sms-gateway/carriers/?force
```

Forced scans still use the same scan lock. If a scan is already running, a
forced request returns HTTP 409 immediately and does not return cached data.
After any real scan completes, forced requests are also suppressed for 60
seconds so browser/server-queued duplicate force requests cannot start a second
scan as soon as the first lock is released.

Example:

```json
{
  "status": "carrier_scan_complete",
  "message": "Carrier scan completed; 6 carriers found; per-carrier signal was not reported by the modem",
  "count": 6,
  "signal_reported": false,
  "carriers": [
    {
      "index": 0,
      "name": "Example Carrier",
      "full_name": "Example Carrier",
      "short_name": "Example",
      "numeric": "23410",
      "state": {
        "code": "1",
        "label": "usable"
      },
      "available": true,
      "registered": false,
      "forbidden": false,
      "rat": {
        "code": "7",
        "label": "4G/LTE"
      },
      "signal": {
        "reported": false,
        "rssi": null,
        "rsrp": null,
        "rsrq": null,
        "sinr": null,
        "strength": null,
        "icon": null
      }
    }
  ]
}
```

```text
GET http://<deployed_server_dns_name>/sms-gateway/ping
X-SMS-Gateway-Token: {token}
```

Checks that the supplied SMS gateway token is valid without contacting the LTE
dongle or sending a message. The token may also be sent as
`Authorization: Bearer {token}`.

Example response:

```json
{
  "auth": "sucessful",
  "datetime": "2026-06-12T10:00:00+00:00",
  "ping": "pong"
}
```

```text
GET http://<deployed_server_dns_name>/sms-gateway/read/
X-SMS-Gateway-Token: {token}
```

Returns cached SMS inbox messages not yet read by the calling token and marks
the returned message IDs read for that token. Run
`bin/sms-gateway-sync.php --interval 10` in the background to keep the local
SQLite cache synchronized from the LTE modem inbox.

Useful read forms:

- `/sms-gateway/read/peek/` returns unread-for-token messages without marking.
- `/sms-gateway/read/ack/` accepts `{"message_ids":["sms_..."]}` as JSON.
- `/sms-gateway/read/?all` dumps the SQLite cache without marking.
- `/sms-gateway/read/?all&mark-read&limit=10` marks only returned rows.
- `/sms-gateway/read/?%2B447700900000` filters by sender.

```text
POST http://<deployed_server_dns_name>/sms-gateway/send/{mobile-number}
Content-Type: text/plain
X-SMS-Gateway-Token: {token}
```

The request body is sent as the SMS payload.
Example mobile numbers in this documentation use Ofcom's drama range:
`07700 900000` to `07700 900999`.

Responses are JSON:

```json
{
  "status": "sent",
  "mobile": "+447700900000",
  "message": "SMS sent"
}
```

Known statuses include:

- `sent`
- `unauthorised`
- `unable_to_send`
- `lte_error`
- `device_missing`
- `sim_card_missing`
- `sim_pin_required`
- `sim_puk_required`
- `no_service`
- `connected`
- `connecting`
- `disconnecting`
- `disconnected`
- `connection_failed`
- `lte_status`
- `data_plan_expired`

The token may also be sent as:

```text
Authorization: Bearer {token}
```

## Local configuration

Copy `config/local.php.example` to `config/local.php` and adjust it on the
deployed server.

The default dongle URL is `http://192.168.8.1/`, which is the common Huawei
HiLink address.

Copy `config/tokens.json.example` to `config/tokens.json` and add the approved
tokens. Each token can be restricted to exact IP addresses or CIDR ranges:

```json
{
  "tokens": [
    {
      "name": "internal-app",
      "enabled": true,
      "token_sha256": "sha256-hash-of-the-token",
      "allowed_ips": ["192.168.1.20", "10.0.0.0/8"]
    }
  ]
}
```

Token entries without `"enabled": true` are disabled by default. The token
`name` is used as the independent SMS read-log identity.

For quick local testing, `token` may be used instead of `token_sha256`, but the
hashed form is better for the live file.

## Deployment

See `DEPLOYMENT.md` for Apache, SQLite, and FreeBSD LTE setup notes. See
`PRIVACY.md` for SMS cache and backup handling guidance.
