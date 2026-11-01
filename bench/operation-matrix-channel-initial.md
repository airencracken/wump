# Common operation matrix

Initial native-channel/TEMP-ownership build, before numeric and yield context
refinements. The [unchanged 10% check](operation-matrix-channel-initial-check.txt)
fails arithmetic work on one/two/four slots (+15.33%/+10.28%/+21.09%) and one-slot
process time (+10.06%). These failures remain part of the record. See the
[numeric follow-up](native-channel-arithmetic.md) and
[latest capture](operation-matrix-channel-current.md). This is not the default baseline.

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.1 | 47.6 | 30.5 | 20.5 | 63.1 | 47.9 | 51.7 | 36.3 | 204.5 | 103.3 | 63.4 | 3.1 | 1.3 | 1.2 |
| calls | 151.8 | 161.9 | 86.4 | 50.3 | 176.7 | 108.0 | 83.9 | 505.8 | 795.3 | 735.8 | 894.6 | 5.1 | 2.8 | 1.9 |
| arrays | 345.6 | 354.9 | 182.4 | 103.4 | 367.3 | 202.4 | 139.4 | 990.6 | 2121.6 | 1095.6 | 696.7 | 21.7 | 15.9 | 14.6 |
| hashes | 239.9 | 247.0 | 128.8 | 74.7 | 259.8 | 146.2 | 109.8 | 672.3 | 4159.2 | 4396.5 | 5623.2 | 70.5 | 38.3 | 24.2 |
| strings | 140.2 | 142.1 | 76.7 | 43.8 | 165.7 | 100.2 | 78.4 | 250.9 | 583.8 | 304.2 | 195.1 | 22.6 | 14.5 | 11.7 |
| regex | 547.7 | 561.8 | 288.8 | 161.2 | 574.6 | 306.4 | 196.6 | 1087.3 | 1674.6 | 861.5 | 502.5 | 324.9 | 166.5 | 106.6 |
| utf8 | 534.1 | 547.9 | 283.9 | 156.3 | 557.1 | 304.7 | 188.5 | 1288.1 | 2730.8 | 4138.7 | 4430.1 | 18.4 | 12.8 | 9.8 |
| json | 6049.1 | 6067.1 | 3022.0 | 1774.8 | 5936.7 | 3053.2 | 1781.2 | 19528.1 | 45656.9 | N/A | N/A | 451.1 | 236.4 | 140.8 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 192.7 | 342.4 | 673.8 | 407.5 | 829.9 | 888.3 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 19590.2 | 19208.5 | 20555.5 | 1380.7 | 768.4 | 764.9 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 5477.6 | 17550.8 | 19655.7 | 988.9 | 1508.5 | 1544.5 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.95x | 5.37x | 1.66x | 65.22x | 53.18x |
| calls | 3.33x | 5.24x | 5.89x | 156.21x | 471.68x |
| arrays | 2.87x | 6.14x | 2.02x | 97.69x | 47.68x |
| hashes | 2.80x | 17.34x | 23.44x | 59.02x | 232.35x |
| strings | 1.79x | 4.16x | 1.39x | 25.86x | 16.66x |
| regex | 1.99x | 3.06x | 0.92x | 5.15x | 4.71x |
| utf8 | 2.41x | 5.11x | 8.29x | 148.06x | 452.21x |
| json | 3.23x | 7.55x | N/A | 101.22x | N/A |
| yield | N/A | N/A | N/A | 0.47x | 0.76x |
| spawn | N/A | N/A | N/A | 14.19x | 26.87x |
| channel | N/A | N/A | N/A | 5.54x | 12.73x |

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

Public Wump syntax; native operations in the compiled worker: wumpact, wumpchan, wumpyield.
Native channel method entries: Wump::Channel::close, Wump::Channel::recv, Wump::Channel::send.
