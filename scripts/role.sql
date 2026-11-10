\getenv role_password :password_variable
BEGIN;
SELECT pg_advisory_xact_lock(hashtext('nss-database:roles'));
SELECT NOT EXISTS (
    SELECT FROM pg_roles WHERE rolname = :'role_name'
      AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
) AND NOT EXISTS (
    SELECT FROM pg_auth_members WHERE member = (SELECT oid FROM pg_roles WHERE rolname = :'role_name')
) AS safe_role \gset
\if :safe_role
SELECT format('CREATE ROLE %I LOGIN NOINHERIT', :'role_name')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role_name') \gexec
SELECT format('ALTER ROLE %I LOGIN NOINHERIT PASSWORD %L', :'role_name', :'role_password') \gexec
\else
DO $$ BEGIN RAISE EXCEPTION 'Papel existente possui privilégios incompatíveis com NSS.'; END $$;
\endif
COMMIT;
