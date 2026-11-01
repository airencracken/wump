# Common operation matrix

Fresh matched control for the solitary-continuation runtime change: the
preceding callee/stash binary, published in checkpoint `ba5a73a`, rerun with
the same current fixture and controls as the
[candidate](operation-matrix-yield-current.md). The executable is identified
by its hash independently of the fixture checkout revision.

This is not the default anchor. The original
[callee baseline](operation-matrix-callee-baseline.md) remains unchanged, and
the prior [failed callee comparison](operation-matrix-callee-check.txt) remains
archived. Both fresh captures retain five runs / 770 samples (640 timed,
130 N/A), 50,000 iterations, eight jobs and CPU mask `0,2,4,6`.

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.2 | 46.7 | 28.7 | 18.6 | 61.8 | 45.8 | 51.3 | 36.0 | 161.8 | 87.0 | 45.7 | 3.4 | 1.8 | 1.3 |
| calls | 151.1 | 162.4 | 84.3 | 49.6 | 174.5 | 102.7 | 79.6 | 487.4 | 754.9 | 602.1 | 687.8 | 4.7 | 2.8 | 1.8 |
| arrays | 343.8 | 352.1 | 182.2 | 101.9 | 366.7 | 200.6 | 137.2 | 967.9 | 2025.0 | 1033.9 | 657.1 | 22.5 | 15.1 | 13.9 |
| hashes | 236.2 | 245.9 | 129.4 | 73.5 | 264.5 | 149.8 | 105.3 | 660.2 | 4133.4 | 4330.1 | 5443.4 | 68.1 | 37.3 | 24.2 |
| strings | 139.3 | 143.7 | 75.4 | 44.8 | 163.8 | 96.9 | 77.6 | 250.1 | 553.3 | 287.6 | 188.9 | 23.3 | 14.9 | 10.6 |
| regex | 540.5 | 556.2 | 285.2 | 160.7 | 574.0 | 308.8 | 195.8 | 1088.4 | 1675.3 | 846.8 | 484.0 | 318.4 | 170.1 | 102.9 |
| utf8 | 540.9 | 548.9 | 279.0 | 153.8 | 561.6 | 300.0 | 189.1 | 1281.2 | 2680.7 | 4117.8 | 4295.2 | 20.4 | 13.2 | 10.0 |
| json | 6053.0 | 6002.7 | 3062.9 | 1691.6 | 5896.0 | 2990.1 | 1736.6 | 19148.8 | 45030.9 | N/A | N/A | 448.3 | 230.8 | 140.2 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 189.6 | 342.8 | 687.0 | 411.2 | 823.1 | 915.6 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 19453.6 | 19033.8 | 20094.3 | 1376.6 | 760.7 | 764.8 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 5402.8 | 17111.9 | 19608.2 | 980.1 | 1353.6 | 1438.1 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.94x | 4.23x | 1.20x | 48.23x | 34.48x |
| calls | 3.23x | 5.00x | 4.55x | 159.73x | 386.28x |
| arrays | 2.82x | 5.89x | 1.91x | 89.90x | 47.29x |
| hashes | 2.80x | 17.50x | 23.05x | 60.71x | 224.83x |
| strings | 1.79x | 3.97x | 1.36x | 23.73x | 17.78x |
| regex | 2.01x | 3.10x | 0.90x | 5.26x | 4.70x |
| utf8 | 2.37x | 4.96x | 7.94x | 131.63x | 428.79x |
| json | 3.16x | 7.44x | N/A | 100.45x | N/A |
| yield | N/A | N/A | N/A | 0.46x | 0.75x |
| spawn | N/A | N/A | N/A | 14.13x | 26.27x |
| channel | N/A | N/A | N/A | 5.51x | 13.63x |

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
