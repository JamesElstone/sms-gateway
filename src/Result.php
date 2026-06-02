<?php

declare(strict_types=1);

namespace SmsGateway;

final class Result
{
    /** @param array<string, mixed> $payload */
    public function __construct(
        public readonly int $httpStatus,
        public readonly array $payload
    ) {
    }
}
