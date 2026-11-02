# Common operation matrix

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.2 | 47.4 | 28.7 | 18.6 | 60.4 | 47.2 | 52.1 | 36.8 | 166.0 | 87.9 | 47.8 | 2.5 | 1.7 | 1.2 |
| calls | 151.3 | 160.3 | 86.4 | 52.3 | 174.3 | 104.0 | 80.7 | 516.5 | 756.8 | 608.6 | 689.9 | 4.4 | 2.8 | 1.7 |
| arrays | 343.4 | 350.8 | 181.1 | 102.9 | 367.1 | 200.3 | 138.9 | 962.5 | 1990.0 | 1041.4 | 653.3 | 23.3 | 15.5 | 13.1 |
| hashes | 236.9 | 246.5 | 129.6 | 73.1 | 261.0 | 146.3 | 105.8 | 674.6 | 3885.0 | 3628.1 | 4356.0 | 70.0 | 37.9 | 24.1 |
| strings | 140.4 | 142.4 | 75.3 | 45.7 | 162.9 | 98.1 | 78.9 | 255.3 | 541.4 | 285.6 | 192.1 | 23.1 | 16.3 | 11.6 |
| regex | 552.6 | 558.1 | 280.8 | 159.6 | 565.9 | 304.5 | 194.5 | 1099.7 | 1694.0 | 857.2 | 494.0 | 318.8 | 169.0 | 106.7 |
| utf8 | 537.4 | 542.0 | 278.0 | 156.5 | 564.7 | 304.3 | 190.2 | 1276.5 | 2625.1 | 3690.8 | 3804.0 | 21.6 | 14.0 | 10.2 |
| json | 6048.2 | 5956.8 | 3040.8 | 1756.3 | 5876.1 | 2992.4 | 1733.0 | 20429.0 | 48500.3 | 42346.4 | 40486.0 | 446.9 | 238.5 | 144.3 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 185.5 | 203.6 | 206.4 | 406.7 | 833.8 | 915.8 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 19365.2 | 18852.0 | 19885.4 | 1371.2 | 761.9 | 741.5 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 5270.3 | 17103.8 | 19399.4 | 981.9 | 1537.9 | 1593.6 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.96x | 4.34x | 1.25x | 66.73x | 40.72x |
| calls | 3.41x | 5.00x | 4.56x | 172.59x | 406.23x |
| arrays | 2.80x | 5.80x | 1.90x | 85.35x | 49.71x |
| hashes | 2.85x | 16.40x | 18.39x | 55.54x | 180.96x |
| strings | 1.82x | 3.86x | 1.37x | 23.40x | 16.59x |
| regex | 1.99x | 3.07x | 0.89x | 5.31x | 4.63x |
| utf8 | 2.38x | 4.89x | 7.08x | 121.43x | 374.15x |
| json | 3.38x | 8.02x | 6.69x | 108.53x | 280.55x |
| yield | N/A | N/A | N/A | 0.46x | 0.23x |
| spawn | N/A | N/A | N/A | 14.12x | 26.82x |
| channel | N/A | N/A | N/A | 5.37x | 12.17x |

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
CPU affinity: 0,2,4,6. Source: 193914b6bbcf0682dad8760820fa63fb94c6f8ee (clean).

Public Wump syntax; native operations in the compiled worker: wumpact, wumpchan, wumpyield.
Native channel method entries: Wump::Channel::close, Wump::Channel::recv, Wump::Channel::send.
