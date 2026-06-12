<?php

declare(strict_types=1);

if ($argc < 5) {
    fwrite(STDERR, "Usage: php examples/php/send_sms.php BASE_URL TOKEN MOBILE MESSAGE [MESSAGE...]\n");
    fwrite(STDERR, "Example: php examples/php/send_sms.php http://sms.example.net/sms-gateway \$TOKEN +447700900000 Hello from PHP\n");
    exit(2);
}

$baseUrl = rtrim($argv[1], '/');
$token = $argv[2];
$mobile = $argv[3];
$message = implode(' ', array_slice($argv, 4));

$sendUrl = $baseUrl . '/send/' . rawurlencode($mobile);
$context = stream_context_create([
    'http' => [
        'method' => 'POST',
        'header' => implode("\r\n", [
            'X-SMS-Gateway-Token: ' . $token,
            'Content-Type: text/plain; charset=utf-8',
        ]),
        'content' => $message,
        'ignore_errors' => true,
    ],
]);

$responseBody = file_get_contents($sendUrl, false, $context);
$statusLine = $http_response_header[0] ?? '';
$httpStatus = preg_match('/^HTTP\/\S+\s+([0-9]{3})\b/', $statusLine, $matches) === 1
    ? (int) $matches[1]
    : 0;

if ($responseBody === false) {
    fwrite(STDERR, "Request failed\n");
    exit(1);
}

echo $responseBody . PHP_EOL;

if ($httpStatus < 200 || $httpStatus >= 300) {
    fwrite(STDERR, "Gateway returned HTTP $httpStatus\n");
    exit(1);
}
