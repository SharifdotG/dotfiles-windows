-- Memory limits for the native PostgreSQL that nopCommerce uses, on both machines.
--
-- Apply once, with the service running, then restart it:
--     & "$env:ProgramFiles\PostgreSQL\18\bin\psql.exe" -U postgres -f config\shared\postgresql\tuning.sql
--     pgstop; pgstart
-- (or open this file in VS Code and run it with the PostgreSQL extension).
--
-- ALTER SYSTEM writes postgresql.auto.conf in the data directory, so the
-- installer's postgresql.conf stays untouched, and `ALTER SYSTEM RESET ALL;`
-- followed by a restart undoes every line below.
--
-- These are the values the Linux setup ran nopCommerce's Postgres container
-- with. PostgreSQL memory multiplies: work_mem applies per sort or hash step,
-- per query, per connection, and autovacuum can take maintenance_work_mem once
-- per worker. No single setting bounds the total, so each one is kept small and
-- connections are capped.

-- NB: the listening port is NOT set here. ALTER SYSTEM needs a connection, and
-- there is no connection until the server can bind a port - so `port` lives in
-- postgresql.conf. It is 5434 on both machines, because the tryton and
-- structflow containers publish 5432 and 5433 (docs\SETUP.md, PostgreSQL).
ALTER SYSTEM SET shared_buffers = '256MB';        -- default 128MB; restart needed
ALTER SYSTEM SET work_mem = '8MB';                -- default 4MB
ALTER SYSTEM SET maintenance_work_mem = '64MB';   -- the default, pinned
ALTER SYSTEM SET autovacuum_work_mem = '32MB';    -- default: maintenance_work_mem per worker
-- One nopCommerce instance plus an editor needs far fewer than the default 100.
-- If you ever see "sorry, too many clients already", raise this first.
ALTER SYSTEM SET max_connections = 50;            -- restart needed
