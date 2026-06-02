<?php

declare(strict_types=1);

namespace SmsGateway\Lte;

final class LteModemClient
{
    /** @var list<string> */
    private array $tokens = [];
    private readonly string $cookieFile;

    public function __construct(
        private readonly string $baseUrl,
        private readonly ?string $username = null,
        private readonly ?string $password = null,
        private readonly int $timeoutSeconds = 10
    ) {
        if (!extension_loaded('curl')) {
            throw new LteTransportException('PHP cURL extension is not loaded');
        }

        $this->cookieFile = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'sms-gateway-lte-' . bin2hex(random_bytes(8)) . '.cookies';
    }

    public function __destruct()
    {
        if (is_file($this->cookieFile)) {
            @unlink($this->cookieFile);
        }
    }

    /** @return array<string, mixed> */
    public function health(): array
    {
        $this->initializeSession();

        return [
            'device_information' => $this->safeGet('device/information'),
            'pin_status' => $this->safeGet('pin/status'),
            'monitoring_status' => $this->safeGet('monitoring/status'),
            'signal' => $this->safeGet('device/signal'),
        ];
    }

    /** @param list<string> $phoneNumbers */
    public function sendSms(array $phoneNumbers, string $message): mixed
    {
        $this->initializeSession();

        return $this->post('sms/send-sms', [
            'Index' => -1,
            'Phones' => ['Phone' => $phoneNumbers],
            'Sca' => '',
            'Content' => $message,
            'Length' => mb_strlen($message, 'UTF-8'),
            'Reserved' => 1,
            'Date' => gmdate('Y-m-d H:i:s'),
        ]);
    }

    private function initializeSession(): void
    {
        $this->tokens = [];

        $response = $this->request('GET', $this->baseUrl);
        if (preg_match_all('/name="csrf_token"\s+content="([^"]+)"/i', $response['body'], $matches)) {
            $this->tokens = array_values($matches[1]);
            return;
        }

        foreach (['webserver/token', 'webserver/SesTokInfo'] as $endpoint) {
            try {
                $tokenResponse = $this->get($endpoint);
                if (isset($tokenResponse['token'])) {
                    $this->tokens[] = (string) $tokenResponse['token'];
                    return;
                }
                if (isset($tokenResponse['TokInfo'])) {
                    $this->tokens[] = (string) $tokenResponse['TokInfo'];
                    return;
                }
            } catch (LteApiException) {
            }
        }
    }

    /** @return array<string, mixed> */
    private function safeGet(string $endpoint): array
    {
        try {
            $response = $this->get($endpoint);
            return is_array($response) ? $response : ['value' => $response];
        } catch (\Throwable $exception) {
            return ['error' => $exception->getMessage()];
        }
    }

    private function get(string $endpoint): mixed
    {
        $headers = [];
        if (count($this->tokens) === 1) {
            $headers[] = '__RequestVerificationToken: ' . $this->tokens[0];
        }

        $response = $this->request('GET', $this->apiUrl($endpoint), null, $headers);
        return $this->decodeDeviceResponse($response['body']);
    }

    /** @param array<string, mixed>|null $payload */
    private function post(string $endpoint, ?array $payload): mixed
    {
        $attempts = 0;
        while (true) {
            $attempts++;
            $headers = ['Content-Type: application/xml'];
            if ($this->tokens !== []) {
                $headers[] = '__RequestVerificationToken: ' . (count($this->tokens) > 1 ? array_shift($this->tokens) : $this->tokens[0]);
            }

            $response = $this->request('POST', $this->apiUrl($endpoint), $payload === null ? '' : $this->requestXml($payload), $headers);
            $this->captureTokensFromHeaders($response['headers']);

            try {
                return $this->decodeDeviceResponse($response['body']);
            } catch (LteApiException $exception) {
                if ($attempts === 1 && in_array($exception->getLteCode(), [125002, 125003], true)) {
                    $this->initializeSession();
                    continue;
                }

                throw $exception;
            }
        }
    }

    private function apiUrl(string $endpoint): string
    {
        return rtrim($this->baseUrl, '/') . '/api/' . ltrim($endpoint, '/');
    }

    /** @param list<string> $headers */
    private function request(string $method, string $url, ?string $body = null, array $headers = []): array
    {
        $curl = curl_init($url);
        if ($curl === false) {
            throw new LteTransportException('Unable to initialise cURL');
        }

        $responseHeaders = [];
        curl_setopt_array($curl, [
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HEADER => false,
            CURLOPT_CONNECTTIMEOUT => $this->timeoutSeconds,
            CURLOPT_TIMEOUT => $this->timeoutSeconds,
            CURLOPT_COOKIEJAR => $this->cookieFile,
            CURLOPT_COOKIEFILE => $this->cookieFile,
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_HEADERFUNCTION => static function ($curl, string $header) use (&$responseHeaders): int {
                $responseHeaders[] = trim($header);
                return strlen($header);
            },
        ]);

        if ($this->username !== null && $this->password !== null) {
            curl_setopt($curl, CURLOPT_USERPWD, $this->username . ':' . $this->password);
        }

        if ($body !== null) {
            curl_setopt($curl, CURLOPT_POSTFIELDS, $body);
        }

        $responseBody = curl_exec($curl);
        if ($responseBody === false) {
            $message = curl_error($curl);
            curl_close($curl);
            throw new LteTransportException($message === '' ? 'Unable to contact LTE device' : $message);
        }

        $statusCode = (int) curl_getinfo($curl, CURLINFO_RESPONSE_CODE);
        curl_close($curl);

        if ($statusCode >= 400 || $statusCode === 0) {
            throw new LteTransportException('LTE device returned HTTP ' . $statusCode);
        }

        return ['body' => (string) $responseBody, 'headers' => $responseHeaders];
    }

    /** @param list<string> $headers */
    private function captureTokensFromHeaders(array $headers): void
    {
        foreach ($headers as $header) {
            if (preg_match('/^__RequestVerificationToken(?:one|two)?:\s*(.+)$/i', $header, $match)) {
                $this->tokens[] = trim($match[1]);
            }
        }
    }

    private function requestXml(array $payload): string
    {
        $document = new \DOMDocument('1.0', 'UTF-8');
        $request = $document->createElement('request');
        $document->appendChild($request);

        foreach ($payload as $key => $value) {
            $this->appendXmlValue($document, $request, (string) $key, $value);
        }

        return $document->saveXML($document->documentElement) ?: '<request/>';
    }

    private function appendXmlValue(\DOMDocument $document, \DOMElement $parent, string $key, mixed $value): void
    {
        if (is_array($value) && array_is_list($value)) {
            foreach ($value as $item) {
                $this->appendXmlValue($document, $parent, $key, $item);
            }
            return;
        }

        $child = $document->createElement($key);
        $parent->appendChild($child);

        if (is_array($value)) {
            foreach ($value as $childKey => $childValue) {
                $this->appendXmlValue($document, $child, (string) $childKey, $childValue);
            }
            return;
        }

        $child->appendChild($document->createTextNode((string) $value));
    }

    private function decodeDeviceResponse(string $body): mixed
    {
        $body = trim($body);
        if ($body === '') {
            return [];
        }

        $xml = @simplexml_load_string($body, 'SimpleXMLElement', LIBXML_NOCDATA);
        if ($xml === false) {
            throw new LteTransportException('LTE device returned non-XML response');
        }

        $rootName = $xml->getName();
        if ($rootName === 'error') {
            $code = isset($xml->code) ? (int) $xml->code : null;
            $message = trim((string) ($xml->message ?? '')) ?: $this->messageForErrorCode($code);
            throw new LteApiException($code === null ? $message : $code . ': ' . $message, $code);
        }

        if ($rootName === 'response' && count($xml->children()) === 0) {
            return (string) $xml;
        }

        return $this->simpleXmlToArray($xml);
    }

    private function messageForErrorCode(?int $code): string
    {
        return match ($code) {
            100002 => 'No support',
            100003 => 'No rights or login required',
            100004 => 'System busy',
            100005 => 'Request format error',
            125002 => 'Session error',
            125003 => 'Wrong session token',
            default => 'Unknown LTE device API error',
        };
    }

    /** @return array<string, mixed>|string */
    private function simpleXmlToArray(\SimpleXMLElement $xml): array|string
    {
        $json = json_encode($xml, JSON_THROW_ON_ERROR);
        $decoded = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
        return is_array($decoded) ? $decoded : (string) $xml;
    }
}
