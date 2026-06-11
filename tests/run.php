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

exit(0);
