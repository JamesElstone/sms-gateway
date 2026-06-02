<?php

declare(strict_types=1);

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
