# Common operation matrix

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.4 | 46.7 | 27.8 | 19.4 | 61.1 | 47.5 | 50.1 | 36.3 | 159.9 | 82.9 | 46.5 | 3.0 | 1.3 | 1.0 |
| calls | 151.7 | 162.6 | 85.4 | 51.6 | 175.3 | 103.6 | 81.8 | 510.1 | 755.5 | 606.3 | 696.6 | 4.8 | 2.8 | 1.5 |
| arrays | 342.8 | 354.2 | 182.6 | 102.5 | 366.4 | 202.8 | 134.6 | 954.8 | 2001.7 | 1035.0 | 679.3 | 22.7 | 16.3 | 13.8 |
| hashes | 238.5 | 246.9 | 127.8 | 73.7 | 258.4 | 147.9 | 106.2 | 668.8 | 4022.0 | 4360.4 | 5462.1 | 68.0 | 38.6 | 25.2 |
| strings | 140.5 | 143.2 | 76.6 | 44.1 | 164.3 | 97.0 | 77.7 | 238.3 | 544.6 | 287.7 | 187.8 | 21.9 | 15.0 | 10.8 |
| regex | 547.4 | 552.9 | 285.9 | 161.7 | 574.7 | 310.9 | 195.3 | 1079.5 | 1639.3 | 838.2 | 476.7 | 315.8 | 167.9 | 99.5 |
| utf8 | 537.6 | 540.0 | 278.1 | 157.5 | 562.9 | 301.8 | 188.6 | 1257.2 | 2620.3 | 4101.5 | 4315.5 | 18.2 | 13.4 | 9.9 |
| json | 6069.6 | 6022.4 | 3020.4 | 1676.6 | 5888.8 | 3017.0 | 1688.5 | 20100.0 | 53741.8 | 53482.3 | 53641.7 | 450.7 | 235.4 | 139.1 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 190.2 | 207.2 | 207.9 | 409.5 | 812.6 | 915.1 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 19472.2 | 19077.2 | 20088.4 | 1367.9 | 774.0 | 764.4 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 5360.0 | 17480.9 | 19505.9 | 985.4 | 1460.1 | 1418.9 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.95x | 4.17x | 1.21x | 53.77x | 48.53x |
| calls | 3.36x | 4.98x | 4.59x | 157.99x | 475.36x |
| arrays | 2.79x | 5.84x | 1.98x | 88.12x | 49.21x |
| hashes | 2.80x | 16.86x | 22.90x | 59.14x | 216.36x |
| strings | 1.70x | 3.88x | 1.34x | 24.85x | 17.37x |
| regex | 1.97x | 2.99x | 0.87x | 5.19x | 4.79x |
| utf8 | 2.34x | 4.87x | 8.03x | 143.85x | 436.64x |
| json | 3.31x | 8.85x | 8.84x | 119.25x | 385.52x |
| yield | N/A | N/A | N/A | 0.46x | 0.23x |
| spawn | N/A | N/A | N/A | 14.24x | 26.28x |
| channel | N/A | N/A | N/A | 5.44x | 13.75x |

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
CPU affinity: 0,2,4,6. Source: 4365dac8ecd80260e0f189d775d11655a8c08917 (clean).

Public Wump syntax; native operations in the compiled worker: wumpact, wumpchan, wumpyield.
Native channel method entries: Wump::Channel::close, Wump::Channel::recv, Wump::Channel::send.
