# Common operation matrix

Median ns per operation; lower is better.

Values divide elapsed wall time by total completed work. Multi-slot columns
describe aggregate throughput, not individual operation latency.

| Operation | Stock Perl | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 38.3 | 36.8 | 181.4 | 95.9 | 55.0 | 2.9 | 1.8 | 1.3 |
| calls | 151.5 | 498.5 | 779.5 | 763.2 | 893.2 | 4.9 | 2.4 | 1.9 |
| arrays | 343.3 | 947.0 | 2035.2 | 1057.7 | 664.0 | 23.6 | 14.4 | 13.3 |
| hashes | 235.0 | 652.9 | 4114.2 | 4443.5 | 5713.6 | 67.2 | 36.6 | 23.5 |
| strings | 139.5 | 262.1 | 576.7 | 299.6 | 202.6 | 22.4 | 16.0 | 11.1 |
| regex | 544.9 | 1069.1 | 1649.8 | 848.5 | 499.4 | 319.1 | 165.3 | 113.3 |
| utf8 | 540.7 | 1273.9 | 2698.9 | 4175.1 | 4606.1 | 19.7 | 13.6 | 9.9 |
| json | 5995.8 | 18979.1 | 44719.5 | N/A | N/A | 455.0 | 236.4 | 136.0 |
| yield | N/A | N/A | 596.6 | 943.9 | 3374.1 | 409.4 | 854.1 | 912.0 |
| spawn | N/A | N/A | 27343.5 | 22872.9 | 25913.8 | 1382.9 | 747.9 | 750.8 |
| channel | N/A | N/A | 7969.2 | 23864.1 | 28901.1 | 990.5 | 1438.3 | 1545.1 |

Time ratios; below 1.0 means Wump takes less time than that control.

| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 0.96x | 4.74x | 1.44x | 61.65x | 43.96x |
| calls | 3.29x | 5.15x | 5.90x | 158.06x | 480.38x |
| arrays | 2.76x | 5.93x | 1.93x | 86.31x | 49.99x |
| hashes | 2.78x | 17.50x | 24.31x | 61.20x | 243.47x |
| strings | 1.88x | 4.13x | 1.45x | 25.71x | 18.20x |
| regex | 1.96x | 3.03x | 0.92x | 5.17x | 4.41x |
| utf8 | 2.36x | 4.99x | 8.52x | 137.09x | 464.19x |
| json | 3.17x | 7.46x | N/A | 98.29x | N/A |
| yield | N/A | N/A | N/A | 1.46x | 3.70x |
| spawn | N/A | N/A | N/A | 19.77x | 34.51x |
| channel | N/A | N/A | N/A | 8.05x | 18.70x |

N/A means unavailable, never a zero-cost operation:

- json / wump-2: parallel XS admission: utf8::encode
- json / wump-4: parallel XS admission: utf8::encode
- yield / stock: no coroutine runtime in this mode
- yield / wump-unused: no coroutine runtime in this mode
- spawn / stock: no coroutine runtime in this mode
- spawn / wump-unused: no coroutine runtime in this mode
- channel / stock: no coroutine runtime in this mode
- channel / wump-unused: no coroutine runtime in this mode

5 rotated runs; 50000 iterations; 8 independent jobs for common operations.
CPU affinity: 0,2,4,6. Source: f25cfbe036b4489325f0acf2bcb07e1d15d42de5 (clean).
