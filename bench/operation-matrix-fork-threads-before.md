# Common operation matrix

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.5 | 47.1 | 27.3 | 17.9 | 58.9 | 43.9 | 42.8 | 36.8 | 182.1 | 94.1 | 52.8 | 2.6 | 1.8 | 1.2 |
| calls | 150.6 | 159.7 | 84.7 | 51.1 | 172.5 | 99.2 | 74.2 | 500.3 | 783.3 | 758.3 | 919.1 | 4.6 | 2.8 | 2.0 |
| arrays | 342.9 | 352.8 | 183.1 | 103.0 | 360.2 | 195.3 | 125.5 | 950.0 | 2030.6 | 1060.6 | 680.4 | 22.8 | 16.6 | 13.9 |
| hashes | 237.2 | 243.0 | 127.2 | 73.7 | 256.4 | 145.4 | 100.7 | 647.1 | 4094.4 | 4531.8 | 5589.4 | 67.5 | 38.4 | 23.9 |
| strings | 140.2 | 142.9 | 75.3 | 45.0 | 160.6 | 94.3 | 72.0 | 257.6 | 580.2 | 300.3 | 191.7 | 21.9 | 14.7 | 11.7 |
| regex | 539.9 | 552.3 | 283.6 | 161.2 | 570.1 | 302.0 | 186.4 | 1062.0 | 1647.7 | 834.8 | 479.5 | 317.9 | 164.7 | 107.5 |
| utf8 | 536.3 | 546.7 | 279.8 | 155.3 | 558.2 | 297.3 | 180.1 | 1276.6 | 2676.7 | 4182.1 | 4487.7 | 18.9 | 13.7 | 10.3 |
| json | 6122.9 | 6062.1 | 3057.5 | 1701.2 | 5866.9 | 2980.6 | 1692.7 | 19085.1 | 44750.7 | N/A | N/A | 448.5 | 232.1 | 135.2 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 599.8 | 928.1 | 3088.8 | 403.5 | 841.3 | 918.9 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 27039.0 | 22749.7 | 26030.1 | 1391.8 | 759.9 | 765.1 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 7979.7 | 24857.4 | 29452.1 | 995.4 | 1460.2 | 1673.9 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.95x | 4.72x | 1.37x | 70.36x | 44.17x |
| calls | 3.32x | 5.20x | 6.10x | 171.01x | 467.50x |
| arrays | 2.77x | 5.92x | 1.98x | 89.07x | 48.99x |
| hashes | 2.73x | 17.26x | 23.56x | 60.68x | 234.18x |
| strings | 1.84x | 4.14x | 1.37x | 26.49x | 16.41x |
| regex | 1.97x | 3.05x | 0.89x | 5.18x | 4.46x |
| utf8 | 2.38x | 4.99x | 8.37x | 141.86x | 434.69x |
| json | 3.12x | 7.31x | N/A | 99.77x | N/A |
| yield | N/A | N/A | N/A | 1.49x | 3.36x |
| spawn | N/A | N/A | N/A | 19.43x | 34.02x |
| channel | N/A | N/A | N/A | 8.02x | 17.59x |

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
