CREATE SCHEMA IF NOT EXISTS shop;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE DOMAIN shop.positive_int AS integer CHECK (VALUE > 0);
CREATE TYPE shop.mood AS ENUM ('sad', 'ok', 'happy');
CREATE TYPE shop.pair AS (a integer, b text);
CREATE TYPE shop.myrange AS RANGE (subtype = float8);
CREATE SEQUENCE shop.order_seq START 100 INCREMENT 5 CACHE 10;
CREATE TABLE shop.customers (
  id serial PRIMARY KEY,
  name text NOT NULL,
  email varchar(120) UNIQUE,
  mood shop.mood DEFAULT 'ok',
  age shop.positive_int,
  created timestamptz DEFAULT now(),
  CONSTRAINT age_ok CHECK (age < 150)
);
COMMENT ON TABLE shop.customers IS 'Customer table';
COMMENT ON COLUMN shop.customers.name IS 'Full name';
CREATE TABLE shop.orders (
  id bigint PRIMARY KEY DEFAULT nextval('shop.order_seq'),
  customer_id integer NOT NULL REFERENCES shop.customers(id) ON DELETE CASCADE,
  total numeric(12,2) NOT NULL DEFAULT 0,
  note text,
  EXCLUDE USING btree (id WITH =)
);
CREATE INDEX orders_customer_idx ON shop.orders (customer_id) WHERE total > 0;
CREATE INDEX customers_name_trgm ON shop.customers USING gin (name gin_trgm_ops);
CREATE TABLE shop.events (id int, at date NOT NULL, payload jsonb) PARTITION BY RANGE (at);
CREATE TABLE shop.events_2026 PARTITION OF shop.events FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE shop.audit (LIKE shop.customers) INHERITS (shop.orders);
CREATE VIEW shop.big_orders AS SELECT * FROM shop.orders WHERE total > 1000;
CREATE MATERIALIZED VIEW shop.order_totals AS SELECT customer_id, sum(total) s FROM shop.orders GROUP BY 1;
CREATE FUNCTION shop.add(a integer, b integer) RETURNS integer LANGUAGE sql IMMUTABLE AS $$ SELECT a + b $$;
CREATE FUNCTION shop.trg_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
CREATE PROCEDURE shop.do_nothing(x int) LANGUAGE plpgsql AS $$ BEGIN END $$;
CREATE TRIGGER orders_trg BEFORE INSERT ON shop.orders FOR EACH ROW EXECUTE FUNCTION shop.trg_fn();
CREATE RULE orders_rule AS ON UPDATE TO shop.orders DO INSTEAD NOTHING;
CREATE POLICY orders_pol ON shop.orders USING (true);
CREATE AGGREGATE shop.mysum(integer) (sfunc = int4pl, stype = integer, initcond = '0');
CREATE COLLATION shop.mycoll (provider = libc, locale = 'C');
CREATE OPERATOR shop.=== (leftarg = integer, rightarg = integer, function = int4eq);
CREATE TEXT SEARCH CONFIGURATION shop.mycfg (COPY = english);
CREATE TEXT SEARCH DICTIONARY shop.mydict (TEMPLATE = simple);
CREATE FOREIGN DATA WRAPPER myfdw;
CREATE SERVER myserver FOREIGN DATA WRAPPER myfdw;
CREATE FOREIGN TABLE shop.ft (id int) SERVER myserver;
CREATE PUBLICATION mypub FOR TABLE shop.customers;
CREATE CAST (shop.pair AS text) WITH INOUT;
GRANT SELECT ON shop.customers TO app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA shop GRANT SELECT ON TABLES TO app_group;
COMMENT ON SCHEMA shop IS 'Shop schema';
CREATE TEXT SEARCH PARSER shop.myparser (START = prsd_start, GETTOKEN = prsd_nexttoken, END = prsd_end, LEXTYPES = prsd_lextype, HEADLINE = prsd_headline);
CREATE TEXT SEARCH TEMPLATE shop.mytmpl (LEXIZE = dsimple_lexize);
CREATE TEXT SEARCH DICTIONARY shop.mydict2 (TEMPLATE = snowball, language = 'english');
CREATE FUNCTION shop.evt_fn() RETURNS event_trigger LANGUAGE plpgsql AS $$ BEGIN END $$;
CREATE EVENT TRIGGER evt ON ddl_command_start EXECUTE FUNCTION shop.evt_fn();
