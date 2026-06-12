<?php
declare(strict_types=1);

// Copyright (c) 2026, James Elstone
// SPDX-License-Identifier: BSD-3-Clause
//
// This file is part of SMS Gateway:
// https://github.com/JamesElstone/sms-gateway
//
// See LICENSE for details.

namespace SmsGateway\Sms;

use SmsGateway\Config;
use SmsGateway\Lte\LteModemClient;

final class SmsSyncService
{
    public function __construct(
        private readonly Config $config,
        private readonly SmsMessageStore $store,
        private readonly LteModemClient $client
    ) {
    }

    /** @param list<string> $enabledTokenNames */
    public function syncIfNeeded(array $enabledTokenNames): array
    {
        $lock = $this->acquireLock();
        if ($lock === null) {
            return ['status' => 'sync_in_progress'];
        }

        try {
            return $this->doSyncIfNeeded($enabledTokenNames);
        } catch (\Throwable $exception) {
            return [
                'status' => 'sync_failed',
                'message' => $exception->getMessage(),
            ];
        } finally {
            flock($lock, LOCK_UN);
            fclose($lock);
        }
    }

    /** @param list<string> $enabledTokenNames */
    private function doSyncIfNeeded(array $enabledTokenNames): array
    {
        $count = $this->client->smsCount();
        $notifications = $this->safeNotifications();
        $signature = $this->countSignature($count, $notifications);
        $previousSignature = $this->store->stateValue('sms_count_signature');
        $pressure = $this->storagePressure($count, $notifications);
        $cacheEmpty = $this->store->messageCount() === 0;

        $synced = false;
        $cached = 0;
        $setRead = 0;

        if ($cacheEmpty || $pressure['active'] || $signature !== $previousSignature) {
            $messages = $this->fetchInboxMessages($count);
            $cached = $this->store->upsertMessages($messages, $this->sourceDeviceId());
            $setRead = $this->markDeviceUnreadMessagesRead($messages);
            $this->store->setStateValue('sms_count_signature', $signature);
            $synced = true;
        }

        $normalDeleted = $this->deleteNormalReadByAll($enabledTokenNames);
        $pressureDeleted = $pressure['active']
            ? $this->deletePressureBatch($this->config->smsPressureDeleteBatchSize())
            : ['deleted' => 0, 'message_ids' => []];

        return [
            'status' => 'ok',
            'synced' => $synced,
            'cached' => $cached,
            'device_marked_read' => $setRead,
            'storage_pressure' => $pressure,
            'normal_deleted' => $normalDeleted,
            'pressure_deleted' => $pressureDeleted,
        ];
    }

    /** @return resource|null */
    private function acquireLock()
    {
        $handle = @fopen($this->config->smsSyncLockFile(), 'c');
        if ($handle === false) {
            throw new \RuntimeException('Unable to create SMS sync lock');
        }

        if (!flock($handle, LOCK_EX | LOCK_NB)) {
            fclose($handle);
            return null;
        }

        ftruncate($handle, 0);
        fwrite($handle, 'pid=' . getmypid() . ' started=' . gmdate(DATE_ATOM) . PHP_EOL);
        return $handle;
    }

    /** @return array<string, mixed> */
    private function safeNotifications(): array
    {
        try {
            return $this->client->notifications();
        } catch (\Throwable) {
            return [];
        }
    }

    /** @param array<string, mixed> $count */
    private function fetchInboxMessages(array $count): array
    {
        $localInbox = $this->intValue($count['LocalInbox'] ?? null);
        if ($localInbox === null || $localInbox === 0) {
            return [];
        }

        $pageSize = max(1, min($this->config->smsSyncPageSize(), max(1, $localInbox)));
        $messages = [];
        $pageIndex = 1;
        $expected = null;

        do {
            $page = $this->client->smsInboxPage($pageIndex, $pageSize);
            $expected = $expected ?? $this->intValue($page['Count'] ?? null);
            $pageMessages = $this->messagesFromPage($page);
            $messages = array_merge($messages, $pageMessages);
            $pageIndex++;
        } while ($pageMessages !== [] && count($messages) < max($expected ?? $localInbox, $localInbox));

        return $messages;
    }

    /** @param array<string, mixed> $page */
    private function messagesFromPage(array $page): array
    {
        $message = $page['Messages']['Message'] ?? [];
        if (!is_array($message)) {
            return [];
        }

        if ($message === []) {
            return [];
        }

        if (array_is_list($message)) {
            return array_values(array_filter($message, 'is_array'));
        }

        return [$message];
    }

    /** @param list<array<string, mixed>> $messages */
    private function markDeviceUnreadMessagesRead(array $messages): int
    {
        $count = 0;
        foreach ($messages as $message) {
            if ($this->intValue($message['Smstat'] ?? null) !== 0) {
                continue;
            }

            $index = $this->intValue($message['Index'] ?? null);
            if ($index === null) {
                continue;
            }

            try {
                $this->client->setSmsRead($index);
                $count++;
            } catch (\Throwable) {
            }
        }

        return $count;
    }

    /** @param list<string> $enabledTokenNames */
    private function deleteNormalReadByAll(array $enabledTokenNames): array
    {
        $candidates = $this->store->modemMessagesReadByAllTokens($enabledTokenNames, 100);
        return $this->deleteCandidates($candidates);
    }

    private function deletePressureBatch(int $limit): array
    {
        return $this->deleteCandidates($this->store->oldestCachedModemResident($limit));
    }

    /** @param list<array{message_id: string, modem_index: int}> $candidates */
    private function deleteCandidates(array $candidates): array
    {
        $deletedIds = [];
        foreach ($candidates as $candidate) {
            try {
                $this->client->deleteSms($candidate['modem_index']);
                $deletedIds[] = $candidate['message_id'];
            } catch (\Throwable) {
            }
        }

        $this->store->markModemDeleted($deletedIds);

        return [
            'deleted' => count($deletedIds),
            'message_ids' => $deletedIds,
        ];
    }

    /** @param array<string, mixed> $count */
    private function storagePressure(array $count, array $notifications): array
    {
        $localInbox = $this->intValue($count['LocalInbox'] ?? null);
        $localMax = $this->intValue($count['LocalMax'] ?? null);
        $simUsed = $this->intValue($count['SimUsed'] ?? null);
        $simMax = $this->intValue($count['SimMax'] ?? null);
        $localRatio = ($localInbox !== null && $localMax !== null && $localMax > 0) ? $localInbox / $localMax : null;
        $simRatio = ($simUsed !== null && $simMax !== null && $simMax > 0) ? $simUsed / $simMax : null;
        $threshold = $this->config->smsStoragePressureThreshold();
        $reportedFull = (string) ($notifications['SmsStorageFull'] ?? '') === '1';

        return [
            'active' => $reportedFull
                || ($localRatio !== null && $localRatio >= $threshold)
                || ($simRatio !== null && $simRatio >= $threshold),
            'threshold' => $threshold,
            'reported_full' => $reportedFull,
            'local_inbox' => $localInbox,
            'local_max' => $localMax,
            'local_ratio' => $localRatio,
            'sim_used' => $simUsed,
            'sim_max' => $simMax,
            'sim_ratio' => $simRatio,
        ];
    }

    /** @param array<string, mixed> $count */
    private function countSignature(array $count, array $notifications): string
    {
        $payload = [
            'LocalUnread' => $this->intValue($count['LocalUnread'] ?? null),
            'LocalInbox' => $this->intValue($count['LocalInbox'] ?? null),
            'SimUnread' => $this->intValue($count['SimUnread'] ?? null),
            'SimInbox' => $this->intValue($count['SimInbox'] ?? null),
            'SimUsed' => $this->intValue($count['SimUsed'] ?? null),
            'SmsStorageFull' => $this->intValue($notifications['SmsStorageFull'] ?? null),
        ];

        $json = json_encode($payload, JSON_UNESCAPED_SLASHES);
        return hash('sha256', $json === false ? '' : $json);
    }

    private function sourceDeviceId(): ?string
    {
        try {
            $info = $this->client->deviceInformation();
        } catch (\Throwable) {
            return $this->config->dongleUrl();
        }

        foreach (['Imei', 'Iccid', 'Msisdn', 'DeviceName'] as $key) {
            $value = $info[$key] ?? null;
            if (!is_array($value) && trim((string) $value) !== '') {
                return $key . ':' . trim((string) $value);
            }
        }

        return $this->config->dongleUrl();
    }

    private function intValue(mixed $value): ?int
    {
        if ($value === null || is_array($value)) {
            return null;
        }

        $string = trim((string) $value);
        return preg_match('/^-?[0-9]+$/', $string) === 1 ? (int) $string : null;
    }
}
