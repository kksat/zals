" Collection YAML, including role defaults and vars, needs zals attached.
" Source this from init.vim/init.lua or copy it into your ftdetect directory.
" Autocmd patterns containing a slash match the full absolute path.
augroup zals_collection_filetypes
  autocmd!
  autocmd BufRead,BufNewFile */ansible_collections/**/*.yml,*/ansible_collections/**/*.yaml set filetype=yaml.ansible
augroup END
