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

    /** @var array<string, string> */
    private const PIN_STATES = [
        '255' => 'no_sim_card',
        '256' => 'cpin_failed',
        '257' => 'pin_ready',
        '258' => 'pin_disabled',
        '259' => 'pin_validating',
        '260' => 'pin_required',
        '261' => 'puk_required',
    ];

    /** @var array<string, string> */
    private const CONNECTION_STATES = [
        '900' => 'connecting',
        '901' => 'connected',
        '902' => 'disconnected',
        '903' => 'disconnecting',
        '904' => 'connect_failed',
        '905' => 'connect_failed_signal_poor',
        '112' => 'auto_connect_forbidden',
        '113' => 'auto_connect_forbidden_roaming',
        '114' => 'reconnect_forbidden',
        '115' => 'reconnect_forbidden_roaming',
        '201' => 'traffic_limit_exceeded',
    ];

    /** @var array<string, string> */
    private const SIM_STATES = [
        '0' => 'usim_unavailable',
        '1' => 'usim_available',
        '2' => 'usim_circuit_switched_unavailable',
        '3' => 'usim_packet_switched_unavailable',
        '4' => 'usim_packet_and_circuit_switched_unavailable',
        '240' => 'romsim',
        '255' => 'usim_not_present',
    ];

    /** @var array<string, string> */
    private const NETWORK_TYPES = [
        '0' => 'no_service',
        '1' => 'GSM',
        '2' => 'GPRS',
        '3' => 'EDGE',
        '4' => 'WCDMA',
        '5' => 'HSDPA',
        '6' => 'HSUPA',
        '7' => 'HSPA',
        '8' => 'TD-SCDMA',
        '9' => 'HSPA+',
        '10' => 'EVDO Rev. 0',
        '11' => 'EVDO Rev. A',
        '12' => 'EVDO Rev. B',
        '13' => '1xRTT',
        '14' => 'UMB',
        '15' => '1xEVDV',
        '16' => '3xRTT',
        '17' => 'HSPA+ 64QAM',
        '18' => 'HSPA+ MIMO',
        '19' => 'LTE',
        '41' => 'WCDMA',
        '42' => 'HSDPA',
        '43' => 'HSUPA',
        '44' => 'HSPA',
        '45' => 'HSPA+',
        '46' => 'DC-HSPA+',
        '61' => 'TD-SCDMA',
        '62' => 'TD-HSDPA',
        '63' => 'TD-HSUPA',
        '64' => 'TD-HSPA',
        '65' => 'TD-HSPA+',
        '81' => '802.16E',
        '101' => 'LTE',
    ];

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

    /** @param array<string, mixed> $health */
    public static function summarizeHealth(array $health): array
    {
        $device = self::arrayAt($health, 'device_information');
        $basic = self::arrayAt($health, 'basic_information');
        $pin = self::arrayAt($health, 'pin_status');
        $monitoring = self::arrayAt($health, 'monitoring_status');
        $signal = self::arrayAt($health, 'signal');
        $smsCount = self::arrayAt($health, 'sms_count');
        $notifications = self::arrayAt($health, 'notifications');
        $moduleSwitch = self::arrayAt($health, 'module_switch');
        $dataSwitch = self::arrayAt($health, 'mobile_dataswitch');
        $dialup = self::arrayAt($health, 'dialup_connection');
        $plmn = self::arrayAt($health, 'current_plmn');
        $traffic = self::arrayAt($health, 'traffic_statistics');
        $login = self::arrayAt($health, 'user_state_login');

        $connection = self::describedCode($monitoring['ConnectionStatus'] ?? null, self::CONNECTION_STATES);
        $simState = self::describedCode($pin['SimState'] ?? $health['converged_status']['SimState'] ?? null, self::PIN_STATES);
        $pinOption = self::describedCode($pin['PinOptState'] ?? null, self::PIN_STATES);
        $simStatus = self::describedCode($monitoring['SimStatus'] ?? null, self::SIM_STATES);
        $networkType = self::describedCode($monitoring['CurrentNetworkType'] ?? null, self::NETWORK_TYPES);
        $networkTypeEx = self::describedCode($monitoring['CurrentNetworkTypeEx'] ?? null, self::NETWORK_TYPES);
        $serviceStatus = self::serviceStatus($monitoring['ServiceStatus'] ?? null);
        $workMode = self::stringOrNull($device['workmode'] ?? $device['WorkMode'] ?? null);
        $signalIcon = self::intOrNull($monitoring['SignalIcon'] ?? null);
        $maxSignal = self::intOrNull($monitoring['maxsignal'] ?? null);

        $status = self::overallStatus($connection['label'], $simState['label'], $serviceStatus['label'], $workMode);
        $message = self::statusMessage(
            self::stringOrNull($device['DeviceName'] ?? $basic['devicename'] ?? null),
            $status,
            $simState['label'],
            $connection['label'],
            $networkTypeEx['label'] !== 'unknown' ? $networkTypeEx['label'] : $networkType['label'],
            $signalIcon,
            $maxSignal
        );

        return [
            'status' => $status,
            'message' => $message,
            'device' => [
                'name' => self::stringOrNull($device['DeviceName'] ?? $basic['devicename'] ?? null),
                'imei' => self::stringOrNull($device['Imei'] ?? null),
                'imsi' => self::stringOrNull($device['Imsi'] ?? null),
                'iccid' => self::stringOrNull($device['Iccid'] ?? null),
                'msisdn' => self::stringOrNull($device['Msisdn'] ?? null),
                'hardware_version' => self::stringOrNull($device['HardwareVersion'] ?? null),
                'software_version' => self::stringOrNull($device['SoftwareVersion'] ?? $basic['SoftwareVersion'] ?? null),
                'web_ui_version' => self::stringOrNull($device['WebUIVersion'] ?? $basic['WebUIVersion'] ?? null),
                'lan_mac_address' => self::stringOrNull($device['MacAddress1'] ?? null),
                'wan_ip_address' => self::stringOrNull($device['WanIPAddress'] ?? null),
                'wan_ipv6_address' => self::stringOrNull($device['WanIPv6Address'] ?? null),
                'product_family' => self::stringOrNull($device['ProductFamily'] ?? $basic['productfamily'] ?? null),
                'classify' => self::stringOrNull($device['Classify'] ?? $basic['classify'] ?? null),
                'support_mode' => self::stringOrNull($device['supportmode'] ?? null),
                'work_mode' => $workMode,
            ],
            'sim' => [
                'state' => $simState,
                'pin_option_state' => $pinOption,
                'status' => $simStatus,
                'pin_attempts_remaining' => self::intOrNull($pin['SimPinTimes'] ?? null),
                'puk_attempts_remaining' => self::intOrNull($pin['SimPukTimes'] ?? null),
                'sim_lock_enabled' => self::flag($health['converged_status']['SimLockEnable'] ?? null),
            ],
            'network' => [
                'connection' => $connection,
                'service' => $serviceStatus,
                'service_domain' => self::describedCode($monitoring['CurrentServiceDomain'] ?? null, [
                    '0' => 'no_service',
                    '1' => 'circuit_switched_only',
                    '2' => 'packet_switched_only',
                    '3' => 'packet_and_circuit_switched',
                ]),
                'current_network_type' => $networkType,
                'current_network_type_ex' => $networkTypeEx,
                'roaming' => self::describedCode($monitoring['RoamingStatus'] ?? null, [
                    '0' => 'not_roaming',
                    '1' => 'roaming',
                ]),
                'plmn' => [
                    'state' => self::stringOrNull($plmn['State'] ?? null),
                    'full_name' => self::stringOrNull($plmn['FullName'] ?? null),
                    'short_name' => self::stringOrNull($plmn['ShortName'] ?? null),
                    'numeric' => self::stringOrNull($plmn['Numeric'] ?? null),
                    'rat' => self::stringOrNull($plmn['Rat'] ?? null),
                ],
                'mobile_data_enabled' => self::flag($dataSwitch['dataswitch'] ?? null),
                'dialup' => [
                    'connect_mode' => self::describedCode($dialup['ConnectMode'] ?? null, [
                        '0' => 'auto',
                        '1' => 'manual',
                    ]),
                    'roam_auto_connect_enabled' => self::flag($dialup['RoamAutoConnectEnable'] ?? null),
                    'auto_dial_enabled' => self::flag($dialup['auto_dial_switch'] ?? null),
                    'pdp_always_on' => self::flag($dialup['pdp_always_on'] ?? null),
                    'mtu' => self::intOrNull($dialup['MTU'] ?? null),
                ],
            ],
            'signal' => [
                'icon' => $signalIcon,
                'strength' => self::intOrNull($monitoring['SignalStrength'] ?? null),
                'max' => $maxSignal,
                'pci' => self::stringOrNull($signal['pci'] ?? null),
                'cell_id' => self::stringOrNull($signal['cell_id'] ?? null),
                'rsrq' => self::stringOrNull($signal['rsrq'] ?? null),
                'rsrp' => self::stringOrNull($signal['rsrp'] ?? null),
                'rssi' => self::stringOrNull($signal['rssi'] ?? null),
                'sinr' => self::stringOrNull($signal['sinr'] ?? null),
                'mode' => self::stringOrNull($signal['mode'] ?? null),
                'lte_bandwidth' => self::stringOrNull($signal['lte_bandwidth'] ?? null),
                'lte_bandinfo' => self::stringOrNull($signal['lte_bandinfo'] ?? null),
            ],
            'sms' => [
                'enabled' => self::flag($moduleSwitch['sms_enabled'] ?? null),
                'local_unread' => self::intOrNull($smsCount['LocalUnread'] ?? null),
                'local_inbox' => self::intOrNull($smsCount['LocalInbox'] ?? null),
                'local_outbox' => self::intOrNull($smsCount['LocalOutbox'] ?? null),
                'local_draft' => self::intOrNull($smsCount['LocalDraft'] ?? null),
                'local_max' => self::intOrNull($smsCount['LocalMax'] ?? null),
                'sim_unread' => self::intOrNull($smsCount['SimUnread'] ?? null),
                'sim_inbox' => self::intOrNull($smsCount['SimInbox'] ?? null),
                'sim_outbox' => self::intOrNull($smsCount['SimOutbox'] ?? null),
                'sim_draft' => self::intOrNull($smsCount['SimDraft'] ?? null),
                'sim_used' => self::intOrNull($smsCount['SimUsed'] ?? null),
                'sim_max' => self::intOrNull($smsCount['SimMax'] ?? null),
                'new_message_count' => self::intOrNull($smsCount['NewMsg'] ?? null),
                'storage_full' => self::flag($notifications['SmsStorageFull'] ?? null),
                'unread_notifications' => self::intOrNull($notifications['UnreadMessage'] ?? null),
            ],
            'traffic' => [
                'current_connect_time_seconds' => self::intOrNull($traffic['CurrentConnectTime'] ?? null),
                'current_upload_bytes' => self::intOrNull($traffic['CurrentUpload'] ?? null),
                'current_download_bytes' => self::intOrNull($traffic['CurrentDownload'] ?? null),
                'current_upload_rate_bps' => self::intOrNull($traffic['CurrentUploadRate'] ?? null),
                'current_download_rate_bps' => self::intOrNull($traffic['CurrentDownloadRate'] ?? null),
                'total_upload_bytes' => self::intOrNull($traffic['TotalUpload'] ?? null),
                'total_download_bytes' => self::intOrNull($traffic['TotalDownload'] ?? null),
                'total_connect_time_seconds' => self::intOrNull($traffic['TotalConnectTime'] ?? null),
            ],
            'features' => [
                'ussd' => self::flag($moduleSwitch['ussd_enabled'] ?? null),
                'phonebook' => self::flag($moduleSwitch['pb_enabled'] ?? null),
                'stk' => self::flag($moduleSwitch['stk_enabled'] ?? null),
                'monthly_volume' => self::flag($moduleSwitch['monthly_volume_enabled'] ?? null),
                'ipv6' => self::flag($moduleSwitch['ipv6_enabled'] ?? null),
                'login_state' => self::describedCode($login['State'] ?? null, [
                    '0' => 'logged_out_or_login_not_required',
                    '1' => 'logged_in',
                    '-1' => 'not_logged_in',
                ]),
                'first_login' => self::flag($login['firstlogin'] ?? null),
            ],
        ];
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

    private static function serviceStatus(mixed $code): array
    {
        $value = self::stringOrNull($code);

        return [
            'code' => $value,
            'label' => match ($value) {
                '2' => 'available',
                null => 'unknown',
                default => 'unavailable_or_limited',
            },
        ];
    }

    private static function flag(mixed $value): array
    {
        $string = self::stringOrNull($value);

        return [
            'value' => $string,
            'enabled' => $string === null ? null : $string === '1',
        ];
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

    private static function overallStatus(string $connection, string $simState, string $service, ?string $workMode): string
    {
        if ($simState === 'no_sim_card') {
            return 'sim_card_missing';
        }

        if ($simState === 'pin_required') {
            return 'sim_pin_required';
        }

        if ($simState === 'puk_required') {
            return 'sim_puk_required';
        }

        if ($workMode !== null && str_contains(strtolower($workMode), 'no service')) {
            return 'no_service';
        }

        if ($connection === 'disconnected' && $service !== 'available') {
            return 'no_service';
        }

        return match ($connection) {
            'connected' => 'connected',
            'connecting' => 'connecting',
            'disconnecting' => 'disconnecting',
            'disconnected' => 'disconnected',
            'connect_failed',
            'connect_failed_signal_poor',
            'traffic_limit_exceeded' => 'connection_failed',
            default => 'lte_status',
        };
    }

    private static function statusMessage(
        ?string $deviceName,
        string $status,
        string $simState,
        string $connection,
        string $networkType,
        ?int $signalIcon,
        ?int $maxSignal
    ): string {
        $device = $deviceName ?? 'LTE device';
        $signal = $signalIcon === null || $maxSignal === null ? 'signal unknown' : 'signal ' . $signalIcon . '/' . $maxSignal;
        $network = $networkType === 'unknown' ? 'network unknown' : 'network ' . $networkType;

        return match ($status) {
            'sim_card_missing' => $device . ' reachable; SIM card is missing',
            'sim_pin_required' => $device . ' reachable; SIM PIN is required',
            'sim_puk_required' => $device . ' reachable; SIM PUK is required',
            'no_service' => $device . ' reachable; SIM ' . $simState . '; modem reports no service; ' . $signal,
            default => $device . ' reachable; SIM ' . $simState . '; connection ' . $connection . '; ' . $network . '; ' . $signal,
        };
    }
}
