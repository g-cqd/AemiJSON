#!/usr/bin/awk -f
#
# bench-compare.awk — render an ADJSON-vs-Foundation comparison table from the standalone
# "Debug results" output of the ADJSONSuite benchmark binary (ordo-one/benchmark).
#
#   .build/release/ADJSONSuite --quiet true | awk -f Scripts/bench-compare.awk
#   awk -f Scripts/bench-compare.awk capture.txt
#
# The suite names benchmarks "<workload>/<variant>" and registers the Foundation baseline
# first in each workload (e.g. "decode/Foundation" before "decode/ADJSON Codable"). For the
# "corpus" workload the variant is preceded by the file name ("corpus/twitter Foundation"),
# so each file is its own comparison group. We pair every ADJSON variant with the Foundation
# baseline in its group and report p50 wall-clock and the speedup (Foundation / ADJSON;
# >1 means ADJSON is faster). Total malloc count per op is shown when present — that metric
# needs jemalloc, and without it the runner reports 0, which we render as "—".
#
# The runner prints wall-clock in NANOSECONDS in standalone debug mode regardless of
# --time-units, so p50 is divided by 1e6 for milliseconds. Output is GitHub-flavoured
# Markdown, suitable for a CI job summary.

# Pull the number after "=" out of a "#[Label = N, StdDeviation = …]" summary line.
function num(line,   v) {
    v = line
    sub(/^#\[[A-Za-z ]*=[ ]*/, "", v)
    sub(/[ ,].*$/, "", v)
    return v + 0
}
function ms(ns) { return sprintf("%.3f", ns / 1000000.0) }
function speed(x) { return (x >= 1.0) ? sprintf("**%.2f×**", x) : sprintf("%.2f× ⚠︎", x) }
function mallocs(f, a) {
    if (f == 0 && a == 0) return "—"
    return sprintf("%d → %d", f, a)
}

/^Debug results for / {
    name = $0
    sub(/^Debug results for /, "", name)
    sub(/:$/, "", name)
    section = ""
    if (!(name in seenIndex)) { seenIndex[name] = ++count; byIndex[count] = name }
    next
}
/^Time \(wall clock\):/ { section = "time"; next }
/^Throughput/           { section = "thru"; next }
/^Malloc/               { section = "mal";  next }

# Histogram p50 row for the wall-clock section: "<value> 0.500000000000 <count> <ratio>".
section == "time" && $2 == "0.500000000000" && !(name in p50) { p50[name] = $1 + 0; next }

# Per-section mean lines; we only need the malloc total mean (the others use the p50 above).
/^#\[Mean/ {
    if (section == "mal") mallocTotal[name] = num($0)
    next
}

END {
    if (count == 0) {
        print "_No benchmark results parsed._"
        exit 0
    }

    # Derive workload group, variant label, and the Foundation baseline for each benchmark.
    for (i = 1; i <= count; i++) {
        name = byIndex[i]
        slash = index(name, "/")
        category = substr(name, 1, slash - 1)
        remainder = substr(name, slash + 1)
        if (category == "corpus") {
            gap = index(remainder, " ")
            workload[name] = category "/" substr(remainder, 1, gap - 1)
            variant[name] = substr(remainder, gap + 1)
        } else {
            workload[name] = category
            variant[name] = remainder
        }
        if (index(variant[name], "Foundation") > 0) baseline[workload[name]] = name
    }

    print "| Workload | Foundation | ADJSON | p50 (F) | p50 (A) | Speedup | Mallocs (F→A) |"
    print "|---|---|---|--:|--:|--:|--:|"

    rows = 0
    for (i = 1; i <= count; i++) {
        name = byIndex[i]
        base = baseline[workload[name]]
        if (base == "" || name == base) continue  # skip groups without a Foundation baseline (and the baseline row itself)
        ratio = p50[base] / p50[name]
        printf "| `%s` | %s | %s | %s ms | %s ms | %s | %s |\n",
            workload[name], variant[base], variant[name],
            ms(p50[base]), ms(p50[name]), speed(ratio),
            mallocs(mallocTotal[base], mallocTotal[name])
        rows++
    }

    print ""
    printf "_%d comparisons · p50 wall-clock · Speedup = Foundation ÷ ADJSON (higher = ADJSON faster; ⚠︎ = ADJSON slower)._\n", rows
    print "_Lazy/partial ADJSON variants (`tape`, `read 2 fields`, `lazy sum`, `walk`) do less work than a full typed decode — read them as upper bounds, not like-for-like._"
    print "_Mallocs = total allocations per op; requires jemalloc, shown as “—” when unavailable._"
}
