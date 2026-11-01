# Common operation matrix

Perl-for-Wump call resolution: one protected snapshot for the ordinary callee
path, plus separate fixes for stash reads in `bless` and `ref`. This is the
third [optimization lane](../docs/BENCHMARKS.md#three-optimization-lanes).
The standalone Wump scheduler/channel implementation is unchanged.

The [comparison](operation-matrix-callee-check.txt) **fails** the unchanged
10% work/process budget for two-slot yield work (**+21.19%**). That is the
only failed metric; its process time is +5.38%. The cause remains unresolved.
The [preceding native-channel build](operation-matrix-callee-baseline.md)
remains the default timing anchor; this candidate has not replaced it.

Calls take 13.73%/18.30% less work time on two/four slots. One-slot and unused
calls are nearly flat (-0.38%/-0.33%). The separate, larger
[interleaved call probe](perl-callee-calls.md) measures -14.89%/-17.77% on
two/four slots and about -2.6%/-2.5% on one slot/unused. Different work sizes
are not pooled. Stock Perl is an unchanged control; an unused-fork gain alone
does not establish an upstream Perl improvement.

The [yield investigation](perl-callee-yield.md) retains seven interleaved runs
at two work sizes, measuring +4.18%/+2.23%. Generated yield/core sources and
selected object `.text` sections match the preceding build. Neither that
observation nor a smaller follow-up difference clears the full-matrix failure
or establishes that it was noise. All 1,540 full-matrix and 91 focused samples
are retained with exact source/binary identities and capture runners.
See [validation](../docs/VALIDATION.md) for the correctness and sanitizer scope.

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.6 | 47.7 | 27.9 | 20.1 | 62.9 | 49.7 | 55.4 | 35.7 | 160.7 | 83.7 | 46.1 | 3.2 | 1.8 | 1.1 |
| calls | 153.4 | 159.5 | 86.2 | 51.8 | 176.4 | 105.9 | 87.1 | 496.5 | 766.7 | 621.6 | 719.1 | 4.0 | 2.9 | 2.1 |
| arrays | 345.7 | 355.1 | 181.9 | 104.8 | 368.6 | 203.9 | 139.9 | 989.4 | 2030.7 | 1053.2 | 662.3 | 23.5 | 15.5 | 12.8 |
| hashes | 237.4 | 244.9 | 128.8 | 74.1 | 261.6 | 152.0 | 108.8 | 694.8 | 4229.2 | 4428.3 | 5641.9 | 71.3 | 38.4 | 23.9 |
| strings | 134.4 | 143.2 | 76.0 | 44.2 | 163.2 | 99.3 | 77.5 | 243.5 | 554.7 | 286.4 | 199.6 | 23.3 | 15.3 | 11.6 |
| regex | 543.9 | 555.1 | 290.3 | 164.7 | 583.3 | 306.4 | 195.6 | 1103.3 | 1671.5 | 852.5 | 497.3 | 321.1 | 169.1 | 109.0 |
| utf8 | 537.1 | 555.4 | 279.4 | 158.7 | 558.5 | 303.3 | 195.2 | 1283.4 | 2666.2 | 4160.0 | 4435.4 | 18.7 | 13.1 | 9.9 |
| json | 6098.2 | 6076.0 | 3112.3 | 1864.6 | 5919.4 | 3042.3 | 1794.3 | 19100.5 | 45091.2 | N/A | N/A | 453.9 | 235.1 | 145.2 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 187.3 | 396.6 | 704.3 | 412.0 | 848.9 | 925.1 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 20361.2 | 19464.3 | 20496.9 | 1391.9 | 771.2 | 768.5 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 5404.9 | 17692.6 | 19523.0 | 994.4 | 1391.7 | 1549.9 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.93x | 4.16x | 1.19x | 50.10x | 41.55x |
| calls | 3.24x | 5.00x | 4.69x | 190.95x | 349.48x |
| arrays | 2.86x | 5.87x | 1.92x | 86.28x | 51.86x |
| hashes | 2.93x | 17.82x | 23.77x | 59.29x | 235.94x |
| strings | 1.81x | 4.13x | 1.49x | 23.82x | 17.27x |
| regex | 2.03x | 3.07x | 0.91x | 5.21x | 4.56x |
| utf8 | 2.39x | 4.96x | 8.26x | 142.69x | 447.51x |
| json | 3.13x | 7.39x | N/A | 99.35x | N/A |
| yield | N/A | N/A | N/A | 0.45x | 0.76x |
| spawn | N/A | N/A | N/A | 14.63x | 26.67x |
| channel | N/A | N/A | N/A | 5.44x | 12.60x |

N/A means unavailable, never a zero-cost operation:

- json / wump-2: parallel XS admission: utf8::encode
- json / wump-4: parallel XS admission: utf8::encode
- yield / stock: no coroutine runtime in this mode
- yield / fork-1: no coroutine runtime in this mode
- yield / fork-2: no coroutine runtime in this mode
- yield / fork-4: no coroutine runtime in this mode
- yield / ithreads-1: no coroutine runtime in this mode
- yield / ithreads-2: no coroutine runtime in this mode
- yield / ithreads-4: no coroutine runtime in this mode
- yield / wump-unused: no coroutine runtime in this mode
- spawn / stock: no coroutine runtime in this mode
- spawn / fork-1: no coroutine runtime in this mode
- spawn / fork-2: no coroutine runtime in this mode
- spawn / fork-4: no coroutine runtime in this mode
- spawn / ithreads-1: no coroutine runtime in this mode
- spawn / ithreads-2: no coroutine runtime in this mode
- spawn / ithreads-4: no coroutine runtime in this mode
- spawn / wump-unused: no coroutine runtime in this mode
- channel / stock: no coroutine runtime in this mode
- channel / fork-1: no coroutine runtime in this mode
- channel / fork-2: no coroutine runtime in this mode
- channel / fork-4: no coroutine runtime in this mode
- channel / ithreads-1: no coroutine runtime in this mode
- channel / ithreads-2: no coroutine runtime in this mode
- channel / ithreads-4: no coroutine runtime in this mode
- channel / wump-unused: no coroutine runtime in this mode

5 rotated runs; 50000 iterations; 8 independent jobs for common operations.
CPU affinity: 0,2,4,6. Source: d048fe53514a68c6152eb0861ea15a318b845e93 (clean).

Public Wump syntax; native operations in the compiled worker: wumpact, wumpchan, wumpyield.
Native channel method entries: Wump::Channel::close, Wump::Channel::recv, Wump::Channel::send.
