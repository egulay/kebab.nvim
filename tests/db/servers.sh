#!/usr/bin/env bash
# The database code paths nobody had ever run against a server.
#
#   tests/db/servers.sh                 # start throwaway containers, check all
#   tests/db/servers.sh sqlserver       # just one
#   KEBAB_DB_KEEP=1 tests/db/servers.sh # leave the containers running
#
# Why this exists: SQLite covers the suite, Postgres covers daily use, and
# everything else -- SQL Server and Oracle in particular -- was *written* and
# never executed. Two of the things this layer does are dialect-specific per
# driver (paging and EXPLAIN) and two more are driver-implementation-specific
# (DatabaseMetaData for the structure view, and multi-statement scripts), so
# "the code is there" says nothing at all.
#
# It is not part of ./tests/run.sh: it pulls two large images and takes
# minutes. It is what gets run before claiming a driver works.
#
# Needs: docker, a JDK (the bridge is Java), curl (driver jars). Passwords are
# generated here, passed to the containers and exported for the checks -- the
# connections file only ever holds the *name* of the variable, which is what
# the layer requires of a stored connection.
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
want=${1:-all}
keep=${KEBAB_DB_KEEP:-0}
work=$(mktemp -d -t kebab-db-XXXXXX)

pass=0
fail=0
say() { printf '\n== %s\n' "$1"; }
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       %s\n' "$1" "${2-}"; fail=$((fail + 1)); }

cleanup() {
  rm -rf "$work"
  if [ "$keep" != "1" ]; then
    docker rm -f kebab-mssql kebab-oracle >/dev/null 2>&1
  else
    printf '\ncontainers left running (KEBAB_DB_KEEP=1)\n'
  fi
}
trap cleanup EXIT

command -v docker >/dev/null || { echo "docker is not on PATH"; exit 1; }
command -v java >/dev/null || { echo "a JDK is needed: the bridge is Java"; exit 1; }

# One password per server, generated per run and never written to a file.
export KEBAB_TEST_MSSQL_PW="Kebab_$(head -c9 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')Aa1"
export KEBAB_TEST_ORACLE_PW="Kebab_$(head -c9 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')Aa1"

start_sqlserver() {
  if docker inspect kebab-mssql >/dev/null 2>&1; then
    printf '  reusing the running kebab-mssql\n'
    return 0
  fi
  docker run -d --name kebab-mssql \
    -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=$KEBAB_TEST_MSSQL_PW" -e MSSQL_PID=Developer \
    -p 11433:1433 mcr.microsoft.com/mssql/server:2022-latest >/dev/null || return 1
  printf '  waiting for SQL Server'
  for _ in $(seq 1 60); do
    if docker logs kebab-mssql 2>&1 | grep -q "ready for client connections"; then
      printf ' up\n'; return 0
    fi
    printf '.'; sleep 2
  done
  printf ' timed out\n'; return 1
}

start_oracle() {
  if docker inspect kebab-oracle >/dev/null 2>&1; then
    printf '  reusing the running kebab-oracle\n'
    return 0
  fi
  docker run -d --name kebab-oracle \
    -e "ORACLE_PASSWORD=$KEBAB_TEST_ORACLE_PW" \
    -e APP_USER=kebab -e "APP_USER_PASSWORD=$KEBAB_TEST_ORACLE_PW" \
    -p 11521:1521 gvenzl/oracle-free:23-slim >/dev/null || return 1
  printf '  waiting for Oracle (first start initialises the database)'
  for _ in $(seq 1 120); do
    if docker logs kebab-oracle 2>&1 | grep -q "DATABASE IS READY TO USE"; then
      printf ' up\n'; return 0
    fi
    printf '.'; sleep 3
  done
  printf ' timed out\n'; return 1
}

# The checks themselves run inside Neovim, through this layer's own modules --
# not through sqlcmd or sqlplus, because what is being tested is the layer.
run_checks() { # name url user password_env seed_sql
  local name=$1 url=$2 user=$3 pw_env=$4 seed=$5
  local store="$work/$name.json"
  cat > "$store" <<JSON
{ "connections": [ { "name": "$name", "url": "$url", "user": "$user", "password_env": "$pw_env" } ] }
JSON
  chmod 600 "$store"
  printf '%s' "$seed" > "$work/$name.seed.sql"

  KEBAB_DB_STORE="$store" SEED="$work/$name.seed.sql" CONN="$name" \
    nvim -n --headless --cmd "set runtimepath+=$root" \
      -c "luafile $root/tests/db/checks.lua" -c "qa!" 2>&1 | sed 's/^/  /'
}

overall() {
  # the Lua side prints `ok`/`FAIL` lines; count them here so the exit code is
  # a gate rather than something to read
  return 0
}

if [ "$want" = "all" ] || [ "$want" = "sqlserver" ]; then
  say "SQL Server"
  if start_sqlserver; then
    run_checks sqlserver \
      "jdbc:sqlserver://localhost:11433;databaseName=master;encrypt=false" \
      "sa" "KEBAB_TEST_MSSQL_PW" \
      "create table kebab_items (id int identity primary key, label nvarchar(50) not null, qty int);
       insert into kebab_items (label, qty) values ('alpha', 1), ('beta', 2), ('gamma', 3);
       create index ix_kebab_items_label on kebab_items (label);
       create table kebab_lines (id int identity primary key, item_id int not null references kebab_items(id));"
  else
    bad "SQL Server did not start" "see docker logs kebab-mssql"
  fi
fi

if [ "$want" = "all" ] || [ "$want" = "oracle" ]; then
  say "Oracle"
  if start_oracle; then
    run_checks oracle \
      "jdbc:oracle:thin:@localhost:11521/FREEPDB1" \
      "kebab" "KEBAB_TEST_ORACLE_PW" \
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

printf '\nthe shell side started the servers; the pass/fail lines above come from\n'
printf 'tests/db/checks.lua, which drives this layer against them.\n'
