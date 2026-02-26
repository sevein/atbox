#!/command/with-contenv php
<?php

declare(strict_types=1);

const ATOM_DIR = '/atom/src';
const ETC_DIR = '/usr/local/etc';

function envOrFail(string $name): string
{
    $value = getenv($name);

    if (false === $value || '' === $value) {
        fwrite(STDERR, "Environment variable {$name} is required\n");
        exit(1);
    }

    return $value;
}

function hostPort(string $value, int $defaultPort): array
{
    $parts = explode(':', $value, 2);

    return [
        'host' => $parts[0],
        'port' => $parts[1] ?? (string) $defaultPort,
    ];
}

function writeFile(string $path, string $contents): void
{
    $dir = dirname($path);
    if (!is_dir($dir)) {
        mkdir($dir, 0775, true);
    }

    file_put_contents($path, $contents);
}

$config = [
    'atom.elasticsearch_host' => envOrFail('ATOM_ELASTICSEARCH_HOST'),
    'atom.mysql_dsn' => envOrFail('ATOM_MYSQL_DSN'),
    'atom.mysql_username' => envOrFail('ATOM_MYSQL_USERNAME'),
    'atom.mysql_password' => envOrFail('ATOM_MYSQL_PASSWORD'),
];

if (!is_dir(ATOM_DIR)) {
    fwrite(STDERR, 'AtoM source tree not found at '.ATOM_DIR."\n");
    exit(1);
}

// Seed generated files expected by AtoM when missing.
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
$readOnlyText = 'true';
$fpmReadOnly = 'on';
$gearmanCompatHost = '127.0.0.1:4730';

// Keep this file for compatibility, but atbox never runs Gearman.
writeFile(
    ATOM_DIR.'/apps/qubit/config/gearman.yml',
    "all:\n  servers:\n    default: {$gearmanCompatHost}\n"
);

writeFile(
    ATOM_DIR.'/apps/qubit/config/app.yml',
    <<<YAML
all:
  upload_limit: -1
  download_timeout: 10
  cache_engine: sfFileCache
  cache_engine_param:
    cache_dir: /tmp/atom/cache/app
  read_only: {$readOnlyText}
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
    class: sfSessionStorage
    param:
      session_name: symfony
      session_cookie_httponly: true
      session_cookie_secure: true

dev:
  storage:
    class: sfSessionStorage
    param:
      session_name: symfony
      session_cookie_httponly: true
      session_cookie_secure: true

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
                'dsn' => '{$config['atom.mysql_dsn']}',
                'username' => '{$config['atom.mysql_username']}',
                'password' => '{$config['atom.mysql_password']}',
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

$phpIni = <<<INI
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
post_max_size = 8M
default_charset = UTF-8
cgi.fix_pathinfo = off
file_uploads = Off
upload_max_filesize = 0
max_file_uploads = 0
date.timezone = UTC
session.use_only_cookies = off
opcache.fast_shutdown = on
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = off

INI;

writeFile(ETC_DIR.'/php/php.ini', $phpIni);

$fpmIni = <<<FPM
[global]
error_log = /proc/self/fd/2
daemonize = no

[atom]
access.log = /proc/self/fd/2
clear_env = no
catch_workers_output = yes
user = root
group = root
listen = 127.0.0.1:9000
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
env[ATOM_READ_ONLY] = "{$fpmReadOnly}"

FPM;

writeFile(ETC_DIR.'/php-fpm.d/atom.conf', $fpmIni);

@symlink(ATOM_DIR.'/vendor/symfony/data/web/sf', ATOM_DIR.'/sf');

fwrite(STDOUT, "atbox php bootstrap complete\n");
fwrite(STDOUT, "  read-only: on\n");
fwrite(STDOUT, "  mysql dsn: {$config['atom.mysql_dsn']}\n");
fwrite(STDOUT, "  elasticsearch: {$config['atom.elasticsearch_host']}\n");
fwrite(STDOUT, "  cache/session backend: local filesystem\n");
fwrite(STDOUT, "  php profile: UTC, memory_limit=512M, max_execution_time=120\n");
