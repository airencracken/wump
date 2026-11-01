# Common operation matrix

Default v3 baseline: the preceding native-yield interpreter, rerun with the
new public-syntax fixture. This is the before capture, not the new native-act/
channel build. See the [current capture](operation-matrix-native-current.md)
and [saved comparison](operation-matrix-native-check.txt). Its four-slot yield
regression remains open; the current capture has not replaced this baseline.

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.2 | 46.5 | 28.8 | 18.8 | 60.5 | 47.2 | 51.2 | 36.7 | 178.8 | 91.8 | 50.6 | 3.3 | 1.8 | 1.3 |
| calls | 152.0 | 161.1 | 84.9 | 50.7 | 175.0 | 104.5 | 81.0 | 497.9 | 791.5 | 747.8 | 925.4 | 5.0 | 2.9 | 1.2 |
| arrays | 344.9 | 352.6 | 181.5 | 101.5 | 363.6 | 199.6 | 136.2 | 947.5 | 2049.4 | 1063.3 | 658.9 | 23.2 | 15.2 | 12.6 |
| hashes | 236.6 | 245.8 | 127.8 | 72.8 | 258.8 | 149.3 | 107.3 | 639.0 | 4117.0 | 4257.7 | 5647.7 | 69.6 | 39.4 | 25.2 |
| strings | 140.3 | 143.7 | 77.3 | 45.4 | 163.6 | 99.7 | 80.9 | 245.9 | 577.2 | 301.3 | 191.3 | 21.2 | 14.5 | 10.9 |
| regex | 547.0 | 552.7 | 283.5 | 160.5 | 573.7 | 307.1 | 196.4 | 1073.1 | 1657.5 | 854.6 | 499.4 | 319.3 | 163.7 | 105.3 |
| utf8 | 530.6 | 545.8 | 280.1 | 156.7 | 555.8 | 301.7 | 192.7 | 1279.6 | 2666.7 | 4127.8 | 4401.4 | 19.5 | 13.0 | 10.3 |
| json | 5986.4 | 6029.5 | 3003.6 | 1732.5 | 5843.8 | 2991.3 | 1744.4 | 19185.1 | 44041.6 | N/A | N/A | 449.7 | 231.5 | 142.8 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 190.5 | 324.4 | 660.1 | 399.8 | 766.9 | 937.1 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 23806.9 | 21329.9 | 23647.1 | 1387.9 | 759.6 | 749.1 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 8073.8 | 24451.5 | 29838.7 | 992.9 | 1432.4 | 1590.2 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.96x | 4.68x | 1.32x | 54.47x | 40.26x |
| calls | 3.28x | 5.21x | 6.09x | 157.51x | 760.82x |
| arrays | 2.75x | 5.94x | 1.91x | 88.37x | 52.18x |
| hashes | 2.70x | 17.40x | 23.87x | 59.19x | 224.24x |
| strings | 1.75x | 4.12x | 1.36x | 27.28x | 17.59x |
| regex | 1.96x | 3.03x | 0.91x | 5.19x | 4.74x |
| utf8 | 2.41x | 5.03x | 8.30x | 136.61x | 427.74x |
| json | 3.20x | 7.36x | N/A | 97.93x | N/A |
| yield | N/A | N/A | N/A | 0.48x | 0.70x |
| spawn | N/A | N/A | N/A | 17.15x | 31.57x |
| channel | N/A | N/A | N/A | 8.13x | 18.76x |

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
CPU affinity: 0,2,4,6. Source: bc96e1772b9b9d292ec7f24f4aaae4e4523d3f41 (clean).

Public Wump syntax; native operations in the compiled worker: wumpyield.
