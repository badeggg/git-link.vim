function! GetPermalink(lnum_start, lnum_end)
    echo "Start Line: " . a:lnum_start
    echo "End Line:   " . a:lnum_end

    let l:commit_sha = trim(system('git rev-parse HEAD'))
    if empty(l:commit_sha)
        echoerr "Error: Not a git repository or no commit history."
        return
    endif

    let l:remote_url = trim(system('git config --get remote.origin.url'))
    if empty(l:remote_url)
        echoerr "Error: Git remote 'origin' not found."
        return
    endif

    if l:remote_url =~# '^git@'
        " SSH Format: git@github.com:owner/repo.name.git
        let l:parsed = matchlist(l:remote_url, '\v^git\@([^:]+):([^/]+)/(.+)\.git$')
    else
        " HTTPS Format: https://github.com/owner/repo.name.git or https://github.com/owner/repo.name
        " todo not handling trailing .git correctly
        let l:parsed = matchlist(l:remote_url, '\v^https?://([^/]+)/([^/]+)/(.+)\(.git\)\?$')
    endif
    if empty(l:parsed) || len(l:parsed) < 4
        echoerr "Error: Could not parse GitHub remote URL: " . l:remote_url
        return
    endif

    let l:host  = l:parsed[1] " e.g., github.com
    let l:owner = l:parsed[2] " e.g., yourname
    let l:repo  = l:parsed[3] " e.g., myproject

    let l:file_path = expand('%:p')
    let l:repo_root = trim(system('git rev-parse --show-toplevel 2>/dev/null'))
    echom 'file_path ' . l:file_path
    echom 'repo_root ' . l:repo_root
    let l:file_path = substitute(l:file_path, '^' . escape(l:repo_root, '\') . '/', '', '')
    echom 'file_path ' . l:file_path

    " Generate the GitHub permalink URL
    let l:link = printf('https://%s/%s/%s/blob/%s/%s#L%d-L%d',
        \ l:host,
        \ l:owner,
        \ l:repo,
        \ l:commit_sha,
        \ l:file_path,
        \ a:lnum_start,
        \ a:lnum_end
        \)

    " Copy the final link to the clipboard and display it
    call setreg('+', l:link)
    echo "Copied Permalink to clipboard: " . l:link


endfunction

command! -range Link call GetPermalink(<line1>, <line2>)
