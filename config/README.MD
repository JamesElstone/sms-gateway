# SMS Gateway Token Configuration

`tokens.json` controls which callers can send SMS messages through the gateway.
Callers provide the plaintext token in either header:

```sh
X-SMS-Gateway-Token: <token>
Authorization: Bearer <token>
```

Only the SHA-256 hash of each token should be stored in `tokens.json`.

## Interactive Setup

Run the helper from the installed project:

```sh
cd /usr/local/sms-gateway/config
sudo sh ./set_token.sh
```

The script prompts for:

- a token entry name
- allowed client IP addresses or CIDR ranges
- whether to generate a new random token or paste an existing token
- whether to replace an existing entry with the same name

Generated tokens are printed once. Store the token before continuing; the file
contains only `token_sha256`, so the plaintext token cannot be recovered later.

The script writes `tokens.json` directly and does not create a backup file.

## Ping Check

After creating a token, test authentication with:

```sh
curl -i \
  -H 'X-SMS-Gateway-Token: <token>' \
  http://hydrogen/sms-gateway/ping
```

Expected JSON includes:

```json
{
  "auth": "sucessful",
  "datetime": "2026-06-12T10:00:00+00:00",
  "ping": "pong"
}
```

You can override the URL printed by the helper:

```sh
SMS_GATEWAY_PING_URL='http://hydrogen.int.elstone.net/sms-gateway/ping' sudo -E sh ./set_token.sh
```

## File Format

Example `tokens.json`:

```json
{
  "tokens": [
    {
      "name": "internal-app",
      "token_sha256": "sha256-hash-of-the-token",
      "allowed_ips": [
        "127.0.0.1",
        "::1",
        "192.168.0.0/16",
        "10.0.0.0/8"
      ]
    }
  ]
}
```

`allowed_ips` may contain exact IPv4/IPv6 addresses or CIDR ranges. An empty
array allows any client IP address to use that token.

For quick local testing only, the application can also read a plaintext
`token` field, but `token_sha256` is preferred for deployed systems.
