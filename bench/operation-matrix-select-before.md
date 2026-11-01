# Common operation matrix

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.1 | 45.6 | 28.2 | 19.2 | 61.8 | 46.3 | 50.0 | 36.8 | 160.2 | 85.5 | 46.3 | 2.8 | 1.8 | 0.8 |
| calls | 151.1 | 160.9 | 85.1 | 50.7 | 173.4 | 103.9 | 82.9 | 493.3 | 765.6 | 608.2 | 695.3 | 5.2 | 2.9 | 1.9 |
| arrays | 343.2 | 351.4 | 182.8 | 103.2 | 367.6 | 200.3 | 133.6 | 989.6 | 2014.6 | 1038.6 | 650.0 | 23.2 | 15.2 | 12.7 |
| hashes | 237.2 | 245.1 | 130.2 | 74.2 | 262.4 | 148.1 | 105.5 | 668.1 | 4161.6 | 4391.3 | 5461.6 | 68.1 | 36.9 | 26.8 |
| strings | 140.1 | 143.3 | 76.7 | 45.3 | 165.4 | 98.1 | 79.6 | 245.8 | 552.8 | 287.6 | 197.4 | 24.3 | 15.8 | 11.5 |
| regex | 541.2 | 550.4 | 284.6 | 159.1 | 576.8 | 306.7 | 195.1 | 1087.5 | 1645.7 | 835.5 | 477.9 | 321.3 | 162.6 | 103.7 |
| utf8 | 537.4 | 548.1 | 280.6 | 155.5 | 555.4 | 296.8 | 189.0 | 1274.7 | 2648.8 | 4123.5 | 4292.0 | 19.4 | 13.7 | 10.0 |
| json | 6029.1 | 6047.7 | 3014.5 | 1673.6 | 5881.2 | 2982.1 | 1703.6 | 19041.4 | 44625.8 | N/A | N/A | 446.3 | 227.9 | 132.4 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 190.3 | 207.4 | 208.2 | 407.2 | 829.4 | 909.8 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 20070.6 | 19298.3 | 20093.4 | 1377.5 | 758.8 | 750.0 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 5449.8 | 17464.4 | 19175.7 | 999.1 | 1464.2 | 1641.6 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.96x | 4.20x | 1.21x | 56.55x | 57.60x |
| calls | 3.27x | 5.07x | 4.60x | 148.16x | 372.91x |
| arrays | 2.88x | 5.87x | 1.89x | 86.76x | 51.25x |
| hashes | 2.82x | 17.55x | 23.03x | 61.15x | 203.63x |
| strings | 1.75x | 3.94x | 1.41x | 22.79x | 17.12x |
| regex | 2.01x | 3.04x | 0.88x | 5.12x | 4.61x |
| utf8 | 2.37x | 4.93x | 7.99x | 136.21x | 431.26x |
| json | 3.16x | 7.40x | N/A | 99.99x | N/A |
| yield | N/A | N/A | N/A | 0.47x | 0.23x |
| spawn | N/A | N/A | N/A | 14.57x | 26.79x |
| channel | N/A | N/A | N/A | 5.45x | 11.68x |

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
