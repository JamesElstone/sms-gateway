#!/usr/bin/env php
<?php

declare(strict_types=1);

function usage(): void
{
    $script = basename(__FILE__);
    echo <<<TEXT
Usage:
  php {$script} --token-file PATH --name NAME --allowed-ips LIST [--replace]
  php {$script} --entry-exists --token-file PATH --name NAME

The update form reads the plaintext token from standard input, stores only its
SHA-256 hash, and writes JSON in the SMS Gateway tokens.json format.

Options:
  --help              Show this help text.
  --token-file PATH   tokens.json path. Defaults to this directory's tokens.json.
  --name NAME         Token entry name.
  --allowed-ips LIST  Comma or whitespace separated IP/CIDR allow-list.
                      Use an empty value to allow any client IP.
  --replace           Replace an existing entry with the same name.
  --entry-exists      Check whether a named entry exists; no file changes.

TEXT;
}

function fail(string $message, int $code = 2): void
{
    fwrite(STDERR, "ERROR: {$message}\n");
    exit($code);
}

/** @param list<string> $args */
function hasFlag(array $args, string $flag): bool
{
    return in_array($flag, $args, true);
}

/** @param list<string> $args */
function optionValue(array $args, string $name): ?string
{
    foreach ($args as $index => $arg) {
        if ($arg === $name) {
            return $args[$index + 1] ?? null;
        }

        if (str_starts_with($arg, $name . '=')) {
            return substr($arg, strlen($name) + 1);
        }
    }

    return null;
}

function validateName(string $name): void
{
    if ($name === '') {
        fail('token name is required');
    }

    if (preg_match('/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/', $name) !== 1) {
        fail('token name must start with a letter or digit and use only letters, digits, dot, underscore, or hyphen');
    }
}

/** @return array<string, mixed> */
function loadTokenDocument(string $tokenFile): array
{
    if (!is_file($tokenFile)) {
        return ['tokens' => []];
    }

    $json = file_get_contents($tokenFile);
    if ($json === false) {
        fail("unable to read {$tokenFile}");
    }

    $decoded = json_decode($json, true);
    if (!is_array($decoded)) {
        fail("{$tokenFile} is not valid JSON");
    }

    if (array_is_list($decoded)) {
        $document = ['tokens' => $decoded];
    } else {
        $document = $decoded;
    }

    if (!isset($document['tokens'])) {
        $document['tokens'] = [];
    }

    if (!is_array($document['tokens'])) {
        fail('tokens field must be an array');
    }

    foreach ($document['tokens'] as $index => $entry) {
        if (!is_array($entry)) {
            fail("tokens[{$index}] must be an object");
        }
    }

    return $document;
}

/** @param array<string, mixed> $document */
function tokenEntryExists(array $document, string $name): bool
{
    foreach ($document['tokens'] as $entry) {
        if (is_array($entry) && ($entry['name'] ?? null) === $name) {
            return true;
        }
    }

    return false;
}

/** @return list<string> */
function parseAllowedIps(string $value): array
{
    $value = trim($value);
    if ($value === '') {
        return [];
    }

    $parts = preg_split('/[\s,]+/', $value) ?: [];
    $allowed = [];
    foreach ($parts as $part) {
        $part = trim($part);
        if ($part === '') {
            continue;
        }

        validateIpRule($part);
        $allowed[] = $part;
    }

    return array_values(array_unique($allowed));
}

function validateIpRule(string $rule): void
{
    if (!str_contains($rule, '/')) {
        if (@inet_pton($rule) === false) {
            fail("allowed IP '{$rule}' is not a valid IP address or CIDR range");
        }
        return;
    }

    [$network, $prefixLength] = explode('/', $rule, 2);
    $packed = @inet_pton($network);
    if ($packed === false || preg_match('/^[0-9]+$/', $prefixLength) !== 1) {
        fail("allowed IP '{$rule}' is not a valid CIDR range");
    }

    $prefix = (int) $prefixLength;
    $max = strlen($packed) * 8;
    if ($prefix < 0 || $prefix > $max) {
        fail("CIDR prefix for '{$rule}' must be between 0 and {$max}");
    }
}

/** @param array<string, mixed> $document */
function writeTokenDocument(string $tokenFile, array $document): void
{
    $dir = dirname($tokenFile);
    if (!is_dir($dir)) {
        fail("directory does not exist: {$dir}");
    }

    $json = json_encode($document, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    if ($json === false) {
        fail('unable to encode token JSON');
    }

    $tmpFile = $tokenFile . '.' . getmypid() . '.tmp';
    if (file_put_contents($tmpFile, $json . PHP_EOL, LOCK_EX) === false) {
        fail("unable to write temporary file {$tmpFile}");
    }

    @chmod($tmpFile, 0600);

    if (!@rename($tmpFile, $tokenFile)) {
        @unlink($tmpFile);
        fail("unable to replace {$tokenFile}");
    }

    @chmod($tokenFile, 0600);
}

/** @param array<string, mixed> $document */
function updateTokenDocument(array $document, string $name, string $token, array $allowedIps, bool $replace): array
{
    if (strlen($token) < 16) {
        fail('token must be at least 16 characters long');
    }

    $newEntry = [
        'name' => $name,
        'token_sha256' => hash('sha256', $token),
        'allowed_ips' => $allowedIps,
    ];

    $updated = false;
    $entries = [];
    foreach ($document['tokens'] as $entry) {
        if (($entry['name'] ?? null) !== $name) {
            $entries[] = $entry;
            continue;
        }

        if (!$replace) {
            fail("token entry '{$name}' already exists; rerun with replacement enabled", 3);
        }

        if (!$updated) {
            $entries[] = $newEntry;
            $updated = true;
        }
    }

    if (!$updated) {
        $entries[] = $newEntry;
    }

    $document['tokens'] = $entries;
    return [$document, $updated ? 'replaced' : 'added'];
}

$args = $argv;
array_shift($args);

if (hasFlag($args, '--help') || hasFlag($args, '-h')) {
    usage();
    exit(0);
}

$tokenFile = optionValue($args, '--token-file') ?? (__DIR__ . '/tokens.json');
$name = optionValue($args, '--name') ?? '';
validateName($name);

$document = loadTokenDocument($tokenFile);

if (hasFlag($args, '--entry-exists')) {
    exit(tokenEntryExists($document, $name) ? 0 : 1);
}

$allowedIps = parseAllowedIps(optionValue($args, '--allowed-ips') ?? '');
$replace = hasFlag($args, '--replace');
$token = trim((string) stream_get_contents(STDIN));

[$document, $action] = updateTokenDocument($document, $name, $token, $allowedIps, $replace);
writeTokenDocument($tokenFile, $document);

echo "Token entry {$action}: {$name}\n";
echo "Token file: {$tokenFile}\n";
echo 'Allowed IP rules: ' . (count($allowedIps) === 0 ? 'any client IP' : implode(', ', $allowedIps)) . "\n";
