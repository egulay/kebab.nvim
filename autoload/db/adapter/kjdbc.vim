" The vim-dadbod adapter that speaks JDBC.
"
" The scheme is `kjdbc:` followed by the real JDBC url --
" `kjdbc:jdbc:postgresql://host:5432/db` -- and not `jdbc:` itself, because
" dadbod does `substitute(url, '^jdbc:', '', '')` in its own resolver: it
" accepts JDBC-shaped urls for its *native* adapters. A `jdbc:postgresql://`
" url therefore reached db#adapter#postgresql and shelled out to psql, so :DB,
" <leader>S, dadbod-completion and the explorer tree never called this layer's
" runner at all. The explorer showed `Tables (0)` for a database with 48 of
" them, because dadbod could not connect and dadbod-ui's populate_tables bails
" out before asking the adapter.
"
" dadbod's own adapters all shell out to a native client -- psql, mysql,
" sqlite3 -- so a database whose client is not installed simply does not work.
" This one runs lua/kebab/jdbc.lua's JVM runner, with the driver downloaded
" from Maven Central, which is how a dedicated database IDE does it. Being a
" dadbod adapter rather than something standalone is the point: :DB, :DBUI and
" vim-dadbod-completion all keep working, over JDBC, unchanged.

" The JDBC url behind our own scheme.
function! s:jdbc(url) abort
  return luaeval('require("kebab.jdbc").plain_url(_A)', a:url)
endfunction

" dadbod canonicalises most urls; ours is already in its vendor's format and
" must reach the driver exactly as written.
function! db#adapter#kjdbc#canonicalize(url) abort
  return a:url
endfunction

function! s:argv(url, mode) abort
  let result = luaeval('require("kebab.jdbc").vim_command(_A[1], _A[2])', [s:jdbc(a:url), a:mode])
  if !get(result, 'ok', 0)
    throw 'DB exception: ' . get(result, 'err', 'could not prepare the JDBC runner')
  endif
  return result.argv
endfunction

" Reads SQL on stdin and prints an aligned result table.
function! db#adapter#kjdbc#command(url) abort
  return s:argv(a:url, 'query')
endfunction

" There is no interactive JDBC shell here, so a 'connect' is a one-shot query
" session. Returning the same command keeps :DB <url> usable rather than
" failing with 'not supported'.
function! db#adapter#kjdbc#interactive(url) abort
  return db#adapter#kjdbc#command(a:url)
endfunction

" dadbod proves a connection works before anything uses it: it runs the
" adapter's command with `auth_input` on stdin and treats a non-zero exit as
" "could not connect". For a client that reads SQL on stdin that probe is a
" query consisting of one newline, which this runner correctly refuses as not a
" statement -- so every connection failed its probe. v:false is dadbod's own
" opt-out, there for adapters that cannot be probed this way. The first real
" query is what finds out whether the credentials work, and it reports the
" reason properly.
function! db#adapter#kjdbc#auth_input() abort
  return v:false
endfunction

" The explorer's table list. A failure is raised, never returned as an empty
" list: "0 tables" for a database full of them, with the real reason only in a
" notification that scrolls away, is how this went unnoticed.
function! db#adapter#kjdbc#tables(url) abort
  let result = luaeval('require("kebab.jdbc").vim_tables(_A)', s:jdbc(a:url))
  if !get(result, 'ok', 0)
    throw 'DB exception: ' . get(result, 'err', 'could not list tables')
  endif
  return get(result, 'tables', [])
endfunction

" Statements arrive without a trailing semicolon when sent from a buffer.
function! db#adapter#kjdbc#massage(input) abort
  return substitute(a:input, ';\s*$', '', '')
endfunction
