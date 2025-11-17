##### Generates git permalink, no need to manually adjust line numbers before sharing!

### Commands
[:Link](https://github.com/badeggg/git-link.vim/blob/ac4aec9dc91bc46d1bffc4dcc8281110fb7e9201/plugin/git-link.vim#L332-L332)
    - Generate perm link of current line, if you are not visually selecting any line.
    - Generate perm link of selected lines, if you are visually selecting few lines.
[:LinkFile](https://github.com/badeggg/git-link.vim/blob/ac4aec9dc91bc46d1bffc4dcc8281110fb7e9201/plugin/git-link.vim#L332-L332)
    - Generate perm link of current file, no line is specified.

### Use which commit hash
This vim plugin will try to find a recent remote commit to use:
    - [This function](https://github.com/badeggg/git-link.vim/blob/ac4aec9dc91bc46d1bffc4dcc8281110fb7e9201/plugin/git-link.vim#L15-L97) track back parent commits to find one recent remote hash, from current HEAD
    - [Max depth is 20](https://github.com/badeggg/git-link.vim/blob/ac4aec9dc91bc46d1bffc4dcc8281110fb7e9201/plugin/git-link.vim#L21-L21)
    - Multi parents are taken care.

### Edge cases
There are few edge cases when translate current line number to remote commit line number.
- Start line of your selection is inside a block of new code(hunk), start line is translated to the start of old code of the hunk.
- End line of your selection is inside a block of new code(hunk), end line is translated to the end of old code of the hunk.
- Your selecting lines are all new lines, the line just at the top of the selection are used, if the line just
  at the top is line 0, line 1 is used.
- Current file is a new file, you will be prompted a message and no content will be sent to clipboard
