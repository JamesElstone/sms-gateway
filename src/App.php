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

use SmsGateway\Http\Response;
use SmsGateway\Logging\TextFileLogger;
use SmsGateway\Lte\LteApiException;
use SmsGateway\Lte\LteModemClient;
use SmsGateway\Lte\LteTransportException;
use SmsGateway\Security\FileTokenAuthorizer;
use SmsGateway\Service\SmsSyncState;
use SmsGateway\Sms\SmsMessageStore;

final class App
{
    public function __construct(private readonly Config $config)
    {
    }

    /**
     * @param array<string, string> $headers
     * @param array<string, mixed> $query
     */
    public function handle(
        string $method,
        string $path,
        string $body,
        array $headers = [],
        string $clientIp = '',
        array $query = []
    ): Response
    {
        if ($method === 'GET' && preg_match('#^/sms-gateway/?$#', $path) === 1) {
            return $this->handleStatus();
        }

        if (preg_match('#^/sms-gateway/ping/?$#', $path) === 1) {
            if ($method !== 'GET') {
                return Response::json(405, ['status' => 'method_not_allowed', 'message' => 'Only GET is supported']);
            }

            return $this->handlePing($headers, $clientIp);
        }

        if ($method === 'GET' && preg_match('#^/sms-gateway/carriers/?$#', $path) === 1) {
            return $this->handleCarriers(array_key_exists('force', $query));
        }

        if (preg_match('#^/sms-gateway/read/ack/?$#', $path) === 1) {
            if ($method !== 'POST') {
                return Response::json(405, ['status' => 'method_not_allowed', 'message' => 'Only POST is supported']);
            }

            return $this->handleReadAck($headers, $clientIp, $body);
        }

        if (preg_match('#^/sms-gateway/read/peek/?$#', $path) === 1) {
            if ($method !== 'GET') {
                return Response::json(405, ['status' => 'method_not_allowed', 'message' => 'Only GET is supported']);
            }

            return $this->handleRead($headers, $clientIp, $query, true);
        }

        if (preg_match('#^/sms-gateway/read/?$#', $path) === 1) {
            if ($method !== 'GET') {
                return Response::json(405, ['status' => 'method_not_allowed', 'message' => 'Only GET is supported']);
            }

            return $this->handleRead($headers, $clientIp, $query, false);
        }

        if ($method !== 'POST') {
            return Response::json(405, ['status' => 'unable_to_send', 'message' => 'Only POST is supported']);
        }

        if (!preg_match('#^/sms-gateway/send/([^/]+)$#', $path, $matches)) {
            return Response::json(404, ['status' => 'unable_to_send', 'message' => 'Unknown endpoint']);
        }

        $mobile = rawurldecode($matches[1]);
        $auth = (new FileTokenAuthorizer($this->config->tokenFile()))->authorize($headers, $clientIp);
        if (!$auth->allowed) {
            $response = Response::json($auth->httpStatus, [
                'status' => 'unauthorised',
                'message' => $auth->message,
            ]);
            $this->logSend($auth->tokenName, $clientIp, $mobile, $response, $body);
            return $response;
        }

        if (!$this->isPlausibleMobileNumber($mobile)) {
            $response = Response::json(400, ['status' => 'unable_to_send', 'message' => 'Invalid mobile number']);
            $this->logSend($auth->tokenName, $clientIp, $mobile, $response, $body);
            return $response;
        }

        if ($body === '') {
            $response = Response::json(400, ['status' => 'unable_to_send', 'message' => 'SMS payload is empty']);
            $this->logSend($auth->tokenName, $clientIp, $mobile, $response, $body);
            return $response;
        }

        if (strlen($body) > $this->config->maxMessageBytes()) {
            $response = Response::json(413, ['status' => 'unable_to_send', 'message' => 'SMS payload is too large']);
            $this->logSend($auth->tokenName, $clientIp, $mobile, $response, $body);
            return $response;
        }

        $gateway = new SmsGateway($this->modemClient());

        try {
            $result = $gateway->send($mobile, $body);
            $response = Response::json($result->httpStatus, $result->payload);
            $this->logSend($auth->tokenName, $clientIp, $mobile, $response, $body);
            return $response;
        } catch (LteApiException $exception) {
            $status = StatusMapper::fromLteApiException($exception);
            $response = Response::json($status->httpStatus, [
                'status' => $status->status,
                'mobile' => $mobile,
                'message' => $status->message,
                'lte_error_code' => $exception->getLteCode(),
            ]);
            $this->logSend($auth->tokenName, $clientIp, $mobile, $response, $body);
            return $response;
        } catch (LteTransportException $exception) {
            $response = Response::json(503, [
                'status' => 'device_missing',
                'mobile' => $mobile,
                'message' => $exception->getMessage(),
            ]);
            $this->logSend($auth->tokenName, $clientIp, $mobile, $response, $body);
            return $response;
        } catch (\Throwable $exception) {
            $response = Response::json(502, [
                'status' => 'lte_error',
                'mobile' => $mobile,
                'message' => $exception->getMessage(),
            ]);
            $this->logSend($auth->tokenName, $clientIp, $mobile, $response, $body);
            return $response;
        }
    }

    /**
     * @param array<string, string> $headers
     * @param array<string, mixed> $query
     */
    private function handleRead(array $headers, string $clientIp, array $query, bool $peek): Response
    {
        $auth = $this->authorizer()->authorize($headers, $clientIp);
        if (!$auth->allowed || $auth->tokenName === null) {
            return Response::json($auth->httpStatus, [
                'status' => 'unauthorised',
                'message' => $auth->message,
            ]);
        }

        $all = false;
        $markRead = false;
        $limit = 0;
        $search = null;

        try {
            $all = $this->queryHasFlag($query, 'all');
            $markRead = !$peek && (!$all || $this->queryHasFlag($query, 'mark-read'));
            $limit = $this->readLimit($query);
            $search = $all ? null : $this->readSearchTerm($query);
            $messages = $this->messageStore()->readForToken($auth->tokenName, $search, $limit, $all, $markRead);

            $response = Response::json(200, [
                'status' => 'ok',
                'mode' => $peek ? 'peek' : ($all ? 'all' : 'unread'),
                'token' => $auth->tokenName,
                'all' => $all,
                'marked_read' => $markRead,
                'limit' => $limit,
                'search' => $search,
                'count' => count($messages),
                'messages' => $messages,
            ]);
            $this->logRead($auth->tokenName, $clientIp, $response->payload['mode'], 'ok', $markRead, $all, $limit, $search, $messages);
            return $response;
        } catch (\InvalidArgumentException $exception) {
            $response = Response::json(400, [
                'status' => 'invalid_request',
                'message' => $exception->getMessage(),
            ]);
            $this->logRead($auth->tokenName, $clientIp, $peek ? 'peek' : ($all ? 'all' : 'unread'), 'invalid_request', $markRead, $all, $limit, $search, []);
            return $response;
        } catch (\Throwable $exception) {
            $response = Response::json(500, [
                'status' => 'sms_cache_error',
                'message' => $exception->getMessage(),
            ]);
            $this->logRead($auth->tokenName, $clientIp, $peek ? 'peek' : ($all ? 'all' : 'unread'), 'sms_cache_error', $markRead, $all, $limit, $search, []);
            return $response;
        }
    }

    /** @param array<string, string> $headers */
    private function handleReadAck(array $headers, string $clientIp, string $body): Response
    {
        $auth = $this->authorizer()->authorize($headers, $clientIp);
        if (!$auth->allowed || $auth->tokenName === null) {
            return Response::json($auth->httpStatus, [
                'status' => 'unauthorised',
                'message' => $auth->message,
            ]);
        }

        $messageIds = [];

        try {
            $messageIds = $this->ackMessageIds($body);
            $result = $this->messageStore()->acknowledge($auth->tokenName, $messageIds);

            $response = Response::json(200, [
                'status' => 'acknowledged',
                'token' => $auth->tokenName,
                'acknowledged_count' => count($result['acknowledged']),
                'acknowledged' => $result['acknowledged'],
                'unknown' => $result['unknown'],
            ]);
            $this->logRead($auth->tokenName, $clientIp, 'ack', 'acknowledged', true, false, 0, null, $result['acknowledged']);
            return $response;
        } catch (\InvalidArgumentException $exception) {
            $response = Response::json(400, [
                'status' => 'invalid_request',
                'message' => $exception->getMessage(),
            ]);
            $this->logRead($auth->tokenName, $clientIp, 'ack', 'invalid_request', true, false, 0, null, $messageIds);
            return $response;
        } catch (\Throwable $exception) {
            $response = Response::json(500, [
                'status' => 'sms_cache_error',
                'message' => $exception->getMessage(),
            ]);
            $this->logRead($auth->tokenName, $clientIp, 'ack', 'sms_cache_error', true, false, 0, null, $messageIds);
            return $response;
        }
    }

    private function isPlausibleMobileNumber(string $mobile): bool
    {
        return preg_match('/^\+?[0-9][0-9 .()-]{6,24}$/', $mobile) === 1;
    }

    private function handleStatus(): Response
    {
        try {
            $health = $this->modemClient()->health();
            $summary = StatusMapper::summarizeHealth($health);

            return Response::json(200, $summary + [
                'service' => $this->serviceStatus(),
                'stats' => $this->statusStats(),
                'raw' => $health,
            ]);
        } catch (LteTransportException $exception) {
            return Response::json(503, [
                'status' => 'device_missing',
                'message' => $exception->getMessage(),
            ] + $this->statusExtras());
        } catch (LteApiException $exception) {
            $status = StatusMapper::fromLteApiException($exception);
            return Response::json($status->httpStatus, [
                'status' => $status->status,
                'message' => $status->message,
                'lte_error_code' => $exception->getLteCode(),
            ] + $this->statusExtras());
        } catch (\Throwable $exception) {
            return Response::json(502, [
                'status' => 'lte_error',
                'message' => $exception->getMessage(),
            ] + $this->statusExtras());
        }
    }

    /** @param array<string, string> $headers */
    private function handlePing(array $headers, string $clientIp): Response
    {
        $auth = (new FileTokenAuthorizer($this->config->tokenFile()))->authorize($headers, $clientIp);
        if (!$auth->allowed) {
            return Response::json($auth->httpStatus, [
                'status' => 'unauthorised',
                'message' => $auth->message,
            ]);
        }

        return Response::json(200, [
            'auth' => 'sucessful',
            'datetime' => gmdate(DATE_ATOM),
            'ping' => 'pong',
        ]);
    }

    private function handleCarriers(bool $force = false): Response
    {
        try {
            if ($force && $this->isCarrierScanForceSuppressed()) {
                return $this->carrierScanInProgressResponse();
            }

            if (!$force) {
                $cached = $this->readCarrierScanCache(false);
                if ($cached !== null) {
                    return Response::json(200, $cached);
                }
            }

            $lock = $this->acquireCarrierScanLock();
            if ($lock === null) {
                if (!$force) {
                    $cached = $this->readCarrierScanCache(true);
                    if ($cached !== null) {
                        return Response::json(200, $cached);
                    }
                }

                return $this->carrierScanInProgressResponse();
            }

            try {
                $this->writeCarrierScanForceState('running', time() + $this->config->carrierScanTimeoutSeconds());
                $search = $this->modemClient($this->config->carrierScanTimeoutSeconds())->searchCarriers();
                $summary = CarrierMapper::fromSearch($search);
                $this->writeCarrierScanCache($summary);
            } finally {
                $this->writeCarrierScanForceState(
                    'recently_completed',
                    time() + $this->config->carrierScanForceSuppressionSeconds()
                );
                $this->releaseCarrierScanLock($lock);
            }

            return Response::json(200, $summary);
        } catch (LteTransportException $exception) {
            return Response::json(503, [
                'status' => 'device_missing',
                'message' => $exception->getMessage(),
            ]);
        } catch (LteApiException $exception) {
            if ($exception->getLteCode() === 100004) {
                return Response::json(503, [
                    'status' => 'device_busy',
                    'message' => 'LTE device is busy; carrier scan could not complete',
                    'lte_error_code' => $exception->getLteCode(),
                ]);
            }

            $status = StatusMapper::fromLteApiException($exception);
            return Response::json($status->httpStatus, [
                'status' => $status->status,
                'message' => $status->message,
                'lte_error_code' => $exception->getLteCode(),
            ]);
        } catch (\Throwable $exception) {
            return Response::json(502, [
                'status' => 'lte_error',
                'message' => $exception->getMessage(),
            ]);
        }
    }

    private function carrierScanInProgressResponse(): Response
    {
        return Response::json(409, [
            'status' => 'scan_in_progress',
            'message' => 'A carrier scan is already in progress; try again shortly',
        ]);
    }

    /** @return resource|null */
    private function acquireCarrierScanLock()
    {
        $handle = @fopen($this->config->carrierScanLockFile(), 'c');
        if ($handle === false) {
            throw new \RuntimeException('Unable to create carrier scan lock');
        }

        if (!flock($handle, LOCK_EX | LOCK_NB)) {
            fclose($handle);
            return null;
        }

        ftruncate($handle, 0);
        fwrite($handle, 'pid=' . getmypid() . ' started=' . gmdate(DATE_ATOM) . PHP_EOL);

        return $handle;
    }

    /** @param resource $handle */
    private function releaseCarrierScanLock($handle): void
    {
        flock($handle, LOCK_UN);
        fclose($handle);
    }

    /** @return array<string, mixed>|null */
    private function readCarrierScanCache(bool $allowExpired): ?array
    {
        $json = @file_get_contents($this->config->carrierScanCacheFile());
        if ($json === false || $json === '') {
            return null;
        }

        $cache = json_decode($json, true);
        if (!is_array($cache)) {
            return null;
        }

        $payload = $cache['payload'] ?? null;
        $expiresAt = $cache['expires_at_epoch'] ?? null;
        if (!is_array($payload) || !is_int($expiresAt)) {
            return null;
        }

        if (!$allowExpired && $expiresAt <= time()) {
            return null;
        }

        return $payload;
    }

    /** @param array<string, mixed> $payload */
    private function writeCarrierScanCache(array $payload): void
    {
        $path = $this->config->carrierScanCacheFile();
        $now = time();
        $cache = [
            'created_at_epoch' => $now,
            'expires_at_epoch' => $now + $this->config->carrierScanCacheTtlSeconds(),
            'payload' => $payload,
        ];
        $json = json_encode($cache, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
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

    private function isCarrierScanForceSuppressed(): bool
    {
        $json = @file_get_contents($this->config->carrierScanForceStateFile());
        if ($json === false || $json === '') {
            return false;
        }

        $state = json_decode($json, true);
        if (!is_array($state)) {
            return false;
        }

        $busyUntil = $state['busy_until_epoch'] ?? null;
        return is_int($busyUntil) && $busyUntil > time();
    }

    private function writeCarrierScanForceState(string $status, int $busyUntil): void
    {
        $path = $this->config->carrierScanForceStateFile();
        $state = [
            'status' => $status,
            'updated_at_epoch' => time(),
            'busy_until_epoch' => $busyUntil,
        ];
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

    private function authorizer(): FileTokenAuthorizer
    {
        return new FileTokenAuthorizer($this->config->tokenFile());
    }

    private function messageStore(): SmsMessageStore
    {
        return SmsMessageStore::fromConfig($this->config);
    }

    /** @return array{service: array<string, mixed>, stats: array<string, mixed>} */
    private function statusExtras(): array
    {
        return [
            'service' => $this->serviceStatus(),
            'stats' => $this->statusStats(),
        ];
    }

    /** @return array<string, mixed> */
    private function serviceStatus(): array
    {
        return [
            'sms_sync' => (new SmsSyncState($this->config))->summary(),
        ];
    }

    /** @return array<string, mixed> */
    private function statusStats(): array
    {
        return [
            'sms_cache' => $this->smsCacheStats(),
        ];
    }

    /** @return array<string, mixed> */
    private function smsCacheStats(): array
    {
        try {
            return $this->messageStore()->stats();
        } catch (\Throwable $exception) {
            return [
                'status' => 'unavailable',
                'message' => $exception->getMessage(),
            ];
        }
    }

    private function logSend(?string $tokenName, string $clientIp, string $mobile, Response $response, string $payload): void
    {
        (new TextFileLogger($this->config->sendLogFile()))->log('send', [
            'token' => $tokenName,
            'ip' => $clientIp,
            'mobile' => $mobile,
            'status' => $response->payload['status'] ?? '',
            'http_status' => $response->statusCode,
            'bytes' => strlen($payload),
            'payload' => $payload,
        ]);
    }

    /** @param array<int, mixed> $messagesOrIds */
    private function logRead(
        string $tokenName,
        string $clientIp,
        string $mode,
        string $status,
        bool $markedRead,
        bool $all,
        int $limit,
        ?string $search,
        array $messagesOrIds
    ): void {
        (new TextFileLogger($this->config->readLogFile()))->log('read', [
            'token' => $tokenName,
            'ip' => $clientIp,
            'mode' => $mode,
            'status' => $status,
            'marked_read' => $markedRead,
            'all' => $all,
            'limit' => $limit,
            'search' => $search,
            'count' => count($messagesOrIds),
            'ids' => $this->messageIds($messagesOrIds),
        ]);
    }

    /** @param array<int, mixed> $messagesOrIds */
    private function messageIds(array $messagesOrIds): array
    {
        $ids = [];
        foreach ($messagesOrIds as $item) {
            if (is_array($item)) {
                $id = $item['id'] ?? null;
                if (!is_array($id) && $id !== null && trim((string) $id) !== '') {
                    $ids[] = (string) $id;
                }
                continue;
            }

            if ($item !== null && trim((string) $item) !== '') {
                $ids[] = (string) $item;
            }
        }

        return $ids;
    }

    /** @param array<string, mixed> $query */
    private function queryHasFlag(array $query, string $flag): bool
    {
        if (array_key_exists($flag, $query)) {
            return true;
        }

        $underscoreFlag = str_replace('-', '_', $flag);
        if (array_key_exists($underscoreFlag, $query)) {
            return true;
        }

        foreach ($this->rawQueryParts($query) as $part) {
            [$key] = array_pad(explode('=', $part, 2), 2, '');
            $decoded = rawurldecode($key);
            if ($decoded === $flag || $decoded === $underscoreFlag) {
                return true;
            }
        }

        return false;
    }

    /** @param array<string, mixed> $query */
    private function readLimit(array $query): int
    {
        $limit = $query['limit'] ?? null;
        if (is_array($limit)) {
            throw new \InvalidArgumentException('limit must be a single integer');
        }

        if ($limit === null || trim((string) $limit) === '') {
            return $this->config->smsReadDefaultLimit();
        }

        $value = trim((string) $limit);
        if (preg_match('/^[0-9]+$/', $value) !== 1) {
            throw new \InvalidArgumentException('limit must be a positive integer');
        }

        return max(1, min((int) $value, $this->config->smsReadMaxLimit()));
    }

    /** @param array<string, mixed> $query */
    private function readSearchTerm(array $query): ?string
    {
        foreach ($this->rawQueryParts($query) as $part) {
            if ($part === '') {
                continue;
            }

            [$rawKey, $rawValue] = array_pad(explode('=', $part, 2), 2, null);
            $key = rawurldecode($rawKey);
            if (in_array($key, ['all', 'mark-read', 'mark_read', 'limit'], true)) {
                continue;
            }

            if ($rawValue !== null) {
                if ($key !== 'from') {
                    continue;
                }

                $term = rawurldecode($rawValue);
                return trim($term) === '' ? null : trim($term);
            }

            $term = trim(rawurldecode($rawKey));
            return $term === '' ? null : $term;
        }

        if (isset($query['from']) && !is_array($query['from'])) {
            $from = trim((string) $query['from']);
            return $from === '' ? null : $from;
        }

        return null;
    }

    /** @param array<string, mixed> $query */
    private function rawQueryParts(array $query): array
    {
        $raw = $query['__raw_query'] ?? '';
        if (!is_string($raw) || $raw === '') {
            return [];
        }

        return explode('&', $raw);
    }

    /** @return list<string> */
    private function ackMessageIds(string $body): array
    {
        $body = trim($body);
        if ($body === '') {
            throw new \InvalidArgumentException('ack body is empty');
        }

        $decoded = json_decode($body, true);
        if (!is_array($decoded)) {
            throw new \InvalidArgumentException('ack body must be JSON');
        }

        $messageIds = $decoded['message_ids'] ?? $decoded['ids'] ?? $decoded;
        if (!is_array($messageIds) || !array_is_list($messageIds)) {
            throw new \InvalidArgumentException('ack body must contain a message_ids array');
        }

        $ids = [];
        foreach ($messageIds as $messageId) {
            if (is_array($messageId)) {
                throw new \InvalidArgumentException('message_ids must contain strings');
            }

            $id = trim((string) $messageId);
            if ($id !== '') {
                $ids[] = $id;
            }
        }

        return array_values(array_unique($ids));
    }

    private function modemClient(?int $timeoutSeconds = null): LteModemClient
    {
        return new LteModemClient(
            $this->config->dongleUrl(),
            $this->config->dongleUsername(),
            $this->config->donglePassword(),
            $timeoutSeconds ?? $this->config->curlTimeoutSeconds()
        );
    }
}
