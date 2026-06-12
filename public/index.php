<?php
declare(strict_types=1);

// Copyright (c) 2026, James Elstone
// SPDX-License-Identifier: BSD-3-Clause
//
// This file is part of SMS Gateway:
// https://github.com/JamesElstone/sms-gateway
//
// See LICENSE for details.

use SmsGateway\App;
use SmsGateway\Config;
use SmsGateway\Http\JsonResponse;

require dirname(__DIR__) . '/src/autoload.php';

$configFile = dirname(__DIR__) . '/config/local.php';
if (!is_file($configFile)) {
    $configFile = dirname(__DIR__) . '/config/local.php.example';
}

$app = new App(new Config(require $configFile));
$headers = function_exists('getallheaders') ? getallheaders() : [];
foreach (['HTTP_AUTHORIZATION' => 'Authorization', 'HTTP_X_SMS_GATEWAY_TOKEN' => 'X-SMS-Gateway-Token'] as $serverKey => $headerName) {
    if (isset($_SERVER[$serverKey]) && !isset($headers[$headerName])) {
        $headers[$headerName] = (string) $_SERVER[$serverKey];
    }
}

$requestUri = $_SERVER['REQUEST_URI'] ?? '/';
$query = [];
$queryString = parse_url($requestUri, PHP_URL_QUERY);
if (is_string($queryString)) {
    parse_str($queryString, $query);
}

$response = $app->handle(
    $_SERVER['REQUEST_METHOD'] ?? 'GET',
    parse_url($requestUri, PHP_URL_PATH) ?: '/',
    file_get_contents('php://input') ?: '',
    $headers,
    $_SERVER['REMOTE_ADDR'] ?? '',
    $query
);

JsonResponse::send($response);
