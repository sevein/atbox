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

function yamlSingleQuoted(string $value): string
{
    return "'".str_replace("'", "''", $value)."'";
}

function yamlStringList(array $values, int $indent): string
{
    $prefix = str_repeat(' ', $indent);
    $lines = [];

    foreach ($values as $value) {
        $lines[] = $prefix.'- '.yamlSingleQuoted((string) $value);
    }

    return implode("\n", $lines);
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

function gearmanWorkerTypesYaml(string $path): string
{
    if (!is_readable($path)) {
        return '';
    }

    $lines = file($path, FILE_IGNORE_NEW_LINES);
    if (false === $lines) {
        return '';
    }

    $block = [];
    $capturing = false;

    foreach ($lines as $line) {
        if (!$capturing) {
            if (preg_match('/^  worker_types:\s*(?:#.*)?$/', $line)) {
                $capturing = true;
                $block[] = $line;
            }

            continue;
        }

        if (preg_match('/^\S/', $line) || preg_match('/^  [A-Za-z0-9_-]+:\s*/', $line)) {
            break;
        }

        if ('' === $line || preg_match('/^( {4,}|  #)/', $line)) {
            $block[] = $line;
            continue;
        }

        break;
    }

    return implode("\n", $block);
}

function validateSimpleName(string $name, string $value): void
{
    if (!preg_match('/^[A-Za-z0-9_-]*$/', $value)) {
        fwrite(STDERR, "{$name} may contain only letters, numbers, '_' or '-'\n");
        exit(1);
    }
}

function envListOrDefault(string $name, array $default): array
{
    $value = envOrDefault($name, '');
    if ('' === trim($value)) {
        return $default;
    }

    $items = array_values(array_filter(array_map('trim', explode(',', $value)), 'strlen'));
    if ([] === $items) {
        fwrite(STDERR, "{$name} must contain at least one non-empty value\n");
        exit(1);
    }

    return $items;
}

function oidcUserGroupsFromEnv(): array
{
    $json = envOrDefault('ATOM_OIDC_USER_GROUPS_JSON', '');
    if ('' === trim($json)) {
        return [
            'administrator' => ['attribute_value' => 'atom-admin', 'group_id' => 100],
            'editor' => ['attribute_value' => 'atom-editor', 'group_id' => 101],
            'contributor' => ['attribute_value' => 'atom-contributor', 'group_id' => 102],
            'translator' => ['attribute_value' => 'atom-translator', 'group_id' => 103],
        ];
    }

    $decoded = json_decode($json, true);
    if (!is_array($decoded)) {
        fwrite(STDERR, "ATOM_OIDC_USER_GROUPS_JSON must be a JSON object\n");
        exit(1);
    }

    $groups = [];
    foreach ($decoded as $name => $group) {
        if (!is_string($name) || !preg_match('/^[A-Za-z0-9_-]+$/', $name)) {
            fwrite(STDERR, "ATOM_OIDC_USER_GROUPS_JSON group names may contain only letters, numbers, '_' or '-'\n");
            exit(1);
        }
        if (!is_array($group)) {
            fwrite(STDERR, "ATOM_OIDC_USER_GROUPS_JSON group {$name} must be an object\n");
            exit(1);
        }

        $attributeValue = $group['attribute_value'] ?? $group['attributeValue'] ?? null;
        $groupId = $group['group_id'] ?? $group['groupId'] ?? null;
        if (!is_string($attributeValue) || '' === trim($attributeValue)) {
            fwrite(STDERR, "ATOM_OIDC_USER_GROUPS_JSON group {$name} requires attribute_value\n");
            exit(1);
        }
        if (!is_int($groupId) && !(is_string($groupId) && preg_match('/^[0-9]+$/', $groupId))) {
            fwrite(STDERR, "ATOM_OIDC_USER_GROUPS_JSON group {$name} requires numeric group_id\n");
            exit(1);
        }

        $groups[$name] = [
            'attribute_value' => $attributeValue,
            'group_id' => (int) $groupId,
        ];
    }

    return $groups;
}

function oidcUserGroupsYaml(array $groups, int $indent): string
{
    $prefix = str_repeat(' ', $indent);
    $lines = [];

    foreach ($groups as $name => $group) {
        $lines[] = $prefix.$name.':';
        $lines[] = $prefix.'  attribute_value: '.yamlSingleQuoted($group['attribute_value']);
        $lines[] = $prefix.'  group_id: '.$group['group_id'];
    }

    return implode("\n", $lines);
}

function configureLoginModule(string $module): void
{
    $path = ATOM_DIR.'/apps/qubit/config/settings.yml';
    if (!is_readable($path)) {
        fwrite(STDERR, "AtoM settings file not found at {$path}\n");
        exit(1);
    }

    $settings = file_get_contents($path);
    $updated = preg_replace('/(^\s*login_module:\s*)[A-Za-z0-9_-]+/m', '${1}'.$module, $settings, 1, $count);
    if (1 !== $count || null === $updated) {
        fwrite(STDERR, "Unable to configure AtoM login_module in {$path}\n");
        exit(1);
    }

    writeFile($path, $updated);
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
$oidcEnabled = boolEnvOrDefault('ATOM_OIDC_ENABLED', false);

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

if ($oidcEnabled && 'admin' !== $role) {
    fwrite(STDERR, "ATOM_OIDC_ENABLED is supported only by the admin role\n");
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

if ($oidcEnabled) {
    $oidcConfig = [
        'provider_url' => envOrFail('ATOM_OIDC_PROVIDER_URL'),
        'client_id' => envOrFail('ATOM_OIDC_CLIENT_ID'),
        'client_secret' => envOrFail('ATOM_OIDC_CLIENT_SECRET'),
        'redirect_url' => envOrFail('ATOM_OIDC_REDIRECT_URL'),
        'logout_redirect_url' => envOrFail('ATOM_OIDC_LOGOUT_REDIRECT_URL'),
        'send_oidc_logout' => boolEnvOrDefault('ATOM_OIDC_SEND_LOGOUT', true),
        'enable_refresh_token_use' => boolEnvOrDefault('ATOM_OIDC_ENABLE_REFRESH_TOKEN_USE', true),
        'server_cert' => envOrDefault('ATOM_OIDC_SERVER_CERT', 'false'),
        'set_groups_from_attributes' => boolEnvOrDefault('ATOM_OIDC_SET_GROUPS_FROM_ATTRIBUTES', true),
        'scopes' => envListOrDefault('ATOM_OIDC_SCOPES', ['openid', 'profile', 'email']),
        'roles_source' => envOrDefault('ATOM_OIDC_ROLES_SOURCE', 'access-token'),
        'roles_path' => envListOrDefault('ATOM_OIDC_ROLES_PATH', ['realm_access', 'roles']),
        'user_matching_source' => envOrDefault('ATOM_OIDC_USER_MATCHING_SOURCE', 'oidc-email'),
        'auto_create_atom_user' => boolEnvOrDefault('ATOM_OIDC_AUTO_CREATE_ATOM_USER', true),
        'user_groups' => oidcUserGroupsFromEnv(),
    ];

    if (!in_array($oidcConfig['roles_source'], ['access-token', 'id-token', 'verified-claims', 'user-info'], true)) {
        fwrite(STDERR, "ATOM_OIDC_ROLES_SOURCE must be one of access-token, id-token, verified-claims, or user-info\n");
        exit(1);
    }
    if (!in_array($oidcConfig['user_matching_source'], ['oidc-email', 'oidc-username'], true)) {
        fwrite(STDERR, "ATOM_OIDC_USER_MATCHING_SOURCE must be oidc-email or oidc-username\n");
        exit(1);
    }

    writeFile(ATOM_DIR.'/activate-oidc-plugin', '');
    configureLoginModule('oidc');
} else {
    @unlink(ATOM_DIR.'/activate-oidc-plugin');
    configureLoginModule('user');
}

$elasticsearch = hostPort($config['atom.elasticsearch_host'], 9200);
$memcached = hostPort($config['atom.memcached_host'], 11211);
$gearman = hostPort($config['atom.gearman_host'], 4730);
$readOnlyYaml = yamlBool($readOnly);
$fpmReadOnly = $readOnly ? 'on' : 'off';
$sessionCookieSecureYaml = yamlBool($sessionCookieSecure);
$oidcUserFactoryYaml = $oidcEnabled ? "\n  user:\n    class: oidcUser\n    param:\n      timeout: 1800\n" : '';
$workersKey = $config['atom.workers_key'];
$gearmanWorkerTypesYaml = gearmanWorkerTypesYaml(ATOM_DIR.'/config/gearman.yml')
    ?: gearmanWorkerTypesYaml(ATOM_DIR.'/apps/qubit/config/gearman.yml');
$gearmanYaml = <<<YAML
all:
  servers:
    default: {$gearman['host']}:{$gearman['port']}

YAML;
if ('' !== $gearmanWorkerTypesYaml) {
    $gearmanYaml .= $gearmanWorkerTypesYaml."\n";
}

// Keep Gearman config present because AtoM job code loads it even before enqueuing work.
// Preserve worker_types so the worker can register AtoM's default abilities.
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
{$oidcUserFactoryYaml}
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

if ($oidcEnabled) {
    $serverCert = 'false' === strtolower($oidcConfig['server_cert'])
        ? 'false'
        : yamlSingleQuoted($oidcConfig['server_cert']);
    $providerUrl = yamlSingleQuoted($oidcConfig['provider_url']);
    $clientId = yamlSingleQuoted($oidcConfig['client_id']);
    $clientSecret = yamlSingleQuoted($oidcConfig['client_secret']);
    $sendOidcLogout = yamlBool($oidcConfig['send_oidc_logout']);
    $enableRefreshTokenUse = yamlBool($oidcConfig['enable_refresh_token_use']);
    $setGroupsFromAttributes = yamlBool($oidcConfig['set_groups_from_attributes']);
    $userGroups = oidcUserGroupsYaml($oidcConfig['user_groups'], 10);
    $scopes = yamlStringList($oidcConfig['scopes'], 10);
    $rolesSource = yamlSingleQuoted($oidcConfig['roles_source']);
    $rolesPath = yamlStringList($oidcConfig['roles_path'], 10);
    $userMatchingSource = yamlSingleQuoted($oidcConfig['user_matching_source']);
    $autoCreateAtomUser = yamlBool($oidcConfig['auto_create_atom_user']);
    $redirectUrl = yamlSingleQuoted($oidcConfig['redirect_url']);
    $logoutRedirectUrl = yamlSingleQuoted($oidcConfig['logout_redirect_url']);
    writeFile(
        ATOM_DIR.'/plugins/arOidcPlugin/config/app.yml',
        <<<YAML
all:
  oidc:
    providers:
      primary:
        url: {$providerUrl}
        client_id: {$clientId}
        client_secret: {$clientSecret}
        send_oidc_logout: {$sendOidcLogout}
        enable_refresh_token_use: {$enableRefreshTokenUse}
        server_cert: {$serverCert}
        set_groups_from_attributes: {$setGroupsFromAttributes}
        user_groups:
{$userGroups}
        scopes:
{$scopes}
        roles_source: {$rolesSource}
        roles_path:
{$rolesPath}
        user_matching_source: {$userMatchingSource}
        auto_create_atom_user: {$autoCreateAtomUser}
    primary_provider_name: primary
    redirect_url: {$redirectUrl}
    logout_redirect_url: {$logoutRedirectUrl}

YAML
    );
}

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
