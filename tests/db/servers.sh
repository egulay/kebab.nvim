#!/usr/bin/env bash
# The database code paths that would otherwise never be executed.
#
#   tests/db/servers.sh                 # everything it can check here
#   tests/db/servers.sh mysql h2        # just those
#   tests/db/servers.sh --list          # what it knows how to check
#   KEBAB_DB_KEEP=1 tests/db/servers.sh # leave the containers running
#
# Why this exists: SQLite covers the suite and PostgreSQL covers daily use, so
# everything else was *written* and never run. Two of the things this layer
# does are dialect-specific per driver (paging and EXPLAIN) and two more are
# driver-implementation-specific (DatabaseMetaData for the structure view, and
# multi-statement scripts), so "the code is there" says nothing at all. It was
# right not to trust it: the first run found the data source tree listing the
# server's own catalog on two drivers, and a structure panel that came back
# empty for a table name typed in the wrong case.
#
# Two kinds of target:
#
#   embedded   H2 and DuckDB are libraries, not servers -- a file and the jar
#              from Maven Central, nothing to start. Nearly free to check, so
#              there is no excuse for leaving them unexercised.
#   container  PostgreSQL, MySQL, MariaDB, SQL Server, Oracle.
#
# ClickHouse is here too, and it is the one that needs its expectations
# stated: it has no foreign keys, and its primary key is an ordering key that
# DatabaseMetaData does not report as one. Those three checks are skipped by
# name through $SKIP rather than quietly passing -- a check that cannot fail is
# worse than no check, and a blanket "if the driver says nothing, call it fine"
# would have hidden the empty structure panel on Oracle.
#
# It is not part of ./tests/run.sh: it pulls images and takes minutes. It is
# what gets run before claiming a driver works.
#
# Needs: docker (for the container targets), a JDK (the bridge is Java), curl
# (driver jars). Passwords are generated per run, passed to the containers and
# exported for the checks -- the connections file only ever holds the *name* of
# the variable, which is what the layer requires of a stored connection.
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
keep=${KEBAB_DB_KEEP:-0}
work=$(mktemp -d -t kebab-db-XXXXXX)

ALL="h2 duckdb sqlite postgres mysql mariadb sqlserver oracle clickhouse"

if [ "${1:-}" = "--list" ]; then
  printf '%s\n' $ALL
  exit 0
fi
want=${*:-$ALL}

pass=0
fail=0
say() { printf '\n== %s\n' "$1"; }
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       %s\n' "$1" "${2-}"; fail=$((fail + 1)); }
wanted() { case " $want " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

cleanup() {
  rm -rf "$work"
  if [ "$keep" != "1" ]; then
    docker rm -f kebab-mssql kebab-oracle kebab-mysql kebab-mariadb kebab-pg kebab-clickhouse >/dev/null 2>&1
  else
    printf '\ncontainers left running (KEBAB_DB_KEEP=1)\n'
  fi
}
trap cleanup EXIT

command -v java >/dev/null || { echo "a JDK is needed: the bridge is Java"; exit 1; }

# One password per server, generated per run and never written to a file.
rand_pw() { printf 'Kebab_%sAa1' "$(head -c9 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"; }
export KEBAB_TEST_MSSQL_PW="$(rand_pw)"
export KEBAB_TEST_ORACLE_PW="$(rand_pw)"
export KEBAB_TEST_MYSQL_PW="$(rand_pw)"
export KEBAB_TEST_MARIADB_PW="$(rand_pw)"
export KEBAB_TEST_PG_PW="$(rand_pw)"
export KEBAB_TEST_CLICKHOUSE_PW="$(rand_pw)"

# ---------------------------------------------------------------- the runner

# The checks themselves run inside Neovim, through this layer's own modules --
# not through a vendor client, because what is being tested is the layer.
run_checks() { # name url user password_env seed_sql
  local name=$1
  local url=$2
  local user=$3
  local pw_env=$4
  local seed=$5
  local store="$work/$name.json"
  local creds=""
  if [ -n "$user" ]; then
    creds=", \"user\": \"$user\", \"password_env\": \"$pw_env\""
  fi
  cat > "$store" <<JSON
{ "connections": [ { "name": "$name", "url": "$url"$creds } ] }
JSON
  chmod 600 "$store"
  printf '%s' "$seed" > "$work/$name.seed.sql"

  KEBAB_DB_STORE="$store" SEED="$work/$name.seed.sql" CONN="$name" SKIP="${SKIP:-}" \
    nvim -n --headless --cmd "set runtimepath+=$root" \
      -c "luafile $root/tests/db/checks.lua" -c "qa!" 2>&1 | sed 's/^/  /'
  # The Lua side exits non-zero through `cq` when one of its checks fails.
  if [ "${PIPESTATUS[0]}" -eq 0 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
}

# Wait for a line in a container's log. Fine for a server that prints one
# *once* -- and a trap for one that does not: both the MySQL and MariaDB images
# start a temporary server to initialise the data directory, so "ready for
# connections" appears, then the temporary server is stopped, and only then
# does the real one start. Connecting on the first match gets "unexpected end
# of stream, read 0 bytes (socket was closed by server)", which reads as a
# driver fault. Those two use wait_for_cmd with a client ping instead; MySQL
# only ever passed here because its temporary server runs with
# --skip-networking, so the port in the pattern happened to exclude it.
wait_for_log() { # container pattern seconds label
  local name=$1
  local pattern=$2
  local budget=$3
  printf '  waiting for %s' "${4:-$name}"
  local waited=0
  while [ "$waited" -lt "$budget" ]; do
    if docker logs "$name" 2>&1 | grep -q "$pattern"; then
      printf ' up\n'
      return 0
    fi
    printf '.'
    sleep 2
    waited=$((waited + 2))
  done
  printf ' timed out\n'
  return 1
}

# Start a container, or reuse the one already running.
#
# On reuse the password is read back out of the container rather than
# regenerated: each run makes a fresh random one, so a reused container would
# be asked for a password it has never heard of -- every check then fails as
# "connects: FAIL", which looks like a driver bug and is a harness bug. That
# happened; this is the fix.
#
# $1 container name, $2 the container's own password variable, $3 the
# KEBAB_TEST_* variable the checks read, then the docker arguments.
# Wait until a command succeeds, for a server that does not announce itself in
# its container log.
#
# ClickHouse is why: it logs to files *inside* the container
# (/var/log/clickhouse-server/), so `docker logs` carries the entrypoint's
# chatter and nothing about being ready -- a log-pattern wait can only ever
# time out. Its HTTP /ping is the documented check.
wait_for_cmd() { # label seconds command...
  local label=$1
  local budget=$2
  shift 2
  printf '  waiting for %s' "$label"
  local waited=0
  while [ "$waited" -lt "$budget" ]; do
    if "$@" >/dev/null 2>&1; then
      printf ' up\n'
      return 0
    fi
    printf '.'
    sleep 2
    waited=$((waited + 2))
  done
  printf ' timed out\n'
  return 1
}

container() { # name pw-var-in-container pw-var-for-checks docker-args...
  local name=$1
  local inside=$2
  local outside=$3
  shift 3
  command -v docker >/dev/null || { bad "$name needs docker" "docker is not on PATH"; return 1; }
  if docker inspect "$name" >/dev/null 2>&1; then
    local existing
    existing=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null \
      | sed -n "s/^${inside}=//p" | head -n 1)
    if [ -n "$existing" ]; then
      export "$outside=$existing"
      printf '  reusing the running %s (its own password)\n' "$name"
    else
      printf '  reusing the running %s\n' "$name"
    fi
    return 0
  fi
  docker run -d --name "$name" "$@" >/dev/null
}

# ------------------------------------------------------------------ embedded
#
# A library, not a server: the URL is a file path, the jar comes from Maven
# Central, and there is nothing to start or wait for.

if wanted h2; then
  say "H2 (embedded, no server)"
  run_checks h2 "jdbc:h2:$work/h2db;DB_CLOSE_DELAY=-1" "" "" \
    "create table kebab_items (id int auto_increment primary key, label varchar(50) not null, qty int);
     insert into kebab_items (label, qty) values ('alpha', 1), ('beta', 2), ('gamma', 3);
     create index ix_kebab_items_label on kebab_items (label);
     create table kebab_lines (id int auto_increment primary key, item_id int not null references kebab_items(id));"
fi

if wanted duckdb; then
  say "DuckDB (embedded, no server)"
  # No auto_increment: DuckDB wants a sequence, and an explicit id keeps the
  # fixture about the layer rather than about DDL.
  run_checks duckdb "jdbc:duckdb:$work/duck.db" "" "" \
    "create table kebab_items (id integer primary key, label varchar not null, qty integer);
     insert into kebab_items values (1, 'alpha', 1), (2, 'beta', 2), (3, 'gamma', 3);
     create index ix_kebab_items_label on kebab_items (label);
     create table kebab_lines (id integer primary key, item_id integer not null references kebab_items(id));"
fi

if wanted sqlite; then
  say "SQLite (embedded, no server)"
  run_checks sqlite "jdbc:sqlite:$work/shop.sqlite" "" "" \
    "create table kebab_items (id integer primary key autoincrement, label text not null, qty integer);
     insert into kebab_items (label, qty) values ('alpha', 1), ('beta', 2), ('gamma', 3);
     create index ix_kebab_items_label on kebab_items (label);
     create table kebab_lines (id integer primary key, item_id integer not null references kebab_items(id));"
fi

# ----------------------------------------------------------------- containers

if wanted postgres; then
  say "PostgreSQL"
  if container kebab-pg POSTGRES_PASSWORD KEBAB_TEST_PG_PW \
      -e "POSTGRES_PASSWORD=$KEBAB_TEST_PG_PW" -e POSTGRES_DB=kebabtest \
      -p 15432:5432 postgres:16 \
    && wait_for_log kebab-pg "database system is ready to accept connections" 60 PostgreSQL; then
    run_checks postgres "jdbc:postgresql://localhost:15432/kebabtest" "postgres" "KEBAB_TEST_PG_PW" \
      "create table kebab_items (id serial primary key, label text not null, qty int);
       insert into kebab_items (label, qty) values ('alpha', 1), ('beta', 2), ('gamma', 3);
       create index ix_kebab_items_label on kebab_items (label);
       create table kebab_lines (id serial primary key, item_id int not null references kebab_items(id));"
  else
    bad "PostgreSQL did not start" "see docker logs kebab-pg"
  fi
fi

if wanted mysql; then
  say "MySQL"
  # MySQL 8.0 reached end of life in April 2026 and 8.4 is the LTS, so that is
  # what gets checked. The entry stays because MariaDB shares its dialect
  # almost exactly -- if MySQL ever stops mattering, its registration becomes
  # an alias rather than a deletion.
  if container kebab-mysql MYSQL_ROOT_PASSWORD KEBAB_TEST_MYSQL_PW \
      -e "MYSQL_ROOT_PASSWORD=$KEBAB_TEST_MYSQL_PW" -e MYSQL_DATABASE=kebabtest \
      -p 13306:3306 mysql:8.4 \
    && wait_for_cmd MySQL 180 \
        docker exec kebab-mysql mysqladmin --protocol=TCP -h127.0.0.1 -uroot \
          "-p$KEBAB_TEST_MYSQL_PW" ping; then
    run_checks mysql "jdbc:mysql://localhost:13306/kebabtest" "root" "KEBAB_TEST_MYSQL_PW" \
      "create table kebab_items (id int auto_increment primary key, label varchar(50) not null, qty int);
       insert into kebab_items (label, qty) values ('alpha', 1), ('beta', 2), ('gamma', 3);
       create index ix_kebab_items_label on kebab_items (label);
       create table kebab_lines (id int auto_increment primary key, item_id int not null, constraint fk_kebab_lines foreign key (item_id) references kebab_items(id));"
  else
    bad "MySQL did not start" "see docker logs kebab-mysql"
  fi
fi

if wanted mariadb; then
  say "MariaDB"
  if container kebab-mariadb MARIADB_ROOT_PASSWORD KEBAB_TEST_MARIADB_PW \
      -e "MARIADB_ROOT_PASSWORD=$KEBAB_TEST_MARIADB_PW" -e MARIADB_DATABASE=kebabtest \
      -p 13307:3306 mariadb:11 \
    && wait_for_cmd MariaDB 180 \
        docker exec kebab-mariadb mariadb-admin --protocol=TCP -h127.0.0.1 -uroot \
          "-p$KEBAB_TEST_MARIADB_PW" ping; then
    run_checks mariadb "jdbc:mariadb://localhost:13307/kebabtest" "root" "KEBAB_TEST_MARIADB_PW" \
      "create table kebab_items (id int auto_increment primary key, label varchar(50) not null, qty int);
       insert into kebab_items (label, qty) values ('alpha', 1), ('beta', 2), ('gamma', 3);
       create index ix_kebab_items_label on kebab_items (label);
       create table kebab_lines (id int auto_increment primary key, item_id int not null, constraint fk_kebab_lines foreign key (item_id) references kebab_items(id));"
  else
    bad "MariaDB did not start" "see docker logs kebab-mariadb"
  fi
fi

if wanted sqlserver; then
  say "SQL Server"
  if container kebab-mssql MSSQL_SA_PASSWORD KEBAB_TEST_MSSQL_PW \
      -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=$KEBAB_TEST_MSSQL_PW" \
      -e MSSQL_PID=Developer -p 11433:1433 mcr.microsoft.com/mssql/server:2022-latest \
    && wait_for_log kebab-mssql "ready for client connections" 120 "SQL Server"; then
    run_checks sqlserver "jdbc:sqlserver://localhost:11433;databaseName=master;encrypt=false" \
      "sa" "KEBAB_TEST_MSSQL_PW" \
      "create table kebab_items (id int identity primary key, label nvarchar(50) not null, qty int);
       insert into kebab_items (label, qty) values ('alpha', 1), ('beta', 2), ('gamma', 3);
       create index ix_kebab_items_label on kebab_items (label);
       create table kebab_lines (id int identity primary key, item_id int not null references kebab_items(id));"
  else
    bad "SQL Server did not start" "see docker logs kebab-mssql"
  fi
fi

if wanted oracle; then
  say "Oracle"
  if container kebab-oracle APP_USER_PASSWORD KEBAB_TEST_ORACLE_PW \
      -e "ORACLE_PASSWORD=$KEBAB_TEST_ORACLE_PW" \
      -e APP_USER=kebab -e "APP_USER_PASSWORD=$KEBAB_TEST_ORACLE_PW" \
      -p 11521:1521 gvenzl/oracle-free:23-slim \
    && wait_for_log kebab-oracle "DATABASE IS READY TO USE" 300 "Oracle (the first start initialises the database)"; then
    run_checks oracle "jdbc:oracle:thin:@localhost:11521/FREEPDB1" "kebab" "KEBAB_TEST_ORACLE_PW" \
      "create table kebab_items (id number generated always as identity primary key, label varchar2(50) not null, qty number);
       insert into kebab_items (label, qty) values ('alpha', 1);
       insert into kebab_items (label, qty) values ('beta', 2);
       insert into kebab_items (label, qty) values ('gamma', 3);
       create index ix_kebab_items_label on kebab_items (label);
       create table kebab_lines (id number primary key, item_id number not null references kebab_items(id));"
  else
    bad "Oracle did not start" "see docker logs kebab-oracle"
  fi
fi

if wanted clickhouse; then
  say "ClickHouse"
  # MergeTree, and an ORDER BY in place of a primary key -- which the driver
  # *does* report as one, so that check is asserted like everywhere else. Two
  # do not apply: ClickHouse has no foreign keys, and its data skipping index
  # is not a SQL index -- the fixture declares one and getIndexInfo still
  # reports nothing, which is the driver telling the truth about a different
  # kind of object.
  if container kebab-clickhouse CLICKHOUSE_PASSWORD KEBAB_TEST_CLICKHOUSE_PW \
      -e "CLICKHOUSE_PASSWORD=$KEBAB_TEST_CLICKHOUSE_PW" -e CLICKHOUSE_DB=kebabtest \
      -e CLICKHOUSE_USER=kebab -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
      -p 18123:8123 clickhouse/clickhouse-server:latest \
    && wait_for_cmd ClickHouse 120 curl -fsS -m 3 "http://localhost:18123/ping"; then
    SKIP="index,referenced" \
    run_checks clickhouse "jdbc:clickhouse://localhost:18123/kebabtest?compress=0" "kebab" "KEBAB_TEST_CLICKHOUSE_PW" \
      "create table kebab_items (id UInt32, label String, qty Int32,
         index ix_kebab_items_label label type set(0) granularity 1) engine = MergeTree order by id;
       insert into kebab_items values (1, 'alpha', 1), (2, 'beta', 2), (3, 'gamma', 3);
       create table kebab_lines (id UInt32, item_id UInt32) engine = MergeTree order by id;"
  else
    bad "ClickHouse did not start" "see docker logs kebab-clickhouse"
  fi
fi

printf '\n%d of %d targets passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
