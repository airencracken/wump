# Common operation matrix

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.2 | 47.1 | 30.4 | 17.8 | 59.8 | 48.1 | 50.2 | 36.1 | 162.7 | 84.9 | 47.1 | 3.5 | 1.8 | 1.2 |
| calls | 151.6 | 159.9 | 85.7 | 50.0 | 174.7 | 104.6 | 81.4 | 517.6 | 763.6 | 612.7 | 698.5 | 4.0 | 2.9 | 1.9 |
| arrays | 345.8 | 352.3 | 182.3 | 101.6 | 366.5 | 200.9 | 133.9 | 956.7 | 2012.5 | 1053.9 | 692.0 | 23.1 | 15.6 | 12.7 |
| hashes | 239.9 | 245.2 | 128.0 | 73.1 | 259.6 | 146.3 | 105.5 | 677.7 | 4095.7 | 4317.4 | 5448.5 | 70.4 | 39.2 | 24.2 |
| strings | 140.2 | 143.4 | 75.9 | 44.2 | 163.6 | 98.6 | 77.7 | 255.8 | 532.9 | 283.2 | 187.8 | 21.5 | 15.4 | 10.2 |
| regex | 545.6 | 552.9 | 282.1 | 158.0 | 573.1 | 303.0 | 193.7 | 1072.6 | 1610.8 | 836.9 | 478.6 | 319.1 | 170.2 | 105.2 |
| utf8 | 547.3 | 544.8 | 279.3 | 155.2 | 561.3 | 295.5 | 186.6 | 1254.4 | 2607.7 | 4064.4 | 4292.0 | 18.9 | 13.1 | 9.6 |
| json | 6067.9 | 6028.1 | 3035.9 | 1678.5 | 5852.1 | 3028.1 | 1720.7 | 20188.2 | 48948.4 | 44104.0 | 42329.5 | 452.6 | 238.7 | 137.4 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 187.1 | 202.3 | 204.1 | 418.5 | 834.2 | 918.6 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 19872.2 | 18985.4 | 19826.2 | 1361.8 | 760.5 | 754.3 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 5450.0 | 17145.6 | 19335.7 | 985.7 | 1499.2 | 1554.1 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.95x | 4.26x | 1.23x | 47.08x | 38.68x |
| calls | 3.41x | 5.04x | 4.61x | 190.70x | 366.67x |
| arrays | 2.77x | 5.82x | 2.00x | 87.28x | 54.46x |
| hashes | 2.82x | 17.07x | 22.71x | 58.15x | 225.08x |
| strings | 1.82x | 3.80x | 1.34x | 24.80x | 18.40x |
| regex | 1.97x | 2.95x | 0.88x | 5.05x | 4.55x |
| utf8 | 2.29x | 4.76x | 7.84x | 138.15x | 447.79x |
| json | 3.33x | 8.07x | 6.98x | 108.16x | 307.99x |
| yield | N/A | N/A | N/A | 0.45x | 0.22x |
| spawn | N/A | N/A | N/A | 14.59x | 26.29x |
| channel | N/A | N/A | N/A | 5.53x | 12.44x |

N/A means unavailable, never a zero-cost operation:

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
CPU affinity: 0,2,4,6. Source: eecbbcd46ea005a11ecfbc70ccfe6f12299c5820 (clean).

Public Wump syntax; native operations in the compiled worker: wumpact, wumpchan, wumpyield.
Native channel method entries: Wump::Channel::close, Wump::Channel::recv, Wump::Channel::send.
