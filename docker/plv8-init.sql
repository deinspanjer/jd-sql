-- Initialize plv8 for development containers
-- This script runs automatically on first cluster init
-- It enables the extension in the default database (postgres) and template1

\connect postgres
CREATE EXTENSION IF NOT EXISTS plv8;

\connect template1
CREATE EXTENSION IF NOT EXISTS plv8;
