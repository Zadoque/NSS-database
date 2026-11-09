#!/bin/sh
set -eu

image=${NSS_DATABASE_IMAGE:-nss-database:0001}
pg_image=${POSTGRES_TEST_IMAGE:-postgres:16-alpine}
name="nss-schema-smoke-$$"
tmp=$(mktemp -d)
trap 'docker rm -f -v "$name" >/dev/null 2>&1 || true; docker network rm "$name" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
cat > "$tmp/roles.env" <<'ENV'
POSTGRES_ADMIN_USER=smoke_admin
POSTGRES_ADMIN_PASSWORD=local-admin-password
POSTGRES_HOST=postgres
APP_RUNTIME_USER=smoke_app
APP_RUNTIME_PASSWORD=local-app-password
APP_MIGRATOR_USER=smoke_app_migrator
APP_MIGRATOR_PASSWORD=local-app-migrator-password
ANALYTICS_READER_USER=smoke_reader
ANALYTICS_READER_PASSWORD=local-reader-password
ANALYTICS_WRITER_USER=smoke_writer
ANALYTICS_WRITER_PASSWORD=local-writer-password
ANALYTICS_MIGRATOR_USER=smoke_analytics_migrator
ANALYTICS_MIGRATOR_PASSWORD=local-analytics-migrator-password
GRAFANA_DB_USER=smoke_grafana
GRAFANA_DB_PASSWORD=local-grafana-password
ENV

docker network create "$name" >/dev/null
docker run --detach --name "$name" --network "$name" --network-alias postgres \
    -e POSTGRES_USER=smoke_admin -e POSTGRES_PASSWORD=local-admin-password "$pg_image" >/dev/null
attempt=0
until docker exec "$name" pg_isready -h 127.0.0.1 -U smoke_admin -d postgres >/dev/null; do
    attempt=$((attempt+1))
    test "$attempt" -lt 30
    sleep 1
done

sql() { docker exec -i "$name" psql -X -v ON_ERROR_STOP=1 -qAt -U smoke_admin -d "$@"; }
migrate() {
    docker run --rm --network "$name" --env-file "$tmp/roles.env" \
        -e POSTGRES_DB="$1" -e POSTGRES_APP_DB="$2" "$image" "${3:-apply}"
}

migrate nss_combined nss_combined
before=$(sql nss_combined -c "SELECT string_agg(component||':'||version||':'||checksum||':'||applied_at, ',' ORDER BY component) FROM nss_schema.version")
migrate nss_combined nss_combined
after=$(sql nss_combined -c "SELECT string_agg(component||':'||version||':'||checksum||':'||applied_at, ',' ORDER BY component) FROM nss_schema.version")
test "$before" = "$after"

migrate nss_analytics nss_app provision
migrate nss_analytics nss_app migrate
test "$(sql nss_app -c "SELECT component||':'||version FROM nss_schema.version")" = 'app:0001'
test "$(sql nss_analytics -c "SELECT component||':'||version FROM nss_schema.version")" = 'analytics:0001'
test "$(sql nss_analytics -c "SELECT to_regclass('public.users') IS NULL AND NOT has_database_privilege('smoke_app', 'nss_analytics', 'CONNECT')")" = t
test "$(sql nss_app -c "SELECT to_regnamespace('analytics') IS NULL AND NOT has_database_privilege('smoke_writer', 'nss_app', 'CONNECT')")" = t

sql nss_combined <<'SQL'
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM nss_schema.version) = 2;
  ASSERT to_regclass('public.refresh_sessions') IS NULL;
  ASSERT (SELECT count(*) FROM pg_tables WHERE schemaname = 'analytics') = 10;
  ASSERT EXISTS (SELECT FROM analytics.dim_unidade_saude WHERE cd_unidade='0000000');
  ASSERT EXISTS (SELECT FROM analytics.dim_classificacao WHERE codigo='NI');
  ASSERT EXISTS (SELECT FROM analytics.dim_evolucao WHERE codigo='NI');
  ASSERT pg_get_indexdef('analytics.idx_fato_casos_territorio_recorte'::regclass)
      LIKE '%notification_district_id, cd_sexo, batch_id)%';
  ASSERT NOT has_schema_privilege('smoke_app', 'public', 'CREATE');
  ASSERT NOT has_table_privilege('smoke_app', 'analytics.fato_casos', 'SELECT');
  ASSERT has_table_privilege('smoke_reader', 'analytics.fato_casos', 'SELECT');
  ASSERT NOT has_table_privilege('smoke_reader', 'analytics.fato_casos', 'INSERT');
  ASSERT has_table_privilege('smoke_grafana', 'analytics.pipeline_execution_metrics', 'SELECT');
  ASSERT has_table_privilege('smoke_grafana', 'analytics.pipeline_publications', 'SELECT');
  ASSERT has_table_privilege('smoke_grafana', 'analytics.pipeline_current_publication', 'SELECT');
  ASSERT NOT has_table_privilege('smoke_grafana', 'analytics.fato_casos', 'SELECT');
  ASSERT NOT has_table_privilege('smoke_grafana', 'analytics.pipeline_publications', 'UPDATE');
  ASSERT NOT has_schema_privilege('smoke_writer', 'analytics', 'CREATE');
  ASSERT NOT has_schema_privilege('smoke_writer', 'public', 'CREATE');
  ASSERT NOT has_database_privilege('smoke_writer', 'nss_combined', 'CREATE');
  ASSERT (SELECT tableowner FROM pg_tables WHERE schemaname='analytics' AND tablename='fato_casos')
      = 'smoke_analytics_migrator';
  ASSERT (SELECT tableowner FROM pg_tables WHERE schemaname='public' AND tablename='users')
      = 'smoke_app_migrator';
END $$;

SET ROLE smoke_app;
INSERT INTO public.users (email) VALUES ('smoke@example.invalid');
RESET ROLE;
SET ROLE smoke_writer;
INSERT INTO analytics_animal.fato_esporo (data_notificacao, especie, sexo_animal, idade_animal, castrado)
VALUES (timestamp '2026-01-01', 'Felino', 'F', '2 anos', 'Sim');
INSERT INTO analytics.dim_doenca VALUES ('DENG', 'Dengue');
INSERT INTO analytics.dim_municipio VALUES ('3304557', 'Rio de Janeiro', '33', 'Rio de Janeiro');
INSERT INTO analytics.fato_casos (disease_codigo, ano, mes, cd_mun, cases_total, batch_id)
VALUES ('DENG', 2024, 1, '3304557', 1, 'teste-a'), ('DENG', 2024, 1, '3304557', 2, 'teste-b');
INSERT INTO analytics.pipeline_current_publication (disease_codigo, ano, cd_mun, batch_id, source_extracted_timestamp)
VALUES ('DENG', 2024, '3304557', 'teste-b', now());
RESET ROLE;
SET ROLE smoke_reader;
DO $$ BEGIN
  ASSERT (SELECT sum(f.cases_total) FROM analytics.fato_casos f
          JOIN analytics.pipeline_current_publication p USING (disease_codigo, ano, cd_mun, batch_id)) = 2;
END $$;
RESET ROLE;
SQL

printf '\n-- checksum alterado\n' > "$tmp/modified.sql"
if docker run --rm --network "$name" --env-file "$tmp/roles.env" \
    -e POSTGRES_DB=nss_combined -v "$tmp/modified.sql:/opt/nss-database/migrations/0001/app.sql:ro" \
    "$image" migrate > "$tmp/checksum.log" 2>&1; then
    printf 'Migração aceitou checksum divergente\n' >&2
    exit 1
fi
grep -q 'checksum da configuração' "$tmp/checksum.log"

sql postgres -c 'CREATE DATABASE nss_legacy'
sql nss_legacy -c 'CREATE TABLE public.users (id integer)'
if migrate nss_legacy nss_legacy > "$tmp/legacy.log" 2>&1; then
    printf 'Migração aceitou banco legado\n' >&2
    exit 1
fi
grep -q 'Banco legado detectado' "$tmp/legacy.log"
# Um componente já registrado não deve ocultar objetos legados do outro componente.
sql nss_app -c 'CREATE SCHEMA analytics; CREATE TABLE analytics.fato_casos (id integer)'
if migrate nss_app nss_app migrate > "$tmp/mixed-legacy.log" 2>&1; then
    printf 'Migração aceitou analytics legado em banco com app registrado\n' >&2
    exit 1
fi
grep -q 'Banco legado detectado' "$tmp/mixed-legacy.log"
test "$(sql nss_app -c "SELECT count(*) FROM nss_schema.version WHERE component = 'analytics'")" = 0
printf 'Schema 0001: alvos juntos e separados, grants, reexecução e proteção de versão conferidos.\n'
