<?php

// Invoked explicitly by deploy.sh for an unfinished local installation only.
if (PHP_SAPI !== 'cli' || !function_exists('posix_geteuid') || posix_geteuid() !== 0) {
    fwrite(STDERR, "Run this repair through sudo bash deploy.sh repair-database.\n");
    exit(77);
}

function runAdminSql(string $sql): void
{
    // SQL, including the generated password, is sent over a private stdin pipe.
    $process = proc_open(['mariadb', '--protocol=socket', '--user=root', '--batch'], [
        0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w'],
    ], $pipes);
    if (!is_resource($process)) {
        throw new RuntimeException('Cannot start the local MariaDB administrator client.');
    }
    fwrite($pipes[0], $sql . "\n");
    fclose($pipes[0]);
    stream_get_contents($pipes[1]);
    stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    if (proc_close($process) !== 0) {
        throw new RuntimeException('Local MariaDB administration failed. Verify sudo mariadb access.');
    }
}

$created = false;
$committed = false;
$temporary = null;
$username = '';
try {
    $root = realpath($argv[1] ?? '');
    $backupRoot = $argv[2] ?? '';
    if (!$root || !$backupRoot || !is_file($root . '/.env') || !is_file($root . '/vendor/autoload.php')) {
        throw new RuntimeException('An unfinished panel with .env and dependencies is required.');
    }
    require $root . '/vendor/autoload.php';
    $path = $root . '/.env';
    $original = file_get_contents($path);
    $settings = Dotenv\Dotenv::parse($original);
    $database = $settings['DB_DATABASE'] ?? '';
    $port = $settings['DB_PORT'] ?? '3306';
    if (!in_array($settings['DB_CONNECTION'] ?? 'mysql', ['mysql', 'mariadb'], true)
        || ($settings['DB_HOST'] ?? '') !== '127.0.0.1'
        || !preg_match('/^[a-zA-Z0-9_]+$/D', $database)
        || in_array(strtolower($database), ['mysql', 'information_schema', 'performance_schema', 'sys'], true)
        || !ctype_digit($port) || (int) $port < 1 || (int) $port > 65535
        || !empty($settings['DB_URL']) || !empty($settings['DATABASE_URL']) || !empty($settings['DB_SOCKET'])) {
        throw new RuntimeException('This repair supports a saved local MySQL/MariaDB TCP connection only.');
    }

    $backup = $backupRoot . '/database-auth-' . gmdate('Ymd\THis\Z') . '-' . bin2hex(random_bytes(4));
    if (!is_dir($backupRoot) && !mkdir($backupRoot, 0700, true)) {
        throw new RuntimeException('Cannot create the private backup directory.');
    }
    if (!mkdir($backup, 0700) || !copy($path, $backup . '/.env') || !chmod($backup . '/.env', 0600)) {
        throw new RuntimeException('Cannot back up the existing environment.');
    }
    fwrite(STDOUT, "Private environment backup: {$backup}/.env\n");

    $username = 'aq_panel_' . bin2hex(random_bytes(8));
    $password = bin2hex(random_bytes(32));
    runAdminSql("CREATE USER '{$username}'@'127.0.0.1' IDENTIFIED BY '{$password}';");
    $created = true;
    runAdminSql("GRANT ALL PRIVILEGES ON `{$database}`.* TO '{$username}'@'127.0.0.1';");

    // Verify the new account at the actual saved TCP endpoint before saving it.
    $connection = new PDO("mysql:host=127.0.0.1;port={$port};dbname={$database};charset=utf8mb4", $username, $password, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);
    $connection->query('SELECT 1');

    $updated = $original;
    foreach (['DB_USERNAME' => $username, 'DB_PASSWORD' => $password] as $key => $value) {
        $pattern = '/^[ \t]*(?:export[ \t]+)?' . $key . '[ \t]*=.*$/m';
        $line = $key . '="' . $value . '"';
        if (preg_match($pattern, $updated)) {
            $updated = preg_replace($pattern, $line, $updated);
        } else {
            $updated = rtrim($updated, "\r\n") . "\n" . $line . "\n";
        }
    }
    $reparsed = Dotenv\Dotenv::parse($updated);
    if (($reparsed['DB_USERNAME'] ?? '') !== $username || ($reparsed['DB_PASSWORD'] ?? '') !== $password) {
        throw new RuntimeException('Cannot validate the new environment.');
    }
    unset($settings['DB_USERNAME'], $settings['DB_PASSWORD'], $reparsed['DB_USERNAME'], $reparsed['DB_PASSWORD']);
    if ($settings !== $reparsed) {
        throw new RuntimeException('Database repair must retain every other environment setting.');
    }
    // Keep keys and all other settings intact; publish the file atomically.
    $metadata = stat($path);
    $temporary = tempnam($root, '.env-database-');
    if (!$temporary || file_put_contents($temporary, $updated) === false
        || !chgrp($temporary, $metadata['gid']) || !chmod($temporary, 0640)
        || !rename($temporary, $path)) {
        throw new RuntimeException('Cannot save the verified database configuration.');
    }
    $committed = true;
    fwrite(STDOUT, "Dedicated loopback database account configured for {$database}. Existing accounts and tables are preserved.\n");
} catch (Throwable $exception) {
    if (is_string($temporary) && is_file($temporary)) {
        unlink($temporary);
    }
    if ($created && !$committed) {
        try {
            runAdminSql("DROP USER '{$username}'@'127.0.0.1';");
        } catch (Throwable) {
            fwrite(STDERR, "An unused repair account may remain; inspect local MariaDB accounts.\n");
        }
    }
    // Do not expose SQL, credentials or arbitrary PDO messages.
    fwrite(STDERR, "Database repair failed; the saved environment was not replaced. Verify the local database, port and administrator socket access.\n");
    exit(69);
}
