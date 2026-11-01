# Common operation matrix

Wump runtime lane: a sole yielded continuation stops advertising itself to
idle thieves. It still enters the scheduler and retains queue locking,
dispatch hooks, timer/global work and shutdown checks. New work, backlogs,
channel readiness and external publication keep their notifications.
No Perl patch source changed in this checkpoint.

Both unchanged 10% work/process checks **pass**:

- [Fresh before/after runtime comparison](operation-matrix-yield-check.txt):
  yield work falls 39.43%/70.07% on two/four slots; one-slot work is +1.14%.
- [Retained-anchor comparison](operation-matrix-yield-anchor-check.txt):
  yield work falls 36.56%/71.53% on two/four slots. Calls retain the preceding
  interpreter gains (-14.97%/-20.99%); this comparison spans those earlier
  changes as well as the runtime change.

The [fresh control](operation-matrix-yield-before.md) does not replace the
[fixed default anchor](operation-matrix-callee-baseline.md). The prior
[+21.19% yield failure](operation-matrix-callee-check.txt) remains recorded.
This checkpoint brings yield within budget without claiming to explain the
earlier timing difference. No sample or threshold was changed to pass.

The [seven-run C/Perl probe](scheduler-yield.md) separately measures two million
yields in one task: C work falls 48.41%/63.49%, Perl 32.52%/69.60% on two/four
slots. One-slot changes are +0.93%/+0.96%. Those work sizes and surfaces are
not pooled with the full matrix; slot count does not mean several independent
yielding tasks. All 1,540 fresh matrix and 84 focused samples retain results,
source/binary/archive hashes, compiler configuration and exact capture sources.
See [validation](../docs/VALIDATION.md) for the correctness/sanitizer scope.

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.2 | 47.1 | 28.3 | 19.5 | 61.5 | 48.1 | 52.2 | 36.1 | 160.6 | 85.3 | 46.6 | 2.9 | 1.7 | 1.2 |
| calls | 150.8 | 160.3 | 86.1 | 50.8 | 173.8 | 104.0 | 82.0 | 496.0 | 765.9 | 612.6 | 695.4 | 4.1 | 2.6 | 2.0 |
| arrays | 342.8 | 353.5 | 181.0 | 102.4 | 366.6 | 200.1 | 133.7 | 982.6 | 2029.1 | 1036.1 | 659.1 | 23.3 | 15.6 | 13.5 |
| hashes | 237.3 | 245.1 | 131.0 | 72.2 | 259.9 | 147.9 | 106.3 | 665.4 | 4084.4 | 4307.0 | 5379.0 | 70.2 | 40.3 | 25.1 |
| strings | 140.1 | 142.0 | 74.9 | 44.8 | 164.1 | 98.7 | 79.1 | 251.9 | 554.5 | 288.0 | 191.0 | 22.7 | 16.7 | 11.4 |
| regex | 541.3 | 555.3 | 283.1 | 159.4 | 570.9 | 305.0 | 194.1 | 1088.6 | 1638.4 | 841.4 | 477.6 | 317.4 | 168.2 | 105.6 |
| utf8 | 542.9 | 545.1 | 278.7 | 156.6 | 561.4 | 302.0 | 192.3 | 1266.6 | 2659.8 | 4098.4 | 4289.2 | 19.9 | 12.4 | 10.1 |
| json | 6041.2 | 5976.1 | 3048.6 | 1674.8 | 5870.0 | 2999.7 | 1694.2 | 19010.6 | 44783.1 | N/A | N/A | 448.3 | 239.5 | 141.0 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 191.7 | 207.6 | 205.6 | 414.3 | 807.9 | 929.4 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 20058.4 | 19089.9 | 19928.0 | 1367.3 | 763.9 | 744.8 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 5389.5 | 17647.0 | 19704.5 | 999.7 | 1526.3 | 1573.7 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.94x | 4.20x | 1.22x | 55.99x | 37.46x |
| calls | 3.29x | 5.08x | 4.61x | 189.11x | 355.75x |
| arrays | 2.87x | 5.92x | 1.92x | 86.94x | 48.96x |
| hashes | 2.80x | 17.21x | 22.66x | 58.21x | 214.54x |
| strings | 1.80x | 3.96x | 1.36x | 24.48x | 16.75x |
| regex | 2.01x | 3.03x | 0.88x | 5.16x | 4.52x |
| utf8 | 2.33x | 4.90x | 7.90x | 133.96x | 426.57x |
| json | 3.15x | 7.41x | N/A | 99.89x | N/A |
| yield | N/A | N/A | N/A | 0.46x | 0.22x |
| spawn | N/A | N/A | N/A | 14.67x | 26.76x |
| channel | N/A | N/A | N/A | 5.39x | 12.52x |

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
CPU affinity: 0,2,4,6. Source: e97e00bafab3fae4aa06329ca56146d00136841a (clean).

Public Wump syntax; native operations in the compiled worker: wumpact, wumpchan, wumpyield.
Native channel method entries: Wump::Channel::close, Wump::Channel::recv, Wump::Channel::send.
