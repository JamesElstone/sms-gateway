# SMS Gateway API

The API is mounted at:

```sh
http://<sms-gateway-server>/sms-gateway
```

All responses are JSON. The `/ping` and `/send/{mobile-number}` endpoints
require an SMS Gateway token. Create a real token on the server first by
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

## Send SMS

```text
POST /send/{mobile-number}
```

The mobile number is part of the URL path. The request body is sent as the SMS
message. The example number below is from Ofcom's drama range.

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
