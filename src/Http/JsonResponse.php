<?php

declare(strict_types=1);

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
