# Mark user-initiated pipeline stages for tea auto-activation.
# Installed to share/fish/vendor_conf.d when using the sh-tea package.
# Only set when the interactive command line contains a pipe — plain `echo hi`
# must not export TEA_USER_PIPE or Warp internal sed/tr/od inherit it.

function __tea_user_pipe_preexec --on-event fish_preexec --argument-names cmd
    if string match -q '*|*' -- $cmd
        set -gx TEA_USER_PIPE 1
    end
end

function __tea_user_pipe_postexec --on-event fish_postexec
    set -e TEA_USER_PIPE
end
