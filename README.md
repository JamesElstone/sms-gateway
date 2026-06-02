# SMS Gateway

Small PHP gateway for sending SMS through an LTE USB dongle exposing a local
XML web API, normally at `http://192.168.8.1/`.

## API

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
