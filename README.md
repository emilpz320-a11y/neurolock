# NeuroLock

**An on-chain neural network that freezes suspicious vault withdrawals before they settle.**
Built for the Reactive Omni Buildathon, track *Reactive Meets AI*. The contracts are named `Sentinel*`; NeuroLock is the project.

## Live on testnet
| | |
|---|---|
| `SentinelVault` (Base Sepolia, chain 84532) | [`0x58067ca3023c9cb88418617f6ec458b87e6e128b`](https://sepolia.basescan.org/address/0x58067ca3023c9cb88418617f6ec458b87e6e128b) |
| `SentinelReactive` (Reactive Lasna, chain 5318007) | [`0xdcaa65afc585d92a43a60b282ec71d03072eb4c3`](https://lasna.reactscan.net/address/0xdcaa65afc585d92a43a60b282ec71d03072eb4c3) |
| Callback proxy used (Base Sepolia) | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |

The full loop, from origin event to callback (recorded in the demo video and in `deployments.json`):

| Step | Chain | Transaction |
|---|---|---|
| 1. Routine request #0: 0.00005 ETH, 5% of the vault | Base Sepolia | [`0xe69dd54b9c167c37…`](https://sepolia.basescan.org/tx/0xe69dd54b9c167c37a098fc2bf30a822278cfde660d130438a62dcb615fb313e5) |
| 2. `react()` scores it: logit −9.93, benign | Reactive Lasna | [`0x421e9d72b60a819f…`](https://lasna.reactscan.net/tx/0x421e9d72b60a819f185f57b478d1b1f4cea61498f2373d517fb171dfb489358e) |
| 3. Drain request #1: 0.0009 ETH, 95% of what is left, to a never-seen address | Base Sepolia | [`0x2025af291c4a983c…`](https://sepolia.basescan.org/tx/0x2025af291c4a983c5977a19bbec26a487f9d1c71f8fc70280eca9977b256c103) |
| 4. `react()` scores it: logit +9.87, anomalous, requests the callback | Reactive Lasna | [`0x95e55edadc770631…`](https://lasna.reactscan.net/tx/0x95e55edadc77063100e54757caabc5f995408208568b670332c942a0e85aba93) |
| 5. `freeze()` callback lands **1 s** after the request (block timestamps) | Base Sepolia | [`0x215c6611785bd86f…`](https://sepolia.basescan.org/tx/0x215c6611785bd86f7e742ada6dbb23e6e5be458539eb85a8b7c8d5fdbf2ea89d) |
| 6. After the 30 s time-lock, request #0 executes; `execute(1)` reverts with `NotPending` | Base Sepolia | [`0x90d1d2afb57818c9…`](https://sepolia.basescan.org/tx/0x90d1d2afb57818c9978b8bb369308e899120b26534ad7560d594a330a500e2cf) |

An earlier run on a first deployment froze the same drain 3 s after the request, so expect 1–3 s end to end.

**Demo video (1:41):** VIDEO_URL

## The problem
Smart-wallet and treasury drains happen in seconds. Time-locks help only if something watches them. Today that watcher is an off-chain bot: a server, an API key, a single point of failure.

## The idea
1. `SentinelVault` (Base Sepolia) makes every withdrawal wait `delay` seconds (30 s in the demo) and emits `WithdrawalRequested`.
2. `SentinelReactive` (Reactive Network) subscribes to that event. In `react()` it builds a 4-feature behavioural profile of the vault:
   - **amount ratio**: amount ÷ free balance;
   - **new recipient**: never paid before and not owner-trusted;
   - **recency**: how soon after the previous request;
   - **velocity**: requests in the last hour.
3. It scores those features with **`SentinelMLP`**, a 4→8→1 ReLU network running *inside the reactive contract* in fixed-point integer math. There is no oracle and no off-chain inference.
4. If the logit is positive, it requests a callback to `SentinelVault.freeze(...)`.

Omni's ~1 s blocks with instant finality let the freeze land well inside the time-lock window. That is the point: the defence is fully on-chain and fast enough to matter.

```
Base Sepolia                     Reactive Network (Omni)                 Base Sepolia
SentinelVault ──WithdrawalRequested──▶ SentinelReactive.react()
                                       ├─ features (ratio, new, recency, velocity)
                                       ├─ SentinelMLP.score()  ← on-chain NN
                                       └─ score > 0 ──callback──▶ SentinelVault.freeze()
```

## The model
- `train/train.py` trains the MLP with numpy on 40k synthetic withdrawals labelled by a reviewer-style risk policy.
- **Validation accuracy: 96.6% (float) → 96.6% after int quantization.** Inputs are scaled by 1e4 and weights by 1e4.
- The script emits `contracts/SentinelMLP.sol` directly, so the deployed weights are reproducible: `npm run train`.

## Security model
- `freeze` uses `onlyServiceProvider` (the Reactive callback proxy) and `onlyCallbackSender(sentinel)`. Nobody else can freeze.
- `react` uses `onlySystem`. Frozen funds stay reserved until the owner reviews them and calls `cancel`.
- `execute` is permissionless after the delay, so the owner cannot be locked out by a stuck bot.
- The owner can whitelist known recipients (`trustRecipient`). Benign scores teach the profile automatically.

## Tests
```bash
npm install
npx hardhat test solidity     # 10 tests: MLP golden vectors, full request → react → callback → freeze loop,
                              # auth on freeze/react, velocity burst detection
```

## Deploy and live demo
```bash
# .env: DEPLOYER_PRIVATE_KEY=0x... funded with ~0.01 Base Sepolia ETH (one Superchain faucet claim)
node --experimental-strip-types scripts/deploy-and-demo.ts faucet   # 0.006 ETH -> 0.6 lREACT on Lasna
node --experimental-strip-types scripts/deploy-and-demo.ts deploy   # sentinel on Lasna, vault on Base Sepolia, subscribe, prepay callbacks
node --experimental-strip-types scripts/deploy-and-demo.ts demo     # benign request passes; drain to a fresh address gets frozen
node --experimental-strip-types scripts/deploy-and-demo.ts settle   # after the time-lock: the benign request executes, the frozen one reverts
```

No Base Sepolia faucet at hand? `scripts/bridge-to-base-sepolia.ts` deposits Sepolia test ETH into Base's `OptimismPortal`.

### Live monitor
`web/index.html` is a dependency-free page that reads both chains over public RPC and shows every request with
the features the network saw, its score, the outcome and links to each transaction:
```bash
npx serve .        # or any static server at the repo root, then open /web/
```
Addresses and transaction hashes are written to `deployments.json`. The deployer in the demo is a throwaway testnet key.

## Layout
- `contracts/SentinelVault.sol`: time-locked vault and callback receiver.
- `contracts/SentinelReactive.sol`: feature extraction, MLP scoring and callback request.
- `contracts/SentinelMLP.sol`: generated network weights.
- `contracts/lib/reactive-lib/`: vendored from Reactive-Network/reactive-lib-omni.
- `train/train.py`: training, quantization and code generation.
- `web/index.html`: live monitor (no build step, no dependencies).
- `scripts/`: deploy, demo and bridge scripts (viem).

## Why the model is on-chain
Other AI entries call a model off-chain and post its verdict. Here the weights are constants in `SentinelMLP.sol`,
the features are computed from the event the Reactive Network delivers, and the decision is taken in the same
`react()` call. Anyone can replay a decision from the `Scored` event (it carries the four features and the logit),
and nobody, including the deployer, can change the verdict of a request after the fact.

## Limits and next steps
- The training set is synthetic (a reviewer-style risk policy), enough to show the mechanism; a production model
  would be trained on labelled drain incidents and re-deployed as a new library.
- One vault per profile; ERC-20 vaults need one more feature (token) and the same loop.
- The vault trusts the sentinel only to freeze. A frozen request can only be cancelled by the owner, never redirected.
- Mainnet path: same contracts on Base and Reactive mainnet with the mainnet callback proxy.

## License
MIT
