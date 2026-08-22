# Tea-aware grep for vendor_functions.d — autoloads before fish's embedded
# grep.fish. Uses `command grep` (PATH) so the sh-tea wrapper runs, while
# keeping fish's default --color=auto when supported.

if echo | command grep --color=auto "" >/dev/null 2>&1
    function grep
        command grep --color=auto $argv
    end
end
