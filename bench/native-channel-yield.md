# Native yield context follow-up

The numeric-refinement matrix passed arithmetic but still failed two-slot yield
at +17.15% work time. [That check](operation-matrix-channel-arithmetic-check.txt)
remains recorded. The native handler now avoids loading/writing an unchanged
operand-stack pointer around suspension. Void/list context leaves the stack
untouched; scalar context obtains fresh state after resumption and pushes undef.
The immediate scheduling check reads its act pointer once. Eligibility, metadata
exclusion, operation masks and context results remain unchanged.

The short comparison measures the original native-yield anchor against the
new handler. The larger comparison isolates the handler change against the
numeric-refinement build. Different references, fixtures and work sizes must
not be pooled or used to clear a failed full-matrix gate. A larger probe does
not establish that a short regression was noise. The
[latest matrix](operation-matrix-channel-current.md) reports its own gate status.

Units below are yields in one main act; these are elapsed loop times including
the completion counter. They do not represent several independently yielding
actors or isolated ABI costs. Every completed count is checked.

## Native-yield anchor to new handler, 50000 yields

Seven interleaved runs; 50000 iterations per worker; CPU affinity `0,2,4,6`.
Source `58e749c3dbf60085240ac86606dac58e92351e0d` (clean). Each arithmetic sample has eight verified jobs;
yield samples count one main act's operations. Slot count configures the scheduler.

| Slots | Before, ns/unit | After, ns/unit | Change | Before range | After range |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 190.557 | 188.166 | -1.255% | 189.059-193.804 | 185.501-189.539 |
| 2 | 320.659 | 365.171 | +13.882% | 290.244-380.182 | 312.773-398.955 |
| 4 | 658.290 | 673.575 | +2.322% | 625.048-700.428 | 657.726-707.524 |

| Slots | Before process median, ms | After process median, ms |
| ---: | ---: | ---: |
| 1 | 36.739 | 37.343 |
| 2 | 43.798 | 44.645 |
| 4 | 60.356 | 60.914 |

All 42 [raw samples](native-channel-yield-short.jsonl), binary/configuration identities and
exact capture runner in the [machine record](native-channel-yield-short-machine.json).
Raw SHA256: `624d4df3430c115ce4072828d60bb3790e1f316b46dae59bca0eac75c5a10e2b`.

## Numeric-refinement build to new handler, 2000000 yields

Seven interleaved runs; 2000000 iterations per worker; CPU affinity `0,2,4,6`.
Source `58e749c3dbf60085240ac86606dac58e92351e0d` (clean). Each arithmetic sample has eight verified jobs;
yield samples count one main act's operations. Slot count configures the scheduler.

| Slots | Before, ns/unit | After, ns/unit | Change | Before range | After range |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 189.748 | 186.174 | -1.884% | 188.110-191.536 | 184.136-189.842 |
| 2 | 311.081 | 298.726 | -3.972% | 295.302-331.860 | 283.029-310.396 |
| 4 | 692.177 | 664.538 | -3.993% | 667.568-712.317 | 645.562-687.407 |

| Slots | Before process median, ms | After process median, ms |
| ---: | ---: | ---: |
| 1 | 406.693 | 400.591 |
| 2 | 650.152 | 624.637 |
| 4 | 1411.788 | 1356.379 |

All 42 [raw samples](native-channel-yield-context.jsonl), binary/configuration identities and
exact capture runner in the [machine record](native-channel-yield-context-machine.json).
Raw SHA256: `18b07d16558c5f782fb48f1c9c3b076f13400b538dedcd0f9ddd3fe9b56f7147`.
