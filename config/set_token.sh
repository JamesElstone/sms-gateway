#!/bin/sh

# Copyright (c) 2026, James Elstone
# SPDX-License-Identifier: BSD-3-Clause
#
# This file is part of SMS Gateway:
# https://github.com/JamesElstone/sms-gateway
#
# See LICENSE for details.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PHP_BIN="${PHP_BIN:-php}"
HELPER="${SMS_GATEWAY_TOKEN_HELPER:-$SCRIPT_DIR/set_token.php}"
TOKEN_FILE="${SMS_GATEWAY_TOKEN_FILE:-$SCRIPT_DIR/tokens.json}"
TOKEN_FILE_OWNER="${SMS_GATEWAY_TOKEN_FILE_OWNER:-www}"
TOKEN_FILE_GROUP="${SMS_GATEWAY_TOKEN_FILE_GROUP:-www}"
SERVER_NAME="${SMS_GATEWAY_SERVER_NAME:-$(uname -n 2>/dev/null || hostname 2>/dev/null || printf '%s' '<deployed_server_dns_name>')}"
PING_URL="${SMS_GATEWAY_PING_URL:-http://$SERVER_NAME/sms-gateway/ping}"

TOKEN_NAME=""
ALLOWED_IPS=""
ALLOWED_IPS_SEEN=0
REPLACE=0
TOKEN_MODE=""
TOKEN_ENABLED=1

umask 077

usage() {
    cat <<EOF
Usage:
  sh set_token.sh [options]

Interactively create or replace an SMS Gateway authorisation token entry in
tokens.json. The plaintext token is never stored; only token_sha256 is written.

Options:
  -h, --help              Show this help text.
      --token-file PATH   Token JSON file. Default: $TOKEN_FILE
      --name NAME         Token entry name.
      --allowed-ips LIST  Comma or whitespace separated IP/CIDR allow-list.
                           Empty means any client IP may use this token.
      --replace           Replace an existing entry with the same name.
      --enabled           Store the token entry as enabled. This is the default.
      --disabled          Store the token entry as disabled.
      --generate          Generate a new random token.
      --paste             Prompt for an existing token instead.
      --ping-url URL      URL shown in the final curl ping example.
                           Default: $PING_URL

Environment:
  PHP_BIN                 PHP executable. Default: php
  SMS_GATEWAY_TOKEN_FILE  Default token JSON file.
  SMS_GATEWAY_TOKEN_FILE_OWNER
                          Owner for tokens.json when running as root. Default: www
  SMS_GATEWAY_TOKEN_FILE_GROUP
                          Group for tokens.json when running as root. Default: www
  SMS_GATEWAY_SERVER_NAME Default server name used in the ping URL.
  SMS_GATEWAY_PING_URL    Default ping URL for the curl example.

EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_value() {
    [ "$#" -ge 2 ] || die "missing value for $1"
}

prompt_default() {
    prompt="$1"
    default="$2"

    printf '%s' "$prompt" >&2
    if IFS= read -r answer; then
        if [ -n "$answer" ]; then
            printf '%s\n' "$answer"
            return
        fi
    fi

    printf '%s\n' "$default"
}

ask_yes_no() {
    prompt="$1"
    default="$2"

    while :; do
        answer="$(prompt_default "$prompt" "$default")"
        answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
        case "$answer" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                printf 'Please answer yes or no.\n' >&2
                ;;
        esac
    done
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

fix_token_file_permissions() {
    [ -f "$TOKEN_FILE" ] || return 0

    if [ "$(id -u 2>/dev/null || printf '1')" = "0" ]; then
        chown "$TOKEN_FILE_OWNER:$TOKEN_FILE_GROUP" "$TOKEN_FILE" 2>/dev/null || true
        chmod 0640 "$TOKEN_FILE" 2>/dev/null || true
        return 0
    fi

    chmod 0600 "$TOKEN_FILE" 2>/dev/null || true
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --token-file)
            require_value "$@"
            TOKEN_FILE="$2"
            shift 2
            ;;
        --token-file=*)
            TOKEN_FILE="${1#--token-file=}"
            shift
            ;;
        --name)
            require_value "$@"
            TOKEN_NAME="$2"
            shift 2
            ;;
        --name=*)
            TOKEN_NAME="${1#--name=}"
            shift
            ;;
        --allowed-ips)
            require_value "$@"
            ALLOWED_IPS="$2"
            ALLOWED_IPS_SEEN=1
            shift 2
            ;;
        --allowed-ips=*)
            ALLOWED_IPS="${1#--allowed-ips=}"
            ALLOWED_IPS_SEEN=1
            shift
            ;;
        --replace)
            REPLACE=1
            shift
            ;;
        --enabled)
            TOKEN_ENABLED=1
            shift
            ;;
        --disabled)
            TOKEN_ENABLED=0
            shift
            ;;
        --generate)
            [ -z "$TOKEN_MODE" ] || die "choose only one of --generate or --paste"
            TOKEN_MODE="generate"
            shift
            ;;
        --paste)
            [ -z "$TOKEN_MODE" ] || die "choose only one of --generate or --paste"
            TOKEN_MODE="paste"
            shift
            ;;
        --ping-url)
            require_value "$@"
            PING_URL="$2"
            shift 2
            ;;
        --ping-url=*)
            PING_URL="${1#--ping-url=}"
            shift
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

command -v "$PHP_BIN" >/dev/null 2>&1 || die "missing PHP executable: $PHP_BIN"
[ -f "$HELPER" ] || die "missing PHP helper: $HELPER"

printf '\nSMS Gateway token setup\n'
printf 'Token file: %s\n\n' "$TOKEN_FILE"

if [ -z "$TOKEN_NAME" ]; then
    TOKEN_NAME="$(prompt_default 'Token name [internal-app]: ' 'internal-app')"
fi
[ -n "$TOKEN_NAME" ] || die "token name is required"

if [ "$ALLOWED_IPS_SEEN" -eq 0 ]; then
    ALLOWED_IPS="$(prompt_default 'Allowed IPs/CIDRs [127.0.0.1, ::1, 192.168.0.0/16, 10.0.0.0/8]: ' '127.0.0.1, ::1, 192.168.0.0/16, 10.0.0.0/8')"
fi

set +e
"$PHP_BIN" "$HELPER" --entry-exists --token-file "$TOKEN_FILE" --name "$TOKEN_NAME" >/dev/null
exists_status="$?"
set -e

case "$exists_status" in
    0)
        if [ "$REPLACE" -eq 0 ]; then
            if ask_yes_no "Token entry '$TOKEN_NAME' already exists. Replace it? [y/N]: " "n"; then
                REPLACE=1
            else
                die "left existing token entry unchanged"
            fi
        fi
        ;;
    1)
        ;;
    *)
        die "could not inspect existing token file"
        ;;
esac

if [ -z "$TOKEN_MODE" ]; then
    if ask_yes_no 'Generate a new random token? [Y/n]: ' 'y'; then
        TOKEN_MODE="generate"
    else
        TOKEN_MODE="paste"
    fi
fi

if [ "$TOKEN_MODE" = "generate" ]; then
    TOKEN="$("$PHP_BIN" -r 'echo bin2hex(random_bytes(32)), PHP_EOL;')"
    printf '\nGenerated SMS Gateway token. Copy it now; it will not be shown again:\n\n'
    printf '%s\n\n' "$TOKEN"
    if [ -t 0 ]; then
        printf 'Press Enter once the token is stored somewhere safe...' >&2
        IFS= read -r _ack || true
        printf '\n' >&2
    fi
    TOKEN_PLACEHOLDER="<token-shown-once-above>"
else
    printf 'Paste existing SMS Gateway token. Input is hidden: ' >&2
    TOKEN="$(read_secret)"
    [ -n "$TOKEN" ] || die "token is required"
    TOKEN_PLACEHOLDER="<the-token-you-entered>"
fi

enabled_arg="--enabled"
if [ "$TOKEN_ENABLED" -eq 0 ]; then
    enabled_arg="--disabled"
fi

if [ "$REPLACE" -eq 1 ]; then
    printf '%s' "$TOKEN" | "$PHP_BIN" "$HELPER" \
        --token-file "$TOKEN_FILE" \
        --name "$TOKEN_NAME" \
        --allowed-ips "$ALLOWED_IPS" \
        "$enabled_arg" \
        --replace
else
    printf '%s' "$TOKEN" | "$PHP_BIN" "$HELPER" \
        --token-file "$TOKEN_FILE" \
        --name "$TOKEN_NAME" \
        --allowed-ips "$ALLOWED_IPS" \
        "$enabled_arg"
fi
TOKEN=""
fix_token_file_permissions

printf '\nPing check example:\n'
printf '  curl -i -H "X-SMS-Gateway-Token: %s" "%s"\n' "$TOKEN_PLACEHOLDER" "$PING_URL"
printf '\nExpected JSON includes:\n'
printf '  {"auth":"sucessful","datetime":"...","ping":"pong"}\n'
