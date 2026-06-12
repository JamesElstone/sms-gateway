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

final class SmsMessageStore
{
    private \PDO $pdo;
    private bool $initialized = false;

    public function __construct(
        private readonly string $dsn,
        private readonly ?string $username = null,
        private readonly ?string $password = null
    ) {
    }

    public static function fromConfig(Config $config): self
    {
        return new self(
            $config->databaseDsn(),
            $config->databaseUsername(),
            $config->databasePassword()
        );
    }

    public function initialize(): void
    {
        if ($this->initialized) {
            return;
        }

        $this->pdo()->exec(
            'CREATE TABLE IF NOT EXISTS sms_messages (
                message_id VARCHAR(80) PRIMARY KEY,
                source_device_id VARCHAR(255),
                modem_index INTEGER,
                sender VARCHAR(255) NOT NULL,
                sender_normalized VARCHAR(255) NOT NULL,
                content MEDIUMTEXT NOT NULL,
                device_date VARCHAR(32),
                smstat INTEGER,
                save_type INTEGER,
                priority INTEGER,
                sms_type INTEGER,
                sca VARCHAR(255),
                cached_at VARCHAR(32) NOT NULL,
                updated_at VARCHAR(32) NOT NULL,
                modem_deleted_at VARCHAR(32),
                raw_payload MEDIUMTEXT NOT NULL
            )'
        );
        $this->createIndex('idx_sms_messages_sender', 'sms_messages', 'sender_normalized');
        $this->createIndex('idx_sms_messages_modem', 'sms_messages', 'modem_index, modem_deleted_at');
        $this->pdo()->exec(
            'CREATE TABLE IF NOT EXISTS sms_token_reads (
                message_id VARCHAR(80) NOT NULL,
                token_name VARCHAR(128) NOT NULL,
                delivered_at VARCHAR(32) NOT NULL,
                PRIMARY KEY (message_id, token_name),
                FOREIGN KEY (message_id) REFERENCES sms_messages(message_id) ON DELETE CASCADE
            )'
        );
        $this->pdo()->exec(
            'CREATE TABLE IF NOT EXISTS sms_sync_state (
                state_key VARCHAR(80) PRIMARY KEY,
                state_value MEDIUMTEXT NOT NULL,
                updated_at VARCHAR(32) NOT NULL
            )'
        );

        $this->initialized = true;
    }

    private function createIndex(string $name, string $table, string $columns): void
    {
        try {
            $this->pdo()->exec('CREATE INDEX ' . $name . ' ON ' . $table . ' (' . $columns . ')');
        } catch (\PDOException $exception) {
            $message = strtolower($exception->getMessage());
            if (
                str_contains($message, 'already exists')
                || str_contains($message, 'duplicate')
                || str_contains($message, '1061')
            ) {
                return;
            }

            throw $exception;
        }
    }

    /** @param list<array<string, mixed>> $messages */
    public function upsertMessages(array $messages, ?string $sourceDeviceId): int
    {
        $this->initialize();
        $now = $this->now();
        $count = 0;

        $this->pdo()->beginTransaction();
        try {
            foreach ($messages as $message) {
                $row = $this->rowFromDeviceMessage($message, $sourceDeviceId, $now);

                $update = $this->pdo()->prepare(
                    'UPDATE sms_messages
                     SET source_device_id = :source_device_id,
                         modem_index = :modem_index,
                         sender = :sender,
                         sender_normalized = :sender_normalized,
                         content = :content,
                         device_date = :device_date,
                         smstat = :smstat,
                         save_type = :save_type,
                         priority = :priority,
                         sms_type = :sms_type,
                         sca = :sca,
                         updated_at = :updated_at,
                         raw_payload = :raw_payload
                     WHERE message_id = :message_id'
                );
                $update->execute($this->updateParameters($row));

                if ($update->rowCount() === 0) {
                    $insert = $this->pdo()->prepare(
                        'INSERT INTO sms_messages (
                            message_id, source_device_id, modem_index, sender, sender_normalized,
                            content, device_date, smstat, save_type, priority, sms_type, sca,
                            cached_at, updated_at, modem_deleted_at, raw_payload
                        ) VALUES (
                            :message_id, :source_device_id, :modem_index, :sender, :sender_normalized,
                            :content, :device_date, :smstat, :save_type, :priority, :sms_type, :sca,
                            :cached_at, :updated_at, NULL, :raw_payload
                        )'
                    );
                    $insert->execute($row);
                }

                $count++;
            }

            $this->pdo()->commit();
        } catch (\Throwable $exception) {
            $this->pdo()->rollBack();
            throw $exception;
        }

        return $count;
    }

    public function messageCount(): int
    {
        $this->initialize();
        return (int) $this->pdo()->query('SELECT COUNT(*) FROM sms_messages')->fetchColumn();
    }

    public function readForToken(
        string $tokenName,
        ?string $senderSearch,
        int $limit,
        bool $all,
        bool $markRead
    ): array {
        $this->initialize();
        $limit = $this->safeLimit($limit);

        if (!$markRead) {
            return $this->selectForToken($tokenName, $senderSearch, $limit, $all);
        }

        $this->pdo()->beginTransaction();
        try {
            $messages = $this->selectForToken($tokenName, $senderSearch, $limit, $all);
            $this->markMessagesRead($tokenName, array_column($messages, 'id'));
            $this->pdo()->commit();
            return $messages;
        } catch (\Throwable $exception) {
            $this->pdo()->rollBack();
            throw $exception;
        }
    }

    /** @param list<string> $messageIds */
    public function acknowledge(string $tokenName, array $messageIds): array
    {
        $this->initialize();
        $messageIds = array_values(array_unique(array_filter(array_map('strval', $messageIds), static fn (string $id): bool => $id !== '')));
        if ($messageIds === []) {
            return ['acknowledged' => [], 'unknown' => []];
        }

        $existing = $this->existingMessageIds($messageIds);
        $unknown = array_values(array_diff($messageIds, $existing));

        $this->pdo()->beginTransaction();
        try {
            $this->markMessagesRead($tokenName, $existing);
            $this->pdo()->commit();
        } catch (\Throwable $exception) {
            $this->pdo()->rollBack();
            throw $exception;
        }

        return ['acknowledged' => $existing, 'unknown' => $unknown];
    }

    /** @param list<string> $enabledTokenNames */
    public function modemMessagesReadByAllTokens(array $enabledTokenNames, int $limit): array
    {
        $this->initialize();
        $enabledTokenNames = array_values(array_unique(array_filter($enabledTokenNames, static fn (string $name): bool => $name !== '')));
        if ($enabledTokenNames === []) {
            return [];
        }

        $candidates = $this->oldestCachedModemResident(max(1, $limit * 3));
        $eligible = [];
        foreach ($candidates as $candidate) {
            $readBy = $this->readTokenNamesForMessage($candidate['message_id'], $enabledTokenNames);
            if (count(array_diff($enabledTokenNames, $readBy)) === 0) {
                $eligible[] = $candidate;
            }

            if (count($eligible) >= $limit) {
                break;
            }
        }

        return $eligible;
    }

    public function oldestCachedModemResident(int $limit): array
    {
        $this->initialize();
        $statement = $this->pdo()->prepare(
            'SELECT message_id, modem_index
             FROM sms_messages
             WHERE modem_index IS NOT NULL AND modem_deleted_at IS NULL
             ORDER BY COALESCE(device_date, cached_at) ASC, cached_at ASC, message_id ASC
             LIMIT :limit'
        );
        $statement->bindValue(':limit', max(1, $limit), \PDO::PARAM_INT);
        $statement->execute();

        $rows = [];
        while (($row = $statement->fetch(\PDO::FETCH_ASSOC)) !== false) {
            $rows[] = [
                'message_id' => (string) $row['message_id'],
                'modem_index' => (int) $row['modem_index'],
            ];
        }

        return $rows;
    }

    /** @param list<string> $messageIds */
    public function markModemDeleted(array $messageIds): void
    {
        $this->initialize();
        $messageIds = array_values(array_unique(array_filter(array_map('strval', $messageIds), static fn (string $id): bool => $id !== '')));
        if ($messageIds === []) {
            return;
        }

        $statement = $this->pdo()->prepare('UPDATE sms_messages SET modem_deleted_at = :deleted_at WHERE message_id = :message_id');
        $deletedAt = $this->now();
        foreach ($messageIds as $messageId) {
            $statement->execute(['message_id' => $messageId, 'deleted_at' => $deletedAt]);
        }
    }

    public function stateValue(string $key): ?string
    {
        $this->initialize();
        $statement = $this->pdo()->prepare('SELECT state_value FROM sms_sync_state WHERE state_key = :state_key');
        $statement->execute(['state_key' => $key]);
        $value = $statement->fetchColumn();
        return $value === false ? null : (string) $value;
    }

    public function setStateValue(string $key, string $value): void
    {
        $this->initialize();
        $now = $this->now();
        $update = $this->pdo()->prepare(
            'UPDATE sms_sync_state
             SET state_value = :state_value, updated_at = :updated_at
             WHERE state_key = :state_key'
        );
        $update->execute(['state_key' => $key, 'state_value' => $value, 'updated_at' => $now]);
        if ($update->rowCount() > 0) {
            return;
        }

        $insert = $this->pdo()->prepare(
            'INSERT INTO sms_sync_state (state_key, state_value, updated_at)
             VALUES (:state_key, :state_value, :updated_at)'
        );
        $insert->execute(['state_key' => $key, 'state_value' => $value, 'updated_at' => $now]);
    }

    public static function normalizeSender(string $sender): string
    {
        $trimmed = trim(preg_replace('/\s+/', ' ', $sender) ?? $sender);
        $compact = preg_replace('/[\s().-]+/', '', $trimmed) ?? $trimmed;

        if (preg_match('/^\+?[0-9]+$/', $compact) === 1) {
            if (str_starts_with($compact, '00')) {
                $compact = '+' . substr($compact, 2);
            }

            if (preg_match('/^\+?44(7[0-9]+)$/', $compact, $match) === 1) {
                return '0' . $match[1];
            }

            return $compact;
        }

        return strtolower($trimmed);
    }

    private function pdo(): \PDO
    {
        if (isset($this->pdo)) {
            return $this->pdo;
        }

        $this->ensureSqliteDirectory();
        $this->pdo = new \PDO($this->dsn, $this->username, $this->password);
        $this->pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
        $this->pdo->setAttribute(\PDO::ATTR_DEFAULT_FETCH_MODE, \PDO::FETCH_ASSOC);
        return $this->pdo;
    }

    private function ensureSqliteDirectory(): void
    {
        if (!str_starts_with($this->dsn, 'sqlite:')) {
            return;
        }

        $path = substr($this->dsn, strlen('sqlite:'));
        if ($path === '' || $path === ':memory:') {
            return;
        }

        $dir = dirname($path);
        if (!is_dir($dir) && !mkdir($dir, 0770, true) && !is_dir($dir)) {
            throw new \RuntimeException('Unable to create SMS database directory: ' . $dir);
        }
    }

    /** @param array<string, mixed> $message */
    private function rowFromDeviceMessage(array $message, ?string $sourceDeviceId, string $now): array
    {
        $sender = $this->stringValue($message['Phone'] ?? '');
        $content = $this->stringValue($message['Content'] ?? '');
        $deviceDate = $this->nullableString($message['Date'] ?? null);
        $smsType = $this->nullableInt($message['SmsType'] ?? null);
        $saveType = $this->nullableInt($message['SaveType'] ?? null);

        $rawPayload = json_encode($message, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        if ($rawPayload === false) {
            $rawPayload = '{}';
        }

        return [
            'message_id' => $this->messageId($sender, $content, $deviceDate, $smsType, $saveType),
            'source_device_id' => $sourceDeviceId,
            'modem_index' => $this->nullableInt($message['Index'] ?? null),
            'sender' => $sender,
            'sender_normalized' => self::normalizeSender($sender),
            'content' => $content,
            'device_date' => $deviceDate,
            'smstat' => $this->nullableInt($message['Smstat'] ?? null),
            'save_type' => $saveType,
            'priority' => $this->nullableInt($message['Priority'] ?? null),
            'sms_type' => $smsType,
            'sca' => $this->nullableString($message['Sca'] ?? null),
            'cached_at' => $now,
            'updated_at' => $now,
            'raw_payload' => $rawPayload,
        ];
    }

    private function messageId(string $sender, string $content, ?string $deviceDate, ?int $smsType, ?int $saveType): string
    {
        $payload = json_encode([
            'sender' => self::normalizeSender($sender),
            'sender_raw' => $sender,
            'content' => $content,
            'device_date' => $deviceDate,
            'sms_type' => $smsType,
            'save_type' => $saveType,
        ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);

        return 'sms_' . hash('sha256', $payload === false ? $sender . $content : $payload);
    }

    /** @param array<string, mixed> $row */
    private function updateParameters(array $row): array
    {
        return array_intersect_key($row, array_flip([
            'message_id',
            'source_device_id',
            'modem_index',
            'sender',
            'sender_normalized',
            'content',
            'device_date',
            'smstat',
            'save_type',
            'priority',
            'sms_type',
            'sca',
            'updated_at',
            'raw_payload',
        ]));
    }

    private function selectForToken(string $tokenName, ?string $senderSearch, int $limit, bool $all): array
    {
        $where = [];
        $params = ['token_name' => $tokenName];
        if (!$all) {
            $where[] = 'r.message_id IS NULL';
        }

        if ($senderSearch !== null && trim($senderSearch) !== '') {
            $where[] = 'm.sender_normalized = :sender_normalized';
            $params['sender_normalized'] = self::normalizeSender($senderSearch);
        }

        $sql = 'SELECT m.*, r.delivered_at AS token_delivered_at
                FROM sms_messages m
                LEFT JOIN sms_token_reads r
                    ON r.message_id = m.message_id AND r.token_name = :token_name';
        if ($where !== []) {
            $sql .= ' WHERE ' . implode(' AND ', $where);
        }
        $sql .= ' ORDER BY COALESCE(m.device_date, m.cached_at) DESC, m.cached_at DESC, m.message_id ASC LIMIT :limit';

        $statement = $this->pdo()->prepare($sql);
        foreach ($params as $key => $value) {
            $statement->bindValue(':' . $key, $value);
        }
        $statement->bindValue(':limit', $limit, \PDO::PARAM_INT);
        $statement->execute();

        $messages = [];
        while (($row = $statement->fetch(\PDO::FETCH_ASSOC)) !== false) {
            $messages[] = $this->apiMessage($row);
        }

        return $messages;
    }

    /** @param list<string> $messageIds */
    private function markMessagesRead(string $tokenName, array $messageIds): void
    {
        $messageIds = array_values(array_unique(array_filter(array_map('strval', $messageIds), static fn (string $id): bool => $id !== '')));
        if ($messageIds === []) {
            return;
        }

        $messageIds = array_values(array_diff($messageIds, $this->readMessageIdsForToken($tokenName, $messageIds)));
        if ($messageIds === []) {
            return;
        }

        $statement = $this->pdo()->prepare(
            'INSERT INTO sms_token_reads (message_id, token_name, delivered_at)
             VALUES (:message_id, :token_name, :delivered_at)'
        );
        $deliveredAt = $this->now();

        foreach ($messageIds as $messageId) {
            $statement->execute([
                'message_id' => $messageId,
                'token_name' => $tokenName,
                'delivered_at' => $deliveredAt,
            ]);
        }
    }

    /** @param list<string> $messageIds */
    private function existingMessageIds(array $messageIds): array
    {
        $placeholders = [];
        $params = [];
        foreach ($messageIds as $index => $messageId) {
            $key = ':id' . $index;
            $placeholders[] = $key;
            $params[$key] = $messageId;
        }

        $statement = $this->pdo()->prepare(
            'SELECT message_id FROM sms_messages WHERE message_id IN (' . implode(', ', $placeholders) . ')'
        );
        foreach ($params as $key => $value) {
            $statement->bindValue($key, $value);
        }
        $statement->execute();

        return array_values(array_map('strval', $statement->fetchAll(\PDO::FETCH_COLUMN)));
    }

    /** @param list<string> $messageIds */
    private function readMessageIdsForToken(string $tokenName, array $messageIds): array
    {
        if ($messageIds === []) {
            return [];
        }

        $placeholders = [];
        $params = ['token_name' => $tokenName];
        foreach ($messageIds as $index => $messageId) {
            $key = 'id' . $index;
            $placeholders[] = ':' . $key;
            $params[$key] = $messageId;
        }

        $statement = $this->pdo()->prepare(
            'SELECT message_id
             FROM sms_token_reads
             WHERE token_name = :token_name AND message_id IN (' . implode(', ', $placeholders) . ')'
        );
        $statement->execute($params);

        return array_values(array_map('strval', $statement->fetchAll(\PDO::FETCH_COLUMN)));
    }

    /** @param list<string> $enabledTokenNames */
    private function readTokenNamesForMessage(string $messageId, array $enabledTokenNames): array
    {
        $placeholders = [];
        $params = ['message_id' => $messageId];
        foreach ($enabledTokenNames as $index => $name) {
            $key = 'token' . $index;
            $placeholders[] = ':' . $key;
            $params[$key] = $name;
        }

        $statement = $this->pdo()->prepare(
            'SELECT DISTINCT token_name
             FROM sms_token_reads
             WHERE message_id = :message_id AND token_name IN (' . implode(', ', $placeholders) . ')'
        );
        $statement->execute($params);

        return array_values(array_map('strval', $statement->fetchAll(\PDO::FETCH_COLUMN)));
    }

    /** @param array<string, mixed> $row */
    private function apiMessage(array $row): array
    {
        return [
            'id' => (string) $row['message_id'],
            'sender' => (string) $row['sender'],
            'sender_normalized' => (string) $row['sender_normalized'],
            'content' => (string) $row['content'],
            'device_date' => $this->nullableString($row['device_date'] ?? null),
            'cached_at' => (string) $row['cached_at'],
            'updated_at' => (string) $row['updated_at'],
            'token_read_at' => $this->nullableString($row['token_delivered_at'] ?? null),
            'modem_deleted_at' => $this->nullableString($row['modem_deleted_at'] ?? null),
            'device' => [
                'source_device_id' => $this->nullableString($row['source_device_id'] ?? null),
                'index' => $this->nullableInt($row['modem_index'] ?? null),
                'smstat' => $this->nullableInt($row['smstat'] ?? null),
                'save_type' => $this->nullableInt($row['save_type'] ?? null),
                'priority' => $this->nullableInt($row['priority'] ?? null),
                'sms_type' => $this->nullableInt($row['sms_type'] ?? null),
                'sca' => $this->nullableString($row['sca'] ?? null),
            ],
        ];
    }

    private function safeLimit(int $limit): int
    {
        return max(1, min($limit, 500));
    }

    private function now(): string
    {
        return gmdate(DATE_ATOM);
    }

    private function stringValue(mixed $value): string
    {
        if ($value === null || is_array($value)) {
            return '';
        }

        return trim((string) $value);
    }

    private function nullableString(mixed $value): ?string
    {
        if ($value === null || is_array($value)) {
            return null;
        }

        $string = trim((string) $value);
        return $string === '' ? null : $string;
    }

    private function nullableInt(mixed $value): ?int
    {
        $string = $this->nullableString($value);
        return $string !== null && preg_match('/^-?[0-9]+$/', $string) === 1 ? (int) $string : null;
    }
}
