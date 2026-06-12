#!/usr/bin/env php
<?php
declare(strict_types=1);

// Copyright (c) 2026, James Elstone
// SPDX-License-Identifier: BSD-3-Clause
//
// This file is part of SMS Gateway:
// https://github.com/JamesElstone/sms-gateway
//
// See LICENSE for details.

use SmsGateway\Config;
use SmsGateway\Lte\LteModemClient;
use SmsGateway\Security\FileTokenAuthorizer;
use SmsGateway\Sms\SmsMessageStore;
use SmsGateway\Sms\SmsSyncService;

require dirname(__DIR__) . '/src/autoload.php';

function sync_usage(): void
{
    $script = basename(__FILE__);
    echo <<<TEXT
Usage:
  php {$script} --once
  php {$script} [--interval SECONDS]

Options:
  --once              Run one sync pass and exit.
  --interval SECONDS  Poll interval for daemon mode. Default: 10.
  --help              Show this help text.

TEXT;
}

/** @param list<string> $args */
function sync_option_value(array $args, string $name): ?string
{
    foreach ($args as $index => $arg) {
        if ($arg === $name) {
            return $args[$index + 1] ?? null;
        }

        if (str_starts_with($arg, $name . '=')) {
            return substr($arg, strlen($name) + 1);
        }
    }

    return null;
}

$args = $argv;
array_shift($args);

if (in_array('--help', $args, true) || in_array('-h', $args, true)) {
    sync_usage();
    exit(0);
}

$once = in_array('--once', $args, true);
$intervalValue = sync_option_value($args, '--interval') ?? '10';
if (preg_match('/^[0-9]+$/', $intervalValue) !== 1 || (int) $intervalValue < 1) {
    fwrite(STDERR, "ERROR: --interval must be a positive integer\n");
    exit(2);
}
$interval = (int) $intervalValue;

$configFile = dirname(__DIR__) . '/config/local.php';
if (!is_file($configFile)) {
    $configFile = dirname(__DIR__) . '/config/local.php.example';
}

$config = new Config(require $configFile);
$store = SmsMessageStore::fromConfig($config);
$client = new LteModemClient(
    $config->dongleUrl(),
    $config->dongleUsername(),
    $config->donglePassword(),
    $config->curlTimeoutSeconds()
);
$authorizer = new FileTokenAuthorizer($config->tokenFile());
$sync = new SmsSyncService($config, $store, $client);

do {
    $result = $sync->syncIfNeeded($authorizer->enabledTokenNames());
    echo json_encode([
        'datetime' => gmdate(DATE_ATOM),
        'result' => $result,
    ], JSON_UNESCAPED_SLASHES) . PHP_EOL;

    if (!$once) {
        sleep($interval);
    }
} while (!$once);
