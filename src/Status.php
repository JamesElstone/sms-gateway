<?php

declare(strict_types=1);

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
