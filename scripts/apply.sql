SELECT pg_advisory_xact_lock(hashtext('nss-database:schema'));
CREATE SCHEMA IF NOT EXISTS nss_schema;
CREATE TABLE IF NOT EXISTS nss_schema.version (
    component TEXT PRIMARY KEY,
    version TEXT NOT NULL,
    checksum TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
SELECT EXISTS (SELECT FROM nss_schema.version WHERE component = :'component') AS applied,
       NOT EXISTS (
           SELECT FROM nss_schema.version WHERE component = :'component'
             AND (version <> :'version' OR checksum <> :'checksum')
       ) AS compatible,
       :'component' = 'app' AS application \gset
\if :compatible
\else
DO $$ BEGIN RAISE EXCEPTION 'Versão ou checksum da configuração do NSS diverge.'; END $$;
\endif

REVOKE CONNECT, TEMPORARY ON DATABASE :"target_db" FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE :"target_db" TO :"migrator";

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
DO $$ BEGIN RAISE EXCEPTION 'Banco legado detectado. A migração foi abortada.'; END $$;
\endif
\if :application
GRANT USAGE, CREATE ON SCHEMA public TO :"migrator";
\else
GRANT CREATE ON DATABASE :"target_db" TO :"migrator";
\endif
SET LOCAL ROLE :"migrator";
\i :migration_file
RESET ROLE;
\if :application
\else
REVOKE CREATE ON DATABASE :"target_db" FROM :"migrator";
\endif
INSERT INTO nss_schema.version (component, version, checksum)
VALUES (:'component', :'version', :'checksum');
\endif

\if :application
GRANT CONNECT ON DATABASE :"target_db" TO :"app_runtime";
REVOKE ALL ON public.users, public.user_first_access FROM :"analytics_reader", :"analytics_writer", :"grafana";
REVOKE ALL ON SEQUENCE public.users_id_seq, public.user_first_access_id_seq
    FROM :"analytics_reader", :"analytics_writer", :"grafana";
REVOKE CREATE ON SCHEMA public FROM :"app_runtime";
GRANT USAGE ON SCHEMA public TO :"app_runtime";
GRANT SELECT, INSERT, UPDATE, DELETE ON public.users, public.user_first_access TO :"app_runtime";
GRANT USAGE ON SEQUENCE public.users_id_seq, public.user_first_access_id_seq TO :"app_runtime";
\else
GRANT CONNECT ON DATABASE :"target_db" TO :"analytics_reader", :"analytics_writer", :"grafana";
REVOKE ALL ON SCHEMA analytics, analytics_animal FROM :"analytics_reader", :"analytics_writer", :"grafana";
REVOKE ALL ON ALL TABLES IN SCHEMA analytics, analytics_animal FROM :"analytics_reader", :"analytics_writer", :"grafana";
REVOKE ALL ON ALL SEQUENCES IN SCHEMA analytics, analytics_animal FROM :"analytics_reader", :"analytics_writer", :"grafana";
GRANT USAGE ON SCHEMA analytics TO :"analytics_reader", :"analytics_writer", :"grafana";
GRANT SELECT ON analytics.fato_casos, analytics.dim_doenca, analytics.pipeline_current_publication
    TO :"analytics_reader";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA analytics TO :"analytics_writer";
GRANT USAGE ON ALL SEQUENCES IN SCHEMA analytics TO :"analytics_writer";
GRANT USAGE ON SCHEMA analytics_animal TO :"analytics_writer";
GRANT SELECT, INSERT, UPDATE, DELETE ON analytics_animal.fato_esporo TO :"analytics_writer";
GRANT USAGE ON SEQUENCE analytics_animal.fato_esporo_id_seq TO :"analytics_writer";
GRANT SELECT ON analytics.pipeline_execution_metrics, analytics.pipeline_publications,
    analytics.pipeline_current_publication TO :"grafana";
\endif
