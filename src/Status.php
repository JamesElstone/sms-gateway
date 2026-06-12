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

final class Status
{
    public function __construct(
        public readonly string $status,
        public readonly int $httpStatus,
        public readonly string $message
    ) {
    }
}
