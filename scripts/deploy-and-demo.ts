// Deploys Reactive Sentinel to Reactive Lasna + Base Sepolia and runs the two-case demo.
// Usage: node --experimental-strip-types scripts/deploy-and-demo.ts [faucet|deploy|demo|settle]
// Needs DEPLOYER_PRIVATE_KEY in .env, funded with Base Sepolia ETH (and lREACT on Lasna).
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  parseEther,
  formatEther,
  type Abi,
  type Hex,
} from 'viem';
import { baseSepolia } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';

const env = Object.fromEntries(
  readFileSync('.env', 'utf8')
    .split(/\r?\n/)
    .filter((l) => l.includes('='))
    .map((l) => l.split('=') as [string, string])
);
const account = privateKeyToAccount(env.DEPLOYER_PRIVATE_KEY as Hex);

const lasna = defineChain({
  id: 5318007,
  name: 'Reactive Lasna',
  nativeCurrency: { name: 'lREACT', symbol: 'lREACT', decimals: 18 },
  rpcUrls: { default: { http: ['https://lasna-rpc.rnk.dev/'] } },
  blockExplorers: { default: { name: 'Reactscan', url: 'https://lasna.reactscan.net' } },
});

const BASE_SEPOLIA_CALLBACK_PROXY = '0x476F44b11F5C942c58f4c8E3d0300E5710743585';
const BASE_SEPOLIA_LREACT_FAUCET = '0x2afaFD298b23b62760711756088F75B7409f5967';
const VAULT_DELAY_SECONDS = 30n;

const artifact = (name: string) =>
  JSON.parse(readFileSync(`artifacts/contracts/${name}.sol/${name}.json`, 'utf8')) as { abi: Abi; bytecode: Hex };
const vaultArt = artifact('SentinelVault');
const sentinelArt = artifact('SentinelReactive');

const base = {
  pub: createPublicClient({ chain: baseSepolia, transport: http() }),
  wal: createWalletClient({ account, chain: baseSepolia, transport: http() }),
};
const react = {
  pub: createPublicClient({ chain: lasna, transport: http() }),
  wal: createWalletClient({ account, chain: lasna, transport: http() }),
};

// Lasna rejects a zero priority fee, which is what viem estimates on a quiet chain.
const lasnaFees = async () => {
  const tip = 1_000_000_000n;
  return { maxPriorityFeePerGas: tip, maxFeePerGas: (await react.pub.getGasPrice()) * 2n + tip };
};

const state: Record<string, string> = existsSync('deployments.json')
  ? JSON.parse(readFileSync('deployments.json', 'utf8'))
  : {};
const save = () => writeFileSync('deployments.json', JSON.stringify(state, null, 2));
const log = (k: string, v: string) => {
  state[k] = v;
  save();
  console.log(`${k}: ${v}`);
};

async function balances() {
  const [b, r] = await Promise.all([
    base.pub.getBalance({ address: account.address }),
    react.pub.getBalance({ address: account.address }),
  ]);
  console.log(`deployer ${account.address}\n  Base Sepolia ${formatEther(b)} ETH\n  Lasna ${formatEther(r)} lREACT`);
}

async function faucet() {
  // 1 Base Sepolia ETH -> 100 lREACT. 0.006 ETH -> 0.6 lREACT is enough for the demo (fits the 0.01 ETH daily faucet).
  const hash = await base.wal.writeContract({
    address: BASE_SEPOLIA_LREACT_FAUCET,
    abi: [{ type: 'function', name: 'request', stateMutability: 'payable', inputs: [{ name: 'recipient', type: 'address' }], outputs: [] }],
    functionName: 'request',
    args: [account.address],
    value: parseEther('0.006'),
  });
  await base.pub.waitForTransactionReceipt({ hash });
  log('faucetTx', hash);
}

async function deploy() {
  const sentinelHash = await react.wal.deployContract({ abi: sentinelArt.abi, bytecode: sentinelArt.bytecode, value: parseEther('0.3'), ...(await lasnaFees()) });
  const sentinel = (await react.pub.waitForTransactionReceipt({ hash: sentinelHash })).contractAddress!;
  log('sentinel', sentinel);
  log('sentinelDeployTx', sentinelHash);

  const vaultHash = await base.wal.deployContract({
    abi: vaultArt.abi,
    bytecode: vaultArt.bytecode,
    args: [BASE_SEPOLIA_CALLBACK_PROXY, sentinel, VAULT_DELAY_SECONDS],
    value: parseEther('0.001'),
  });
  const vault = (await base.pub.waitForTransactionReceipt({ hash: vaultHash })).contractAddress!;
  log('vault', vault);
  log('vaultDeployTx', vaultHash);

  const watchHash = await react.wal.writeContract({
    address: sentinel,
    abi: sentinelArt.abi,
    functionName: 'watch',
    args: [BigInt(baseSepolia.id), vault],
    ...(await lasnaFees()),
  });
  await react.pub.waitForTransactionReceipt({ hash: watchHash });
  log('watchTx', watchHash);

  // Prepay callback fees for the vault at the Base Sepolia callback proxy.
  const depositHash = await base.wal.writeContract({
    address: BASE_SEPOLIA_CALLBACK_PROXY,
    abi: [{ type: 'function', name: 'depositTo', stateMutability: 'payable', inputs: [{ name: '', type: 'address' }], outputs: [] }],
    functionName: 'depositTo',
    args: [vault],
    value: parseEther('0.0015'),
  });
  await base.pub.waitForTransactionReceipt({ hash: depositHash });
  log('callbackDepositTx', depositHash);
}

async function demo() {
  const vault = state.vault as Hex;
  const friend = '0x000000000000000000000000000000000000F00D';
  const fresh = privateKeyToAccount(('0x' + 'ab'.repeat(32)) as Hex).address; // never-seen recipient

  for (const [label, to, amount] of [
    ['benignRequest', friend, '0.00005'],
    ['drainRequest', fresh, '0.0009'],
  ] as const) {
    const hash = await base.wal.writeContract({
      address: vault,
      abi: vaultArt.abi,
      functionName: 'requestWithdrawal',
      args: [to, parseEther(amount)],
    });
    await base.pub.waitForTransactionReceipt({ hash });
    log(`${label}Tx`, hash);
    if (label === 'benignRequest') await new Promise((r) => setTimeout(r, 8000)); // let the first one be scored on its own
  }

  console.log('Waiting for the sentinel callback (Omni ~1s blocks + relay)...');
  const frozenEvent = vaultArt.abi.find((x) => x.type === 'event' && x.name === 'WithdrawalFrozen');
  const requested = await base.pub.getTransactionReceipt({ hash: state.drainRequestTx as Hex });
  const requestedAt = (await base.pub.getBlock({ blockNumber: requested.blockNumber })).timestamp;
  // Public Base Sepolia RPCs cap eth_getLogs at 200 blocks (40 s of 200 ms blocks), so scan forward in windows.
  let from = requested.blockNumber;
  for (let i = 0; i < 60; i++) {
    const head = await base.pub.getBlockNumber();
    while (from <= head) {
      const to = from + 199n < head ? from + 199n : head;
      const logs = await base.pub.getLogs({ address: vault, event: frozenEvent as never, fromBlock: from, toBlock: to });
      if (logs.length > 0) {
        const frozenAt = (await base.pub.getBlock({ blockNumber: logs[0]!.blockNumber! })).timestamp;
        log('freezeCallbackTx', logs[0]!.transactionHash!);
        log('freezeLatencySeconds', String(frozenAt - requestedAt));
        return;
      }
      from = to + 1n;
    }
    await new Promise((r) => setTimeout(r, 1500));
  }
  console.log('No freeze seen yet; check Reactscan for the Scored event.');
}

// After the time-lock: the benign request settles, the frozen one cannot.
async function settle() {
  const vault = state.vault as Hex;
  const hash = await base.wal.writeContract({ address: vault, abi: vaultArt.abi, functionName: 'execute', args: [0n] });
  await base.pub.waitForTransactionReceipt({ hash });
  log('benignExecuteTx', hash);
  try {
    await base.pub.simulateContract({ account, address: vault, abi: vaultArt.abi, functionName: 'execute', args: [1n] });
    console.log('WARNING: the frozen request is still executable');
  } catch {
    log('drainExecuteBlocked', 'execute(1) reverts with NotPending: the frozen withdrawal cannot settle');
  }
}

const cmd = process.argv[2] ?? 'balances';
await balances();
if (cmd === 'faucet') await faucet();
if (cmd === 'deploy') await deploy();
if (cmd === 'demo') await demo();
if (cmd === 'settle') await settle();
