# Common operation matrix

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.2 | 46.8 | 27.8 | 18.2 | 57.6 | 43.1 | 43.7 | 36.8 | 183.3 | 97.2 | 53.8 | 2.5 | 1.8 | 1.3 |
| calls | 152.1 | 160.0 | 85.8 | 49.7 | 172.0 | 100.2 | 75.7 | 498.3 | 777.5 | 741.7 | 909.2 | 4.7 | 2.8 | 1.9 |
| arrays | 343.8 | 352.3 | 181.3 | 102.7 | 360.8 | 198.0 | 127.1 | 943.1 | 2043.6 | 1053.8 | 669.5 | 22.7 | 15.1 | 14.0 |
| hashes | 237.0 | 245.7 | 127.5 | 73.9 | 258.8 | 141.7 | 95.1 | 637.5 | 4056.6 | 4404.8 | 5551.0 | 70.1 | 39.3 | 25.5 |
| strings | 140.1 | 142.0 | 76.2 | 46.0 | 160.7 | 94.2 | 73.2 | 246.0 | 574.0 | 299.1 | 194.0 | 24.0 | 15.3 | 11.0 |
| regex | 545.5 | 554.4 | 285.8 | 160.2 | 565.8 | 302.6 | 187.1 | 1069.9 | 1676.9 | 839.9 | 475.5 | 316.0 | 172.0 | 101.0 |
| utf8 | 541.4 | 548.0 | 277.0 | 158.3 | 557.6 | 297.4 | 181.6 | 1268.5 | 2657.9 | 4158.2 | 4445.6 | 20.2 | 12.5 | 9.6 |
| json | 6116.1 | 6010.5 | 3075.9 | 1693.1 | 5889.0 | 2988.1 | 1702.3 | 18934.7 | 44593.6 | N/A | N/A | 447.7 | 231.9 | 130.2 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 596.9 | 916.2 | 3397.5 | 409.7 | 797.4 | 917.2 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 23608.9 | 21336.6 | 23927.9 | 1377.8 | 760.8 | 746.7 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 7917.4 | 24450.9 | 30197.6 | 994.3 | 1567.4 | 1429.7 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.96x | 4.80x | 1.41x | 72.54x | 41.84x |
| calls | 3.28x | 5.11x | 5.98x | 166.55x | 480.35x |
| arrays | 2.74x | 5.94x | 1.95x | 90.21x | 47.73x |
| hashes | 2.69x | 17.11x | 23.42x | 57.84x | 217.73x |
| strings | 1.76x | 4.10x | 1.38x | 23.95x | 17.66x |
| regex | 1.96x | 3.07x | 0.87x | 5.31x | 4.71x |
| utf8 | 2.34x | 4.91x | 8.21x | 131.78x | 460.89x |
| json | 3.10x | 7.29x | N/A | 99.60x | N/A |
| yield | N/A | N/A | N/A | 1.46x | 3.70x |
| spawn | N/A | N/A | N/A | 17.14x | 32.05x |
| channel | N/A | N/A | N/A | 7.96x | 21.12x |

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
CPU affinity: 0,2,4,6. Source: 4ca06aa1035b236a9cde5a1bdb94ebd6355feb79 (clean).
