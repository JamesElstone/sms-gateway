<!--
Copyright (c) 2026, James Elstone
SPDX-License-Identifier: BSD-3-Clause

This file is part of SMS Gateway:
https://github.com/JamesElstone/sms-gateway

See LICENSE for details.
-->
# SMS Gateway API

The API is mounted at:

```sh
http://<sms-gateway-server>/sms-gateway
```

All responses are JSON. The `/ping`, `/send/{mobile-number}`, and `/read`
endpoints require an enabled SMS Gateway token. Create a real token on the server first by
running [set_token.sh](config/set_token.sh):

```sh
cd config
sh ./set_token.sh
```

Generated tokens are shown once. Store the token somewhere safe and use it in
the examples below. This document uses a random example token; replace it with
your real token before testing:

```sh
SERVER='<sms-gateway-server>'
TOKEN='sgw_tU4qV3dE72hbME7mQphCNmY8LKLHpzP7euW4VTFdy8E'
BASE="http://$SERVER/sms-gateway"
```

## Status

```text
GET /
```

Returns current LTE dongle status. This endpoint does not require a token.

```sh
curl -i "$BASE/"
```

Example successful response shape:

```json
{
  "general": {
    "status": "connected",
    "health": "good",
    "ok": true,
    "message": "E3372 reachable",
    "sms_send": {
      "blocked": false,
      "status": "ready",
      "http_status": null,
      "message": "SMS send pre-flight checks passed"
    }
  },
  "status": "connected",
  "message": "E3372 reachable",
  "device": {
    "name": "E3372",
    "imei": "510563996265102"
  },
  "raw": {}
}
```

Common error responses include:

```json
{
  "status": "device_missing",
  "message": "LTE device returned HTTP 0"
}
```

## Ping

```text
GET /ping
```

Checks that the token is valid without contacting the LTE dongle or sending an
SMS.

```sh
curl -i \
  -H "X-SMS-Gateway-Token: $TOKEN" \
  "$BASE/ping"
```

You can also pass the token as a bearer token:

```sh
curl -i \
  -H "Authorization: Bearer $TOKEN" \
  "$BASE/ping"
```

Expected response:

```json
{
  "auth": "sucessful",
  "datetime": "2026-06-12T10:00:00+00:00",
  "ping": "pong"
}
```

Missing or invalid tokens return JSON like:

```json
{
  "status": "unauthorised",
  "message": "Missing authorisation token"
}
```

Disabled token entries return HTTP 403. Token entries without `"enabled": true`
are disabled by default. `enabled` may be a JSON boolean or a case-insensitive
string such as `"true"` or `"false"`.

## Read SMS

The read API returns messages from the local SMS cache. On FreeBSD, the
`sms_gateway` rc.d service starts the sync poller. For manual foreground
testing, run `php src/Service/sms-gateway-sync.php --interval 10` from the
application root.

On FreeBSD, authenticated read, peek, and ack activity is logged to
`/var/log/sms-gateway/read.log` by default.

Each enabled token has its own read log, keyed by the token `name` in
`config/tokens.json`.

```text
GET /read/
```

Returns messages not yet read by the calling token, then records those returned
message IDs as read for that token.

```sh
curl -i \
  -H "X-SMS-Gateway-Token: $TOKEN" \
  "$BASE/read/"
```

```text
GET /read/peek/
```

Returns messages not yet read by the calling token without changing read state.

```text
POST /read/ack/
```

Marks explicit cached message IDs as read for the calling token:

```sh
curl -i \
  -X POST \
  -H "X-SMS-Gateway-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"message_ids":["sms_..."]}' \
  "$BASE/read/ack/"
```

```text
GET /read/?all
```

Dumps cached SQLite messages without changing read state. Add `mark-read` to
record only the returned rows as read for the calling token:

```text
GET /read/?all&mark-read&limit=10
```

`limit` applies to `/read/`, `/read/peek/`, and `?all`.

Sender filtering uses the raw query string:

```text
GET /read/?07700%20000%20000
GET /read/?%2B447000%20000%20000
```

The leading `+` should be URL-encoded as `%2B`.

Example response:

```json
{
  "status": "ok",
  "mode": "unread",
  "token": "internal-app",
  "all": false,
  "marked_read": true,
  "limit": 100,
  "search": null,
  "count": 1,
  "messages": [
    {
      "id": "sms_...",
      "sender": "+447700900000",
      "sender_normalized": "07700900000",
      "content": "Example message",
      "device_date": "2026-06-12 16:25:10",
      "cached_at": "2026-06-12T16:25:20+00:00",
      "updated_at": "2026-06-12T16:25:20+00:00",
      "token_read_at": null,
      "modem_deleted_at": null,
      "device": {
        "source_device_id": "Imei:510563996265102",
        "index": 40009,
        "smstat": 0,
        "save_type": 4,
        "priority": 0,
        "sms_type": 1,
        "sca": null
      }
    }
  ]
}
```

## Send SMS

```text
POST /send/{mobile-number}
```

The mobile number is part of the URL path. The request body is sent as the SMS
message. The example number below is from Ofcom's drama range.

On FreeBSD, send attempts are logged to `/var/log/sms-gateway/send.log` by
default. SMS payloads are URL-encoded in the text log.

```sh
curl -i \
  -X POST \
  -H "X-SMS-Gateway-Token: $TOKEN" \
  -H "Content-Type: text/plain; charset=utf-8" \
  --data-binary 'Test SMS from the SMS Gateway API' \
  "$BASE/send/+447700900000"
```

Bearer-token form:

```sh
curl -i \
  -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: text/plain; charset=utf-8" \
  --data-binary 'Test SMS from the SMS Gateway API' \
  "$BASE/send/+447700900000"
```

Successful response:

```json
{
  "status": "sent",
  "mobile": "+447700900000",
  "message": "SMS sent"
}
```

Common send errors:

```json
{
  "status": "unauthorised",
  "message": "Invalid authorisation token"
}
```

```json
{
  "status": "unable_to_send",
  "message": "Invalid mobile number"
}
```

```json
{
  "status": "unable_to_send",
  "message": "SMS payload is empty"
}
```

```json
{
  "status": "no_service",
  "mobile": "+447700900000",
  "message": "LTE device has no mobile network service",
  "dongle": {}
}
```

## Quick Test Sequence

After creating a real token with [set_token.sh](config/set_token.sh), run:

```sh
SERVER='<sms-gateway-server>'
TOKEN='<token-created-by-set_token.sh>'
BASE="http://$SERVER/sms-gateway"

curl -i "$BASE/"

curl -i \
  -H "X-SMS-Gateway-Token: $TOKEN" \
  "$BASE/ping"

curl -i \
  -X POST \
  -H "X-SMS-Gateway-Token: $TOKEN" \
  -H "Content-Type: text/plain; charset=utf-8" \
  --data-binary 'Test SMS from the SMS Gateway API' \
  "$BASE/send/+447700900000"
```
