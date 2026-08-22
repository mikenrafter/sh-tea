# Optional bash hook: export TEA_USER_PIPE=1 for user pipeline commands.
# Add to ~/.bashrc (not installed automatically — fish hook ships with the package).
#
# Requires bash 4.1+ (DEBUG trap). Only marks commands whose DEBUG string contains |.

_tea_user_pipe_pre() {
    case "${BASH_COMMAND-}" in
        *'|'*) export TEA_USER_PIPE=1 ;;
    esac
}

_tea_user_pipe_post() {
    unset TEA_USER_PIPE
}

trap '_tea_user_pipe_pre' DEBUG
trap '_tea_user_pipe_post' RETURN
