<?php
declare(strict_types=1);

// Copyright (c) 2026, James Elstone
// SPDX-License-Identifier: BSD-3-Clause
//
// This file is part of SMS Gateway:
// https://github.com/JamesElstone/sms-gateway
//
// See LICENSE for details.

namespace SmsGateway\Http;

final class JsonResponse
{
    public static function send(Response $response): void
    {
        http_response_code($response->statusCode);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode($response->payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
    }
}
