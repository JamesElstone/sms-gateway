<?php
declare(strict_types=1);

// Copyright (c) 2026, James Elstone
// SPDX-License-Identifier: BSD-3-Clause
//
// This file is part of SMS Gateway:
// https://github.com/JamesElstone/sms-gateway
//
// See LICENSE for details.

namespace SmsGateway\Lte;

final class LteApiException extends \RuntimeException
{
    public function __construct(
        string $message,
        private readonly ?int $lteCode = null,
        ?\Throwable $previous = null
    ) {
        parent::__construct($message, $lteCode ?? 0, $previous);
    }

    public function getLteCode(): ?int
    {
        return $this->lteCode;
    }
}
