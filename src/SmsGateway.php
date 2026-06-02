<?php

declare(strict_types=1);

namespace SmsGateway;

use SmsGateway\Lte\LteModemClient;

final class SmsGateway
{
    public function __construct(private readonly LteModemClient $client)
    {
    }

    public function send(string $mobile, string $message): Result
    {
        $health = $this->client->health();
        $healthStatus = StatusMapper::fromHealth($health);
        if ($healthStatus !== null) {
            return new Result($healthStatus->httpStatus, [
                'status' => $healthStatus->status,
                'mobile' => $mobile,
                'message' => $healthStatus->message,
                'dongle' => $health,
            ]);
        }

        $sendResult = $this->client->sendSms([$mobile], $message);
        if ($sendResult === 'OK') {
            return new Result(200, [
                'status' => 'sent',
                'mobile' => $mobile,
                'message' => 'SMS sent',
            ]);
        }

        return new Result(502, [
            'status' => 'unable_to_send',
            'mobile' => $mobile,
            'message' => 'LTE device API did not confirm the send',
            'lte_response' => $sendResult,
        ]);
    }
}
