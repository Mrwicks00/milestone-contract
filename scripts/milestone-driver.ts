/**
 * MilestoneXYZ Driver Script
 * 
 * Usage:
 *   npx tsx scripts/milestone-driver.ts --mode=lifecycle
 *   npx tsx scripts/milestone-driver.ts --mode=create-project
 *   npx tsx scripts/milestone-driver.ts --mode=read
 * 
 * Options:
 *   --fast (shortens delays)
 */

import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { createNetwork, TransactionVersion } from "@stacks/network";
import {
    AnchorMode,
    PostConditionMode,
    makeContractCall,
    broadcastTransaction,
    fetchCallReadOnlyFunction,
    cvToString,
    uintCV,
    stringUtf8CV,
    stringAsciiCV,
    principalCV,
    bufferCV,
    cvToValue
} from "@stacks/transactions";
import { generateWallet, getStxAddress } from "@stacks/wallet-sdk";
import * as TOML from "toml";

type NetworkSettings = {
    network?: {
        name?: string;
        stacks_node_rpc_address?: string;
        deployment_fee_rate?: number;
    };
    accounts?: {
        deployer?: {
            mnemonic?: string;
        };
    };
};

const CONTRACT_ADDRESS = "SP1GNDB8SXJ51GBMSVVXMWGTPRFHGSMWNNBEY25A4";
const CONTRACT_NAME = "milestone";

// Function Names
const FN_CREATE_PROJECT = "create-project";
const FN_ACCEPT_PROPOSAL = "accept-proposal";
const FN_CREATE_MILESTONE = "create-milestone";
const FN_SUBMIT_MILESTONE = "submit-milestone";
const FN_APPROVE_MILESTONE = "approve-milestone";
const FN_GET_PROJECT = "get-project";
const FN_GET_NONCES = "get-nonces";

const DEFAULT_FEE_USTX = 100000; // 0.1 STX (generous fee to ensure inclusion)

const FAST = process.argv.includes("--fast");
const MODE = process.argv.find((arg) => arg.startsWith("--mode="))?.split("=")[1] || "lifecycle";

let DELAY_MS = FAST ? 5000 : 30000;

function thisDirname(): string {
    const __filename = fileURLToPath(import.meta.url);
    return path.dirname(__filename);
}

async function readMainnetMnemonic(): Promise<string> {
    const baseDir = thisDirname();
    const settingsPath = path.resolve(baseDir, "../settings/Mainnet.toml");
    const raw = await fs.readFile(settingsPath, "utf8");
    const parsed = TOML.parse(raw) as NetworkSettings;
    const mnemonic = parsed?.accounts?.deployer?.mnemonic;
    if (!mnemonic) throw new Error("Mnemonic not found in Mainnet.toml");
    return mnemonic.trim();
}

async function deriveSender(mnemonic: string) {
    const wallet = await generateWallet({ secretKey: mnemonic, password: "" });
    const account = wallet.accounts[0];
    const rawKey = account.stxPrivateKey || "";
    const senderKey = rawKey.startsWith("0x") ? rawKey.slice(2) : rawKey;
    const senderAddress = getStxAddress({ account, transactionVersion: TransactionVersion.Mainnet });
    return { senderKey, senderAddress };
}

function delay(ms: number) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

async function contractCall(
    network: any,
    senderKey: string,
    functionName: string,
    args: any[]
) {
    console.log(`Preparing ${functionName}...`);
    const tx = await makeContractCall({
        contractAddress: CONTRACT_ADDRESS,
        contractName: CONTRACT_NAME,
        functionName,
        functionArgs: args,
        senderKey,
        network,
        fee: DEFAULT_FEE_USTX,
        anchorMode: AnchorMode.Any,
        postConditionMode: PostConditionMode.Allow,
    });

    const res = await broadcastTransaction({ transaction: tx, network });
    // @ts-ignore
    const txid = res.txid || res;
    console.log(`Broadcasted ${functionName}: ${txid}`);
    return txid;
}

// Helpers for reading state
async function getNonces(network: any, senderAddress: string) {
    const res = await fetchCallReadOnlyFunction({
        contractAddress: CONTRACT_ADDRESS,
        contractName: CONTRACT_NAME,
        functionName: FN_GET_NONCES,
        functionArgs: [],
        network,
        senderAddress
    });
    return cvToValue(res);
}

async function getProject(network: any, senderAddress: string, id: number) {
    const res = await fetchCallReadOnlyFunction({
        contractAddress: CONTRACT_ADDRESS,
        contractName: CONTRACT_NAME,
        functionName: FN_GET_PROJECT,
        functionArgs: [uintCV(id)],
        network,
        senderAddress
    });
    return cvToValue(res);
}

// Helper to wait for transaction confirmation (simple polling of nonce or just strict delay)
// Since mainnet block times are long (10m), we can't really wait for confirmation in a loop conveniently.
// We will just perform actions and assume they will mine, or wait a looong time.
// actually, for 'lifecycle', we need sequential dependence. 
// If we send 'create-project', we can't 'accept-proposal' until it's mined.
// This script is better suited for "firing and forgetting" or LONG running daemon.
// If valid nonces are managed, we can chain mempool txs?
// Stacks supports chained mempool txs if nonces are sequential.
// The wallet-sdk handles nonce automatically if we don't specify it? 
// makeContractCall fetches next nonce. So yes, we can chain!

async function runLifecycle(network: any, senderKey: string, senderAddress: string) {
    console.log("Starting Full Lifecycle Mode (Chained Mempool Transactions)...");

    // 1. Get current IDs to know what we are creating
    const nonces = await getNonces(network, senderAddress);
    const nextProjectId = Number(nonces.value['project-nonce'].value) + 1;
    const nextMilestoneId = Number(nonces.value['milestone-nonce'].value) + 1;

    console.log(`Targeting Project ID: ${nextProjectId}`);

    // 2. Create Project
    await contractCall(network, senderKey, FN_CREATE_PROJECT, [
        stringUtf8CV(`Auto Project ${nextProjectId}`),
        stringUtf8CV("Automated lifecycle test project"),
        uintCV(100000000), // 100 STX budget
        uintCV(1000000), // Deadline (buffer)
        stringAsciiCV("development"),
        uintCV(1) // 1 milestone
    ]);

    await delay(2000); // Small buffer for nonce propagation in local mempool cache if any

    // 3. Accept Proposal (Self-assign)
    await contractCall(network, senderKey, FN_ACCEPT_PROPOSAL, [
        uintCV(nextProjectId),
        principalCV(senderAddress) // Freelancer = Self
    ]);

    await delay(2000);

    // 4. Create Milestone
    await contractCall(network, senderKey, FN_CREATE_MILESTONE, [
        uintCV(nextProjectId),
        stringUtf8CV("Phase 1"),
        stringUtf8CV("Initial deliverable"),
        uintCV(10000000), // 10 STX
        uintCV(1000000) // valid deadline
    ]);

    await delay(2000);

    // 5. Submit Milestone (Freelancer action)
    // deliverable-hash (buff 64)
    const hash = new Uint8Array(64).fill(1);
    await contractCall(network, senderKey, FN_SUBMIT_MILESTONE, [
        uintCV(nextMilestoneId),
        bufferCV(hash)
    ]);

    await delay(2000);

    // 6. Approve Milestone (Client action)
    await contractCall(network, senderKey, FN_APPROVE_MILESTONE, [
        uintCV(nextMilestoneId)
    ]);

    console.log("Lifecycle sequence broadcasted! Check explorer for confirmation.");
}

async function runCreateProject(network: any, senderKey: string) {
    const timestamp = new Date().toISOString();
    await contractCall(network, senderKey, FN_CREATE_PROJECT, [
        stringUtf8CV(`Project ${timestamp}`),
        stringUtf8CV("Automated project creation"),
        uintCV(50000000), // 50 STX
        uintCV(200000),
        stringAsciiCV("design"),
        uintCV(2)
    ]);
}

async function runRead(network: any, senderAddress: string) {
    const nonces = await getNonces(network, senderAddress);
    console.log("Current Nonces:", nonces);

    const projectId = Number(nonces.value['project-nonce'].value);
    if (projectId > 0) {
        const proj = await getProject(network, senderAddress, projectId);
        console.log(`Latest Project (#${projectId}):`, proj);
    }
}

async function main() {
    const mnemonic = await readMainnetMnemonic();
    const { senderKey, senderAddress } = await deriveSender(mnemonic);
    const network = createNetwork("mainnet");

    console.log(`Driver running. Mode: ${MODE}`);
    console.log(`Account: ${senderAddress}`);

    try {
        if (MODE === 'lifecycle') {
            await runLifecycle(network, senderKey, senderAddress);
        } else if (MODE === 'create-project') {
            await runCreateProject(network, senderKey);
        } else if (MODE === 'read') {
            await runRead(network, senderAddress);
        } else {
            console.log("Unknown mode. Available: lifecycle, create-project, read");
        }
    } catch (err) {
        console.error("Execution failed:", err);
    }
}

main();
