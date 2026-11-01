# Common operation matrix

Native channel entries plus numeric/yield context refinements and the TEMP
ownership fix. The [comparison](operation-matrix-channel-check.txt) against the
[fixed anchor](operation-matrix-channel-baseline.md) passes the unchanged 10%
work/process regression budget. Channel work falls 32.81%/29.06%/31.47% and
spawn work falls 14.73%/9.04%/15.18% on one/two/four slots. Yield work falls
2.41%/2.26%/2.70%; ordinary Perl remains much slower than stock in active mode.

Each capture retains five runs, 154 cells and 770 samples (640 timed, 130 N/A).
The original native-yield binary remains the default baseline. This full
comparison includes native act/constructor changes since that anchor; the
[same-binary channel probe](native-channel-api.md) isolates method dispatch.
The [initial arithmetic failures](operation-matrix-channel-initial.md),
[numeric refinement and yield failure](operation-matrix-channel-arithmetic.md),
[numeric probes](native-channel-arithmetic.md) and
[yield probes](native-channel-yield.md) remain available. Different work sizes
and before binaries are not pooled; a passing later capture does not remove
the earlier failures or establish that they were noise.

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.5 | 47.9 | 29.4 | 20.0 | 62.6 | 48.1 | 53.2 | 38.7 | 174.7 | 89.6 | 51.7 | 3.4 | 1.3 | 1.2 |
| calls | 153.0 | 160.9 | 87.3 | 49.7 | 173.9 | 103.8 | 83.3 | 502.7 | 783.7 | 718.0 | 869.9 | 4.2 | 2.7 | 1.8 |
| arrays | 345.2 | 355.2 | 180.0 | 104.2 | 367.7 | 202.9 | 136.5 | 964.4 | 2020.6 | 1035.0 | 655.4 | 23.9 | 15.0 | 13.4 |
| hashes | 240.8 | 248.2 | 128.4 | 74.2 | 258.7 | 151.0 | 108.9 | 677.4 | 4141.0 | 4341.4 | 5632.4 | 69.6 | 38.2 | 23.6 |
| strings | 140.5 | 143.4 | 77.7 | 45.5 | 164.0 | 99.3 | 80.6 | 246.2 | 552.2 | 287.6 | 187.5 | 21.3 | 15.4 | 10.9 |
| regex | 544.2 | 551.0 | 285.5 | 161.6 | 576.9 | 305.8 | 195.6 | 1083.5 | 1661.6 | 837.3 | 494.5 | 321.7 | 173.5 | 106.6 |
| utf8 | 547.3 | 546.5 | 279.0 | 158.5 | 555.1 | 298.1 | 190.4 | 1283.8 | 2664.7 | 4185.4 | 4343.2 | 18.9 | 11.8 | 10.2 |
| json | 6066.8 | 6024.8 | 3034.7 | 1791.7 | 5863.6 | 3012.1 | 1751.7 | 19326.5 | 45489.6 | N/A | N/A | 453.0 | 235.2 | 145.9 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 185.9 | 327.7 | 648.9 | 413.6 | 830.8 | 908.6 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 20268.8 | 19482.1 | 20400.1 | 1384.9 | 779.6 | 747.7 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 5480.2 | 17503.6 | 19751.9 | 990.8 | 1557.8 | 1550.1 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 1.01x | 4.54x | 1.35x | 51.62x | 43.15x |
| calls | 3.28x | 5.12x | 5.68x | 185.39x | 493.26x |
| arrays | 2.79x | 5.85x | 1.90x | 84.64x | 48.75x |
| hashes | 2.81x | 17.20x | 23.39x | 59.47x | 238.36x |
| strings | 1.75x | 3.93x | 1.33x | 25.94x | 17.24x |
| regex | 1.99x | 3.05x | 0.91x | 5.17x | 4.64x |
| utf8 | 2.35x | 4.87x | 7.94x | 140.84x | 424.11x |
| json | 3.19x | 7.50x | N/A | 100.41x | N/A |
| yield | N/A | N/A | N/A | 0.45x | 0.71x |
| spawn | N/A | N/A | N/A | 14.64x | 27.28x |
| channel | N/A | N/A | N/A | 5.53x | 12.74x |

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
CPU affinity: 0,2,4,6. Source: 58e749c3dbf60085240ac86606dac58e92351e0d (clean).

Public Wump syntax; native operations in the compiled worker: wumpact, wumpchan, wumpyield.
Native channel method entries: Wump::Channel::close, Wump::Channel::recv, Wump::Channel::send.
