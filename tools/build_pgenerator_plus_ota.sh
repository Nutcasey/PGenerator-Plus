#!/usr/bin/env bash

# Build the cumulative OTA overlay described by README.md.
#
# The repository is the source of truth for this checkout: the archive contains
# the current etc/, usr/, var/, and lib/ trees, with transient operator state
# omitted.  The updater extracts this archive at filesystem root, so the paths
# in the tarball intentionally retain their FHS prefixes.

set -euo pipefail

# On macOS, stop bsdtar from embedding AppleDouble ._* metadata companions
# that a device would extract as junk files (harmless elsewhere).
export COPYFILE_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_ROOT/usr/share/PGenerator/version.pm"
FRAGMENT_CHECKER="$REPO_ROOT/t/check_webui_package.pl"

FORCE=0
KEEP_STAGING=0
OUTPUT=""
STAGING=""
ARCHIVE_CREATED=0

log() {
    printf '[build-ota] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./tools/build_pgenerator_plus_ota.sh [options]

Build a cumulative PGenerator+ OTA overlay from the current checkout.

Options:
  --output PATH   Output archive (default: build/pgenerator-plus-VERSION.tar.gz)
  --force         Replace an existing output archive
  --keep-staging  Keep the temporary staging tree and print its path
  -h, --help      Show this help
EOF
}

cleanup() {
    local rc=$?
    set +e
    if [[ "$KEEP_STAGING" -eq 0 && -n "$STAGING" && -d "$STAGING" ]]; then
        rm -rf -- "$STAGING"
    fi
    # Never leave an archive that failed validation on disk, ready to be
    # published by mistake.
    if [[ "$rc" -ne 0 && "$ARCHIVE_CREATED" -eq 1 && -e "$OUTPUT" ]]; then
        rm -f -- "$OUTPUT"
        printf 'ERROR: removed invalid archive: %s\n' "$OUTPUT" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT HUP INT TERM

require_commands() {
    local command_name
    for command_name in mktemp rsync tar sed perl; do
        command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
    done
}

version() {
    local value
    value="$(sed -n 's/^\$version="\([^"]*\)";$/\1/p' "$VERSION_FILE" | head -n 1)"
    [[ -n "$value" ]] || die "could not read version from $VERSION_FILE"
    printf '%s\n' "$value"
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --output)
                [[ "$#" -ge 2 ]] || die '--output requires a path'
                OUTPUT="$2"
                shift 2
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --keep-staging)
                KEEP_STAGING=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown option: $1"
                ;;
        esac
    done
}

prepare_output() {
    local current_version
    current_version="$(version)"
    if [[ -z "$OUTPUT" ]]; then
        OUTPUT="$REPO_ROOT/build/pgenerator-plus-${current_version}.tar.gz"
    elif [[ "$OUTPUT" != /* ]]; then
        OUTPUT="$REPO_ROOT/$OUTPUT"
    fi
    mkdir -p -- "$(dirname "$OUTPUT")"
    if [[ -e "$OUTPUT" && "$FORCE" -ne 1 ]]; then
        die "output already exists: $OUTPUT (use --force to replace it)"
    fi
}

stage_tree() {
    STAGING="$(mktemp -d "${TMPDIR:-/tmp}/pgenerator-ota-build.XXXXXX")"

    local root
    for root in etc usr lib; do
        [[ -d "$REPO_ROOT/$root" ]] || continue
        mkdir -p -- "$STAGING/$root"
        log "staging /$root"
        rsync -a --delete -- "$REPO_ROOT/$root/" "$STAGING/$root/"
    done

    # OTA tarballs ship factory defaults as PGenerator.conf.dist and must
    # never overwrite the device's live PGenerator.conf (operator state);
    # pgenerator-update merges new default keys from the .dist copy.
    if [[ -f "$STAGING/etc/PGenerator/PGenerator.conf" ]]; then
        log 'shipping etc/PGenerator/PGenerator.conf as PGenerator.conf.dist'
        mv -- "$STAGING/etc/PGenerator/PGenerator.conf" \
              "$STAGING/etc/PGenerator/PGenerator.conf.dist"
    fi

    if [[ -d "$REPO_ROOT/var" ]]; then
        mkdir -p -- "$STAGING/var"
        log 'staging /var without transient operator state'
        # Include rules keep the tracked placeholder files; `**` (not `***`)
        # keeps the directories themselves so devices always have them.
        rsync -a --delete \
            --exclude=/lib/PGenerator/operations.txt \
            --include=/lib/PGenerator/tmp/ \
            --include=/lib/PGenerator/tmp/PatternStart \
            --exclude=/lib/PGenerator/tmp/** \
            --include=/lib/PGenerator/running/ \
            --include=/lib/PGenerator/running/tmp/ \
            --include=/lib/PGenerator/running/tmp/.gitkeep \
            --exclude=/lib/PGenerator/running/** \
            --exclude=/lib/PGenerator/updates/** \
            --exclude=/lib/PGenerator/lg/pin-sessions/** \
            -- "$REPO_ROOT/var/" "$STAGING/var/"
    fi
}

build_archive() {
    local roots=()
    local root
    for root in etc usr var lib; do
        [[ -d "$STAGING/$root" ]] && roots+=("$root")
    done
    [[ "${#roots[@]}" -gt 0 ]] || die 'no FHS trees were found to package'

    rm -f -- "$OUTPUT"
    log "creating $OUTPUT"
    ARCHIVE_CREATED=1
    tar --uid 0 --gid 0 --numeric-owner -czf "$OUTPUT" -C "$STAGING" "${roots[@]}"
}

validate_archive() {
    [[ -s "$OUTPUT" ]] || die 'archive was not created'
    log 'checking Web UI fragment manifest'
    perl "$FRAGMENT_CHECKER" "$OUTPUT"
    log "archive size: $(wc -c < "$OUTPUT" | tr -d ' ') bytes"
}

main() {
    parse_args "$@"
    require_commands
    prepare_output
    stage_tree
    build_archive
    validate_archive
    if [[ "$KEEP_STAGING" -eq 1 ]]; then
        log "staging tree kept at $STAGING"
    fi
    log "build complete: $OUTPUT"
}

main "$@"
