# Guarded stack reuse: focused C runtime timings

Five alternating before/after runs, 100,000 requested iterations, one/four
slots and affinity `0,2,4,6`. All nine workloads remain in the
[raw record](stack-cache-runtime.csv); build identities, hashes, flags and
the follow-up fixture source are in [the machine record](stack-cache-runtime-machine.json).
This compares the runtime at `0d166bf` and `4ca06aa`, independently of native
Perl yield. These C operations are different from the Perl API fixtures.

| Operation | Slots | Before, ns/op | After, ns/op | Change |
| --- | ---: | ---: | ---: | ---: |
| spawn/completion | 1 | 8728.4 | 5666.7 | -35.08% |
| spawn/completion | 4 | 11994.8 | 2800.9 | -76.65% |
| yield | 1 | 60.0 | 61.7 | +2.83% |
| yield | 4 | 235.6 | 221.5 | -5.98% |
| channel round trip | 1 | 245.0 | 239.5 | -2.24% |
| channel round trip | 4 | 1189.1 | 1242.6 | +4.50% |

The native Perl yield loop includes interpreter execution and a completion
counter; its timing cannot be subtracted from C yield to isolate XS ABI costs.

The short all-workload driver also records four-slot selection rising from
105.9 to 116.9 ns (+10.39%). That observation is retained, not omitted from
an aggregate. A select-only follow-up used seven alternating runs and
2,000,000 iterations with the same runtime libraries and CPU mask:

| Selection | Before, ns/op | After, ns/op | Change |
| --- | ---: | ---: | ---: |
| One slot | 93.0 | 93.9 | +0.97% |
| Four slots | 96.0 | 96.7 | +0.73% |

The larger fixture did not reproduce the initial increase. Work size and
driver layout both differ, so it does not prove that the shorter result was
noise. The [follow-up samples](stack-cache-select-followup.csv) and exact
fixture source remain available for investigation. No selection algorithm
or expected result was changed.

The full [Perl operation comparison](operation-matrix-stack-cache-check.txt)
passes its unchanged per-cell 10% gate and records spawn reductions of
12.69%/6.21%/8.08% on one/two/four slots. Four-slot compatibility yield rises
9.995%, just inside that budget. There is no general claim that every operation
became faster.
