" A vim-dadbod adapter that speaks JDBC.
"
" dadbod's own adapters shell out to a native client -- psql, mysql, sqlite3 --
" so a database whose client is not installed simply does not work. This one
" runs lua/kebab/jdbc.lua's JVM runner instead, with the driver downloaded from
" Maven Central, which is how a dedicated database IDE does it.
"
" Being a dadbod adapter rather than something standalone is the point: :DB,
" :DBUI and vim-dadbod-completion all keep working, over JDBC, unchanged.

" dadbod canonicalises most URLs; a JDBC URL is already in its own vendor's
" format and must be handed to the driver exactly as written.
function! db#adapter#jdbc#canonicalize(url) abort
  return a:url
endfunction

function! s:argv(url, mode) abort
  let result = luaeval('require("kebab.jdbc").vim_command(_A[1], _A[2])', [a:url, a:mode])
  if !get(result, 'ok', 0)
    throw 'DB exception: ' . get(result, 'err', 'could not prepare the JDBC runner')
  endif
  return result.argv
endfunction

" Reads SQL on stdin and prints an aligned result table.
function! db#adapter#jdbc#command(url) abort
  return s:argv(a:url, 'query')
endfunction

" There is no interactive JDBC shell here, so a 'connect' is a one-shot query
" session. Returning the same command keeps :DB <url> usable rather than
" failing with 'not supported'.
function! db#adapter#jdbc#interactive(url) abort
  return db#adapter#jdbc#command(a:url)
endfunction

function! db#adapter#jdbc#tables(url) abort
  return luaeval('require("kebab.jdbc").vim_tables(_A)', a:url)
endfunction

" Statements arrive without a trailing semicolon when sent from a buffer.
function! db#adapter#jdbc#massage(input) abort
  return substitute(a:input, ';\s*$', '', '')
endfunction
