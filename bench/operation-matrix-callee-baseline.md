# Common operation matrix

Fixed performance anchor for the Perl-for-Wump call-resolution checkpoint:
the preceding native-channel/context binary (core source `58e749c`, published
checkpoint `cdc9f24`), rerun with the same current fixture as the
[candidate](operation-matrix-callee-current.md). Both captures retain five
runs, 50,000 iterations, eight jobs, CPU mask `0,2,4,6`, and all 770 samples
(640 timed, 130 N/A). Binary hashes identify the executables independently
of the fixture checkout revision. This is the default timing baseline;
the cold-cache correctness regression separately fails on this older core.

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.1 | 47.6 | 28.4 | 18.6 | 61.4 | 47.3 | 52.4 | 36.8 | 174.8 | 91.2 | 51.6 | 3.1 | 1.8 | 1.2 |
| calls | 152.0 | 160.8 | 85.9 | 51.7 | 175.3 | 104.7 | 83.0 | 498.2 | 769.6 | 720.5 | 880.2 | 5.3 | 2.9 | 1.8 |
| arrays | 345.2 | 352.0 | 183.3 | 104.6 | 367.7 | 202.8 | 142.4 | 980.6 | 2034.7 | 1036.8 | 671.2 | 22.8 | 15.2 | 12.9 |
| hashes | 235.3 | 245.1 | 129.0 | 73.6 | 267.3 | 150.4 | 106.1 | 673.1 | 4136.3 | 4323.3 | 5542.7 | 70.1 | 37.8 | 24.7 |
| strings | 140.8 | 142.1 | 75.7 | 44.1 | 163.8 | 101.3 | 77.6 | 252.5 | 549.7 | 292.4 | 199.4 | 22.0 | 16.5 | 11.5 |
| regex | 546.6 | 550.7 | 286.4 | 163.0 | 568.4 | 310.2 | 192.9 | 1089.3 | 1660.0 | 842.6 | 487.4 | 323.5 | 173.4 | 117.9 |
| utf8 | 543.8 | 555.5 | 284.8 | 157.9 | 560.5 | 301.7 | 188.4 | 1295.5 | 2663.8 | 4171.7 | 4366.8 | 19.6 | 13.0 | 10.1 |
| json | 6084.7 | 6065.2 | 3026.7 | 1813.8 | 5895.3 | 3029.2 | 1759.0 | 19426.1 | 45265.2 | N/A | N/A | 446.0 | 232.8 | 144.8 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 184.4 | 327.3 | 722.2 | 406.8 | 847.9 | 920.7 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 19653.1 | 19411.4 | 20444.9 | 1390.3 | 783.6 | 774.9 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 5436.6 | 17665.2 | 19609.1 | 985.5 | 1486.3 | 1565.9 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.97x | 4.59x | 1.36x | 56.70x | 44.38x |
| calls | 3.28x | 5.06x | 5.79x | 144.25x | 495.11x |
| arrays | 2.84x | 5.89x | 1.94x | 89.22x | 52.07x |
| hashes | 2.86x | 17.58x | 23.56x | 58.99x | 224.02x |
| strings | 1.79x | 3.90x | 1.42x | 25.03x | 17.27x |
| regex | 1.99x | 3.04x | 0.89x | 5.13x | 4.14x |
| utf8 | 2.38x | 4.90x | 8.03x | 135.74x | 431.45x |
| json | 3.19x | 7.44x | N/A | 101.50x | N/A |
| yield | N/A | N/A | N/A | 0.45x | 0.78x |
| spawn | N/A | N/A | N/A | 14.14x | 26.38x |
| channel | N/A | N/A | N/A | 5.52x | 12.52x |

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
CPU affinity: 0,2,4,6. Source: d048fe53514a68c6152eb0861ea15a318b845e93 (clean).

Public Wump syntax; native operations in the compiled worker: wumpact, wumpchan, wumpyield.
Native channel method entries: Wump::Channel::close, Wump::Channel::recv, Wump::Channel::send.
