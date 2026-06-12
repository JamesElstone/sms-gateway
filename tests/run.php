<?php
declare(strict_types=1);

// Copyright (c) 2026, James Elstone
// SPDX-License-Identifier: BSD-3-Clause
//
// This file is part of SMS Gateway:
// https://github.com/JamesElstone/sms-gateway
//
// See LICENSE for details.

require dirname(__DIR__) . '/src/autoload.php';

$files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator(dirname(__DIR__) . '/src'));
foreach ($files as $file) {
    if ($file->isFile() && $file->getExtension() === 'php') {
        passthru('php -l ' . escapeshellarg($file->getPathname()), $exitCode);
        if ($exitCode !== 0) {
            exit($exitCode);
        }
    }
}

passthru('php -l ' . escapeshellarg(dirname(__DIR__) . '/public/index.php'), $exitCode);
if ($exitCode !== 0) {
    exit($exitCode);
}

passthru('php -l ' . escapeshellarg(dirname(__DIR__) . '/config/set_token.php'), $exitCode);
if ($exitCode !== 0) {
    exit($exitCode);
}

passthru('php -l ' . escapeshellarg(dirname(__DIR__) . '/bin/sms-gateway-sync.php'), $exitCode);
if ($exitCode !== 0) {
    exit($exitCode);
}

function assert_test(bool $condition, string $message): void
{
    if (!$condition) {
        fwrite(STDERR, $message . "\n");
        exit(1);
    }
}

$carrierSummary = SmsGateway\CarrierMapper::fromSearch([
    'net_mode' => [
        'NetworkMode' => '03',
        'NetworkBand' => '3FFFFFFF',
        'LTEBand' => '7FFFFFFFFFFFFFFF',
    ],
    'net_mode_apply' => 'OK',
    'plmn_list' => [
        'Networks' => [
            'Network' => [
                [
                    'Index' => '0',
                    'State' => '1',
                    'FullName' => 'O2 - UK',
                    'ShortName' => 'O2 - UK',
                    'Numeric' => '23410',
                    'Rat' => '7',
                ],
                [
                    'Index' => '1',
                    'State' => '3',
                    'FullName' => 'vodafone UK',
                    'ShortName' => 'voda UK',
                    'Numeric' => '23415',
                    'Rat' => '7',
                ],
            ],
        ],
    ],
]);

if ($carrierSummary['status'] !== 'carrier_scan_complete') {
    fwrite(STDERR, "Carrier mapper status failed\n");
    exit(1);
}

if ($carrierSummary['count'] !== 2 || $carrierSummary['signal_reported'] !== false) {
    fwrite(STDERR, "Carrier mapper count/signal failed\n");
    exit(1);
}

if (($carrierSummary['carriers'][0]['state']['label'] ?? null) !== 'usable') {
    fwrite(STDERR, "Carrier mapper usable state failed\n");
    exit(1);
}

if (($carrierSummary['carriers'][1]['forbidden'] ?? null) !== true) {
    fwrite(STDERR, "Carrier mapper forbidden state failed\n");
    exit(1);
}

$testPrefix = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'sms-gateway-test-' . getmypid();
$lockPath = $testPrefix . '.lock';
$cachePath = $testPrefix . '.cache.json';
$forceStatePath = $testPrefix . '.force.json';
$tokenPath = $testPrefix . '.tokens.json';
$dbPath = $testPrefix . '.sqlite3';
@unlink($lockPath);
@unlink($cachePath);
@unlink($forceStatePath);
@unlink($tokenPath);
@unlink($dbPath);

file_put_contents($tokenPath, json_encode([
    'tokens' => [
        [
            'name' => 'ping-test',
            'enabled' => true,
            'token_sha256' => hash('sha256', 'ping-secret-token'),
            'allowed_ips' => ['127.0.0.1'],
        ],
        [
            'name' => 'string-enabled',
            'enabled' => 'TrUe',
            'token_sha256' => hash('sha256', 'string-enabled-token'),
            'allowed_ips' => ['127.0.0.1'],
        ],
        [
            'name' => 'disabled-test',
            'enabled' => false,
            'token_sha256' => hash('sha256', 'disabled-secret-token'),
            'allowed_ips' => ['127.0.0.1'],
        ],
        [
            'name' => 'missing-enabled-test',
            'token_sha256' => hash('sha256', 'missing-enabled-secret-token'),
            'allowed_ips' => ['127.0.0.1'],
        ],
        [
            'name' => 'ack-test',
            'enabled' => true,
            'token_sha256' => hash('sha256', 'ack-secret-token'),
            'allowed_ips' => ['127.0.0.1'],
        ],
        [
            'name' => 'all-test',
            'enabled' => true,
            'token_sha256' => hash('sha256', 'all-secret-token'),
            'allowed_ips' => ['127.0.0.1'],
        ],
        [
            'name' => 'filter-test',
            'enabled' => true,
            'token_sha256' => hash('sha256', 'filter-secret-token'),
            'allowed_ips' => ['127.0.0.1'],
        ],
    ],
]));

$config = new SmsGateway\Config([
    'dongle_url' => 'http://127.0.0.1:9/',
    'curl_timeout_seconds' => 1,
    'carrier_scan_timeout_seconds' => 1,
    'carrier_scan_lock_file' => $lockPath,
    'carrier_scan_cache_file' => $cachePath,
    'carrier_scan_force_state_file' => $forceStatePath,
    'token_file' => $tokenPath,
    'database_dsn' => 'sqlite:' . $dbPath,
    'sms_sync_lock_file' => $testPrefix . '.sms-sync.lock',
    'sms_read_default_limit' => 100,
]);

$app = new SmsGateway\App($config);

$response = $app->handle(
    'GET',
    '/sms-gateway/ping',
    '',
    ['X-SMS-Gateway-Token' => 'ping-secret-token'],
    '127.0.0.1'
);
if (
    $response->statusCode !== 200
    || ($response->payload['auth'] ?? null) !== 'sucessful'
    || ($response->payload['ping'] ?? null) !== 'pong'
) {
    fwrite(STDERR, "Authenticated ping response failed\n");
    exit(1);
}

$response = $app->handle(
    'GET',
    '/sms-gateway/ping',
    '',
    ['X-SMS-Gateway-Token' => 'string-enabled-token'],
    '127.0.0.1'
);
assert_test($response->statusCode === 200, 'String-enabled token ping response failed');

$response = $app->handle(
    'GET',
    '/sms-gateway/ping',
    '',
    ['X-SMS-Gateway-Token' => 'disabled-secret-token'],
    '127.0.0.1'
);
assert_test($response->statusCode === 403 && ($response->payload['message'] ?? null) === 'Token is disabled', 'Disabled token response failed');

$response = $app->handle(
    'GET',
    '/sms-gateway/ping',
    '',
    ['X-SMS-Gateway-Token' => 'missing-enabled-secret-token'],
    '127.0.0.1'
);
assert_test($response->statusCode === 403 && ($response->payload['message'] ?? null) === 'Token is disabled', 'Missing enabled token response failed');

$response = $app->handle('GET', '/sms-gateway/ping', '', [], '127.0.0.1');
if ($response->statusCode !== 401 || ($response->payload['status'] ?? null) !== 'unauthorised') {
    fwrite(STDERR, "Missing token ping response failed\n");
    exit(1);
}

file_put_contents($cachePath, json_encode([
    'created_at_epoch' => time(),
    'expires_at_epoch' => time() + 900,
    'payload' => [
        'status' => 'carrier_scan_complete',
        'message' => 'cached carrier scan',
        'count' => 99,
        'signal_reported' => false,
        'carriers' => [],
        'raw' => [],
    ],
]));
$response = $app->handle('GET', '/sms-gateway/carriers/', '', [], '127.0.0.1');
if ($response->statusCode !== 200 || ($response->payload['count'] ?? null) !== 99) {
    fwrite(STDERR, "Carrier scan fresh cache response failed\n");
    exit(1);
}

file_put_contents($forceStatePath, json_encode([
    'status' => 'recently_completed',
    'updated_at_epoch' => time(),
    'busy_until_epoch' => time() + 60,
]));
$response = $app->handle('GET', '/sms-gateway/carriers/', '', [], '127.0.0.1', ['force' => '']);
if ($response->statusCode !== 409 || ($response->payload['status'] ?? null) !== 'scan_in_progress') {
    fwrite(STDERR, "Carrier scan force suppression response failed\n");
    exit(1);
}
@unlink($forceStatePath);

$lock = fopen($lockPath, 'c');
if ($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) {
    fwrite(STDERR, "Carrier scan force lock setup failed\n");
    exit(1);
}

$response = $app->handle('GET', '/sms-gateway/carriers/', '', [], '127.0.0.1', ['force' => '']);
flock($lock, LOCK_UN);
fclose($lock);

if ($response->statusCode !== 409 || ($response->payload['status'] ?? null) !== 'scan_in_progress') {
    fwrite(STDERR, "Carrier scan force lock response failed\n");
    exit(1);
}
@unlink($cachePath);

$lock = fopen($lockPath, 'c');
if ($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) {
    fwrite(STDERR, "Carrier scan lock setup failed\n");
    exit(1);
}

$response = $app->handle('GET', '/sms-gateway/carriers/', '', [], '127.0.0.1');
flock($lock, LOCK_UN);
fclose($lock);

if ($response->statusCode !== 409 || ($response->payload['status'] ?? null) !== 'scan_in_progress') {
    fwrite(STDERR, "Carrier scan lock response failed\n");
    exit(1);
}

file_put_contents($cachePath, json_encode([
    'created_at_epoch' => time() - 1000,
    'expires_at_epoch' => time() - 100,
    'payload' => [
        'status' => 'carrier_scan_complete',
        'message' => 'stale cached carrier scan',
        'count' => 42,
        'signal_reported' => false,
        'carriers' => [],
        'raw' => [],
    ],
]));
$lock = fopen($lockPath, 'c');
if ($lock === false || !flock($lock, LOCK_EX | LOCK_NB)) {
    fwrite(STDERR, "Carrier scan stale cache lock setup failed\n");
    exit(1);
}

$response = $app->handle('GET', '/sms-gateway/carriers/', '', [], '127.0.0.1');
flock($lock, LOCK_UN);
fclose($lock);

if ($response->statusCode !== 200 || ($response->payload['count'] ?? null) !== 42) {
    fwrite(STDERR, "Carrier scan stale cache during lock response failed\n");
    exit(1);
}

$store = SmsGateway\Sms\SmsMessageStore::fromConfig($config);
$store->upsertMessages([
    [
        'Smstat' => '0',
        'Index' => '40009',
        'Phone' => '+447700900000',
        'Content' => 'First cached message',
        'Date' => '2026-06-12 16:25:10',
        'Sca' => '',
        'SaveType' => '4',
        'Priority' => '0',
        'SmsType' => '1',
    ],
    [
        'Smstat' => '1',
        'Index' => '40010',
        'Phone' => 'Lyca Mobile',
        'Content' => 'Network service message',
        'Date' => '2026-06-12 16:20:10',
        'Sca' => '',
        'SaveType' => '4',
        'Priority' => '0',
        'SmsType' => '2',
    ],
    [
        'Smstat' => '0',
        'Index' => '40011',
        'Phone' => '07700 900111',
        'Content' => 'Second cached message',
        'Date' => '2026-06-12 16:10:10',
        'Sca' => '',
        'SaveType' => '4',
        'Priority' => '0',
        'SmsType' => '1',
    ],
], 'test-device');

$pingHeaders = ['X-SMS-Gateway-Token' => 'ping-secret-token'];
$ackHeaders = ['X-SMS-Gateway-Token' => 'ack-secret-token'];
$allHeaders = ['X-SMS-Gateway-Token' => 'all-secret-token'];
$filterHeaders = ['X-SMS-Gateway-Token' => 'filter-secret-token'];

$response = $app->handle('GET', '/sms-gateway/read/peek/', '', $pingHeaders, '127.0.0.1');
assert_test($response->statusCode === 200 && ($response->payload['count'] ?? null) === 3, 'Peek unread response failed');
$firstPeekIds = array_column($response->payload['messages'], 'id');

$response = $app->handle('GET', '/sms-gateway/read/', '', $pingHeaders, '127.0.0.1');
assert_test($response->statusCode === 200 && ($response->payload['count'] ?? null) === 3 && ($response->payload['marked_read'] ?? null) === true, 'Default read response failed');

$response = $app->handle('GET', '/sms-gateway/read/peek/', '', $pingHeaders, '127.0.0.1');
assert_test($response->statusCode === 200 && ($response->payload['count'] ?? null) === 0, 'Default read did not mark token messages read');

$response = $app->handle('GET', '/sms-gateway/read/peek/', '', $ackHeaders, '127.0.0.1');
assert_test($response->statusCode === 200 && ($response->payload['count'] ?? null) === 3, 'Per-token unread response failed');
$ackIds = array_column($response->payload['messages'], 'id');

$response = $app->handle(
    'POST',
    '/sms-gateway/read/ack/',
    json_encode(['message_ids' => [$ackIds[0]]], JSON_UNESCAPED_SLASHES) ?: '{}',
    $ackHeaders,
    '127.0.0.1'
);
assert_test($response->statusCode === 200 && ($response->payload['acknowledged_count'] ?? null) === 1, 'Ack response failed');

$response = $app->handle('GET', '/sms-gateway/read/peek/', '', $ackHeaders, '127.0.0.1');
assert_test($response->statusCode === 200 && ($response->payload['count'] ?? null) === 2, 'Ack did not mark only supplied message read');

$response = $app->handle('GET', '/sms-gateway/read/', '', $allHeaders, '127.0.0.1', [
    'all' => '',
    'limit' => '2',
    '__raw_query' => 'all&limit=2',
]);
assert_test($response->statusCode === 200 && ($response->payload['count'] ?? null) === 2 && ($response->payload['marked_read'] ?? null) === false, 'All limit response failed');

$response = $app->handle('GET', '/sms-gateway/read/peek/', '', $allHeaders, '127.0.0.1');
assert_test($response->statusCode === 200 && ($response->payload['count'] ?? null) === 3, 'All unexpectedly marked messages read');

$response = $app->handle('GET', '/sms-gateway/read/', '', $allHeaders, '127.0.0.1', [
    'all' => '',
    'mark-read' => '',
    'limit' => '1',
    '__raw_query' => 'all&mark-read&limit=1',
]);
assert_test($response->statusCode === 200 && ($response->payload['count'] ?? null) === 1 && ($response->payload['marked_read'] ?? null) === true, 'All mark-read limit response failed');

$response = $app->handle('GET', '/sms-gateway/read/peek/', '', $allHeaders, '127.0.0.1');
assert_test($response->statusCode === 200 && ($response->payload['count'] ?? null) === 2, 'All mark-read limit marked the wrong number of messages');

$response = $app->handle('GET', '/sms-gateway/read/', '', $filterHeaders, '127.0.0.1', [
    '__raw_query' => '07700%20900000',
]);
assert_test(
    $response->statusCode === 200
    && ($response->payload['count'] ?? null) === 1
    && ($response->payload['messages'][0]['id'] ?? null) === $firstPeekIds[0],
    'Mobile sender filter response failed'
);

$response = $app->handle('GET', '/sms-gateway/read/peek/', '', $filterHeaders, '127.0.0.1');
assert_test($response->statusCode === 200 && ($response->payload['count'] ?? null) === 2, 'Mobile sender filter did not mark returned message read');

@unlink($lockPath);
@unlink($cachePath);
@unlink($forceStatePath);
@unlink($tokenPath);
@unlink($dbPath);

exit(0);
