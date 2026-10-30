// Fordefi vault access shared by replay.mjs and sign-message.mjs.
//
// A vault is named by a LABEL (DEPLOYER, CONTRACT_ADMIN, ...). Its address and
// API-user credentials come from env, never from a file this tool writes:
//   FORDEFI_<LABEL>_ADDRESS            vault EVM address
//   FORDEFI_<LABEL>_VAULT_ID           vault UUID (replay.mjs: Create Transaction takes the id, not the address)
//   FORDEFI_<LABEL>_API_TOKEN          API user token
//   FORDEFI_<LABEL>_PRIVATE_KEY_PEM    API request-signing key: PEM content or a path
// The PEM is the P-256 key that signs API requests, NOT a blockchain key.

import { createPrivateKey, createSign } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { FordefiWeb3Provider } from "@fordefi/web3-provider";
import { JsonRpcProvider, toQuantity } from "ethers";

export const CHAIN_ID = Number(process.env.CHAIN_ID ?? 97);
// The chains this tool may send on (EXPLORER_TX_URL in env overrides the explorer).
const CHAINS = {
  97: { explorer: "https://testnet.bscscan.com/tx/" },
  56: { explorer: "https://bscscan.com/tx/" },
};
if (!CHAINS[CHAIN_ID]) throw new Error(`CHAIN_ID ${CHAIN_ID} is not supported (${Object.keys(CHAINS).join(", ")})`);
export const EXPLORER = process.env.EXPLORER_TX_URL ?? CHAINS[CHAIN_ID].explorer;
// Rehearsal only (script-bsc/simulate-fordefi-stack.sh): vaults are anvil-impersonated
// accounts and txs go through the node's eth_sendTransaction. Refused on anything but a
// local anvil node, so it cannot send on a real chain.
const TEST_RPC_SIGNER = process.env.REPLAY_TEST_RPC_SIGNER === "1";
const APPROVAL_TIMEOUT_MS = Number(process.env.FORDEFI_APPROVAL_TIMEOUT_MS ?? 3_600_000);
const API_URL = "https://api.fordefi.com";
const API_TIMEOUT_MS = 60_000;
const POLL_MS = 5_000;
const LIST_PAGE_SIZE = 100; // the List Transactions maximum
const TEST_POLL_MS = 100; // anvil mines in milliseconds
// Fordefi has no default chain 97: a custom chain is addressed as `evm_<chainId>`
// (OpenAPI EvmChainRequest / EvmChainUniqueId; same form as the platform's Rust adapter).
const FORDEFI_CHAIN = `evm_${CHAIN_ID}`;
// States after which the request provably never reached the chain.
const NOT_SENT_STATES = new Set(["aborted", "error_signing", "insufficient_funds"]);
// Terminal states that do not say whether, or under which hash, the step landed
// (`cancelled`: a replacement was mined on the planned nonce).
const STOP_STATES = new Set(["error_pushing_to_blockchain", "dropped", "accelerated", "cancelled"]);

/** Fordefi definitively did not send the step; a retry may create a new request. */
export class NotSent extends Error {}

export function env(name) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

/** Plain-RPC reader pinned to CHAIN_ID; refuses an RPC that serves another chain. */
export async function readProvider() {
  // cacheTimeout -1: ethers otherwise answers an identical call made within 250 ms from cache,
  // so a sender's nonce check right after its previous tx confirmed reads the stale nonce.
  const ro = new JsonRpcProvider(env("RPC_URL"), CHAIN_ID, { staticNetwork: true, cacheTimeout: -1 });
  const served = Number(await ro.send("eth_chainId", []));
  if (served !== CHAIN_ID) throw new Error(`RPC_URL serves chain ${served}, expected ${CHAIN_ID}`);
  return ro;
}

/** lowercase address -> [labels], from every FORDEFI_<LABEL>_ADDRESS in env (one vault may hold several roles). */
export function vaultLabels() {
  const byAddress = new Map();
  for (const [k, v] of Object.entries(process.env)) {
    const m = /^FORDEFI_(.+)_ADDRESS$/.exec(k);
    if (!m || !v) continue;
    const a = v.toLowerCase();
    byAddress.set(a, [...(byAddress.get(a) ?? []), m[1]].sort());
  }
  return byAddress;
}

/** The one label for `address` whose API credentials are configured; fail closed otherwise. */
export function signerLabel(address) {
  const labels = vaultLabels().get(address.toLowerCase()) ?? [];
  if (labels.length === 0) throw new Error(`no FORDEFI_<LABEL>_ADDRESS maps sender ${address}`);
  const withCreds = labels.filter((l) => TEST_RPC_SIGNER || process.env[`FORDEFI_${l}_API_TOKEN`]);
  if (withCreds.length !== 1) {
    throw new Error(`sender ${address} (${labels.join("/")}) needs exactly one label with FORDEFI_<LABEL>_API_TOKEN set, found ${withCreds.length}`);
  }
  return withCreds[0];
}

// The provider validates the header and demands SEC1 ("BEGIN EC PRIVATE KEY");
// Secrets Manager / the Rust adapter keep PKCS#8. Convert in-process.
function signingKey(label) {
  const name = `FORDEFI_${label}_PRIVATE_KEY_PEM`;
  let v = env(name);
  if (!v.includes("-----BEGIN")) {
    if (!existsSync(v)) throw new Error(`${name} is neither PEM content nor an existing file`);
    v = readFileSync(v, "utf8");
  }
  v = v.replace(/\\n/g, "\n");
  if (v.includes("BEGIN EC PRIVATE KEY")) return v;
  if (!v.includes("BEGIN PRIVATE KEY")) throw new Error(`${name} is not an EC private key PEM`);
  return createPrivateKey(v).export({ type: "sec1", format: "pem" }).toString();
}

/** Throws unless every credential for `label` is present. Reads nothing remote. */
export function assertCredentials(label) {
  env(`FORDEFI_${label}_ADDRESS`);
  if (TEST_RPC_SIGNER) return;
  env(`FORDEFI_${label}_API_TOKEN`);
  signingKey(label);
}

/**
 * Connected web3 provider for one vault, for personal_sign (sign-message.mjs).
 * It resolves only once Fordefi reports the request SIGNED, i.e. after policy
 * approval. It cannot pin a nonce, so transactions go through vaultApi().
 */
export async function vaultProvider(label) {
  const address = env(`FORDEFI_${label}_ADDRESS`);
  const provider = new FordefiWeb3Provider({
    address,
    apiUserToken: env(`FORDEFI_${label}_API_TOKEN`),
    apiPayloadSignKey: signingKey(label),
    chainId: CHAIN_ID,
    rpcUrl: env("RPC_URL"),
    // Fordefi cannot simulate against contracts an earlier step of the same
    // plan creates; forge already simulated the whole plan.
    skipPrediction: true,
    timeoutDurationMs: APPROVAL_TIMEOUT_MS,
  });
  // The constructor starts connect() and swallows its error, leaving the provider
  // "disconnected" for every later signing call. connect() joins that attempt or
  // retries it, so a failed vault/chain lookup surfaces here with its real cause.
  await provider.connect();
  const accounts = await provider.request({ method: "eth_accounts" });
  const chainId = Number(await provider.request({ method: "eth_chainId" }));
  if (chainId !== CHAIN_ID) throw new Error(`${label}: Fordefi resolved chain ${chainId}, expected ${CHAIN_ID}`);
  if (accounts?.[0]?.toLowerCase() !== address.toLowerCase()) {
    throw new Error(`${label}: Fordefi resolved account ${accounts?.[0]}, expected ${address}`);
  }
  return { provider, address };
}

// One Fordefi API call. A POST is signed per docs.fordefi.com/developers/authentication:
// ECDSA P-256 / SHA-256 over `${path}|${timestamp}|${body}`, timestamp in ms,
// base64 DER signature (as @fordefi/web3-provider's signApiRequestBody). GETs need the token only.
async function api(label, path, body, idempotenceId) {
  const headers = { Authorization: `Bearer ${env(`FORDEFI_${label}_API_TOKEN`)}` };
  if (body !== undefined) {
    const timestamp = String(Date.now());
    const signature = createSign("SHA256")
      .update(`${path}|${timestamp}|${body}`, "utf8")
      .sign(createPrivateKey(signingKey(label)), "base64");
    Object.assign(headers, {
      "Content-Type": "application/json",
      "x-timestamp": timestamp,
      "x-signature": signature,
      "x-idempotence-id": idempotenceId,
    });
  }
  const res = await fetch(`${API_URL}${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers,
    body,
    signal: AbortSignal.timeout(API_TIMEOUT_MS),
  });
  const text = await res.text();
  if (res.ok) return JSON.parse(text);
  const msg = `Fordefi ${path} ${res.status}: ${text}`;
  // Only these refuse a create outright; 408, 409, 429 and 5xx may have created the request.
  if (body !== undefined && [400, 401, 403, 422].includes(res.status)) throw new NotSent(msg);
  throw Object.assign(new Error(msg), { status: res.status });
}

/**
 * Transaction sender for one vault over Fordefi's raw API (POST /api/v1/transactions),
 * the only route that takes a custom nonce. Checks before any send that the vault
 * id resolves to FORDEFI_<LABEL>_ADDRESS.
 *   create(tx, nonce, idempotenceId, note) -> Fordefi transaction id; the nonce is pinned
 *     (details.custom_nonce), so two requests for one step can never both be mined,
 *     and a re-POST under the same idempotence id returns the same request. A 409 is
 *     resolved by find(note).
 *   find(note) -> id of the one request of this vault carrying `note` (unique per
 *     attempt), or null if none; throws if several. Used before any re-POST.
 *   wait(id) -> tx hash once Fordefi has signed it; NotSent on a state that never
 *     reached the chain; throws on any ambiguous terminal state or on timeout.
 */
export async function vaultApi(label) {
  if (TEST_RPC_SIGNER) return testRpcSigner(label);
  const address = env(`FORDEFI_${label}_ADDRESS`);
  const vaultId = env(`FORDEFI_${label}_VAULT_ID`);
  const vault = await api(label, `/api/v1/vaults/${vaultId}`);
  if (vault.address?.toLowerCase() !== address.toLowerCase()) {
    throw new Error(`${label}: Fordefi vault ${vaultId} has address ${vault.address}, expected ${address}`);
  }
  const create = async (tx, nonce, idempotenceId, note) => {
    const body = JSON.stringify({
      vault_id: vaultId,
      signer_type: "api_signer",
      type: "evm_transaction",
      note,
      details: {
        type: "evm_raw_transaction",
        chain: FORDEFI_CHAIN,
        ...(tx.to ? { to: tx.to } : {}),
        value: tx.value,
        ...(tx.data !== "0x" ? { data: { type: "hex", hex_data: tx.data } } : {}),
        gas: { type: "priority", priority_level: "medium", gas_limit: tx.gas },
        custom_nonce: String(nonce),
      },
    });
    try {
      const { id } = await api(label, "/api/v1/transactions", body, idempotenceId);
      if (!id) throw new Error("Fordefi create response has no id");
      return id;
    } catch (e) {
      const id = e.status === 409 ? await find(note) : null;
      if (!id) throw e;
      return id;
    }
  };
  // The list API filters neither by note nor by idempotence id: page through this vault's
  // requests on the chain and match the note exactly.
  const find = async (note) => {
    const ids = [];
    for (let page = 1; ; page++) {
      const q = new URLSearchParams({ vault_ids: vaultId, chains: FORDEFI_CHAIN, types: "evm_transaction", size: String(LIST_PAGE_SIZE), page: String(page) });
      const { transactions } = await api(label, `/api/v1/transactions?${q}`);
      ids.push(...transactions.filter((t) => t.note === note).map((t) => t.id));
      if (transactions.length < LIST_PAGE_SIZE) break;
    }
    if (ids.length > 1) throw new Error(`${ids.length} Fordefi requests carry note "${note}" (${ids.join(", ")}); resolve them in the console`);
    return ids[0] ?? null;
  };
  const wait = async (id) => {
    const deadline = Date.now() + APPROVAL_TIMEOUT_MS;
    for (;;) {
      const t = await api(label, `/api/v1/transactions/${id}`);
      if (NOT_SENT_STATES.has(t.state)) throw new NotSent(`Fordefi transaction ${id} ${t.state}`);
      if (STOP_STATES.has(t.state)) throw new Error(`Fordefi transaction ${id} is '${t.state}'`);
      if (t.hash) return t.hash;
      if (Date.now() > deadline) throw new Error(`Fordefi transaction ${id} still '${t.state}' after ${APPROVAL_TIMEOUT_MS}ms`);
      await new Promise((r) => setTimeout(r, POLL_MS));
    }
  };
  return { address, create, find, wait };
}

async function testRpcSigner(label) {
  const address = env(`FORDEFI_${label}_ADDRESS`);
  const ro = await readProvider();
  const host = new URL(env("RPC_URL")).hostname;
  const client = await ro.send("web3_clientVersion", []);
  if (!["127.0.0.1", "localhost"].includes(host) || !/^anvil\//.test(client)) {
    throw new Error(`REPLAY_TEST_RPC_SIGNER needs a local anvil node; RPC_URL is ${host} (${client})`);
  }
  await ro.send("anvil_impersonateAccount", [address]);
  // The tx hash doubles as the request id. Anvil automines just after eth_sendTransaction
  // returns and then mines nothing more, so wait() hands the hash on only once its receipt
  // exists; otherwise confirm() reads the pre-mining block and waits for a block that never comes.
  const create = (tx, nonce) =>
    ro.send("eth_sendTransaction", [{ from: address, ...tx, value: toQuantity(tx.value), gas: toQuantity(tx.gas), nonce: toQuantity(nonce) }]);
  const wait = async (hash) => {
    while (!(await ro.getTransactionReceipt(hash))) await new Promise((r) => setTimeout(r, TEST_POLL_MS));
    return hash;
  };
  // No Fordefi request exists to look up: a resumed step re-sends with its pinned nonce.
  return { address, create, find: async () => null, wait };
}
