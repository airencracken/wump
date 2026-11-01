# Two-slot yield investigation

The [full-matrix check](operation-matrix-callee-check.txt) fails two-slot yield
work at **+21.19%**, against an unchanged 10% budget. Its five samples are
retained, including two candidate samples near the baseline and three slower
ones. The cause remains unresolved. These separate probes do not clear that
gate or establish that the failure was noise. The candidate has not replaced
the preceding native-channel build as the performance anchor.

Seven interleaved runs use the exact matrix worker and both frozen binaries,
CPU mask `0,2,4,6`, and two execution slots. One main act yields and increments
its completion counter; there are no independently yielding worker acts.
Every completion count is checked. The 50,000-yield work size matches the full
matrix; the two-million-yield probe uses more work. Size order rotates and
binary order alternates. The two sizes are reported separately.

Clean fixture source `d048fe53514a68c6152eb0861ea15a318b845e93`.

| Yields | Before, ns/yield | After, ns/yield | Change | Before range | After range |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 50000 | 338.964 | 353.126 | +4.178% | 286.602-436.251 | 314.874-446.952 |
| 2000000 | 308.528 | 315.420 | +2.234% | 293.286-329.574 | 292.115-321.650 |

| Yields | Before process, ms | After process, ms |
| ---: | ---: | ---: |
| 50000 | 58.579 | 57.686 |
| 2000000 | 656.923 | 670.658 |

Generated `wump_core.c` and `wump_active_ops.c` sources match the preceding
build. The scheduler and core/yield object `.text` sections also match byte
for byte; this excludes debug information and final link relocations. Final
layout, startup and scheduling can still differ. Those observations do not
prove the timed programs equivalent or explain the regression.

Local section SHA256 values, extracted with `objcopy --dump-section .text=FILE`
and checked with `cmp` for both builds:

- Scheduler: `768b5b7f82065d9cc5fee552631eb707844860f2147dfd031068b9c1aeec56ee`.
- Core/yield: `49ec97f68bfd7ca007d587a88d70ee6c945bd7d65ea60ba4c5a931561bb5e1c9`.

All 28 [raw samples](perl-callee-yield.jsonl), including work/process timings,
and the [machine record](perl-callee-yield-machine.json) retain exact source,
binary/configuration identities and runner. Stock binary metadata identifies
the shared control; this focused diagnostic does not time stock Perl.

Raw sample SHA256: `c1aed9193c8df2544fa88bf7cb7b1113e2e84104165f8db4475c4f08385dd984`.
