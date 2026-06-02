<?php

declare(strict_types=1);

namespace SmsGateway;

final class Config
{
    /** @param array<string, mixed> $values */
    public function __construct(private readonly array $values)
    {
    }

    public function dongleUrl(): string
    {
        return rtrim((string) ($this->values['dongle_url'] ?? 'http://192.168.8.1/'), '/') . '/';
    }

    public function dongleUsername(): ?string
    {
        $value = $this->values['dongle_username'] ?? null;
        return $value === '' ? null : $value;
    }

    public function donglePassword(): ?string
    {
        $value = $this->values['dongle_password'] ?? null;
        return $value === '' ? null : $value;
    }

    public function curlTimeoutSeconds(): int
    {
        return max(1, (int) ($this->values['curl_timeout_seconds'] ?? 10));
    }

    public function maxMessageBytes(): int
    {
        return max(1, (int) ($this->values['max_message_bytes'] ?? 1600));
    }

    public function tokenFile(): string
    {
        return (string) ($this->values['token_file'] ?? dirname(__DIR__) . '/config/tokens.json');
    }
}
