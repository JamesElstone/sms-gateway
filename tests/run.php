<?php

declare(strict_types=1);

require dirname(__DIR__) . '/src/autoload.php';

$files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator(dirname(__DIR__) . '/src'));
foreach ($files as $file) {
    if ($file->isFile() && $file->getExtension() === 'php') {
        passthru('php -l ' . escapeshellarg($file->getPathname()), $exitCode);
        if ($exitCode !== 0) {
            exit($exitCode);
        }
    }
}

passthru('php -l ' . escapeshellarg(dirname(__DIR__) . '/public/index.php'), $exitCode);
exit($exitCode);
