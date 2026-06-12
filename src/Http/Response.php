<?php
declare(strict_types=1);

// Copyright (c) 2026, James Elstone
// SPDX-License-Identifier: BSD-3-Clause
//
// This file is part of SMS Gateway:
// https://github.com/JamesElstone/sms-gateway
//
// See LICENSE for details.

namespace SmsGateway\Http;

final class Response
{
    /** @param array<string, mixed> $payload */
    public function __construct(
        public readonly int $statusCode,
        public readonly array $payload
    ) {
    }

    /** @param array<string, mixed> $payload */
    public static function json(int $statusCode, array $payload): self
    {
        return new self($statusCode, $payload);
    }
}
