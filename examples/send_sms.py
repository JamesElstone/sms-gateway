#!/usr/bin/env python3

import sys
import urllib.error
import urllib.parse
import urllib.request


def main() -> int:
    if len(sys.argv) < 5:
        print(
            "Usage: python send_sms.py BASE_URL TOKEN MOBILE MESSAGE [MESSAGE...]",
            file=sys.stderr,
        )
        print(
            "Example: python send_sms.py http://sms.example.net/sms-gateway "
            "$TOKEN +447700900000 Hello from Python",
            file=sys.stderr,
        )
        return 2

    base_url = sys.argv[1].rstrip("/")
    token = sys.argv[2]
    mobile = sys.argv[3]
    message = " ".join(sys.argv[4:])

    send_url = f"{base_url}/send/{urllib.parse.quote(mobile, safe='')}"
    request = urllib.request.Request(
        send_url,
        data=message.encode("utf-8"),
        method="POST",
        headers={
            "X-SMS-Gateway-Token": token,
            "Content-Type": "text/plain; charset=utf-8",
        },
    )

    try:
        with urllib.request.urlopen(request) as response:
            print(response.read().decode("utf-8"))
            return 0
    except urllib.error.HTTPError as error:
        print(error.read().decode("utf-8"), file=sys.stderr)
        print(f"Gateway returned HTTP {error.code}", file=sys.stderr)
        return 1
    except urllib.error.URLError as error:
        print(f"Request failed: {error.reason}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
