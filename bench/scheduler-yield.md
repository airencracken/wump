# Solitary continuation notification probe

This is the Wump runtime optimization lane. After saving a yielded task, its
live owner omits notification only if that task is the sole item in its local
queue. Queue locks remain. New spawns, channel readiness, backlogs and global
publication retain their notifications/epoch protocol. Every yield still
enters the scheduler, checks shutdown/timers/global work, and dispatches again.
The regression verifies context-entry hooks and errno before/after native-call
handoff, and requires newly queued work to notify. It fails on the preceding
runtime's redundant notification and passes after the change.

Seven rotated runs compare frozen before/after C and private-Perl binaries at
two million yields per sample, using CPU mask `0,2,4,6`. Surface/slot order
rotates and binary order alternates. Each sample has exactly **one yielding
task**, even when multiple execution slots are configured. These measurements
do not represent several independently yielding tasks or application speed.
The Perl probe uses the unchanged public-syntax matrix worker, including its
completion counter and actual compiled-binding checks. Its `jobs=8` metadata
does not create eight tasks for this primitive. The C probe increments a
volatile completion counter after each yield. Every count is verified.

Clean source `e97e00bafab3fae4aa06329ca56146d00136841a`; before checkpoint `ba5a73a30734af0cfbd36ed44a768df75b88e9dd`.

| Surface | Slots | Before, ns/yield | After, ns/yield | Change | Before range | After range |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| c | 1 | 61.532 | 62.105 | +0.931% | 60.670-62.046 | 61.254-64.614 |
| c | 2 | 152.947 | 78.901 | -48.413% | 139.044-172.680 | 77.452-80.483 |
| c | 4 | 215.817 | 78.792 | -63.491% | 206.695-231.820 | 77.718-81.769 |
| perl | 1 | 186.879 | 188.666 | +0.956% | 184.440-191.350 | 185.886-189.205 |
| perl | 2 | 308.800 | 208.382 | -32.519% | 289.667-342.439 | 203.865-210.641 |
| perl | 4 | 679.396 | 206.568 | -69.595% | 643.595-711.017 | 204.535-211.845 |

Negative change means less elapsed work time. Whole-process medians also
include interpreter/runtime startup, dependencies, setup and teardown:

| Surface | Slots | Before process, ms | After process, ms |
| --- | ---: | ---: | ---: |
| c | 1 | 126.811 | 128.207 |
| c | 2 | 310.475 | 162.558 |
| c | 4 | 435.006 | 161.268 |
| perl | 1 | 414.143 | 417.692 |
| perl | 2 | 657.657 | 457.601 |
| perl | 4 | 1402.390 | 456.754 |

The [full matrix](operation-matrix-yield-current.md) uses its own work sizes
and includes stock Perl, forks, ithreads and Go. The focused results do not
replace that gate. The previous [failed comparison](operation-matrix-callee-check.txt)
remains archived; this optimization targets demonstrated notification cost
without claiming to explain that earlier timing change.

All 84 [raw samples](scheduler-yield.jsonl) and the
[machine record](scheduler-yield-machine.json) retain compiler configuration,
source/binary/archive hashes, exact C worker and capture runner. Work/process
times are separate; no sample was dropped. Build trees and the coordination
regression's failed-before/passed-after logs remain under
`build/checkpoint-yield-wake/` locally.

Raw sample SHA256: `0488d1388c3702c75731dae88da244556f243e83cd73d1cd6e1b561b3e980c8e`.
