// personal_sign (EIP-191) through a Fordefi vault — the governance proof
// (FORDEFI_GOVERNANCE_SIG). Prints only the signature, which is not a secret.
//
//   node sign-message.mjs <0x-hex | text>
//
// 0x-hex is signed as raw bytes (a bytes32 proof hash matches Solidity's
// MessageHashUtils.toEthSignedMessageHash(bytes32)); anything else as UTF-8.
// The vault is CONTRACT_ADMIN unless SIGN_VAULT_LABEL names another label.

import { Signature, getBytes, hexlify, isHexString, toUtf8Bytes, verifyMessage } from "ethers";
import { assertCredentials, vaultProvider } from "./fordefi.mjs";

const input = process.argv[2];
if (!input) {
  console.error("usage: node sign-message.mjs <0x-hex | text>");
  process.exit(2);
}
const label = process.env.SIGN_VAULT_LABEL ?? "CONTRACT_ADMIN";

async function main() {
  const bytes = isHexString(input) ? getBytes(input) : toUtf8Bytes(input);
  assertCredentials(label);
  const { provider, address } = await vaultProvider(label);
  console.error(`signing ${bytes.length} bytes with ${label} ${address} — awaiting Fordefi approval…`);
  const raw = await provider.request({ method: "personal_sign", params: [hexlify(bytes), address] });
  // Normalise to 65-byte r||s||v with v in {27,28}: OpenZeppelin ECDSA rejects v in {0,1}.
  const sig = Signature.from(raw).serialized;
  // Never hand out a signature that does not recover to the vault.
  const signer = verifyMessage(bytes, sig);
  if (signer.toLowerCase() !== address.toLowerCase()) {
    throw new Error(`signature recovers to ${signer}, not ${address}`);
  }
  console.log(sig);
}

main().catch((e) => {
  console.error(`SIGN FAILED: ${e.message ?? e}`);
  process.exit(1);
});
