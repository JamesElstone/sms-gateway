#!/bin/sh

# Copyright (c) 2026, James Elstone
# SPDX-License-Identifier: BSD-3-Clause
#
# This file is part of SMS Gateway:
# https://github.com/JamesElstone/sms-gateway
#
# See LICENSE for details.
set -u

CURL_BIN="${SMS_GATEWAY_CURL:-curl}"
CHUNK_SIZE="${SMS_GATEWAY_CHUNK_SIZE:-160}"

usage() {
    cat <<EOF
Usage:
  sms-gateway-send SERVER TOKEN DESTINATION MESSAGE [MESSAGE...]

Send an SMS through the SMS Gateway API from the command line.

Arguments:
  SERVER       Gateway host, origin URL, or full API base URL.
               Examples: sms.example.net, http://sms.example.net,
               http://sms.example.net/sms-gateway
  TOKEN        SMS Gateway authorisation token.
  DESTINATION  Destination mobile number.
  MESSAGE      SMS payload. Multiple words are joined with spaces.

When no arguments are supplied, this help text is shown and the script prompts
for each field interactively.

Environment:
  SMS_GATEWAY_CURL        curl executable. Default: curl
  SMS_GATEWAY_CHUNK_SIZE  Characters per SMS part. Default: 160

Examples:
  sh ./examples/shells/sms-gateway-send.sh sms.example.net "\$TOKEN" +447700900000 Hello from CLI
  sh ./examples/shells/sms-gateway-send.sh http://sms.example.net/sms-gateway "\$TOKEN" +447700900000 "A longer message"

EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

prompt_required() {
    prompt="$1"
    value=""

    while [ -z "$value" ]; do
        printf '%s' "$prompt" >&2
        if ! IFS= read -r value; then
            die "input ended before ${prompt%: } was provided"
        fi

        [ -n "$value" ] || printf 'Please enter a value.\n' >&2
    done

    printf '%s\n' "$value"
}

read_secret() {
    if [ -t 0 ]; then
        old_stty="$(stty -g)"
        trap 'stty "$old_stty" >/dev/null 2>&1 || true' INT TERM EXIT
        stty -echo
        IFS= read -r secret || secret=""
        stty "$old_stty"
        trap - INT TERM EXIT
        printf '\n' >&2
    else
        IFS= read -r secret || secret=""
    fi

    printf '%s\n' "$secret"
}

prompt_secret_required() {
    prompt="$1"
    value=""

    while [ -z "$value" ]; do
        printf '%s' "$prompt" >&2
        value="$(read_secret)"
        [ -n "$value" ] || printf 'Please enter a value.\n' >&2
    done

    printf '%s\n' "$value"
}

normalise_base_url() {
    server="$1"

    case "$server" in
        http://*|https://*)
            base="$server"
            ;;
        *)
            base="http://$server"
            ;;
    esac

    while [ "${base%/}" != "$base" ]; do
        base="${base%/}"
    done

    case "$base" in
        */sms-gateway)
            ;;
        *)
            base="$base/sms-gateway"
            ;;
    esac

    printf '%s\n' "$base"
}

path_escape_mobile() {
    printf '%s' "$1" | sed 's/%/%25/g;s/ /%20/g;s/+/%2B/g;s/(/%28/g;s/)/%29/g'
}

message_length() {
    printf '%s' "$1" | awk 'BEGIN { text = "" } { text = text $0 } END { print length(text) }'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing executable: $1"
}

case "$CHUNK_SIZE" in
    ''|*[!0-9]*)
        die "SMS_GATEWAY_CHUNK_SIZE must be a positive integer"
        ;;
esac

[ "$CHUNK_SIZE" -gt 0 ] 2>/dev/null || die "SMS_GATEWAY_CHUNK_SIZE must be a positive integer"

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
    exit 0
fi

if [ "$#" -eq 0 ]; then
    usage >&2
    printf '\nInteractive send\n' >&2
    SERVER="$(prompt_required 'Server or base URL: ')"
    TOKEN="$(prompt_secret_required 'Token: ')"
    DESTINATION="$(prompt_required 'Destination number: ')"
    MESSAGE="$(prompt_required 'SMS payload: ')"
else
    [ "$#" -ge 4 ] || {
        usage >&2
        die "expected SERVER TOKEN DESTINATION MESSAGE"
    }

    SERVER="$1"
    TOKEN="$2"
    DESTINATION="$3"
    shift 3
    MESSAGE="$*"
fi

[ -n "$SERVER" ] || die "server is required"
[ -n "$TOKEN" ] || die "token is required"
[ -n "$DESTINATION" ] || die "destination is required"
[ -n "$MESSAGE" ] || die "message payload is required"

require_command "$CURL_BIN"
require_command awk
require_command sed
require_command mktemp

BASE_URL="$(normalise_base_url "$SERVER")"
DESTINATION_PATH="$(path_escape_mobile "$DESTINATION")"
SEND_URL="$BASE_URL/send/$DESTINATION_PATH"

TMPDIR="${TMPDIR:-/tmp}"
TMPDIR="${TMPDIR%/}"
[ -n "$TMPDIR" ] || TMPDIR="/"
CHUNKS_FILE="$(mktemp "$TMPDIR/sms-gateway-send-chunks.XXXXXX")" || die "unable to create temporary chunk file"
RESPONSE_FILE="$(mktemp "$TMPDIR/sms-gateway-send-response.XXXXXX")" || die "unable to create temporary response file"
trap 'rm -f "$CHUNKS_FILE" "$RESPONSE_FILE"' EXIT HUP INT TERM

printf '%s' "$MESSAGE" | awk -v chunk_size="$CHUNK_SIZE" '
    BEGIN {
        text = ""
    }
    NR == 1 {
        text = $0
        next
    }
    {
        text = text "\n" $0
    }
    END {
        for (i = 1; i <= length(text); i += chunk_size) {
            print substr(text, i, chunk_size)
        }
    }
' > "$CHUNKS_FILE" || die "unable to split message into SMS parts"

TOTAL_PARTS="$(wc -l < "$CHUNKS_FILE" | tr -d '[:space:]')"
[ "$TOTAL_PARTS" -gt 0 ] 2>/dev/null || die "message payload is required"

part=0
while IFS= read -r chunk; do
    part=$((part + 1))
    length="$(message_length "$chunk")"
    printf 'Sending SMS part %s/%s to %s (%s characters)\n' "$part" "$TOTAL_PARTS" "$DESTINATION" "$length" >&2

    : > "$RESPONSE_FILE"
    http_code="$(
        printf '%s' "$chunk" | "$CURL_BIN" -sS \
            -o "$RESPONSE_FILE" \
            -w '%{http_code}' \
            -X POST \
            -H "X-SMS-Gateway-Token: $TOKEN" \
            -H "Content-Type: text/plain; charset=utf-8" \
            --data-binary @- \
            "$SEND_URL"
    )"
    curl_status="$?"

    if [ "$curl_status" -ne 0 ]; then
        [ ! -s "$RESPONSE_FILE" ] || cat "$RESPONSE_FILE" >&2
        die "curl failed while sending SMS part $part/$TOTAL_PARTS"
    fi

    [ ! -s "$RESPONSE_FILE" ] || {
        cat "$RESPONSE_FILE"
        printf '\n'
    }

    case "$http_code" in
        2??)
            ;;
        *)
            die "gateway returned HTTP $http_code while sending SMS part $part/$TOTAL_PARTS"
            ;;
    esac
done < "$CHUNKS_FILE"

printf 'Sent %s SMS part(s).\n' "$TOTAL_PARTS" >&2
