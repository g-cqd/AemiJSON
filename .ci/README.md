# CI

The pinned swift-ci caller reads `action.json`. `swift-ci run <check>` is the
same entry point locally. Fixture preparation runs before each selected test
leg; the flag-free consumer leg also compiles the Foundation-free core on its
warm tree. The existing root dolly baseline remains in force.

Special integrations remain in the caller: API compatibility on PRs, the
path-gated macOS thread and address+undefined sanitizers, five exact Apple
SDK/triple builds, Linux fuzzing with crash artifacts, hosted-runner benchmark
baseline generation, and combined DocC link validation/Pages deployment.
Platform, fuzz and benchmark jobs run on schedule or manual dispatch rather
than on every push. `update_baseline` remains a manual input. DocC builds once,
with warnings as errors, and deploys that same site only from main.

Per-change Linux ASan is handled by swift-ci. Its Linux runtime suppressions
are documented in swift-ci's `.ci/probes`; they do not disable leak detection.
