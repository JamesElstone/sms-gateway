<?php
declare(strict_types=1);

// Copyright (c) 2026, James Elstone
// SPDX-License-Identifier: BSD-3-Clause
//
// This file is part of SMS Gateway:
// https://github.com/JamesElstone/sms-gateway
//
// See LICENSE for details.

namespace SmsGateway;

final class Config
{
    /** @param array<string, mixed> $values */
    public function __construct(private readonly array $values)
    {
    }

    public function dongleUrl(): string
    {
        return rtrim((string) ($this->values['dongle_url'] ?? 'http://192.168.8.1/'), '/') . '/';
    }

    public function dongleUsername(): ?string
    {
        $value = $this->values['dongle_username'] ?? null;
        return $value === '' ? null : $value;
    }

    public function donglePassword(): ?string
    {
        $value = $this->values['dongle_password'] ?? null;
        return $value === '' ? null : $value;
    }

    public function curlTimeoutSeconds(): int
    {
        return max(1, (int) ($this->values['curl_timeout_seconds'] ?? 10));
    }

    public function carrierScanTimeoutSeconds(): int
    {
        return max(
            $this->curlTimeoutSeconds(),
            (int) ($this->values['carrier_scan_timeout_seconds'] ?? 240)
        );
    }

    public function carrierScanCacheTtlSeconds(): int
    {
        return max(1, (int) ($this->values['carrier_scan_cache_ttl_seconds'] ?? 900));
    }

    public function carrierScanForceSuppressionSeconds(): int
    {
        return max(1, (int) ($this->values['carrier_scan_force_suppression_seconds'] ?? 60));
    }

    public function carrierScanLockFile(): string
    {
        return (string) (
            $this->values['carrier_scan_lock_file']
            ?? sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'sms-gateway-carrier-scan.lock'
        );
    }

    public function carrierScanCacheFile(): string
    {
        return (string) (
            $this->values['carrier_scan_cache_file']
            ?? sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'sms-gateway-carrier-scan-cache.json'
        );
    }

    public function carrierScanForceStateFile(): string
    {
        return (string) (
            $this->values['carrier_scan_force_state_file']
            ?? sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'sms-gateway-carrier-scan-force.json'
        );
    }

    public function maxMessageBytes(): int
    {
        return max(1, (int) ($this->values['max_message_bytes'] ?? 1600));
    }

    public function databaseDsn(): string
    {
        return (string) (
            $this->values['database_dsn']
            ?? 'sqlite:' . dirname(__DIR__) . DIRECTORY_SEPARATOR . 'data' . DIRECTORY_SEPARATOR . 'sms-gateway.sqlite3'
        );
    }

    public function databaseUsername(): ?string
    {
        $value = $this->values['database_username'] ?? null;
        return $value === '' ? null : (is_string($value) ? $value : null);
    }

    public function databasePassword(): ?string
    {
        $value = $this->values['database_password'] ?? null;
        return $value === '' ? null : (is_string($value) ? $value : null);
    }

    public function smsReadDefaultLimit(): int
    {
        return max(1, min((int) ($this->values['sms_read_default_limit'] ?? 100), $this->smsReadMaxLimit()));
    }

    public function smsReadMaxLimit(): int
    {
        return max(1, (int) ($this->values['sms_read_max_limit'] ?? 500));
    }

    public function smsStoragePressureThreshold(): float
    {
        $value = (float) ($this->values['sms_storage_pressure_threshold'] ?? 0.9);
        return max(0.1, min($value, 1.0));
    }

    public function smsPressureDeleteBatchSize(): int
    {
        return max(1, (int) ($this->values['sms_pressure_delete_batch_size'] ?? 10));
    }

    public function smsSyncPageSize(): int
    {
        return max(1, min((int) ($this->values['sms_sync_page_size'] ?? 50), 500));
    }

    public function smsSyncLockFile(): string
    {
        return (string) (
            $this->values['sms_sync_lock_file']
            ?? sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'sms-gateway-sms-sync.lock'
        );
    }

    public function tokenFile(): string
    {
        return (string) ($this->values['token_file'] ?? dirname(__DIR__) . '/config/tokens.json');
    }
}
