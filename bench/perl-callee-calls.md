# Perl-for-Wump call resolution

This is the third optimization lane: changes to the interpreter that lower
Wump execution costs. The before binary is the preceding native-channel/context
build. The after binary combines one protected callee snapshot with the separate
stash-read correctness fixes. The timed increment loop performs no blessing or
reference-name lookup; this is still whole-interpreter work, not an isolated
mutex or ABI measurement. Code layout and scheduling can affect differences.

Seven interleaved runs use 500,000 iterations per job and eight verified jobs,
with CPU mask `0,2,4,6`. Variant order rotates; before/after order alternates.
Unused mode runs sequentially without activating Wump; active columns execute
independent jobs on one/two/four slots. Each iteration calls an increment
function, adds its result and performs modulo/loop work. Every job identity
and checksum is checked against the independent closed-form expectation.

Source `d048fe53514a68c6152eb0861ea15a318b845e93` (clean); AMD Ryzen 7 PRO 4750U with Radeon Graphics.

Unmodified matched stock Perl: **151.845 ns/call** median (151.781-156.059 range).

| Mode | Before, ns/call | After, ns/call | Change | Before range | After range |
| --- | ---: | ---: | ---: | ---: | ---: |
| wump-unused | 505.795 | 492.973 | -2.535% | 501.836-510.036 | 489.581-501.739 |
| wump-1 | 775.162 | 754.885 | -2.616% | 769.846-783.498 | 751.282-760.376 |
| wump-2 | 716.610 | 609.909 | -14.890% | 709.522-717.996 | 602.269-613.464 |
| wump-4 | 898.299 | 738.717 | -17.765% | 881.666-965.709 | 694.013-772.728 |

Negative change means less elapsed work time. Whole-process medians include
startup, dependency loading, setup and report serialization:

| Mode | Before process, ms | After process, ms |
| --- | ---: | ---: |
| wump-unused | 2060.206 | 2008.150 |
| wump-1 | 3142.214 | 3059.724 |
| wump-2 | 2907.232 | 2480.050 |
| wump-4 | 3634.325 | 2995.495 |

The [full matrix](operation-matrix-callee-current.md) has its own work sizes
and regression check; these focused samples are not pooled with it. Stock
Perl is an unchanged reference. A gain in the unused modified interpreter
would not establish that the change benefits upstream Perl independently.
The Wump scheduler/channel implementation is unchanged in this checkpoint.

All 63 [raw samples](perl-callee-calls.jsonl), including stock controls, work
and process times, are retained. The [machine record](perl-callee-machine.json)
contains source/binary hashes, compiler settings, exact runner and sample order.
Every source/binary hash, identity, checksum, operation count and report value
was revalidated. These host-specific results do not establish application speed.

Raw sample SHA256: `3e192fef217ab52b1f2c0bc0281e48435a4303b36cdd622269d81007a29203bc`.
