# Complete application compile-time contract

Mochi compiles each representative application in strictly less than 1,000 ms.
The limit applies to every individual invocation; the gate does not average
results, retry slow builds, or accept a cache-only pass.

## Standard gate

Run `task compile-time` from the Mochi repository. `task check` runs the gate
after its delayed-compiler regression test and before payload, runtime, GVM,
browser, and frontend behavior checks. The task builds the compiler first; that
compiler build is outside the application timing window.

The serial matrix measures five invocations for each fixture and scenario:

| Fixture | Source | Single edited component |
| --- | --- | --- |
| Minimal | `compiler/motestproj` | `MyCounter` |
| Full Costs | sibling `frontend-mochi` application | `CostsScreen` |
| Full Logs | sibling `frontend-mochi` application | `LogsScreen` |
| Full Cowboy port | sibling `frontend-mochi` application | `ZRoot` |

The current compiler discovers and transpiles every component in an input
project. The Costs, Logs, and full-port rows therefore each retain the complete
application source tree; their edit cases name the component whose Ruby source
changes. This keeps the full optional capability graph and all screens in each
measurement instead of creating reduced route-only inputs.

The scenarios run in this order:

1. **Cold output:** stage the full source tree before timing, then remove its
   generated build directory and output directory before each invocation.
2. **Warm:** preserve the staged source, generated build directory, and output
   between invocations.
3. **Single-component edit:** preserve the warm output and append a harmless
   Ruby comment to the named component before each timed invocation.

The gate starts a monotonic wall clock immediately before launching the already
built compiler with `-i <staged-project> -o <output>`. It stops when that process
exits, so source staging and cleanup are excluded while compiler startup,
compilation, and artifact writes are included. Any invocation at or above
1,000 ms fails with its fixture and scenario in the output.

## Gate regression test

`task compile-time:test` runs the same gate with a temporary compiler wrapper
that waits 1,100 ms. It must fail the one-run minimal cold case with exit status
1 and identify `minimal/cold` as over the strict limit. The wrapper and staged
fixture are temporary; no compiler or application source is changed.

## Local reproduction and diagnosis

Run one named scenario while iterating:

```sh
node scripts/compile_time_gate.cjs --fixture costs --scenario cold --runs 5
node scripts/compile_time_gate.cjs --fixture logs --scenario edit --runs 5
```

For a slow case, inspect the `mochi_build.pftrace` written in that staged
project by the compiler. Open it in a Perfetto-compatible viewer and follow the
slow fixture's setup/transpilation slices. Do not use a separate reduced build
to make the report pass. Optimize the measured critical path without omitting
components, resources, type checks, generated artifacts, or behavior. After
timing passes, `task check` runs payload and functional assertions.

## Reference evidence

The current reference machine is a Mac16,8 with Apple M4 Pro, running macOS
26.6.2 arm64. Timing output belongs to the local test run, not a dashboard or
committed benchmark history. Record the machine and invocation when reporting
a result. On 2026-11-12, the complete frontend application measured 510 ms for
a fresh output build and 405 ms through `task build`; those individual
observations preceded the final matrix and do not replace the gate.
