# Common operation matrix

Fixed anchor for the native-channel continuation: the original native-yield
interpreter, rerun with the same new fixture, controls, work sizes and CPU mask
as the [latest capture](operation-matrix-channel-current.md). It records native
yield and no native channel methods. The default checker retains this anchor.

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.1 | 47.6 | 27.7 | 19.5 | 61.1 | 47.5 | 51.2 | 39.4 | 177.3 | 93.7 | 52.4 | 3.0 | 1.8 | 1.3 |
| calls | 151.4 | 159.4 | 85.9 | 49.8 | 173.7 | 107.8 | 81.7 | 494.5 | 785.9 | 764.8 | 940.8 | 4.7 | 2.8 | 1.7 |
| arrays | 343.2 | 353.1 | 181.1 | 103.7 | 366.0 | 201.4 | 135.2 | 950.8 | 2052.3 | 1050.1 | 672.2 | 22.5 | 13.6 | 13.0 |
| hashes | 235.8 | 247.2 | 127.9 | 71.9 | 258.2 | 147.3 | 105.2 | 626.0 | 4116.5 | 4408.3 | 5671.2 | 70.0 | 38.7 | 24.6 |
| strings | 138.1 | 142.3 | 76.5 | 45.3 | 163.6 | 98.3 | 77.9 | 251.3 | 582.1 | 306.8 | 202.6 | 21.9 | 14.8 | 11.5 |
| regex | 548.8 | 553.8 | 284.9 | 163.5 | 574.5 | 307.0 | 197.6 | 1077.9 | 1685.7 | 846.7 | 478.1 | 321.0 | 175.7 | 105.0 |
| utf8 | 536.2 | 545.8 | 280.3 | 157.3 | 553.6 | 300.5 | 191.1 | 1277.6 | 2661.4 | 4163.6 | 4431.9 | 20.8 | 14.0 | 8.7 |
| json | 6034.7 | 6064.4 | 3040.2 | 1775.4 | 5915.0 | 3029.4 | 1796.9 | 19080.6 | 44558.4 | N/A | N/A | 450.2 | 236.8 | 131.4 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 190.5 | 335.2 | 666.9 | 405.7 | 816.6 | 938.2 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 23769.4 | 21417.6 | 24051.5 | 1388.1 | 750.2 | 772.0 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 8156.4 | 24673.9 | 28823.6 | 985.5 | 1417.0 | 1479.6 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 1.03x | 4.65x | 1.37x | 59.06x | 41.52x |
| calls | 3.27x | 5.19x | 6.21x | 168.40x | 541.72x |
| arrays | 2.77x | 5.98x | 1.96x | 91.24x | 51.72x |
| hashes | 2.66x | 17.46x | 24.05x | 58.77x | 230.44x |
| strings | 1.82x | 4.21x | 1.47x | 26.60x | 17.58x |
| regex | 1.96x | 3.07x | 0.87x | 5.25x | 4.55x |
| utf8 | 2.38x | 4.96x | 8.26x | 128.16x | 512.30x |
| json | 3.16x | 7.38x | N/A | 98.98x | N/A |
| yield | N/A | N/A | N/A | 0.47x | 0.71x |
| spawn | N/A | N/A | N/A | 17.12x | 31.15x |
| channel | N/A | N/A | N/A | 8.28x | 19.48x |

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
CPU affinity: 0,2,4,6. Source: a9f86a0a614ee5c3123e56d657437b84db0ae6e9 (clean).

Public Wump syntax; native operations in the compiled worker: wumpyield.
Native channel method entries: none (compatibility wrappers).
