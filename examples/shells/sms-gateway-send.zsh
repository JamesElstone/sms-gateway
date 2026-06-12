#!/usr/bin/env zsh
emulate -R zsh
setopt no_unset

CURL_BIN="${SMS_GATEWAY_CURL:-curl}"
CHUNK_SIZE="${SMS_GATEWAY_CHUNK_SIZE:-160}"

usage() {
    cat <<EOF
Usage:
  sms-gateway-send.zsh SERVER TOKEN DESTINATION MESSAGE [MESSAGE...]

Send an SMS through the SMS Gateway API from Zsh.

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
  zsh ./examples/shells/sms-gateway-send.zsh sms.example.net "\$TOKEN" +447700900000 Hello from Zsh
  zsh ./examples/shells/sms-gateway-send.zsh http://sms.example.net/sms-gateway "\$TOKEN" +447700900000 "A longer message"

EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

prompt_required() {
    local prompt="$1"
    local value=""

    while [[ -z "$value" ]]; do
        printf '%s' "$prompt" >&2
        IFS= read -r value || die "input ended before ${prompt%: } was provided"
        [[ -n "$value" ]] || printf 'Please enter a value.\n' >&2
    done

    print -r -- "$value"
}

read_secret() {
    local secret=""
    local old_stty=""

    if [[ -t 0 ]]; then
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

    print -r -- "$secret"
}

prompt_secret_required() {
    local prompt="$1"
    local value=""

    while [[ -z "$value" ]]; do
        printf '%s' "$prompt" >&2
        value="$(read_secret)"
        [[ -n "$value" ]] || printf 'Please enter a value.\n' >&2
    done

    print -r -- "$value"
}

normalise_base_url() {
    local server="$1"
    local base="$server"

    case "$base" in
        http://*|https://*)
            ;;
        *)
            base="http://$base"
            ;;
    esac

    while [[ "${base%/}" != "$base" ]]; do
        base="${base%/}"
    done

    case "$base" in
        */sms-gateway)
            ;;
        *)
            base="$base/sms-gateway"
            ;;
    esac

    print -r -- "$base"
}

path_escape_mobile() {
    printf '%s' "$1" | sed 's/%/%25/g;s/ /%20/g;s/+/%2B/g;s/(/%28/g;s/)/%29/g'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing executable: $1"
}

case "$CHUNK_SIZE" in
    ''|*[!0-9]*)
        die "SMS_GATEWAY_CHUNK_SIZE must be a positive integer"
        ;;
esac
(( CHUNK_SIZE > 0 )) || die "SMS_GATEWAY_CHUNK_SIZE must be a positive integer"

if [[ "$#" -eq 1 ]]; then
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
    esac
fi

if [[ "$#" -eq 0 ]]; then
    usage >&2
    printf '\nInteractive send\n' >&2
    SERVER="$(prompt_required 'Server or base URL: ')"
    TOKEN="$(prompt_secret_required 'Token: ')"
    DESTINATION="$(prompt_required 'Destination number: ')"
    MESSAGE="$(prompt_required 'SMS payload: ')"
else
    [[ "$#" -ge 4 ]] || {
        usage >&2
        die "expected SERVER TOKEN DESTINATION MESSAGE"
    }

    SERVER="$1"
    TOKEN="$2"
    DESTINATION="$3"
    shift 3
    MESSAGE="$*"
fi

[[ -n "$SERVER" ]] || die "server is required"
[[ -n "$TOKEN" ]] || die "token is required"
[[ -n "$DESTINATION" ]] || die "destination is required"
[[ -n "$MESSAGE" ]] || die "message payload is required"

require_command "$CURL_BIN"
require_command sed
require_command mktemp

BASE_URL="$(normalise_base_url "$SERVER")"
DESTINATION_PATH="$(path_escape_mobile "$DESTINATION")"
SEND_URL="$BASE_URL/send/$DESTINATION_PATH"

TEMP_DIR="${TMPDIR:-/tmp}"
TEMP_DIR="${TEMP_DIR%/}"
[[ -n "$TEMP_DIR" ]] || TEMP_DIR="/"
RESPONSE_FILE="$(mktemp "$TEMP_DIR/sms-gateway-send-zsh-response.XXXXXX")" || die "unable to create temporary response file"
trap 'rm -f "$RESPONSE_FILE"' EXIT HUP INT TERM

message_length="${#MESSAGE}"
total_parts=$(( (message_length + CHUNK_SIZE - 1) / CHUNK_SIZE ))
part=0
start=1

while (( start <= message_length )); do
    end=$(( start + CHUNK_SIZE - 1 ))
    chunk="${MESSAGE[$start,$end]}"
    part=$((part + 1))
    printf 'Sending SMS part %s/%s to %s (%s characters)\n' "$part" "$total_parts" "$DESTINATION" "${#chunk}" >&2

    : > "$RESPONSE_FILE"
    if ! http_code="$(
        printf '%s' "$chunk" | "$CURL_BIN" -sS \
            -o "$RESPONSE_FILE" \
            -w '%{http_code}' \
            -X POST \
            -H "X-SMS-Gateway-Token: $TOKEN" \
            -H "Content-Type: text/plain; charset=utf-8" \
            --data-binary @- \
            "$SEND_URL"
    )"; then
        [[ ! -s "$RESPONSE_FILE" ]] || cat "$RESPONSE_FILE" >&2
        die "curl failed while sending SMS part $part/$total_parts"
    fi

    [[ ! -s "$RESPONSE_FILE" ]] || {
        cat "$RESPONSE_FILE"
        printf '\n'
    }

    [[ "$http_code" == 2?? ]] || die "gateway returned HTTP $http_code while sending SMS part $part/$total_parts"
    start=$((end + 1))
done

printf 'Sent %s SMS part(s).\n' "$total_parts" >&2
