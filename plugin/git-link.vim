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

" Parses the output of git diff -U0 into a list of hunk dictionaries.
function! s:ParseDiffHunks(lines)
    let hunks = []
    let hunk_header_pattern = '^@@\s-\(\d\+\)\(,\d\+\)\?\s+\(\d\+\)\(,\d\+\)\?\s@@'

    for line in a:lines
        let match = matchlist(line, hunk_header_pattern)
        if !empty(match)
            let old_s = str2nr(match[1]) " Old Start Line
            " Old Count: Defaults to 1 if not specified (match[2] is empty), otherwise removes the comma and converts.
            let old_c = empty(match[2]) ? 1 : str2nr(match[2][1:])

            let new_s = str2nr(match[3]) " New Start Line
            " New Count: Defaults to 1 if not specified (match[4] is empty), otherwise removes the comma and converts.
            let new_c = empty(match[4]) ? 1 : str2nr(match[4][1:])

            let hunk = {
                \ 'old_c': old_c,
                \ 'new_c': new_c,
                \ 'old_s': old_c == 0 ? old_s : old_s - 1,
                \ 'new_s': new_c == 0 ? new_s : new_s - 1,
                \ 'old_e': old_s + old_c - (old_c == 0 ? 0 : 1),
                \ 'new_e': new_s + new_c - (new_c == 0 ? 0 : 1)
                \ }
            call add(hunks, hunk)
        endif
    endfor

    return hunks
endfunction

" Finds where a new line number sits relative to the hunks.
" Returns a dict: {hunk1, hunk2, position: 'in-hunk' | 'between'}
function! s:FindHunkPosition(line_number_new, hunks)
    let prev_hunk = v:null

    for hunk in a:hunks
        " 1. Case: Before the very first hunk
        if v:null == prev_hunk && a:line_number_new <= hunk.new_s
            return {'hunk1': v:null, 'hunk2': hunk, 'position': 'between'}
        endif

        " 2. Case: In-Hunk (line number is within the changed block)
        if a:line_number_new > hunk.new_s && a:line_number_new <= hunk.new_e
            return {'hunk1': hunk, 'hunk2': v:null, 'position': 'in-hunk'}
        endif

        " 3. Case: Between hunks
        if v:null != prev_hunk && a:line_number_new > prev_hunk.new_e && a:line_number_new <= hunk.new_s
            return {'hunk1': prev_hunk, 'hunk2': hunk, 'position': 'between'}
        endif

        let prev_hunk = hunk
    endfor

    " 4. Case: After the very last hunk (or in an unchanged file)
    if v:null != prev_hunk && a:line_number_new > prev_hunk.new_e
        return {'hunk1': prev_hunk, 'hunk2': v:null, 'position': 'between'}
    endif

    " 5. Case: No hunks were parsed and line is valid (implies fully unchanged file)
    if empty(a:hunks)
         return {'hunk1': v:null, 'hunk2': v:null, 'position': 'between'}
    endif

    return {'hunk1': v:null, 'hunk2': v:null, 'position': 'unknown'}
endfunction

" Implements the line number translation based on the position dict.
" Arg type can be 'start' or 'end' to determine rectification logic.
function! s:RectifyLine(line_number_new, pos_dict, arg_type)
    let hunk1 = a:pos_dict.hunk1
    let hunk2 = a:pos_dict.hunk2

    if a:pos_dict.position == 'in-hunk'
        if a:arg_type == 'start'
            " Rectify start line to the start of the old hunk
            " '0.5' means there is not a corresponding old line number
            return hunk1.old_s + (hunk1.old_c == 0 ? 0.5 : 1)
        else
            " Rectify end line to the end of the old hunk
            " '0.5' means there is not a corresponding old line number
            return hunk1.old_e + (hunk1.old_c == 0 ? 0.5 : 0)
        endif

    elseif a:pos_dict.position == 'between'
        " Line is in an unchanged block. Translate using offset from nearest hunk.

        " Case 1: Line is after hunk1
        if v:null != hunk1
            let offset = a:line_number_new - hunk1.new_e
            return hunk1.old_e + offset

        " Case 2: Line is before hunk2
        elseif v:null != hunk2
            " The offset for the first hunk starts at line 1.
            return a:line_number_new

        " Case 3: Completely unchanged file (no hunks, hunk1/hunk2 are null)
        else
            return a:line_number_new
        endif

    else
        " Unknown or error position, return original line as a fallback
        return a:line_number_new
    endif
endfunction


" Purpose: Translates current working file (new) line numbers to commit (old) line numbers.
" Returns: A Dictionary:
"          - {'success': 1, 'start': old_start_line, 'end': old_end_line} on success.
"          - {'success': 0, 'error': 'Error Message'} on failure.
function! s:TranslateLinesNewToOld(commit_hash, file_path, start_line_new, end_line_new)
    if a:start_line_new <= 0 || a:end_line_new <= 0 || a:start_line_new > a:end_line_new
        return {'success': 0, 'error': "Invalid line number arguments provided."}
    endif

    " Check if the file exists in the old commit
    let existence_check_cmd = 'git cat-file -e ' . shellescape(a:commit_hash) . ':' . shellescape(a:file_path)
    let system_result = system(existence_check_cmd) " run to set v:shell_error
    if v:shell_error
        return {'success': 0, 'error': 'This is a new file.'}
    endif

    " Get the diff output with zero context
    let diff_command = 'git diff -U0 ' . shellescape(a:commit_hash) . ' -- :/' . shellescape(a:file_path)
    let diff_lines = split(system(diff_command), '\n')
    if v:shell_error
        return {'success': 0, 'error': "Git command failed while generating diff: " . diff_command}
    endif

    let hunks = s:ParseDiffHunks(diff_lines)

    " If there are no hunks (diff_lines was empty), the file is identical to the commit.
    if empty(hunks)
        return {'success': 1, 'start': a:start_line_new, 'end': a:end_line_new}
    endif

    " Find positions and translate start line
    let start_pos_dict = s:FindHunkPosition(a:start_line_new, hunks)
    let old_start_line = s:RectifyLine(a:start_line_new, start_pos_dict, 'start')

    " Find positions and translate end line
    let end_pos_dict = s:FindHunkPosition(a:end_line_new, hunks)
    let old_end_line = s:RectifyLine(a:end_line_new, end_pos_dict, 'end')

    if old_start_line == old_end_line && type(old_start_line) == v:t_float
        " no corresponding line
        let old_start_line = float2nr(old_start_line) == 0 ? 1 : float2nr(old_start_line)
        let old_end_line = old_start_line
    elseif old_start_line != old_end_line && type(old_start_line) == v:t_float && type(old_end_line) == v:t_float
        let old_start_line = float2nr(old_start_line) + 1
        let old_end_line = float2nr(old_end_line)
    elseif type(old_start_line) == v:t_float && type(old_end_line) != v:t_float
        let old_start_line = float2nr(old_start_line) + 1
    elseif type(old_start_line) != v:t_float && type(old_end_line) == v:t_float
        let old_end_line = float2nr(old_end_line)
    endif

    return {
        \ 'success': 1,
        \ 'start': old_start_line,
        \ 'end': old_end_line
        \ }
endfunction

function! GetPermalink(lnum_start, lnum_end)
    let commit = s:FindOneRecentRemoteCommit()

    if !commit.success
        echoerr commit.err_msg
        return
    endif

    let remote_url = trim(system('git config --get remote.' . commit.remote . '.url'))
    if empty(remote_url)
        echoerr "Error: Git remote '" . commit.remote . "' not found."
        return
    endif

    if remote_url =~# '^git@'
        " SSH Format: git@github.com:owner/repo.name.git or git@github.com:owner/repo.name
        let parsed = matchlist(remote_url, '\v^git\@([^:]+):([^/]+)/(.{-})(\.git)?$')
    else
        " HTTPS Format: https://github.com/owner/repo.name.git or https://github.com/owner/repo.name
        let parsed = matchlist(remote_url, '\v^https?://([^/]+)/([^/]+)/(.{-})(\.git)?$')
    endif
    if empty(parsed) || len(parsed) < 4
        echoerr "Error: Could not parse GitHub remote URL: " . remote_url
        return
    endif

    let host  = parsed[1] " e.g., github.com
    let owner = parsed[2] " e.g., yourname
    let repo  = parsed[3] " e.g., myproject

    let file_path = expand('%:p')
    let repo_root = trim(system('git rev-parse --show-toplevel 2>/dev/null'))
    let file_path = substitute(file_path, '^' . escape(repo_root, '\') . '/', '', '')

    " Generate the GitHub permalink URL
    if a:lnum_start >= 1 && a:lnum_end >= 1
        let translated = s:TranslateLinesNewToOld(commit.hash, file_path, a:lnum_start, a:lnum_end)
        if !translated.success
            echoerr "Error: " . translated.error
            return
        endif
        let link = printf('https://%s/%s/%s/blob/%s/%s#L%d-L%d',
            \ host,
            \ owner,
            \ repo,
            \ commit.hash,
            \ file_path,
            \ translated.start,
            \ translated.end
            \)
    else
        let link = printf('https://%s/%s/%s/blob/%s/%s',
            \ host,
            \ owner,
            \ repo,
            \ commit.hash,
            \ file_path
            \)
    endif

    " Copy the final link to the clipboard and display it
    call setreg('+', link)
    echo "Copied Permalink to clipboard: " . link
endfunction

command! -range Link     call GetPermalink(<line1>, <line2>)
command! -range LinkFile call GetPermalink(0, 0)
