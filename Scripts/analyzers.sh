#!/bin/sh
# Static analyzers for AemiJSON: deadwood (unused code), dolly (duplicated code) and arcleak (retain
# cycles and leaks), all from github.com/g-cqd, all syntax-level so they need no build.
#
#   Scripts/analyzers.sh            install the pinned releases if absent, then run all three
#   Scripts/analyzers.sh install    install only
#
# Each tool is pinned to a release and to the SHA-256 of its archive for each platform, checked
# before anything is executed. Baseline fingerprints move between versions, so an unpinned tool would make a
# gate go red for no change of ours. To upgrade: change VERSION and SHA together, run, and read the diff of
# findings before committing.
#
# Exit: 0 clean, 1 a tool found something, 2 a tool could not be installed or run.
set -eu

# Archive hashes per platform: the macOS arm64 archive is what a developer machine runs, the Linux x86_64 one
# is what CI runs (a hosted Linux runner costs a tenth of a macOS one, and the analyzers read source).
VERSION_DEADWOOD=0.10.1
SHA_DEADWOOD_MACOS=7f50297615ab85f9d73bef131ebca81f0fe4e70e46235dd315615e86bd5b34fc
SHA_DEADWOOD_LINUX=77f9cfae91bf7a56ebebf9a5a3eed51ab88864d33f4a76a967b664613139ba02
VERSION_DOLLY=0.10.2
SHA_DOLLY_MACOS=56b3885f71a68b79e0ff231ae861104d111b7b72aee5206ffff76631a7f471a4
SHA_DOLLY_LINUX=0b10c705fe602cfe7513c417956eee066340ec389ef7251ec9d44b7cf432c98d
VERSION_ARCLEAK=0.10.2
SHA_ARCLEAK_MACOS=42f23953dd1d270d06ac4c36ec204d6aebc598906ca9ba082f83f84bd90e21f8
SHA_ARCLEAK_LINUX=add97ed80a6c7f93765cd8360b5ef91a8b8ba77d60130ae73c3f2143ecd13392

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) PLATFORM=macos-arm64 SHA_SUFFIX=MACOS CACHE_ROOT="$HOME/Library/Caches" ;;
    Linux-x86_64) PLATFORM=linux-x86_64 SHA_SUFFIX=LINUX CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}" ;;
    *) printf '[FAIL] only macOS arm64 and Linux x86_64 archives are pinned here\n' >&2; exit 2 ;;
esac

# Outside the repository, so a verification worktree reuses the download instead of repeating it.
CACHE="${AEMIJSON_ANALYZERS_DIR:-$CACHE_ROOT/aemijson/analyzers}"

# What each tool analyzes. Benchmarks/ is left out: the Benchmark plugin finds a global named `benchmarks` by
# name, which no syntax-level analyzer can see, so every benchmark looks like dead code.
# The corpus is otherwise the whole package: reachability and clone detection are
# whole-program, and a smaller corpus makes live code look dead.
CORPUS="Sources Tests"

fail() { printf '[FAIL] %s\n' "$1" >&2; exit "${2:-1}"; }

install_tool() {
    tool=$1 version=$2
    upper=$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')
    sha=$(eval "printf '%s' \"\$SHA_${upper}_${SHA_SUFFIX}\"")
    dir="$CACHE/$tool-$version"
    [ -x "$dir/$tool" ] && return 0
    name="$tool-$version-$PLATFORM"
    scratch=$(mktemp -d)
    trap 'rm -rf "$scratch"' EXIT
    printf '==> installing %s %s (%s)\n' "$tool" "$version" "$PLATFORM"
    curl -fsSL --retry 3 -o "$scratch/$name.tar.gz" \
        "https://github.com/g-cqd/$tool/releases/download/v$version/$name.tar.gz" \
        || fail "$tool: download failed" 2
    if command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$scratch/$name.tar.gz" | cut -d' ' -f1)
    else
        actual=$(sha256sum "$scratch/$name.tar.gz" | cut -d' ' -f1)
    fi
    [ "$actual" = "$sha" ] || fail "$tool: archive hash $actual is not the pinned $sha" 2
    tar -xzf "$scratch/$name.tar.gz" -C "$scratch"
    mkdir -p "$dir"
    # The whole directory: the Linux archive carries the Swift runtime libraries beside the binary.
    cp -R "$scratch/$name/." "$dir/"
    reported=$("$dir/$tool" --version 2>/dev/null || true)
    [ "$reported" = "$version" ] || { rm -rf "$dir"; fail "$tool reports '$reported', not $version" 2; }
}

install_tool deadwood "$VERSION_DEADWOOD"
install_tool dolly "$VERSION_DOLLY"
install_tool arcleak "$VERSION_ARCLEAK"
[ "${1:-}" = "install" ] && exit 0

run() {
    tool=$1 version=$2
    printf '==> %s %s\n' "$tool" "$version"
    # A committed baseline holds the duplication that predates the gate; only a finding it does not hold
    # fails. Fingerprints hash the path relative to --relative-to, so the baseline matches on any machine.
    baseline=""
    [ "$tool" = dolly ] && [ -f .dolly-baseline.json ] && baseline="--baseline .dolly-baseline.json"
    # --strict: a warning fails, a note never does. Each tool reads its own .<tool>.json.
    # shellcheck disable=SC2086
    "$CACHE/$tool-$version/$tool" analyze --strict --no-cache --relative-to . $baseline $CORPUS \
        || failed=1
}

failed=0
run deadwood "$VERSION_DEADWOOD"
run dolly "$VERSION_DOLLY"
run arcleak "$VERSION_ARCLEAK"
[ "$failed" -eq 0 ] || fail "a static analyzer reported findings (accept one with a directive and a reason, never silently)"
printf '[OK] analyzers clean\n'
