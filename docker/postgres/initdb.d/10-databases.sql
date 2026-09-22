-- One Postgres server, one database per repository.
--
-- Every repository used to name its database `twin`, which was fine while each
-- ran a server of its own. On one shared server that is three repositories
-- sharing a schema: twin-backend's drizzle migrations and twin-engine's alembic
-- would both own `public`, and the first `alembic upgrade head` to meet a
-- drizzle table fails in a way that reads like a corrupt migration history.
--
-- So the name moved rather than the server. `twin_backend`, `twin_engine` and
-- `twin_memory` are the same schemas they always were, under names that can
-- coexist. Nothing else about any of them changed.
--
-- This runs **only on an empty data directory** - that is the postgres image's
-- rule for /docker-entrypoint-initdb.d, not ours. A server that already has a
-- volume never sees this file again, so adding a database here later needs the
-- `CREATE DATABASE` run by hand (or the volume dropped, which costs the data).
--
-- `\gexec` rather than a bare CREATE: Postgres has no `CREATE DATABASE IF NOT
-- EXISTS`, and this file should be safe to paste into psql against a live
-- server when that day comes.

\set ON_ERROR_STOP on

SELECT format('CREATE DATABASE %I OWNER %I', name, 'twin')
FROM (VALUES ('twin_backend'), ('twin_engine'), ('twin_memory')) AS wanted(name)
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = wanted.name);
\gexec

-- The `vector` extension is deliberately not created here. twin-memory's first
-- migration runs `CREATE EXTENSION IF NOT EXISTS vector` itself, and a schema
-- with two owners is the thing this file exists to prevent. twin-engine dropped
-- pgvector in its baseline migration and needs none.
