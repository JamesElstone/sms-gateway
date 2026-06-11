<?php

declare(strict_types=1);

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
@unlink($lockPath);
@unlink($cachePath);
@unlink($forceStatePath);

$app = new SmsGateway\App(new SmsGateway\Config([
    'dongle_url' => 'http://127.0.0.1:9/',
    'curl_timeout_seconds' => 1,
    'carrier_scan_timeout_seconds' => 1,
    'carrier_scan_lock_file' => $lockPath,
    'carrier_scan_cache_file' => $cachePath,
    'carrier_scan_force_state_file' => $forceStatePath,
]));

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
@unlink($lockPath);
@unlink($cachePath);
@unlink($forceStatePath);

if ($response->statusCode !== 200 || ($response->payload['count'] ?? null) !== 42) {
    fwrite(STDERR, "Carrier scan stale cache during lock response failed\n");
    exit(1);
}

exit(0);
