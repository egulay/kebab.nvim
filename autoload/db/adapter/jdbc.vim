" Kept only so a hand-written `jdbc:`-prefixed url, or a direct call to one of
" these functions, still reaches the JDBC runner. Nothing dadbod resolves ever
" arrives here: it strips the `jdbc:` prefix first and dispatches on what is
" left. db/adapter/kjdbc.vim is the real adapter and explains why.
function! db#adapter#jdbc#canonicalize(url) abort
  return luaeval('require("kebab.jdbc").dadbod_url(_A)', a:url)
endfunction

function! db#adapter#jdbc#command(url) abort
  return db#adapter#kjdbc#command(a:url)
endfunction

function! db#adapter#jdbc#interactive(url) abort
  return db#adapter#kjdbc#interactive(a:url)
endfunction

function! db#adapter#jdbc#auth_input() abort
  return db#adapter#kjdbc#auth_input()
endfunction

function! db#adapter#jdbc#tables(url) abort
  return db#adapter#kjdbc#tables(a:url)
endfunction

function! db#adapter#jdbc#massage(input) abort
  return db#adapter#kjdbc#massage(a:input)
endfunction
