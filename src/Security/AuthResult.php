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

final class AuthResult
{
    public function __construct(
        public readonly bool $allowed,
        public readonly int $httpStatus,
        public readonly string $message,
        public readonly ?string $tokenName = null
    ) {
    }

    public static function allow(string $tokenName): self
    {
        return new self(true, 200, 'Authorised', $tokenName);
    }

    public static function deny(int $httpStatus, string $message): self
    {
        return new self(false, $httpStatus, $message);
    }
}
