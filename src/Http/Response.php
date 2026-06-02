<?php

declare(strict_types=1);

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
