<?php

declare(strict_types=1);

namespace SmsGateway\Security;

final class AuthResult
{
    public function __construct(
        public readonly bool $allowed,
        public readonly int $httpStatus,
        public readonly string $message
    ) {
    }

    public static function allow(): self
    {
        return new self(true, 200, 'Authorised');
    }

    public static function deny(int $httpStatus, string $message): self
    {
        return new self(false, $httpStatus, $message);
    }
}
