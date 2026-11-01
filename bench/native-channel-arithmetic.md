# Numeric context follow-up

The first native-channel matrix capture failed arithmetic on one/two/four
slots (+15.33%/+10.28%/+21.09% work) and one-slot process time (+10.06%).
[Its complete check](operation-matrix-channel-initial-check.txt) remains saved.

Numeric admission repeatedly selected opcode, phase and operand-stack state
through TLS getters. The revised bounded C path reads fields owned by its act
once, using interpreter fields for the main act. It cannot invoke Perl or
suspend in that region. Input/range validation, writer exclusion and dynamic
executor allocation/reader selection remain unchanged.

The two comparisons below have different before binaries and work sizes.
They must not be pooled. Units are arithmetic loop iterations, not isolated
machine additions; every worker's result is checked independently.

The larger probe compares the initial native-channel build against the numeric
context refinement. The short probe compares the original native-yield anchor
against that refinement at the full matrix's iteration count. Later native
yield changes are measured separately. These probes do not erase a failing
full-matrix check; see the [latest matrix](operation-matrix-channel-current.md).

## Initial channel build to numeric refinement, 500000 iterations

Seven interleaved runs; 500000 iterations per worker; CPU affinity `0,2,4,6`.
Source `6b2da796a7e5604707d6bf8f4837f55d507c66ce` (clean). Each arithmetic sample has eight verified jobs;
yield samples count one main act's operations. Slot count configures the scheduler.

| Slots | Before, ns/unit | After, ns/unit | Change | Before range | After range |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 197.316 | 183.763 | -6.869% | 196.818-197.482 | 182.548-184.930 |
| 2 | 99.603 | 93.501 | -6.127% | 98.470-100.570 | 92.508-94.144 |
| 4 | 53.385 | 51.106 | -4.270% | 52.258-55.682 | 48.734-52.301 |

| Slots | Before process median, ms | After process median, ms |
| ---: | ---: | ---: |
| 1 | 830.793 | 775.869 |
| 2 | 439.893 | 414.290 |
| 4 | 253.598 | 245.102 |

All 42 [raw samples](native-channel-arithmetic.jsonl), binary/configuration identities and
exact capture runner in the [machine record](native-channel-arithmetic-machine.json).
Raw SHA256: `3e060c3f793226b733f934cc83aec89b2085722b62edb9572d031a3f75bf3f5f`.

## Native-yield anchor to numeric refinement, 50000 iterations

Seven interleaved runs; 50000 iterations per worker; CPU affinity `0,2,4,6`.
Source `6b2da796a7e5604707d6bf8f4837f55d507c66ce` (clean). Each arithmetic sample has eight verified jobs;
yield samples count one main act's operations. Slot count configures the scheduler.

| Slots | Before, ns/unit | After, ns/unit | Change | Before range | After range |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 177.902 | 184.022 | +3.440% | 176.341-179.541 | 183.020-185.498 |
| 2 | 92.997 | 96.278 | +3.527% | 91.281-96.362 | 94.627-97.846 |
| 4 | 54.182 | 52.323 | -3.431% | 49.894-59.765 | 51.443-53.717 |

| Slots | Before process median, ms | After process median, ms |
| ---: | ---: | ---: |
| 1 | 111.631 | 115.243 |
| 2 | 78.198 | 80.329 |
| 4 | 63.308 | 62.128 |

All 42 [raw samples](native-channel-arithmetic-short.jsonl), binary/configuration identities and
exact capture runner in the [machine record](native-channel-arithmetic-short-machine.json).
Raw SHA256: `6efab734c8d4c9f966434288461f2480cceb205b6163cceb2c470a67710df066`.
