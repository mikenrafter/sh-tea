# Runtime wraps from TEA_EXTRA_TOOLS — "name=path" pairs, comma or whitespace
# separated, where path is the real binary's outpath (e.g. a Nix store path,
# not an env-resolved path). vendor_conf.d is sourced by every fish session
# with sh-tea installed, but setup waits for the first fish_prompt event,
# which only fires in interactive shells: env-var wraps shadow tools only
# there. The build-time equivalent — wrapper binaries on PATH everywhere — is
# the flake's extraTools package override. Entries go through the same
# tea-wrap gate as built-in wraps: config.toml, --tea/--coffee,
# TEA_OFF/TEA_FORCE, agentic/interactive auto-detect.

function __tea_extra_tools_apply --description 'tea: (re)create TEA_EXTRA_TOOLS shadow functions'
    # Drop wraps from a previous pass so re-running tracks the variable
    # (call by hand after changing TEA_EXTRA_TOOLS mid-session).
    if set -q __tea_extra_tools_wrapped
        for name in $__tea_extra_tools_wrapped
            functions -e (string escape -- $name)
        end
    end
    set -g __tea_extra_tools_wrapped

    if not set -q TEA_EXTRA_TOOLS; or not command -q tea-wrap
        return
    end

    set -l flat (string replace -r '[\s,]+' ' ' -- (string trim -- $TEA_EXTRA_TOOLS))
    for pair in (string split ' ' -- $flat)
        # Split on the first '='; values themselves must not contain
        # whitespace or commas (Nix store paths never do).
        set -l name (string replace -r '=.*$' '' -- $pair)
        set -l real (string replace -r '^[^=]*=' '' -- $pair)
        if not string match -qr '^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$' -- $name
            continue
        end
        if test -z "$real"; or not test -x "$real"
            continue
        end
        set -a __tea_extra_tools_wrapped $name
        # Bake name/real into the body via eval — a plain `function $name`
        # body would resolve $name/$real at call time and come up empty.
        set -l fn (string escape -- $name)
        set -l bin (string escape -- $real)
        eval "function $fn --description 'tea (TEA_EXTRA_TOOLS): $name';
            set -lx TEA_EXTRA_TOOLS $fn=$bin; command tea-wrap $fn $bin \$argv; end"
    end
end

# First prompt only: conf.d and config.fish may still be about to set the
# variable. Non-interactive sessions never see fish_prompt, so they stay
# unwrapped; the set -lx inside each function keeps the wrap working even
# when the variable itself was never exported (set -U, plain set -g).
function __tea_extra_tools_init --on-event fish_prompt
    set -q __tea_extra_tools_done; and return
    set -g __tea_extra_tools_done 1
    __tea_extra_tools_apply
end
