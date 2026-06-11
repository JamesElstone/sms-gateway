<?php

declare(strict_types=1);

namespace SmsGateway;

use SmsGateway\Http\Response;
use SmsGateway\Lte\LteApiException;
use SmsGateway\Lte\LteModemClient;
use SmsGateway\Lte\LteTransportException;
use SmsGateway\Security\FileTokenAuthorizer;

final class App
{
    public function __construct(private readonly Config $config)
    {
    }

    /** @param array<string, string> $headers */
    public function handle(string $method, string $path, string $body, array $headers = [], string $clientIp = ''): Response
    {
        if ($method === 'GET' && preg_match('#^/sms-gateway/?$#', $path) === 1) {
            return $this->handleStatus();
        }

        if ($method === 'GET' && preg_match('#^/sms-gateway/carriers/?$#', $path) === 1) {
            return $this->handleCarriers();
        }

        if ($method !== 'POST') {
            return Response::json(405, ['status' => 'unable_to_send', 'message' => 'Only POST is supported']);
        }

        if (!preg_match('#^/sms-gateway/send/([^/]+)$#', $path, $matches)) {
            return Response::json(404, ['status' => 'unable_to_send', 'message' => 'Unknown endpoint']);
        }

        $auth = (new FileTokenAuthorizer($this->config->tokenFile()))->authorize($headers, $clientIp);
        if (!$auth->allowed) {
            return Response::json($auth->httpStatus, [
                'status' => 'unauthorised',
                'message' => $auth->message,
            ]);
        }

        $mobile = rawurldecode($matches[1]);
        if (!$this->isPlausibleMobileNumber($mobile)) {
            return Response::json(400, ['status' => 'unable_to_send', 'message' => 'Invalid mobile number']);
        }

        if ($body === '') {
            return Response::json(400, ['status' => 'unable_to_send', 'message' => 'SMS payload is empty']);
        }

        if (strlen($body) > $this->config->maxMessageBytes()) {
            return Response::json(413, ['status' => 'unable_to_send', 'message' => 'SMS payload is too large']);
        }

        $gateway = new SmsGateway($this->modemClient());

        try {
            $result = $gateway->send($mobile, $body);
            return Response::json($result->httpStatus, $result->payload);
        } catch (LteApiException $exception) {
            $status = StatusMapper::fromLteApiException($exception);
            return Response::json($status->httpStatus, [
                'status' => $status->status,
                'mobile' => $mobile,
                'message' => $status->message,
                'lte_error_code' => $exception->getLteCode(),
            ]);
        } catch (LteTransportException $exception) {
            return Response::json(503, [
                'status' => 'device_missing',
                'mobile' => $mobile,
                'message' => $exception->getMessage(),
            ]);
        } catch (\Throwable $exception) {
            return Response::json(502, [
                'status' => 'lte_error',
                'mobile' => $mobile,
                'message' => $exception->getMessage(),
            ]);
        }
    }

    private function isPlausibleMobileNumber(string $mobile): bool
    {
        return preg_match('/^\+?[0-9][0-9 .()-]{6,24}$/', $mobile) === 1;
    }

    private function handleStatus(): Response
    {
        try {
            $health = $this->modemClient()->health();
            $summary = StatusMapper::summarizeHealth($health);

            return Response::json(200, $summary + ['raw' => $health]);
        } catch (LteTransportException $exception) {
            return Response::json(503, [
                'status' => 'device_missing',
                'message' => $exception->getMessage(),
            ]);
        } catch (LteApiException $exception) {
            $status = StatusMapper::fromLteApiException($exception);
            return Response::json($status->httpStatus, [
                'status' => $status->status,
                'message' => $status->message,
                'lte_error_code' => $exception->getLteCode(),
            ]);
        } catch (\Throwable $exception) {
            return Response::json(502, [
                'status' => 'lte_error',
                'message' => $exception->getMessage(),
            ]);
        }
    }

    private function handleCarriers(): Response
    {
        try {
            $lock = $this->acquireCarrierScanLock();
            if ($lock === null) {
                return Response::json(409, [
                    'status' => 'scan_in_progress',
                    'message' => 'A carrier scan is already in progress; try again shortly',
                ]);
            }

            try {
                $search = $this->modemClient($this->config->carrierScanTimeoutSeconds())->searchCarriers();
            } finally {
                $this->releaseCarrierScanLock($lock);
            }

            return Response::json(200, CarrierMapper::fromSearch($search));
        } catch (LteTransportException $exception) {
            return Response::json(503, [
                'status' => 'device_missing',
                'message' => $exception->getMessage(),
            ]);
        } catch (LteApiException $exception) {
            if ($exception->getLteCode() === 100004) {
                return Response::json(503, [
                    'status' => 'device_busy',
                    'message' => 'LTE device is busy; carrier scan could not complete',
                    'lte_error_code' => $exception->getLteCode(),
                ]);
            }

            $status = StatusMapper::fromLteApiException($exception);
            return Response::json($status->httpStatus, [
                'status' => $status->status,
                'message' => $status->message,
                'lte_error_code' => $exception->getLteCode(),
            ]);
        } catch (\Throwable $exception) {
            return Response::json(502, [
                'status' => 'lte_error',
                'message' => $exception->getMessage(),
            ]);
        }
    }

    /** @return resource|null */
    private function acquireCarrierScanLock()
    {
        $handle = @fopen(sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'sms-gateway-carrier-scan.lock', 'c');
        if ($handle === false) {
            throw new \RuntimeException('Unable to create carrier scan lock');
        }

        if (!flock($handle, LOCK_EX | LOCK_NB)) {
            fclose($handle);
            return null;
        }

        ftruncate($handle, 0);
        fwrite($handle, 'pid=' . getmypid() . ' started=' . gmdate(DATE_ATOM) . PHP_EOL);

        return $handle;
    }

    /** @param resource $handle */
    private function releaseCarrierScanLock($handle): void
    {
        flock($handle, LOCK_UN);
        fclose($handle);
    }

    private function modemClient(?int $timeoutSeconds = null): LteModemClient
    {
        return new LteModemClient(
            $this->config->dongleUrl(),
            $this->config->dongleUsername(),
            $this->config->donglePassword(),
            $timeoutSeconds ?? $this->config->curlTimeoutSeconds()
        );
    }
}
