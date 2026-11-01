# Native yield and API call overhead

Seven rotated runs on clean source `fbe0e8a`, using the same private Perl
binary and CPU mask `0,2,4,6`. Lower is better. These are elapsed work times,
including the Perl loop and completion counter, not isolated ABI-call costs.

| Operation | Path | One slot, ns/op | Four slots, ns/op |
| --- | --- | ---: | ---: |
| yield | Perl wrapper, `Wump::yield()` | 598.4 | 3351.2 |
| yield | Direct XS, `Wump::_yield()` | 321.3 | 1358.4 |
| yield | Native opcode, `yield` | 189.5 | 641.3 |
| spawn/completion | Perl `act` wrapper | 18728.1 | 19483.3 |
| spawn/completion | Direct XS act entry | 18163.0 | 18255.0 |

Native yield takes 68.3%/80.9% less work time than the wrapper on one/four
slots, and 41.0%/52.8% less than direct XS. Both the Perl wrapper and the
XS/interpreter call path matter for this operation. This does not identify
every nanosecond of the difference as ABI overhead: call frames, interpreter
bookkeeping and scheduling behavior also differ.

Removing only `act`'s wrapper saves 3.0%/6.3% in this fixture. Creation and
completion retain substantial costs underneath that wrapper; native `act`
and channel operations are not implemented by this experiment.

| Yield path | One-slot range, ns/op | Four-slot range, ns/op |
| --- | ---: | ---: |
| Wrapper | 586.3–602.9 | 3117.1–3461.6 |
| XS | 312.5–323.8 | 1318.1–1390.5 |
| Native | 188.7–191.8 | 618.8–707.4 |

Whole-process medians, including interpreter/runtime startup, common module
loading and final report serialization:

| Operation/path | One slot, ms | Four slots, ms |
| --- | ---: | ---: |
| yield/wrapper | 143.8 | 696.7 |
| yield/XS | 88.4 | 295.8 |
| yield/native | 62.6 | 153.3 |
| spawn/wrapper | 406.4 | 423.2 |
| spawn/XS | 394.6 | 398.4 |

Yield runs 200,000 iterations in one main act. Four slots describe the
scheduler configuration, not four independently yielding actors. Spawn runs
20,000 tasks in cohorts of at most 1,024; each sends one completion value.
Both spawn paths retain the same channel methods and validate every reply
and the total count. The common matrix's unique-ID spawn workload is different
and its numbers must not be substituted here.

Clock constants and common dependencies are prepared before work timing.
The reporter uses ASCII JSON without the unsupported parallel `utf8::encode`
entry. The native probe rejects interpreters missing the opcode. All 70 raw
samples, process timings, mode order, binary/source hashes, compiler settings
and the exact capture runner are retained in
[the samples](native-yield-api.jsonl) and [machine record](native-yield-machine.json).

The common [operation matrix](operation-matrix-fork-threads-baseline.md)
still measures qualified compatibility yield. This focused experiment measures
the native keyword directly without changing that matrix's historical fixture.
These host-specific results do not establish general program speed or Go parity.

The native build passes 30 focused checks, the project/context/legacy suites,
and 2,919 files / 1,351,319 standard upstream checks. The first full run found
missing Opcode classification; the corrected operation is classified with
thread operations and honors compilation masks. Parser/opcode regeneration,
source upgrades, 103 matrix validation checks and 312 integration checks pass.
Whole-Perl sanitizers were not rerun for the native opcode.
