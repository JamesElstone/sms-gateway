# SMS Gateway

Small PHP gateway for sending SMS through an LTE USB dongle exposing a local
XML web API, normally at `http://192.168.8.1/`.

## API

```text
GET http://hydrogen.int.elstone.net/sms-gateway/
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
    "imei": "866785032862038"
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
POST http://hydrogen.int.elstone.net/sms-gateway/send/{mobile-number}
Content-Type: text/plain
X-SMS-Gateway-Token: {token}
```

The request body is sent as the SMS payload.

Responses are JSON:

```json
{
  "status": "sent",
  "mobile": "+447700900123",
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

Copy `config/example.php` to `config/local.php` and adjust it on Hydrogen.

The default dongle URL is `http://192.168.8.1/`, matching the old working files.

Copy `config/tokens.example.json` to `config/tokens.json` and add the approved
tokens. Each token can be restricted to exact IP addresses or CIDR ranges:

```json
{
  "tokens": [
    {
      "name": "internal-app",
      "token_sha256": "sha256-hash-of-the-token",
      "allowed_ips": ["192.168.1.20", "10.0.0.0/8"]
    }
  ]
}
```

For quick local testing, `token` may be used instead of `token_sha256`, but the
hashed form is better for the live file.

## Hydrogen notes

See `docs/hydrogen-freebsd.md` for Apache and FreeBSD USB mode-switching notes.
