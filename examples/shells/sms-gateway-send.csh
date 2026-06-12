#!/bin/csh -f

# Copyright (c) 2026, James Elstone
# SPDX-License-Identifier: BSD-3-Clause
#
# This file is part of SMS Gateway:
# https://github.com/JamesElstone/sms-gateway
#
# See LICENSE for details.

if ($?SMS_GATEWAY_CURL) then
    set curl_bin = "$SMS_GATEWAY_CURL"
else
    set curl_bin = curl
endif

if ($?SMS_GATEWAY_CHUNK_SIZE) then
    set chunk_size = "$SMS_GATEWAY_CHUNK_SIZE"
else
    set chunk_size = 160
endif

set interactive = 0

if ($#argv == 1 && ("$1" == "-h" || "$1" == "--help")) then
    cat <<EOF
Usage:
  sms-gateway-send.csh SERVER TOKEN DESTINATION MESSAGE [MESSAGE...]

Send an SMS through the SMS Gateway API from Csh.

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
  csh ./examples/shells/sms-gateway-send.csh sms.example.net "\$TOKEN" +447700900000 Hello from Csh
  csh ./examples/shells/sms-gateway-send.csh http://sms.example.net/sms-gateway "\$TOKEN" +447700900000 "A longer message"

EOF
    exit 0
endif

if ($#argv == 0) then
    cat <<EOF
Usage:
  sms-gateway-send.csh SERVER TOKEN DESTINATION MESSAGE [MESSAGE...]

Send an SMS through the SMS Gateway API from Csh.

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
  csh ./examples/shells/sms-gateway-send.csh sms.example.net "\$TOKEN" +447700900000 Hello from Csh
  csh ./examples/shells/sms-gateway-send.csh http://sms.example.net/sms-gateway "\$TOKEN" +447700900000 "A longer message"

EOF
    echo ""
    echo "Interactive send"
    set interactive = 1
endif

echo "$chunk_size" | grep '^[0-9][0-9]*$' > /dev/null
if ($status != 0) then
    echo "ERROR: SMS_GATEWAY_CHUNK_SIZE must be a positive integer" > /dev/stderr
    exit 1
endif

if ($chunk_size <= 0) then
    echo "ERROR: SMS_GATEWAY_CHUNK_SIZE must be a positive integer" > /dev/stderr
    exit 1
endif

if ($interactive) then
    echo -n "Server or base URL: "
    set server = "$<"
    while ("$server" == "")
        echo "Please enter a value." > /dev/stderr
        echo -n "Server or base URL: "
        set server = "$<"
    end

    echo -n "Token: "
    if (-t 0) then
        stty -echo
        set token = "$<"
        stty echo
        echo ""
    else
        set token = "$<"
    endif
    while ("$token" == "")
        echo "Please enter a value." > /dev/stderr
        echo -n "Token: "
        if (-t 0) then
            stty -echo
            set token = "$<"
            stty echo
            echo ""
        else
            set token = "$<"
        endif
    end

    echo -n "Destination number: "
    set destination = "$<"
    while ("$destination" == "")
        echo "Please enter a value." > /dev/stderr
        echo -n "Destination number: "
        set destination = "$<"
    end

    echo -n "SMS payload: "
    set message = "$<"
    while ("$message" == "")
        echo "Please enter a value." > /dev/stderr
        echo -n "SMS payload: "
        set message = "$<"
    end
else
    if ($#argv < 4) then
        echo "Usage: sms-gateway-send.csh SERVER TOKEN DESTINATION MESSAGE [MESSAGE...]" > /dev/stderr
        echo "ERROR: expected SERVER TOKEN DESTINATION MESSAGE" > /dev/stderr
        exit 1
    endif

    set server = "$argv[1]"
    set token = "$argv[2]"
    set destination = "$argv[3]"
    set message = "$argv[4-]"
endif

if ("$server" == "") then
    echo "ERROR: server is required" > /dev/stderr
    exit 1
endif
if ("$token" == "") then
    echo "ERROR: token is required" > /dev/stderr
    exit 1
endif
if ("$destination" == "") then
    echo "ERROR: destination is required" > /dev/stderr
    exit 1
endif
if ("$message" == "") then
    echo "ERROR: message payload is required" > /dev/stderr
    exit 1
endif

which "$curl_bin" >& /dev/null
if ($status != 0) then
    echo "ERROR: missing executable: $curl_bin" > /dev/stderr
    exit 1
endif
foreach tool (awk grep mktemp printf sed tr wc)
    which "$tool" >& /dev/null
    if ($status != 0) then
        echo "ERROR: missing executable: $tool" > /dev/stderr
        exit 1
    endif
end

set base_url = "$server"
if ("$base_url" !~ http://* && "$base_url" !~ https://*) then
    set base_url = "http://$base_url"
endif
set base_url = `printf '%s' "$base_url" | sed 's:/*$::'`
if ("$base_url" !~ */sms-gateway) then
    set base_url = "$base_url/sms-gateway"
endif

set destination_path = `printf '%s' "$destination" | sed 's/%/%25/g;s/ /%20/g;s/+/%2B/g;s/(/%28/g;s/)/%29/g'`
set send_url = "$base_url/send/$destination_path"

if ($?TMPDIR) then
    set temp_dir = "$TMPDIR"
else
    set temp_dir = /tmp
endif
set temp_dir = `printf '%s' "$temp_dir" | sed 's:/*$::'`
if ("$temp_dir" == "") then
    set temp_dir = /
endif

set chunks_file = `mktemp "$temp_dir/sms-gateway-send-csh-chunks.XXXXXX"`
if ($status != 0) then
    echo "ERROR: unable to create temporary chunk file" > /dev/stderr
    exit 1
endif
set response_file = `mktemp "$temp_dir/sms-gateway-send-csh-response.XXXXXX"`
if ($status != 0) then
    rm -f "$chunks_file"
    echo "ERROR: unable to create temporary response file" > /dev/stderr
    exit 1
endif
set part_file = `mktemp "$temp_dir/sms-gateway-send-csh-part.XXXXXX"`
if ($status != 0) then
    rm -f "$chunks_file" "$response_file"
    echo "ERROR: unable to create temporary SMS part file" > /dev/stderr
    exit 1
endif

printf '%s' "$message" | awk -v chunk_size="$chunk_size" '{ text = text $0 } END { for (i = 1; i <= length(text); i += chunk_size) print substr(text, i, chunk_size) }' > "$chunks_file"
if ($status != 0) then
    rm -f "$chunks_file" "$response_file" "$part_file"
    echo "ERROR: unable to split message into SMS parts" > /dev/stderr
    exit 1
endif

set total_parts = `wc -l < "$chunks_file" | tr -d '[:space:]'`
if ($total_parts <= 0) then
    rm -f "$chunks_file" "$response_file" "$part_file"
    echo "ERROR: message payload is required" > /dev/stderr
    exit 1
endif

@ part = 1
while ($part <= $total_parts)
    awk -v part="$part" 'NR == part { printf "%s", $0 }' "$chunks_file" > "$part_file"
    if ($status != 0) then
        rm -f "$chunks_file" "$response_file" "$part_file"
        echo "ERROR: unable to read SMS part $part/$total_parts" > /dev/stderr
        exit 1
    endif

    set part_length = `wc -m < "$part_file" | tr -d '[:space:]'`
    echo "Sending SMS part $part/$total_parts to $destination ($part_length characters)" > /dev/stderr

    printf '' > "$response_file"
    set http_code = `"$curl_bin" -sS -o "$response_file" -w "%{http_code}" -X POST -H "X-SMS-Gateway-Token: $token" -H "Content-Type: text/plain; charset=utf-8" --data-binary @"$part_file" "$send_url"`
    if ($status != 0) then
        if (-s "$response_file") then
            cat "$response_file" > /dev/stderr
        endif
        rm -f "$chunks_file" "$response_file" "$part_file"
        echo "ERROR: curl failed while sending SMS part $part/$total_parts" > /dev/stderr
        exit 1
    endif

    if (-s "$response_file") then
        cat "$response_file"
        echo ""
    endif

    if ("$http_code" !~ 2??) then
        rm -f "$chunks_file" "$response_file" "$part_file"
        echo "ERROR: gateway returned HTTP $http_code while sending SMS part $part/$total_parts" > /dev/stderr
        exit 1
    endif

    @ part++
end

rm -f "$chunks_file" "$response_file" "$part_file"
echo "Sent $total_parts SMS part(s)." > /dev/stderr
