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
VERSION_DEADWOOD=0.10.2
SHA_DEADWOOD_MACOS=6a69fde41051a4dde558f3e2747addf85fcc7e0fa61479a35e5ececd3fb78ab2
SHA_DEADWOOD_LINUX=e1c3d966c62a17f9e07556e697e681b6e35a1f69d150080c9e427087afd386a6
VERSION_DOLLY=0.10.3
SHA_DOLLY_MACOS=9ca8e0d236c3a273b5ef3351d04857b9ae191e63356da9919cfc800f0863deb6
SHA_DOLLY_LINUX=a6ff5d69c06a8aaa2832284a4d40b73cd1dc3952a2704cdf2eb9a51ec13ee6c7
VERSION_ARCLEAK=0.11.0
SHA_ARCLEAK_MACOS=7829e2efd4c4cd91c947962c6052c5949d22551352e074aefcf43f41e547e139
SHA_ARCLEAK_LINUX=ec92296422a9bc116667546d3abdd1106177b590f1a986c16c40df00d145cdc1

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
