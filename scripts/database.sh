#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
: "${POSTGRES_ADMIN_USER:?Informe POSTGRES_ADMIN_USER}"
: "${POSTGRES_ADMIN_PASSWORD:?Informe POSTGRES_ADMIN_PASSWORD}"
: "${POSTGRES_DB:?Informe POSTGRES_DB}"
POSTGRES_APP_DB=${POSTGRES_APP_DB:-$POSTGRES_DB}
components=${NSS_DATABASE_COMPONENTS:-all}
export PGHOST=${POSTGRES_HOST:-db} PGPORT=${POSTGRES_PORT:-5432}
export PGUSER=$POSTGRES_ADMIN_USER PGPASSWORD=$POSTGRES_ADMIN_PASSWORD PGCONNECT_TIMEOUT=5

name() {
    case "$1" in
        ''|[0-9]*|*[!a-z0-9_]*) printf 'Identificador PostgreSQL inválido: %s\n' "$1" >&2; exit 2 ;;
    esac
    if [ "${#1}" -gt 63 ]; then
        printf 'Identificador PostgreSQL muito longo: %s\n' "$1" >&2
        exit 2
    fi
}

psql_db() {
    database=$1
    shift
    psql --no-psqlrc --set ON_ERROR_STOP=1 --dbname "$database" "$@"
}

validate_roles() {
    seen=" $POSTGRES_ADMIN_USER "
    for role in "$@"; do
        name "$role"
        case "$seen" in
            *" $role "*) printf 'Cada papel precisa ter uma identidade distinta: %s\n' "$role" >&2; exit 2 ;;
        esac
        seen="$seen$role "
    done
}

ensure_database() {
    psql_db postgres --set target_db="$1" <<'SQL'
SELECT format('CREATE DATABASE %I', :'target_db')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'target_db') \gexec
SQL
}

checksum_for() {
    sha256sum "$root/migrations/0001/$1.sql" | cut -d ' ' -f 1
}

check_new_database() {
    psql_db "$1" --set component="$2" --set checksum="$(checksum_for "$2")" <<'SQL'
SELECT to_regclass('nss_schema.version') IS NOT NULL AS history \gset
\if :history
SELECT EXISTS (SELECT FROM nss_schema.version WHERE component = :'component') AS applied,
       NOT EXISTS (SELECT FROM nss_schema.version WHERE component = :'component'
           AND (version <> '0001' OR checksum <> :'checksum')) AS compatible \gset
\else
\set applied false
\set compatible true
\endif
\if :compatible
\else
DO $$ BEGIN RAISE EXCEPTION 'Versão ou checksum da configuração do NSS diverge.'; END $$;
\endif
\if :applied
\else
SELECT CASE :'component'
    WHEN 'app' THEN to_regclass('public.users') IS NOT NULL
                  OR to_regclass('public.user_first_access') IS NOT NULL
                  OR to_regclass('public.flyway_schema_history') IS NOT NULL
    ELSE to_regnamespace('analytics') IS NOT NULL
         OR to_regnamespace('analytics_animal') IS NOT NULL
         OR to_regclass('public.alembic_version') IS NOT NULL
END AS legacy \gset
\if :legacy
DO $$ BEGIN RAISE EXCEPTION 'Banco legado detectado. Prepare um banco vazio ou ensaie a transferência em uma cópia.'; END $$;
\endif
\endif
SQL
}

role() {
    psql_db postgres --set role_name="$1" --set password_variable="$2" -f "$root/scripts/role.sql"
}

provision() {
    : "${ANALYTICS_READER_PASSWORD:?Informe ANALYTICS_READER_PASSWORD}"
    : "${ANALYTICS_WRITER_PASSWORD:?Informe ANALYTICS_WRITER_PASSWORD}"
    : "${ANALYTICS_MIGRATOR_PASSWORD:?Informe ANALYTICS_MIGRATOR_PASSWORD}"
    : "${GRAFANA_DB_PASSWORD:?Informe GRAFANA_DB_PASSWORD}"
    if [ "$components" = all ]; then
        : "${APP_RUNTIME_PASSWORD:?Informe APP_RUNTIME_PASSWORD}"
        : "${APP_MIGRATOR_PASSWORD:?Informe APP_MIGRATOR_PASSWORD}"
    fi
    ensure_database "$POSTGRES_DB"
    if [ "$components" = all ] && [ "$POSTGRES_APP_DB" != "$POSTGRES_DB" ]; then
        ensure_database "$POSTGRES_APP_DB"
    fi
    if [ "$components" = all ]; then check_new_database "$POSTGRES_APP_DB" app; fi
    check_new_database "$POSTGRES_DB" analytics
    if [ "$components" = all ]; then
        role "$APP_RUNTIME_USER" APP_RUNTIME_PASSWORD
        role "$APP_MIGRATOR_USER" APP_MIGRATOR_PASSWORD
    fi
    role "$ANALYTICS_READER_USER" ANALYTICS_READER_PASSWORD
    role "$ANALYTICS_WRITER_USER" ANALYTICS_WRITER_PASSWORD
    role "$ANALYTICS_MIGRATOR_USER" ANALYTICS_MIGRATOR_PASSWORD
    role "$GRAFANA_DB_USER" GRAFANA_DB_PASSWORD
}

apply_component() {
    target=$1
    component=$2
    migrator=$3
    migration="$root/migrations/0001/$component.sql"
    checksum=$(checksum_for "$component")
    psql_db "$target" --single-transaction \
        --set component="$component" --set target_db="$target" \
        --set version=0001 --set checksum="$checksum" --set migration_file="$migration" \
        --set migrator="$migrator" --set app_runtime="${APP_RUNTIME_USER:-unused}" \
        --set analytics_reader="$ANALYTICS_READER_USER" --set analytics_writer="$ANALYTICS_WRITER_USER" \
        --set grafana="$GRAFANA_DB_USER" -f "$root/scripts/apply.sql"
}

migrate() {
    if [ "$components" = all ]; then check_new_database "$POSTGRES_APP_DB" app; fi
    check_new_database "$POSTGRES_DB" analytics
    if [ "$components" = all ]; then
        apply_component "$POSTGRES_APP_DB" app "$APP_MIGRATOR_USER"
    fi
    apply_component "$POSTGRES_DB" analytics "$ANALYTICS_MIGRATOR_USER"
}

name "$POSTGRES_DB"
name "$POSTGRES_APP_DB"
: "${ANALYTICS_READER_USER:?Informe ANALYTICS_READER_USER}"
: "${ANALYTICS_WRITER_USER:?Informe ANALYTICS_WRITER_USER}"
: "${ANALYTICS_MIGRATOR_USER:?Informe ANALYTICS_MIGRATOR_USER}"
: "${GRAFANA_DB_USER:?Informe GRAFANA_DB_USER}"

case "$components" in
    all)
        : "${APP_RUNTIME_USER:?Informe APP_RUNTIME_USER}"
        : "${APP_MIGRATOR_USER:?Informe APP_MIGRATOR_USER}"
        validate_roles "$APP_RUNTIME_USER" "$APP_MIGRATOR_USER" \
            "$ANALYTICS_READER_USER" "$ANALYTICS_WRITER_USER" "$ANALYTICS_MIGRATOR_USER" "$GRAFANA_DB_USER"
        ;;
    analytics) validate_roles "$ANALYTICS_READER_USER" "$ANALYTICS_WRITER_USER" "$ANALYTICS_MIGRATOR_USER" "$GRAFANA_DB_USER" ;;
    *) printf 'Componente NSS inválido: %s\n' "$components" >&2; exit 2 ;;
esac

case "${1:-apply}" in
    provision) provision ;;
    migrate) migrate ;;
    apply) provision; migrate ;;
    *) printf 'Uso: database.sh [apply|provision|migrate]\n' >&2; exit 2 ;;
esac
