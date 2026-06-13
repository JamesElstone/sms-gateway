#!/usr/bin/env php
<?php
declare(strict_types=1);

// Copyright (c) 2026, James Elstone
// SPDX-License-Identifier: BSD-3-Clause
//
// This file is part of SMS Gateway:
// https://github.com/JamesElstone/sms-gateway
//
// See LICENSE for details.

require dirname(__DIR__) . '/autoload.php';

exit((new SmsGateway\Service\SmsGatewaySyncCommand(dirname(__DIR__, 2)))->run($argv));
