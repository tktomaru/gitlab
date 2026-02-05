-- GitLab CE requires these PostgreSQL extensions
-- This file is used by the postgresql container on first startup

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS plpgsql;
