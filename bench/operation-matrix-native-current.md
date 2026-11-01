# Common operation matrix

Native act/channel interpreter using the same public-syntax fixture and controls
as the [preceding baseline](operation-matrix-native-baseline.md). The
[saved check](operation-matrix-native-check.txt) **fails** four-slot yield at
+11.87%; all other work/process cells remain within the 10% budget. Spawn work
falls 1.83%/3.06%/12.73% on one/two/four slots. A
[larger yield follow-up](native-primitives-yield-followup.md) measures +6.86%
on four slots; the cause remains unresolved. This capture is not the default baseline.

Median ns per operation; lower is better.

| Operation | Stock Perl | Fork 1 | Fork 2 | Fork 4 | ithreads 1 | ithreads 2 | ithreads 4 | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.2 | 46.6 | 29.2 | 18.0 | 61.5 | 46.2 | 50.0 | 36.7 | 177.8 | 93.9 | 51.2 | 3.4 | 1.8 | 1.3 |
| calls | 150.8 | 161.6 | 85.2 | 50.5 | 175.0 | 103.3 | 80.9 | 514.9 | 809.5 | 762.4 | 907.4 | 4.7 | 2.9 | 1.8 |
| arrays | 343.3 | 351.1 | 181.8 | 102.9 | 365.3 | 201.3 | 133.3 | 971.5 | 2064.6 | 1073.7 | 684.5 | 23.1 | 15.4 | 13.3 |
| hashes | 236.7 | 243.0 | 129.5 | 73.6 | 263.0 | 150.3 | 106.4 | 679.8 | 4179.0 | 4300.2 | 5670.9 | 69.3 | 39.1 | 24.9 |
| strings | 140.0 | 142.9 | 75.5 | 44.0 | 164.7 | 98.7 | 80.1 | 250.4 | 569.9 | 297.6 | 191.8 | 22.4 | 14.7 | 11.5 |
| regex | 544.2 | 546.2 | 286.4 | 161.3 | 571.1 | 304.4 | 196.2 | 1079.0 | 1670.4 | 854.4 | 488.0 | 317.5 | 172.6 | 102.8 |
| utf8 | 542.5 | 547.0 | 283.6 | 155.6 | 559.1 | 294.8 | 187.8 | 1282.5 | 2723.4 | 4187.2 | 4535.3 | 22.1 | 12.8 | 10.3 |
| json | 6020.7 | 6009.7 | 3006.0 | 1738.6 | 5865.5 | 2982.8 | 1735.3 | 19447.3 | 45421.6 | N/A | N/A | 448.3 | 235.9 | 141.3 |
| yield | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 188.9 | 327.8 | 738.5 | 407.1 | 826.3 | 919.1 |
| spawn | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 23371.7 | 20677.8 | 20636.5 | 1371.3 | 773.1 | 743.9 |
| channel | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | 8239.0 | 25201.4 | 31002.4 | 985.7 | 1483.2 | 1611.5 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.96x | 4.66x | 1.34x | 52.56x | 40.35x |
| calls | 3.41x | 5.37x | 6.02x | 173.62x | 511.18x |
| arrays | 2.83x | 6.01x | 1.99x | 89.44x | 51.30x |
| hashes | 2.87x | 17.66x | 23.96x | 60.30x | 227.73x |
| strings | 1.79x | 4.07x | 1.37x | 25.48x | 16.64x |
| regex | 1.98x | 3.07x | 0.90x | 5.26x | 4.75x |
| utf8 | 2.36x | 5.02x | 8.36x | 123.28x | 440.22x |
| json | 3.23x | 7.54x | N/A | 101.32x | N/A |
| yield | N/A | N/A | N/A | 0.46x | 0.80x |
| spawn | N/A | N/A | N/A | 17.04x | 27.74x |
| channel | N/A | N/A | N/A | 8.36x | 19.24x |

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

Public Wump syntax; native operations in the compiled worker: wumpact, wumpchan, wumpyield.
