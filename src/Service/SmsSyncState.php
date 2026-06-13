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

final class SmsSyncState
{
    public function __construct(private readonly Config $config)
    {
    }

    public function recordStarting(bool $daemon, int $intervalSeconds): void
    {
        $now = time();
        $previous = $this->readState();
        $this->writeState(array_merge($previous, [
            'status' => 'running',
            'mode' => $daemon ? 'daemon' : 'once',
            'pid' => getmypid(),
            'started_at_epoch' => $previous['started_at_epoch'] ?? $now,
            'last_heartbeat_at_epoch' => $now,
            'interval_seconds' => $intervalSeconds,
        ]));
    }

    /** @param array<string, mixed> $result */
    public function recordResult(array $result, bool $daemon, int $intervalSeconds): void
    {
        $now = time();
        $this->writeState([
            'status' => $daemon ? 'idle' : 'completed',
            'mode' => $daemon ? 'daemon' : 'once',
            'pid' => getmypid(),
            'started_at_epoch' => $this->readState()['started_at_epoch'] ?? $now,
            'last_heartbeat_at_epoch' => $now,
            'last_run_at_epoch' => $now,
            'interval_seconds' => $intervalSeconds,
            'last_result' => $result,
        ]);
    }

    public function recordStopping(bool $daemon, int $intervalSeconds): void
    {
        $now = time();
        $previous = $this->readState();
        $this->writeState(array_merge($previous, [
            'status' => 'stopped',
            'mode' => $daemon ? 'daemon' : 'once',
            'pid' => getmypid(),
            'last_heartbeat_at_epoch' => $now,
            'interval_seconds' => $intervalSeconds,
        ]));
    }

    /** @return array<string, mixed> */
    public function summary(): array
    {
        $state = $this->readState();
        if ($state === []) {
            return [
                'status' => 'never_run',
                'running' => false,
                'stale' => null,
                'message' => 'SMS sync service has not written a state file yet',
            ];
        }

        $now = time();
        $heartbeatAt = $this->intValue($state['last_heartbeat_at_epoch'] ?? null);
        $interval = max(1, $this->intValue($state['interval_seconds'] ?? null) ?? 10);
        $staleAfter = max(30, $interval * 3);
        $stale = $heartbeatAt === null || ($now - $heartbeatAt) > $staleAfter;
        $lockRunning = $this->syncLockHeld();
        $reportedStatus = $this->stringValue($state['status'] ?? null) ?? 'unknown';
        $running = $lockRunning || (!$stale && in_array($reportedStatus, ['running', 'idle'], true));
        $status = $stale ? 'stale' : $reportedStatus;

        return [
            'status' => $status,
            'running' => $running,
            'stale' => $stale,
            'message' => $this->message($status, $running, $heartbeatAt, $staleAfter),
            'mode' => $this->stringValue($state['mode'] ?? null),
            'pid' => $this->intValue($state['pid'] ?? null),
            'started_at' => $this->atom($this->intValue($state['started_at_epoch'] ?? null)),
            'last_heartbeat_at' => $this->atom($heartbeatAt),
            'last_run_at' => $this->atom($this->intValue($state['last_run_at_epoch'] ?? null)),
            'seconds_since_heartbeat' => $heartbeatAt === null ? null : max(0, $now - $heartbeatAt),
            'stale_after_seconds' => $staleAfter,
            'interval_seconds' => $interval,
            'sync_pass_running' => $lockRunning,
            'last_result' => isset($state['last_result']) && is_array($state['last_result']) ? $state['last_result'] : null,
        ];
    }

    /** @return array<string, mixed> */
    private function readState(): array
    {
        $json = @file_get_contents($this->config->smsSyncStateFile());
        if ($json === false || $json === '') {
            return [];
        }

        $state = json_decode($json, true);
        return is_array($state) ? $state : [];
    }

    /** @param array<string, mixed> $state */
    private function writeState(array $state): void
    {
        $path = $this->config->smsSyncStateFile();
        $dir = dirname($path);
        if (!is_dir($dir) && !mkdir($dir, 0770, true) && !is_dir($dir)) {
            return;
        }

        $json = json_encode($state, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
        if ($json === false) {
            return;
        }

        $tmpPath = $path . '.' . getmypid() . '.tmp';
        if (@file_put_contents($tmpPath, $json, LOCK_EX) === false) {
            return;
        }

        if (@rename($tmpPath, $path)) {
            return;
        }

        @unlink($path);
        if (!@rename($tmpPath, $path)) {
            @unlink($tmpPath);
        }
    }

    private function syncLockHeld(): bool
    {
        $handle = @fopen($this->config->smsSyncLockFile(), 'c');
        if ($handle === false) {
            return false;
        }

        $locked = flock($handle, LOCK_EX | LOCK_NB);
        if ($locked) {
            flock($handle, LOCK_UN);
        }
        fclose($handle);

        return !$locked;
    }

    private function atom(?int $epoch): ?string
    {
        return $epoch === null ? null : gmdate(DATE_ATOM, $epoch);
    }

    private function message(string $status, bool $running, ?int $heartbeatAt, int $staleAfter): string
    {
        if ($status === 'never_run') {
            return 'SMS sync service has not written a state file yet';
        }

        if ($status === 'stale') {
            return 'SMS sync service heartbeat is stale';
        }

        if ($running) {
            return 'SMS sync service heartbeat is recent';
        }

        if ($heartbeatAt === null) {
            return 'SMS sync service state exists but no heartbeat was recorded';
        }

        return 'SMS sync service last heartbeat was within ' . $staleAfter . ' seconds';
    }

    private function intValue(mixed $value): ?int
    {
        if ($value === null || is_array($value)) {
            return null;
        }

        $string = trim((string) $value);
        return preg_match('/^-?[0-9]+$/', $string) === 1 ? (int) $string : null;
    }

    private function stringValue(mixed $value): ?string
    {
        if ($value === null || is_array($value)) {
            return null;
        }

        $string = trim((string) $value);
        return $string === '' ? null : $string;
    }
}
