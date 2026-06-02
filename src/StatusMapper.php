<?php

declare(strict_types=1);

namespace SmsGateway;

use SmsGateway\Lte\LteApiException;

final class StatusMapper
{
    private const LTE_SYSTEM_NO_SUPPORT = 100002;
    private const LTE_SYSTEM_NO_RIGHTS = 100003;
    private const LTE_SYSTEM_BUSY = 100004;
    private const LTE_SYSTEM_CSRF = 125002;
    private const LTE_WRONG_SESSION_TOKEN = 125003;

    /** @param array<string, mixed> $health */
    public static function fromHealth(array $health): ?Status
    {
        $simState = strtolower((string) ($health['pin_status']['SimState'] ?? $health['pin_status']['simstate'] ?? ''));
        $pinStatus = strtolower((string) ($health['pin_status']['SimStatus'] ?? $health['pin_status']['simstatus'] ?? ''));

        if (str_contains($simState, 'nosim') || str_contains($pinStatus, 'nosim')) {
            return new Status('sim_card_missing', 503, 'SIM card is missing or not detected');
        }

        $connectionStatus = (string) ($health['monitoring_status']['ConnectionStatus'] ?? '');
        if (in_array($connectionStatus, ['901', '902', '903', '904'], true)) {
            return new Status('data_plan_expired', 402, 'LTE data plan or network connection appears unavailable');
        }

        return null;
    }

    public static function fromLteApiException(LteApiException $exception): Status
    {
        return match ($exception->getLteCode()) {
            self::LTE_SYSTEM_NO_SUPPORT => new Status('lte_error', 502, 'LTE device API endpoint is not supported by this device'),
            self::LTE_SYSTEM_NO_RIGHTS => new Status('lte_error', 502, 'LTE device API requires login or credentials are missing'),
            self::LTE_SYSTEM_BUSY => new Status('unable_to_send', 503, 'LTE device is busy'),
            self::LTE_SYSTEM_CSRF,
            self::LTE_WRONG_SESSION_TOKEN => new Status('lte_error', 502, 'LTE device API session token failed'),
            default => new Status('lte_error', 502, $exception->getMessage()),
        };
    }
}
