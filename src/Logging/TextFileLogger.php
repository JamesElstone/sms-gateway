<?php
declare(strict_types=1);

// Copyright (c) 2026, James Elstone
// SPDX-License-Identifier: BSD-3-Clause
//
// This file is part of SMS Gateway:
// https://github.com/JamesElstone/sms-gateway
//
// See LICENSE for details.

namespace SmsGateway\Logging;

final class TextFileLogger
{
    public function __construct(private readonly ?string $path)
    {
    }

    /** @param array<string, mixed> $fields */
    public function log(string $event, array $fields): void
    {
        if ($this->path === null || $this->path === '') {
            return;
        }

        $line = gmdate('Y-m-d\TH:i:s\Z') . ' ' . $event;
        foreach ($fields as $key => $value) {
            $line .= ' ' . $key . '=' . $this->fieldValue($value);
        }
        $line .= PHP_EOL;

        @file_put_contents($this->path, $line, FILE_APPEND | LOCK_EX);
    }

    private function fieldValue(mixed $value): string
    {
        if (is_bool($value)) {
            return $value ? 'yes' : 'no';
        }

        if ($value === null) {
            return '';
        }

        if (is_array($value)) {
            $encoded = [];
            foreach ($value as $item) {
                if ($item === null || is_array($item)) {
                    continue;
                }
                $encoded[] = rawurlencode((string) $item);
            }

            return implode(',', $encoded);
        }

        return rawurlencode((string) $value);
    }
}
