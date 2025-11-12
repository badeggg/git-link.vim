function! s:IsRemoteHead(hash)
    let check_cmd = 'git branch -r --points-at ' . a:hash
    let output = trim(system(check_cmd))

    if v:shell_error
        " If the command failed, return empty string.
        return ''
    endif

    " Returns a string containing remote branch names separated by newlines
    " (e.g., "origin/main\nupstream/main"). Returns '' if none found.
    return output
endfunction

" Function to track back parent commits to find one recent remote hash.
" Handle merges as separate divisions.
" Returns: A Dictionary:
"          - {'success': 1, 'hash': 'COMMIT_HASH', 'remote': 'remote_name', 'branch': 'remote_branch_name'} on success.
"          - {'success': 0, 'err_msg': 'Error Message'} on failure.
function! s:FindOneRecentRemoteCommit()
    let s:max_depth = 20

    let current_hash = trim(system('git rev-parse HEAD'))
    if v:shell_error || empty(current_hash)
        return {'success': 0, 'err_msg': "Error: Not a git repository, or failed to resolve HEAD."}
    endif

    " Active paths to process. Each entry tracks:
    " {'hash': 'COMMIT_HASH', 'depth': 0}
    let paths_to_process = [{'hash': current_hash, 'depth': 0}]

    let found_hash = ''
    let found_remote_branches_str = '' " Stores the raw output from s:IsRemoteHead

    " Loop through active paths, stopping as soon as a successful result is found
    while !empty(paths_to_process)
        let current_path = remove(paths_to_process, 0)
        let hash = current_path.hash
        let depth = current_path.depth

        " Get the remote branch names pointing to the current hash
        let remote_branches = s:IsRemoteHead(hash)

        if !empty(remote_branches)
            let found_hash = hash
            let found_remote_branches_str = remote_branches
            break " Success: Terminate all searching immediately
        endif

        " Max Depth Reached (Path dead-end)
        if depth >= s:max_depth
            continue " Stop tracking this specific path
        endif

        " Get Parents of the current commit
        " %P returns parent hashes separated by space (e.g., "hashA hashB")
        let parents_string = trim(system('git log -1 --pretty=format:%P ' . hash))
        let parents = split(parents_string, '\s\+')

        " Reached the initial commit (no parents) (Path dead-end)
        if empty(parents_string)
            continue " Stop tracking this specific path
        endif

        " Enqueue New Divisions (Parents)
        for parent_hash in parents
            if empty(parent_hash) | continue | endif

            " Create a new division/path state
            let new_path = {
                \ 'hash': parent_hash,
                \ 'depth': depth + 1
                \ }

            call add(paths_to_process, new_path)
        endfor
    endwhile

    if empty(found_hash)
        return {'success': 0, 'err_msg': "Error: Search completed, but no remote branch head was found within the tracking limits."}
    else
        " Process the result: The output is a string of branch names separated by \n.
        " We take the first one found.
        let first_branch = split(found_remote_branches_str, '\n')[0]

        " Extract the remote name (e.g., 'origin') from the branch path (e.g., 'origin/main')
        let parts = split(first_branch, '/', 1) " Split only once
        let remote_name = len(parts) > 0 ? parts[0] : 'Unknown'

        return {
            \ 'success': 1,
            \ 'hash': found_hash,
            \ 'remote': remote_name,
            \ 'branch': first_branch
            \ }
    endif
endfunction

function! GetPermalink(lnum_start, lnum_end)
    let commit = s:FindOneRecentRemoteCommit()

    if !commit.success
        echoerr commit.err_msg
        return
    endif

    let l:remote_url = trim(system('git config --get remote.' . commit.remote . '.url'))
    if empty(l:remote_url)
        echoerr "Error: Git remote '" . commit.remote . "' not found."
        return
    endif

    if l:remote_url =~# '^git@'
        " SSH Format: git@github.com:owner/repo.name.git or git@github.com:owner/repo.name
        let l:parsed = matchlist(l:remote_url, '\v^git\@([^:]+):([^/]+)/(.{-})(\.git)?$')
    else
        " HTTPS Format: https://github.com/owner/repo.name.git or https://github.com/owner/repo.name
        let l:parsed = matchlist(l:remote_url, '\v^https?://([^/]+)/([^/]+)/(.{-})(\.git)?$')
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
    let l:file_path = substitute(l:file_path, '^' . escape(l:repo_root, '\') . '/', '', '')

    " Generate the GitHub permalink URL
    if a:lnum_start >= 1 && a:lnum_end >= 1
        let l:link = printf('https://%s/%s/%s/blob/%s/%s#L%d-L%d',
            \ l:host,
            \ l:owner,
            \ l:repo,
            \ l:commit.hash,
            \ l:file_path,
            \ a:lnum_start,
            \ a:lnum_end
            \)
    else
        let l:link = printf('https://%s/%s/%s/blob/%s/%s',
            \ l:host,
            \ l:owner,
            \ l:repo,
            \ l:commit.hash,
            \ l:file_path
            \)
    endif

    " Copy the final link to the clipboard and display it
    call setreg('+', l:link)
    echo "Copied Permalink to clipboard: " . l:link
endfunction

command! -range Link     call GetPermalink(<line1>, <line2>)
command! -range LinkFile call GetPermalink(0, 0)
