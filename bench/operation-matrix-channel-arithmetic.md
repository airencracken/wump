# Common operation matrix

Numeric-context refinement, before the final native-yield refinement.
Arithmetic returns within the unchanged 10% budget, but the
[comparison](operation-matrix-channel-arithmetic-check.txt) fails two-slot yield
work at +17.15%. See the [yield follow-up](native-channel-yield.md) and
[latest capture](operation-matrix-channel-current.md). This is not the default baseline.

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.1 | 46.3 | 27.4 | 19.0 | 61.8 | 46.3 | 52.8 | 36.3 | 183.6 | 97.6 | 56.5 | 2.9 | 1.0 | 1.3 |
| calls | 151.5 | 160.4 | 83.9 | 49.3 | 174.6 | 104.0 | 80.7 | 503.9 | 788.1 | 716.5 | 849.0 | 4.2 | 2.1 | 1.9 |
| arrays | 343.9 | 352.2 | 182.0 | 102.0 | 365.4 | 198.7 | 134.6 | 962.0 | 2058.4 | 1043.5 | 652.2 | 23.0 | 15.0 | 14.8 |
| hashes | 235.8 | 251.5 | 129.4 | 72.4 | 260.7 | 145.9 | 105.5 | 678.5 | 4157.1 | 4321.4 | 5564.5 | 67.5 | 38.0 | 27.4 |
| strings | 140.2 | 142.9 | 75.1 | 51.9 | 163.3 | 100.2 | 80.4 | 248.4 | 557.6 | 289.2 | 195.2 | 21.9 | 14.4 | 9.8 |
| regex | 547.3 | 552.2 | 291.1 | 162.1 | 568.1 | 304.4 | 196.0 | 1085.4 | 1668.8 | 848.0 | 476.7 | 318.6 | 167.0 | 106.2 |
| utf8 | 536.1 | 543.2 | 279.6 | 155.4 | 556.1 | 301.3 | 191.6 | 1281.2 | 2677.8 | 4145.7 | 4348.0 | 18.3 | 13.1 | 9.9 |
| json | 6067.3 | 6024.4 | 3010.1 | 1692.8 | 5855.5 | 3002.1 | 1722.3 | 19509.3 | 45336.8 | N/A | N/A | 449.5 | 234.8 | 136.7 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 192.2 | 392.7 | 721.2 | 407.9 | 856.3 | 933.4 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 19546.3 | 19165.7 | 20369.2 | 1369.6 | 761.8 | 740.6 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 5340.8 | 17701.1 | 19871.0 | 994.2 | 1556.8 | 1479.2 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.95x | 4.82x | 1.48x | 63.12x | 45.01x |
| calls | 3.33x | 5.20x | 5.60x | 189.52x | 454.67x |
| arrays | 2.80x | 5.99x | 1.90x | 89.60x | 44.01x |
| hashes | 2.88x | 17.63x | 23.60x | 61.57x | 203.09x |
| strings | 1.77x | 3.98x | 1.39x | 25.42x | 20.01x |
| regex | 1.98x | 3.05x | 0.87x | 5.24x | 4.49x |
| utf8 | 2.39x | 4.99x | 8.11x | 146.31x | 439.02x |
| json | 3.22x | 7.47x | N/A | 100.85x | N/A |
| yield | N/A | N/A | N/A | 0.47x | 0.77x |
| spawn | N/A | N/A | N/A | 14.27x | 27.50x |
| channel | N/A | N/A | N/A | 5.37x | 13.43x |

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
CPU affinity: 0,2,4,6. Source: 6b2da796a7e5604707d6bf8f4837f55d507c66ce (clean).

Public Wump syntax; native operations in the compiled worker: wumpact, wumpchan, wumpyield.
Native channel method entries: Wump::Channel::close, Wump::Channel::recv, Wump::Channel::send.
