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

final class CarrierMapper
{
    /** @var array<string, string> */
    private const STATES = [
        '1' => 'usable',
        '2' => 'registered',
        '3' => 'forbidden',
    ];

    /** @var array<string, string> */
    private const RATS = [
        '0' => '2G',
        '2' => '3G',
        '7' => '4G/LTE',
    ];

    /** @param array<string, mixed> $search */
    public static function fromSearch(array $search): array
    {
        $plmnList = self::arrayAt($search, 'plmn_list');
        $carriers = array_map(
            self::carrier(...),
            self::networkList(self::arrayAt($plmnList, 'Networks'))
        );
        $signalReported = self::hasReportedSignal($carriers);

        return [
            'status' => 'carrier_scan_complete',
            'message' => self::message(count($carriers), $signalReported),
            'count' => count($carriers),
            'signal_reported' => $signalReported,
            'carriers' => $carriers,
            'raw' => $search,
        ];
    }

    /** @param array<string, mixed> $networks */
    private static function networkList(array $networks): array
    {
        $network = $networks['Network'] ?? [];
        if (!is_array($network) || $network === []) {
            return [];
        }

        return array_is_list($network) ? array_values(array_filter($network, 'is_array')) : [$network];
    }

    /** @param array<string, mixed> $network */
    private static function carrier(array $network): array
    {
        $state = self::describedCode($network['State'] ?? null, self::STATES);
        $rat = self::describedCode($network['Rat'] ?? null, self::RATS);
        $signal = self::signal($network);

        return [
            'index' => self::intOrNull($network['Index'] ?? null),
            'name' => self::stringOrNull($network['FullName'] ?? null)
                ?? self::stringOrNull($network['ShortName'] ?? null)
                ?? self::stringOrNull($network['Numeric'] ?? null),
            'full_name' => self::stringOrNull($network['FullName'] ?? null),
            'short_name' => self::stringOrNull($network['ShortName'] ?? null),
            'numeric' => self::stringOrNull($network['Numeric'] ?? null),
            'state' => $state,
            'available' => in_array($state['label'], ['usable', 'registered'], true),
            'registered' => $state['label'] === 'registered',
            'forbidden' => $state['label'] === 'forbidden',
            'rat' => $rat,
            'signal' => $signal,
            'raw' => $network,
        ];
    }

    /** @param array<string, mixed> $network */
    private static function signal(array $network): array
    {
        $signal = [
            'rssi' => self::field($network, ['RSSI', 'Rssi', 'rssi']),
            'rsrp' => self::field($network, ['RSRP', 'Rsrp', 'rsrp']),
            'rsrq' => self::field($network, ['RSRQ', 'Rsrq', 'rsrq']),
            'sinr' => self::field($network, ['SINR', 'Sinr', 'sinr']),
            'strength' => self::intOrNull(self::field($network, ['SignalStrength', 'signalstrength', 'signal_strength'])),
            'icon' => self::intOrNull(self::field($network, ['SignalIcon', 'signalicon', 'signal_icon'])),
        ];

        return ['reported' => self::hasSignal($signal)] + $signal;
    }

    /** @param array<string, mixed> $carrier */
    private static function hasSignal(array $carrier): bool
    {
        foreach ($carrier as $key => $value) {
            if ($key !== 'reported' && $value !== null) {
                return true;
            }
        }

        return false;
    }

    /** @param list<array<string, mixed>> $carriers */
    private static function hasReportedSignal(array $carriers): bool
    {
        foreach ($carriers as $carrier) {
            if (($carrier['signal']['reported'] ?? false) === true) {
                return true;
            }
        }

        return false;
    }

    private static function message(int $count, bool $signalReported): string
    {
        $networkText = $count === 1 ? '1 carrier found' : $count . ' carriers found';
        $signalText = $signalReported ? 'per-carrier signal was reported' : 'per-carrier signal was not reported by the modem';

        return 'Carrier scan completed; ' . $networkText . '; ' . $signalText;
    }

    /** @param array<string, mixed> $values */
    private static function arrayAt(array $values, string $key): array
    {
        return isset($values[$key]) && is_array($values[$key]) ? $values[$key] : [];
    }

    /** @param array<string, string> $labels */
    private static function describedCode(mixed $code, array $labels): array
    {
        $value = self::stringOrNull($code);

        return [
            'code' => $value,
            'label' => $value === null ? 'unknown' : ($labels[$value] ?? 'unknown'),
        ];
    }

    /** @param array<string, mixed> $values */
    private static function field(array $values, array $keys): ?string
    {
        foreach ($keys as $key) {
            $value = self::stringOrNull($values[$key] ?? null);
            if ($value !== null) {
                return $value;
            }
        }

        return null;
    }

    private static function stringOrNull(mixed $value): ?string
    {
        if ($value === null || is_array($value)) {
            return null;
        }

        $string = trim((string) $value);
        return $string === '' ? null : $string;
    }

    private static function intOrNull(mixed $value): ?int
    {
        $string = self::stringOrNull($value);
        return $string !== null && preg_match('/^-?[0-9]+$/', $string) === 1 ? (int) $string : null;
    }
}
