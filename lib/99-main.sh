# omnish — backend dispatcher
# Chooses fzf or loop based on $OMNISH_BACKEND (resolved by entrypoint).
#
# [FIX 1] All error messages go to /dev/tty (stderr is redirected to
#         $TMP_OMNISH_DIR/debug.log by 00-config.sh — errors were invisible).
# [FIX 2] Prefixed error messages with "omnish:" for consistency with
#         the entrypoint and 70-* backends.
# [FIX 3] Clarified the "auto" comment: usually unreachable when called
#         from the standard entrypoint, but reachable when sourced
#         directly (tests, debugging).

main() {
    local backend="${OMNISH_BACKEND:-auto}"

    _ffm_err() {
        # Route a fatal error to the terminal, falling back to stderr
        # if /dev/tty is unavailable (CI, non-interactive shells).
        printf 'omnish: %s\n' "$1" >/dev/tty 2>/dev/null \
            || printf 'omnish: %s\n' "$1" >&2
    }

    case "$backend" in
        loop)
            if declare -F loop_main >/dev/null; then
                loop_main "$@"
            else
                _ffm_err "OMNISH_BACKEND=loop but loop_main is not defined (70-loop.sh missing?)"
                exit 1
            fi
            ;;
        fzf)
            if declare -F fzf_main >/dev/null; then
                fzf_main "$@"
            else
                _ffm_err "OMNISH_BACKEND=fzf but fzf_main is not defined (70-fzf.sh missing?)"
                exit 1
            fi
            ;;
        auto)
            # Usually unreachable: the entrypoint resolves auto → fzf|loop
            # before dispatching. This branch is a safety net for direct
            # calls (tests, debugging).
            if declare -F fzf_main >/dev/null; then
                fzf_main "$@"
            elif declare -F loop_main >/dev/null; then
                loop_main "$@"
            else
                _ffm_err "no backend available (neither fzf_main nor loop_main is defined)"
                exit 1
            fi
            ;;
        *)
            _ffm_err "unknown OMNISH_BACKEND='$backend' (expected: fzf|loop|auto)"
            exit 1
            ;;
    esac
}