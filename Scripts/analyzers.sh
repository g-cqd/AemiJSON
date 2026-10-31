#!/bin/sh
# Static analyzers for AemiJSON: deadwood (unused code), dolly (duplicated code) and arcleak (retain cycles and leaks), from
# github.com/g-cqd, all syntax-level so they need no build.
#
#   Scripts/analyzers.sh            install the pinned releases if absent, then run them
#   Scripts/analyzers.sh install    install only
#
# The script and its lock (each tool's version and archive SHA-256 per platform) are the family's, in Aemi-Studio/aemi,
# pinned here to a commit: to upgrade the tools, move AEMI to a commit whose Scripts/analyzers.lock has the new
# versions, run, and read the findings diff before committing.
#
# Exit: 0 clean, 1 a tool found something, 2 a tool could not be installed or run.
set -eu

AEMI=d1b496ec940e2c2ecffb4b9b4fb5f08033b37f0a

# Benchmarks/ is left out: the Benchmark plugin finds a global named `benchmarks` by name, which no syntax-level
# analyzer can see, so every benchmark looks like dead code. The corpus is otherwise the whole package: reachability
# and clone detection are whole-program, and a smaller corpus makes live code look dead.
export ANALYZERS_CORPUS="${ANALYZERS_CORPUS:-Sources Tests}"
export ANALYZERS_TOOLS="${ANALYZERS_TOOLS:-deadwood dolly arcleak}"

case "$(uname -s)" in
    Darwin) cache_root="$HOME/Library/Caches" ;;
    *) cache_root="${XDG_CACHE_HOME:-$HOME/.cache}" ;;
esac
dir="$cache_root/g-cqd-analyzers/aemi-$AEMI"
if [ ! -f "$dir/analyzers.sh" ] || [ ! -f "$dir/analyzers.lock" ]; then
    scratch=$(mktemp -d)
    for file in analyzers.sh analyzers.lock; do
        curl -fsSL --retry 3 -o "$scratch/$file" \
            "https://raw.githubusercontent.com/Aemi-Studio/aemi/$AEMI/Scripts/$file" \
            || { rm -rf "$scratch"; printf '[FAIL] could not fetch %s at aemi %s\n' "$file" "$AEMI" >&2; exit 2; }
    done
    mkdir -p "$dir"
    mv "$scratch/analyzers.sh" "$scratch/analyzers.lock" "$dir/"
    rm -rf "$scratch"
fi
export ANALYZERS_LOCK="$dir/analyzers.lock"
exec sh "$dir/analyzers.sh" "$@"
