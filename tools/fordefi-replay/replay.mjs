// Replays a forge dry-run plan (broadcast/<Script>/<chain>/dry-run/<sig>-latest.json)
// through Fordefi vaults, one transaction at a time, strictly in plan order.
//
//   node replay.mjs <plan.json>              PLAN: print the table + plan hash; no network
//   PLAN_SHA256=<hash> node replay.mjs <plan.json> --execute
//   node replay.mjs <plan.json> --clear <idx>   drop an unresolved "submitting" marker
//
// Safety model:
//   - --execute sends only the exact plan a human approved (PLAN_SHA256).
//   - Every `from` must map to a vault with credentials, and every vault must
//     connect, before the first send.
//   - Each sender's pending nonce must equal the planned nonce before its send,
//     the Fordefi request pins that nonce (raw API, details.custom_nonce), and the
//     mined tx must carry it, so the replay is the plan forge simulated (CREATE
//     addresses and ordering included) or it stops. A step re-sent after --clear
//     reuses the nonce, so at most one of its Fordefi requests can ever be mined.
//   - <plan>.progress.json records each step's idempotence id before the create and
//     its Fordefi transaction id after, so a re-run resumes: it polls the recorded
//     request, else finds it by its unique note, else re-posts under the same
//     x-idempotence-id; several requests with that note stop the run.

import { createHash, randomUUID } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { CHAIN_ID, EXPLORER, NotSent, assertCredentials, readProvider, signerLabel, vaultApi, vaultLabels } from "./fordefi.mjs";

const RECEIPT_TIMEOUT_MS = Number(process.env.RECEIPT_TIMEOUT_MS ?? 600_000);

const [planPath, ...flags] = process.argv.slice(2);
if (!planPath) {
  console.error("usage: node replay.mjs <dry-run.json> [--execute | --clear <idx>]");
  process.exit(2);
}
const progressPath = `${planPath}.progress.json`;

const dec = (hex) => (hex == null ? "0" : BigInt(hex).toString());
const lower = (a) => (a ? a.toLowerCase() : null);

function loadPlan() {
  const raw = JSON.parse(readFileSync(planPath, "utf8"));
  if (!Array.isArray(raw.transactions) || raw.transactions.length === 0) {
    throw new Error(`${planPath} has no transactions`);
  }
  return raw.transactions.map((t, idx) => {
    const tx = t.transaction ?? {};
    const step = {
      type: t.transactionType,
      from: lower(tx.from),
      to: lower(tx.to),
      value: dec(tx.value),
      input: lower(tx.input ?? tx.data ?? "0x"),
      gas: dec(tx.gas),
      nonce: Number(dec(tx.nonce)),
      chainId: Number(dec(tx.chainId)),
      contractAddress: lower(t.contractAddress),
      created: (t.additionalContracts ?? []).map((c) => lower(c.address)),
    };
    if (!["CREATE", "CREATE2", "CALL"].includes(step.type)) throw new Error(`#${idx}: unsupported type ${step.type}`);
    if (step.chainId !== CHAIN_ID) throw new Error(`#${idx}: chainId ${step.chainId}, expected ${CHAIN_ID}`);
    if (!step.from) throw new Error(`#${idx}: no from`);
    if (!tx.gas) throw new Error(`#${idx}: no gas limit in plan`);
    if ((step.type === "CREATE") !== (step.to === null)) throw new Error(`#${idx}: ${step.type} with to=${step.to}`);
    return { ...step, label: `${t.contractName ?? ""}${t.function ? `.${t.function}` : ""}` };
  });
}

// Hash only what is sent and what is verified after; labels are display-only.
function planHash(steps) {
  const canon = steps.map((s) => [s.type, s.from, s.to, s.value, s.input, s.gas, s.nonce, s.chainId, s.contractAddress, s.created]);
  return createHash("sha256").update(JSON.stringify(canon)).digest("hex");
}

function printPlan(steps, hash) {
  const vaults = vaultLabels();
  const rows = steps.map((s, i) => [
    i,
    vaults.get(s.from)?.join("/") ?? `UNMAPPED ${s.from}`,
    s.nonce,
    s.type,
    s.to ?? "(create)",
    s.type === "CALL" ? s.input.slice(0, 10) : "-",
    s.value,
    s.gas,
    s.contractAddress ?? "",
    s.label,
  ]);
  const head = ["idx", "from", "nonce", "type", "to", "selector", "value(wei)", "gas", "creates", "call"];
  const w = head.map((h, c) => Math.max(h.length, ...rows.map((r) => String(r[c]).length)));
  for (const r of [head, ...rows]) console.log(r.map((v, c) => String(v).padEnd(w[c])).join("  "));
  console.log(`\nchain ${CHAIN_ID}, ${steps.length} txs`);
  console.log(`PLAN_SHA256=${hash}`);
}

function loadProgress(hash) {
  if (!existsSync(progressPath)) return { planSha256: hash, txs: {} };
  const p = JSON.parse(readFileSync(progressPath, "utf8"));
  if (p.planSha256 !== hash) {
    throw new Error(
      `${progressPath} belongs to plan ${p.planSha256}, not ${hash}. ` +
        `Archive it (it records what was sent) before replaying a different plan.`,
    );
  }
  return p;
}

function saveProgress(p) {
  writeFileSync(`${progressPath}.tmp`, JSON.stringify(p, null, 2) + "\n");
  renameSync(`${progressPath}.tmp`, progressPath); // atomic: never a torn progress file
}

async function assertNonce(ro, label, address, expected) {
  const pending = await ro.getTransactionCount(address, "pending");
  if (pending !== expected) {
    throw new Error(
      `${label} ${address} pending nonce is ${pending}, plan expects ${expected}. ` +
        `The chain moved since the dry-run (or a tx is in flight): re-run the forge dry-run for a fresh plan.`,
    );
  }
}

async function confirm(ro, i, s, hash) {
  console.log(`  #${i} sent ${hash}\n      ${EXPLORER}${hash}`);
  const receipt = await ro.waitForTransaction(hash, 1, RECEIPT_TIMEOUT_MS);
  if (!receipt) {
    throw new Error(
      `#${i}: no receipt within ${RECEIPT_TIMEOUT_MS}ms. If ${s.from} nonce ${s.nonce} was mined by another ` +
        `request for this step, archive the progress file and re-run the forge dry-run.`,
    );
  }
  const tx = await ro.getTransaction(hash);
  if (receipt.status !== 1) return { state: "reverted", hash, block: receipt.blockNumber };
  if (tx.nonce !== s.nonce) throw new Error(`#${i}: mined with nonce ${tx.nonce}, plan expected ${s.nonce}`);
  if (Number(tx.chainId) !== CHAIN_ID) throw new Error(`#${i}: mined on chain ${tx.chainId}`);
  if (s.type === "CREATE" && lower(receipt.contractAddress) !== s.contractAddress) {
    throw new Error(`#${i}: created ${receipt.contractAddress}, plan expected ${s.contractAddress}`);
  }
  for (const a of [s.contractAddress, ...s.created].filter(Boolean)) {
    if ((await ro.getCode(a)) === "0x") throw new Error(`#${i}: expected contract ${a} has no code`);
  }
  return { state: "confirmed", hash, block: receipt.blockNumber };
}

async function execute(steps, hash) {
  if (process.env.PLAN_SHA256 !== hash) {
    throw new Error(`PLAN_SHA256 does not match this plan (${hash}). Review the plan, then approve its hash.`);
  }
  const progress = loadProgress(hash);
  const todo = steps.map((s, i) => [i, s]).filter(([i]) => progress.txs[i]?.state !== "confirmed");

  // Fail closed before any send: reverted steps, unmapped senders, missing creds.
  for (const [i] of todo) {
    if (progress.txs[i]?.state === "reverted") {
      throw new Error(`#${i} reverted on chain (${progress.txs[i].hash}); investigate, then re-run the forge dry-run.`);
    }
  }
  const labelOf = new Map(todo.map(([, s]) => [s.from, signerLabel(s.from)]));
  const labels = [...new Set(labelOf.values())];
  labels.forEach(assertCredentials);

  const ro = await readProvider();
  const signers = {};
  for (const l of labels) {
    signers[l] = await vaultApi(l);
    const bal = await ro.getBalance(signers[l].address);
    console.log(`  ${l.padEnd(18)} ${signers[l].address}  balance ${bal} wei`);
    if (bal === 0n) throw new Error(`${l} has no gas balance on chain ${CHAIN_ID}`);
  }

  for (const [i, s] of todo) {
    const label = labelOf.get(s.from);
    let p = progress.txs[i];
    if (p?.state !== "sent") {
      const resumed = Boolean(p);
      if (!p) {
        await assertNonce(ro, label, s.from, s.nonce);
        p = progress.txs[i] = { state: "submitting", idempotenceId: randomUUID() };
        saveProgress(progress);
      }
      console.log(`\n#${i} ${label} ${s.type} ${s.label} — awaiting Fordefi approval…`);
      try {
        if (!p.fordefiId) {
          // Unique per attempt: the idempotence id is new for every marker.
          const note = `replay #${i} ${s.label} plan ${hash} request ${p.idempotenceId}`;
          // An earlier run's create may have landed without its id being recorded: find it first.
          const found = resumed ? await signers[label].find(note) : null;
          const tx = { ...(s.to ? { to: s.to } : {}), data: s.input, value: s.value, gas: s.gas };
          p.fordefiId = found ?? (await signers[label].create(tx, s.nonce, p.idempotenceId, note));
          saveProgress(progress);
        }
        progress.txs[i] = { state: "sent", fordefiId: p.fordefiId, hash: await signers[label].wait(p.fordefiId) };
      } catch (e) {
        if (e instanceof NotSent) {
          delete progress.txs[i];
          saveProgress(progress);
          throw new Error(`#${i} not sent (${e.message}); nothing reached the chain. Re-run the same command to retry.`);
        }
        throw new Error(
          `#${i} outcome unknown (${e.message ?? e}). Progress kept as 'submitting'${p.fordefiId ? ` (Fordefi ${p.fordefiId})` : ""}: ` +
            `re-run the same command to resume it; see the resume note in README.`,
        );
      }
      saveProgress(progress);
    }
    progress.txs[i] = await confirm(ro, i, s, progress.txs[i].hash);
    saveProgress(progress);
    if (progress.txs[i].state !== "confirmed") throw new Error(`#${i} reverted on chain: ${EXPLORER}${progress.txs[i].hash}`);
    console.log(`  #${i} confirmed in block ${progress.txs[i].block}`);
  }
  console.log(`\nAll ${steps.length} txs confirmed. Progress: ${progressPath}`);
}

function clear(steps, hash, idx) {
  const progress = loadProgress(hash);
  if (progress.txs[idx]?.state !== "submitting") throw new Error(`#${idx} is not in 'submitting' state`);
  delete progress.txs[idx];
  saveProgress(progress);
  console.log(`#${idx} cleared; it will be resubmitted on the next --execute.`);
}

async function main() {
  const steps = loadPlan();
  const hash = planHash(steps);
  printPlan(steps, hash);
  if (flags[0] === "--execute") await execute(steps, hash);
  else if (flags[0] === "--clear") clear(steps, hash, Number(flags[1]));
  else if (flags.length) throw new Error(`unknown argument ${flags[0]}`);
}

main().catch((e) => {
  console.error(`\nREPLAY STOPPED: ${e.message ?? e}`);
  console.error(`Progress (if any) is in ${progressPath}; re-run the same command to resume.`);
  process.exit(1);
});
