#!/command/with-contenv php
<?php

declare(strict_types=1);

const ATOM_DIR = '/atom/src';
const PHP_SERIES = '8.3';
const ROLE_FILE = '/etc/atbox/role';

function envOrFail(string $name): string
{
    $value = getenv($name);

    if (false === $value || '' === $value) {
        fwrite(STDERR, "Environment variable {$name} is required\n");
        exit(1);
    }

    return $value;
}

function envOrDefault(string $name, string $default): string
{
    $value = getenv($name);

    if (false === $value || '' === $value) {
        return $default;
    }

    return $value;
}

function nonEmptyEnvOrDefault(string $name, string $default): string
{
    $value = trim(envOrDefault($name, $default));

    return '' === $value ? $default : $value;
}

function boolEnvOrDefault(string $name, bool $default): bool
{
    $value = getenv($name);

    if (false === $value || '' === $value) {
        return $default;
    }

    $normalized = strtolower($value);
    if (in_array($normalized, ['1', 'true', 'yes', 'on'], true)) {
        return true;
    }
    if (in_array($normalized, ['0', 'false', 'no', 'off'], true)) {
        return false;
    }

    fwrite(STDERR, "{$name} must be a boolean value\n");
    exit(1);
}

function hostPort(string $value, int $defaultPort): array
{
    $parts = explode(':', $value, 2);

    return [
        'host' => $parts[0],
        'port' => $parts[1] ?? (string) $defaultPort,
    ];
}

function phpSingleQuoted(string $value): string
{
    return str_replace(['\\', "'"], ['\\\\', "\\'"], $value);
}

function writeFile(string $path, string $contents): void
{
    $dir = dirname($path);

    if (!is_dir($dir)) {
        mkdir($dir, 0775, true);
    }

    file_put_contents($path, $contents);
}

function roleOrFail(): string
{
    if (!is_readable(ROLE_FILE)) {
        fwrite(STDERR, 'atbox role file not found at '.ROLE_FILE."\n");
        exit(1);
    }

    $role = trim((string) file_get_contents(ROLE_FILE));
    if (!in_array($role, ['readonly', 'admin', 'cli', 'worker'], true)) {
        fwrite(STDERR, "Unsupported atbox role: {$role}\n");
        exit(1);
    }

    return $role;
}

function yamlBool(bool $value): string
{
    return $value ? 'true' : 'false';
}

function validateSimpleName(string $name, string $value): void
{
    if (!preg_match('/^[A-Za-z0-9_-]*$/', $value)) {
        fwrite(STDERR, "{$name} may contain only letters, numbers, '_' or '-'\n");
        exit(1);
    }
}

$role = roleOrFail();
$legacyNamespace = envOrDefault('ATOM_NAMESPACE', 'atom');
$config = [
    'atom.elasticsearch_host' => envOrFail('ATOM_ELASTICSEARCH_HOST'),
    'atom.memcached_host' => envOrFail('ATOM_MEMCACHED_HOST'),
    'atom.gearman_host' => nonEmptyEnvOrDefault('ATOM_GEARMAN_HOST', '127.0.0.1:4730'),
    'atom.cache_namespace' => envOrDefault('ATOM_CACHE_NAMESPACE', $legacyNamespace),
    'atom.session_name' => envOrDefault('ATOM_SESSION_NAME', $legacyNamespace),
    'atom.workers_key' => envOrDefault('ATOM_WORKERS_KEY', ''),
    'atom.mysql_dsn' => envOrFail('ATOM_MYSQL_DSN'),
    'atom.mysql_username' => envOrFail('ATOM_MYSQL_USERNAME'),
    'atom.mysql_password' => envOrFail('ATOM_MYSQL_PASSWORD'),
];
$readOnly = 'readonly' === $role;
$uploadsEnabled = 'admin' === $role && boolEnvOrDefault('ATOM_UPLOADS_ENABLED', false);
$uploadLimit = $readOnly || !$uploadsEnabled && 'admin' === $role
    ? '0'
    : envOrDefault('ATOM_UPLOAD_LIMIT', '-1');
$sessionCookieSecure = 'admin' === $role
    ? boolEnvOrDefault('ATOM_SESSION_COOKIE_SECURE', true)
    : true;
$sessionCookieSameSite = strtolower(envOrDefault('ATOM_SESSION_COOKIE_SAMESITE', 'lax'));
$phpPostMaxSize = $uploadsEnabled ? envOrDefault('ATOM_PHP_POST_MAX_SIZE', '512M') : '8M';
$phpFileUploads = $uploadsEnabled ? 'On' : 'Off';
$phpUploadMaxFilesize = $uploadsEnabled ? envOrDefault('ATOM_PHP_UPLOAD_MAX_FILESIZE', '512M') : '0';
$phpMaxFileUploads = $uploadsEnabled ? envOrDefault('ATOM_PHP_MAX_FILE_UPLOADS', '20') : '0';

if (!is_dir(ATOM_DIR)) {
    fwrite(STDERR, 'AtoM source tree not found at '.ATOM_DIR."\n");
    exit(1);
}

if (!class_exists('Memcache')) {
    fwrite(STDERR, "PHP Memcache extension is required (class Memcache not found)\n");
    exit(1);
}

foreach ([
    'ATOM_CACHE_NAMESPACE' => $config['atom.cache_namespace'],
    'ATOM_SESSION_NAME' => $config['atom.session_name'],
] as $name => $value) {
    if (!preg_match('/^[A-Za-z0-9_-]+$/', $value)) {
        fwrite(STDERR, "{$name} may contain only letters, numbers, '_' or '-'\n");
        exit(1);
    }
}
validateSimpleName('ATOM_WORKERS_KEY', $config['atom.workers_key']);

if (!preg_match('/^-?[0-9]+(?:\.[0-9]+)?$/', $uploadLimit)) {
    fwrite(STDERR, "ATOM_UPLOAD_LIMIT must be a number of gigabytes\n");
    exit(1);
}

if (!in_array($sessionCookieSameSite, ['strict', 'lax', 'none'], true)) {
    fwrite(STDERR, "ATOM_SESSION_COOKIE_SAMESITE must be one of strict, lax, or none\n");
    exit(1);
}

if (!file_exists(ATOM_DIR.'/apps/qubit/config/settings.yml') && file_exists(ATOM_DIR.'/apps/qubit/config/settings.yml.tmpl')) {
    copy(ATOM_DIR.'/apps/qubit/config/settings.yml.tmpl', ATOM_DIR.'/apps/qubit/config/settings.yml');
}

if (!file_exists(ATOM_DIR.'/config/appChallenge.yml') && file_exists(ATOM_DIR.'/config/appChallenge.yml.tmpl')) {
    copy(ATOM_DIR.'/config/appChallenge.yml.tmpl', ATOM_DIR.'/config/appChallenge.yml');
}

if (file_exists(ATOM_DIR.'/config/propel.ini.tmpl')) {
    copy(ATOM_DIR.'/config/propel.ini.tmpl', ATOM_DIR.'/config/propel.ini');
}

$elasticsearch = hostPort($config['atom.elasticsearch_host'], 9200);
$memcached = hostPort($config['atom.memcached_host'], 11211);
$gearman = hostPort($config['atom.gearman_host'], 4730);
$readOnlyYaml = yamlBool($readOnly);
$fpmReadOnly = $readOnly ? 'on' : 'off';
$sessionCookieSecureYaml = yamlBool($sessionCookieSecure);
$workersKey = $config['atom.workers_key'];
$gearmanYaml = <<<YAML
all:
  servers:
    default: {$gearman['host']}:{$gearman['port']}

YAML;

// Keep Gearman config present because AtoM job code loads it even before enqueuing work.
writeFile(ATOM_DIR.'/config/gearman.yml', $gearmanYaml);
writeFile(ATOM_DIR.'/apps/qubit/config/gearman.yml', $gearmanYaml);

writeFile(
    ATOM_DIR.'/apps/qubit/config/app.yml',
    <<<YAML
all:
  upload_limit: {$uploadLimit}
  download_timeout: 10
  workers_key: {$workersKey}
  cache_engine: sfMemcacheCache
  cache_engine_param:
    host: {$memcached['host']}
    port: {$memcached['port']}
    prefix: {$config['atom.cache_namespace']}
    storeCacheInfo: true
    persistent: true
  read_only: {$readOnlyYaml}
  htmlpurifier_enabled: false
  csp:
    response_header: Content-Security-Policy
    directives: >
      default-src 'self';
      font-src 'self' https://fonts.gstatic.com;
      form-action 'self';
      img-src 'self' https://*.googleapis.com https://*.gstatic.com *.google.com *.googleusercontent.com data: https://www.gravatar.com/avatar/ https://*.google-analytics.com https://*.googletagmanager.com blob:;
      script-src 'self' https://*.googletagmanager.com 'nonce' https://*.googleapis.com https://*.gstatic.com *.google.com https://*.ggpht.com *.googleusercontent.com blob:;
      style-src 'self' 'nonce' https://fonts.googleapis.com;
      worker-src 'self' blob:;
      connect-src 'self' https://*.google-analytics.com https://*.analytics.google.com https://*.googletagmanager.com https://*.googleapis.com *.google.com https://*.gstatic.com data: blob:;
      frame-ancestors 'self';
YAML
);

writeFile(
    ATOM_DIR.'/apps/qubit/config/factories.yml',
    <<<YAML
prod:
  storage:
    class: QubitCacheSessionStorage
    param:
      session_name: {$config['atom.session_name']}
      session_cookie_httponly: true
      session_cookie_secure: {$sessionCookieSecureYaml}
      session_cookie_samesite: {$sessionCookieSameSite}
      cache:
        class: sfMemcacheCache
        param:
          host: {$memcached['host']}
          port: {$memcached['port']}
          prefix: {$config['atom.cache_namespace']}
          storeCacheInfo: true
          persistent: true

dev:
  storage:
    class: QubitCacheSessionStorage
    param:
      session_name: {$config['atom.session_name']}
      session_cookie_httponly: true
      session_cookie_secure: {$sessionCookieSecureYaml}
      session_cookie_samesite: {$sessionCookieSameSite}
      cache:
        class: sfMemcacheCache
        param:
          host: {$memcached['host']}
          port: {$memcached['port']}
          prefix: {$config['atom.cache_namespace']}
          storeCacheInfo: true
          persistent: true

all:
  i18n:
    class: sfTranslateI18N
    param:
      cache:
        class: sfFileCache
        param:
          automatic_cleaning_factor: 0
          cache_dir: %SF_TEMPLATE_CACHE_DIR%
          lifetime: 86400
          prefix: %SF_APP_DIR%/template

  view_cache:
    class: sfFileCache
    param:
      automatic_cleaning_factor: 0
      cache_dir: %SF_TEMPLATE_CACHE_DIR%
      lifetime: 86400
      prefix: %SF_APP_DIR%/template

  logger:
    class: sfAggregateLogger
    param:
      level: warning
      loggers:
        sf_file:
          class: sfStreamLogger
          param:
            level: warning
            stream: php://stderr
YAML
);

writeFile(
    ATOM_DIR.'/config/search.yml',
    <<<YAML
all:
  server:
    host: {$elasticsearch['host']}
    port: {$elasticsearch['port']}

YAML
);

$mysqlDsn = phpSingleQuoted($config['atom.mysql_dsn']);
$mysqlUser = phpSingleQuoted($config['atom.mysql_username']);
$mysqlPassword = phpSingleQuoted($config['atom.mysql_password']);

writeFile(
    ATOM_DIR.'/config/config.php',
    <<<PHP
<?php

return [
    'all' => [
        'propel' => [
            'class' => 'sfPropelDatabase',
            'param' => [
                'encoding' => 'utf8mb4',
                'persistent' => true,
                'pooling' => true,
                'dsn' => '{$mysqlDsn}',
                'username' => '{$mysqlUser}',
                'password' => '{$mysqlPassword}',
            ],
        ],
    ],
    'dev' => [
        'propel' => [
            'param' => [
                'classname' => 'PropelPDO',
                'debug' => [
                    'realmemoryusage' => true,
                    'details' => [
                        'time' => ['enabled' => true],
                        'slow' => ['enabled' => true, 'threshold' => 0.1],
                        'mem' => ['enabled' => true],
                        'mempeak' => ['enabled' => true],
                        'memdelta' => ['enabled' => true],
                    ],
                ],
            ],
        ],
    ],
    'test' => [
        'propel' => [
            'param' => [
                'classname' => 'PropelPDO',
            ],
        ],
    ],
];

PHP
);

writeFile(
    '/etc/php/'.PHP_SERIES.'/mods-available/atbox.ini',
    <<<INI
[PHP]
output_buffering = 4096
expose_php = off
log_errors = on
error_reporting = E_ALL
display_errors = stderr
display_startup_errors = on
max_execution_time = 120
max_input_time = 60
memory_limit = 512M
post_max_size = {$phpPostMaxSize}
default_charset = UTF-8
cgi.fix_pathinfo = off
file_uploads = {$phpFileUploads}
upload_max_filesize = {$phpUploadMaxFilesize}
max_file_uploads = {$phpMaxFileUploads}
date.timezone = UTC
session.use_only_cookies = on
opcache.fast_shutdown = on
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = off

INI
);

@symlink('/etc/php/'.PHP_SERIES.'/mods-available/atbox.ini', '/etc/php/'.PHP_SERIES.'/cli/conf.d/99-atbox.ini');
@symlink('/etc/php/'.PHP_SERIES.'/mods-available/atbox.ini', '/etc/php/'.PHP_SERIES.'/fpm/conf.d/99-atbox.ini');

writeFile(
    '/etc/php/'.PHP_SERIES.'/fpm/pool.d/atom.conf',
    <<<FPM
[atom]
clear_env = no
catch_workers_output = yes
decorate_workers_output = no
access.log = /dev/null
listen = 127.0.0.1:9000
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
env[ATOM_READ_ONLY] = "{$fpmReadOnly}"

FPM
);

@symlink(ATOM_DIR.'/vendor/symfony/data/web/sf', ATOM_DIR.'/sf');

foreach ([
    ATOM_DIR.'/web/uploads',
    ATOM_DIR.'/web/uploads/tmp',
    ATOM_DIR.'/web/downloads',
] as $runtimeDir) {
    if (!is_dir($runtimeDir)) {
        @mkdir($runtimeDir, 0775, true);
    }

    @chown($runtimeDir, 'atbox');
    @chgrp($runtimeDir, 'atbox');
}

fwrite(STDOUT, "atbox php bootstrap complete ({$role})\n");
