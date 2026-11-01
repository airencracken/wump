# Native Perl selection checkpoint

`sel($cases [, $timeout])` now compiles to a native opcode. Selection itself
is correctness-tested here; the common-operations workload is unchanged.

The [fresh check](operation-matrix-select-check.txt) **fails** four-slot yield
work: +13.18% against the unchanged +10% budget. The separate
[retained-anchor check](operation-matrix-select-anchor-check.txt) passes.
All samples remain recorded. This feature checkpoint does not replace the
default anchor or claim a complete performance pass.

The [fresh control](operation-matrix-select-before.md),
[raw current capture](operation-matrix-select-current.json),
[machine/provenance record](native-select-machine.json), and
[correctness scope](../docs/VALIDATION.md#native-perl-selection-checkpoint-2026-11-01)
retain the evidence. Both binaries use the same Wump.pm and unchanged matrix
fixtures, stock/fork/ithread/Go controls, CPU mask and 5-run/50,000-iteration
parameters. NEW selection timing is not inferred from existing channel rows.

# Common operation matrix

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.3 | 47.1 | 29.3 | 19.1 | 62.0 | 47.3 | 51.6 | 36.3 | 170.8 | 90.6 | 50.0 | 2.8 | 1.8 | 1.2 |
| calls | 150.9 | 161.0 | 83.5 | 49.9 | 174.6 | 104.1 | 80.2 | 494.5 | 748.3 | 604.3 | 694.0 | 5.0 | 2.7 | 1.9 |
| arrays | 342.9 | 353.4 | 181.4 | 101.0 | 369.1 | 201.4 | 133.3 | 990.0 | 2014.5 | 1038.3 | 688.9 | 21.5 | 16.4 | 14.1 |
| hashes | 234.7 | 247.7 | 129.4 | 72.6 | 257.9 | 149.7 | 104.5 | 690.4 | 4068.8 | 4318.4 | 5643.4 | 69.8 | 40.1 | 25.4 |
| strings | 140.6 | 143.4 | 75.5 | 44.8 | 161.8 | 98.1 | 82.3 | 254.6 | 544.3 | 282.7 | 188.1 | 21.2 | 15.8 | 11.5 |
| regex | 546.5 | 554.6 | 287.4 | 161.3 | 570.8 | 307.7 | 194.3 | 1066.2 | 1657.6 | 842.7 | 478.6 | 316.1 | 166.0 | 107.3 |
| utf8 | 535.2 | 547.5 | 278.9 | 155.8 | 560.0 | 304.7 | 189.6 | 1268.2 | 2623.3 | 4042.1 | 4233.9 | 19.0 | 12.9 | 9.9 |
| json | 6060.4 | 5983.9 | 3031.3 | 1681.5 | 5871.1 | 2983.2 | 1693.4 | 18992.6 | 44240.5 | N/A | N/A | 449.9 | 233.0 | 136.7 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 187.4 | 207.0 | 235.6 | 406.5 | 822.3 | 891.8 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 19568.6 | 19057.9 | 19764.3 | 1368.7 | 771.1 | 760.6 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 5341.7 | 17364.8 | 19369.7 | 988.9 | 1516.1 | 1667.7 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.95x | 4.46x | 1.31x | 60.78x | 41.16x |
| calls | 3.28x | 4.96x | 4.60x | 148.23x | 371.56x |
| arrays | 2.89x | 5.87x | 2.01x | 93.55x | 48.82x |
| hashes | 2.94x | 17.34x | 24.05x | 58.26x | 222.18x |
| strings | 1.81x | 3.87x | 1.34x | 25.65x | 16.40x |
| regex | 1.95x | 3.03x | 0.88x | 5.24x | 4.46x |
| utf8 | 2.37x | 4.90x | 7.91x | 138.36x | 425.72x |
| json | 3.13x | 7.30x | N/A | 98.33x | N/A |
| yield | N/A | N/A | N/A | 0.46x | 0.26x |
| spawn | N/A | N/A | N/A | 14.30x | 25.98x |
| channel | N/A | N/A | N/A | 5.40x | 11.61x |

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
CPU affinity: 0,2,4,6. Source: 80ecd64fb401b390e0e3b6553d0e0fa87d783589 (clean).

Public Wump syntax; native operations in the compiled worker: wumpact, wumpchan, wumpyield.
Native channel method entries: Wump::Channel::close, Wump::Channel::recv, Wump::Channel::send.
