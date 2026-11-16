// Bridges Sepolia test ETH to Base Sepolia by depositing into Base's OptimismPortal on L1.
// Usage: node --experimental-strip-types scripts/bridge-to-base-sepolia.ts <amountEth>
import { readFileSync } from 'node:fs';
import { createPublicClient, createWalletClient, http, parseEther, formatEther, type Hex } from 'viem';
import { sepolia } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';

const env = Object.fromEntries(
  readFileSync('.env', 'utf8').split(/\r?\n/).filter((l) => l.includes('=')).map((l) => l.split('=') as [string, string])
);
const account = privateKeyToAccount(env.DEPLOYER_PRIVATE_KEY as Hex);
const BASE_SEPOLIA_PORTAL = '0x49f53e41452C74589E85cA1677426Ba426459e85';
const transport = http('https://ethereum-sepolia-rpc.publicnode.com');
const pub = createPublicClient({ chain: sepolia, transport });
const wal = createWalletClient({ account, chain: sepolia, transport });

const amount = parseEther(process.argv[2] ?? '0.04');
const hash = await wal.sendTransaction({ to: BASE_SEPOLIA_PORTAL, value: amount, gas: 200000n });
const receipt = await pub.waitForTransactionReceipt({ hash });
console.log(`deposit ${formatEther(amount)} ETH tx ${hash} status ${receipt.status}`);
