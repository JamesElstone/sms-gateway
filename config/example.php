<?php

return [
    'dongle_url' => getenv('SMS_GATEWAY_DONGLE_URL') ?: 'http://192.168.8.1/',
    'dongle_username' => getenv('SMS_GATEWAY_DONGLE_USERNAME') ?: null,
    'dongle_password' => getenv('SMS_GATEWAY_DONGLE_PASSWORD') ?: null,
    'curl_timeout_seconds' => (int) (getenv('SMS_GATEWAY_CURL_TIMEOUT') ?: 10),
    'max_message_bytes' => (int) (getenv('SMS_GATEWAY_MAX_MESSAGE_BYTES') ?: 1600),
    'token_file' => getenv('SMS_GATEWAY_TOKEN_FILE') ?: dirname(__DIR__) . '/config/tokens.json',
];
