<?php
declare(strict_types=1);

// Copyright (c) 2026, James Elstone
// SPDX-License-Identifier: BSD-3-Clause
//
// This file is part of SMS Gateway:
// https://github.com/JamesElstone/sms-gateway
//
// See LICENSE for details.

namespace SmsGateway\Service;

use SmsGateway\Config;
use SmsGateway\Lte\LteModemClient;
use SmsGateway\Security\FileTokenAuthorizer;
use SmsGateway\Sms\SmsMessageStore;
use SmsGateway\Sms\SmsSyncService;

final class SmsGatewaySyncCommand
{
    public function __construct(private readonly string $rootDir)
    {
    }

    /** @param list<string> $argv */
    public function run(array $argv): int
    {
        $script = basename($argv[0] ?? 'sms-gateway-sync.php');
        $args = $argv;
        array_shift($args);

        if (in_array('--help', $args, true) || in_array('-h', $args, true)) {
            $this->usage($script);
            return 0;
        }

        $once = in_array('--once', $args, true);
        $intervalValue = $this->optionValue($args, '--interval') ?? '10';
        if (preg_match('/^[0-9]+$/', $intervalValue) !== 1 || (int) $intervalValue < 1) {
            fwrite(STDERR, "ERROR: --interval must be a positive integer\n");
            return 2;
        }
        $interval = (int) $intervalValue;

        $config = Config::fromRoot($this->rootDir);
        $store = SmsMessageStore::fromConfig($config);
        $client = new LteModemClient(
            $config->dongleUrl(),
            $config->dongleUsername(),
            $config->donglePassword(),
            $config->curlTimeoutSeconds()
        );
        $authorizer = new FileTokenAuthorizer($config->tokenFile());
        $sync = new SmsSyncService($config, $store, $client);
        $state = new SmsSyncState($config);

        do {
            $state->recordStarting(!$once, $interval);
            $result = $sync->syncIfNeeded($authorizer->enabledTokenNames());
            $state->recordResult($result, !$once, $interval);
            echo json_encode([
                'datetime' => gmdate(DATE_ATOM),
                'result' => $result,
            ], JSON_UNESCAPED_SLASHES) . PHP_EOL;

            if (!$once) {
                sleep($interval);
            }
        } while (!$once);

        return 0;
    }

    private function usage(string $script): void
    {
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
    private function optionValue(array $args, string $name): ?string
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

}
