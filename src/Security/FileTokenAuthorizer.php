<?php
declare(strict_types=1);

// Copyright (c) 2026, James Elstone
// SPDX-License-Identifier: BSD-3-Clause
//
// This file is part of SMS Gateway:
// https://github.com/JamesElstone/sms-gateway
//
// See LICENSE for details.

namespace SmsGateway\Security;

final class FileTokenAuthorizer
{
    public function __construct(private readonly string $tokenFile)
    {
    }

    /** @param array<string, string> $headers */
    public function authorize(array $headers, string $clientIp): AuthResult
    {
        $token = $this->extractToken($headers);
        if ($token === null) {
            return AuthResult::deny(401, 'Missing authorisation token');
        }

        if (!is_file($this->tokenFile)) {
            return AuthResult::deny(503, 'Token file is not configured');
        }

        $tokens = $this->loadTokens();
        foreach ($tokens as $entry) {
            if (!$this->tokenMatches($token, $entry)) {
                continue;
            }

            if (!$this->ipAllowed($clientIp, $entry['allowed_ips'] ?? [])) {
                return AuthResult::deny(403, 'Token is not approved for this IP address');
            }

            return AuthResult::allow();
        }

        return AuthResult::deny(403, 'Invalid authorisation token');
    }

    /** @param array<string, string> $headers */
    private function extractToken(array $headers): ?string
    {
        $normalised = [];
        foreach ($headers as $name => $value) {
            $normalised[strtolower($name)] = trim((string) $value);
        }

        if (($normalised['x-sms-gateway-token'] ?? '') !== '') {
            return $normalised['x-sms-gateway-token'];
        }

        $authorization = $normalised['authorization'] ?? '';
        if (preg_match('/^Bearer\s+(.+)$/i', $authorization, $match)) {
            return trim($match[1]);
        }

        return null;
    }

    /** @return list<array<string, mixed>> */
    private function loadTokens(): array
    {
        $json = file_get_contents($this->tokenFile);
        if ($json === false) {
            return [];
        }

        $decoded = json_decode($json, true);
        if (!is_array($decoded)) {
            return [];
        }

        $tokens = $decoded['tokens'] ?? $decoded;
        return is_array($tokens) ? array_values(array_filter($tokens, 'is_array')) : [];
    }

    /** @param array<string, mixed> $entry */
    private function tokenMatches(string $token, array $entry): bool
    {
        if (isset($entry['token']) && hash_equals((string) $entry['token'], $token)) {
            return true;
        }

        if (isset($entry['token_sha256'])) {
            return hash_equals((string) $entry['token_sha256'], hash('sha256', $token));
        }

        return false;
    }

    /** @param mixed $allowedIps */
    private function ipAllowed(string $clientIp, mixed $allowedIps): bool
    {
        if (!is_array($allowedIps) || $allowedIps === []) {
            return true;
        }

        foreach ($allowedIps as $allowedIp) {
            if ($this->ipMatches($clientIp, (string) $allowedIp)) {
                return true;
            }
        }

        return false;
    }

    private function ipMatches(string $clientIp, string $rule): bool
    {
        if ($clientIp === '' || $rule === '') {
            return false;
        }

        if ($clientIp === $rule) {
            return true;
        }

        if (!str_contains($rule, '/')) {
            return false;
        }

        [$network, $prefixLength] = explode('/', $rule, 2);
        $clientPacked = @inet_pton($clientIp);
        $networkPacked = @inet_pton($network);
        if ($clientPacked === false || $networkPacked === false || strlen($clientPacked) !== strlen($networkPacked)) {
            return false;
        }

        $prefix = (int) $prefixLength;
        if ($prefix < 0 || $prefix > strlen($clientPacked) * 8) {
            return false;
        }

        $bytes = intdiv($prefix, 8);
        $bits = $prefix % 8;

        if ($bytes > 0 && substr($clientPacked, 0, $bytes) !== substr($networkPacked, 0, $bytes)) {
            return false;
        }

        if ($bits === 0) {
            return true;
        }

        $mask = 0xff << (8 - $bits) & 0xff;
        return (ord($clientPacked[$bytes]) & $mask) === (ord($networkPacked[$bytes]) & $mask);
    }
}
