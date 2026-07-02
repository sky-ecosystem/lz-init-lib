# AVAX-migration clone experiment — runbook

This package stands up an **independent clone** of the Sky LayerZero gov-bridge + OFT setup on
**real Ethereum mainnet and real Avalanche C-chain**, runs the Avalanche hardening migration
(`migrateAvax` / `migrateAvaxRemote`) against that clone end-to-end, and (optionally) bridges USDS
round-trip through the migrated adapters — all driven by **your own funded deployer**, deploying
**your own** contracts. Nothing here touches production Sky contracts; every token/chainlog is a fake.

It is the on-chain counterpart to the in-process capstone test
`test/CloneAvaxMigration.t.sol::test_clone_migration_end_to_end`, which validates the exact same
deploy → wire → migrate → round-trip flow on forks.

> ⚠️ These `make` targets broadcast **real transactions** and spend **real gas** (single-digit USD
> total). Use `make -n all` first to dry-run (prints the ordered command list, sends nothing).

---

## What it deploys

- **Gov bridge** (`CloneAvaxBridge.s.sol`): `GovernanceOAppSender` + `L1GovernanceRelay` on mainnet;
  `GovernanceOAppReceiver` + OLD & NEW `L2GovernanceRelay` on Avalanche; plus fake USDS/sUSDS tokens
  and a `FakeChainlog` seeded with your deployer as `MCD_PAUSE_PROXY`.
- **OFT adapters** (`CloneAvaxOft.s.sol`): 8 real audited `SkyOFTAdapter`/`SkyOFTAdapterMintBurn`
  behind UUPS proxies (OLD+NEW × USDS+sUSDS × L1+Avax), plus a CCIP send-side DVN adapter.
- **L2 migration spell + migration** (`CloneAvaxRunMigration.s.sol`): the L2 clone spell on Avalanche,
  then `migrateAvax` on mainnet (which relays the L2 spell over LayerZero).

Deployed addresses are written to `script/clone.eth.json` and `script/clone.avax.json` and reused as
idempotency sentinels (a re-run skips work already done). **The committed JSON files hold a previous
run's addresses — run `make clean-state` first so your run deploys your own clone.**

---

## Prerequisites

1. **Foundry** (`forge`, `cast`) and **`jq`**, **`make`**, **`bash`** on PATH.
2. **A funded deployer EOA** — this single key is the owner / pause-proxy stand-in for the whole clone:
   - **~0.1 ETH on Ethereum mainnet** (deploys + wiring + migration; the actual run used well under this).
   - **~2 AVAX on Avalanche C-chain** (Avalanche gas is the bulk of the cost).
   - Fund AVAX **directly** to the deployer. During the real run, gas.zip was drained; **LI.FI**
     worked for bridging ETH→AVAX if you'd rather bridge than buy.
3. **RPCs**: an Ethereum RPC and an Avalanche C-chain RPC. Broadcasting does **not** need archive
   nodes (only the fork tests do). Public nodes that worked: `https://ethereum-rpc.publicnode.com`
   and `https://avalanche-c-chain-rpc.publicnode.com`.

### Environment

```sh
export DEPLOYER=0xYourDeployerEOA        # MUST equal the address of PRIVATE_KEY below
export PRIVATE_KEY=0xYourPrivateKey      # broadcasting key
export MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com
export AVALANCHE_RPC_URL=https://avalanche-c-chain-rpc.publicnode.com
```

Prefer a keystore over a raw key? Leave `PRIVATE_KEY` unset and pass a wallet override to every
target: `make deploy-bridge WALLET="--account mydeployer"`. (The `deliver.sh` force-delivery path
still reads `PRIVATE_KEY`; export it or run the printed `cast send` command yourself.)

Every script does `require(msg.sender == vm.envAddress("DEPLOYER"))`, so `DEPLOYER` **must** match
your broadcasting key or the scripts reject you.

---

## Quick start

```sh
make check          # verify env, foundry, jq, and deployer balances on both chains
make clean-state    # wipe clone.*.json so you deploy YOUR OWN fresh clone
make -n all         # DRY RUN: print the ordered command list, send nothing
make all            # deploy + wire (both chains) + deploy L2 spell + run migrateAvax
```

`make all` stops right after `migrate` and prints the remaining steps, because the next step needs
the `migrate()` transaction hash (only known once it broadcasts) and LZ delivery can't be chained
blindly. Finish with:

```sh
make deliver-migration MIGRATE_TX=<the migrate() tx hash printed by `make all`>
make exec-migration
make verify
```

Optional token round-trip and cleanup:

```sh
make roundtrip      # prints the 4 interactive steps (each leg's tx hash feeds the next deliver)
make reclaim        # recover leftover LZ-fee ETH from the clone L1 relay back to your deployer
```

---

## Targets

| Target | Chain(s) | What it does |
|---|---|---|
| `check` | both | Verify env + foundry + `jq` + deployer balances + chain ids. |
| `clean-state` | — | Wipe `clone.*.json` for a fresh clone. |
| `deploy-bridge` | eth, avax | Gov bridge + fake tokens + FakeChainlog. |
| `deploy-oft-eth` | eth | The 4 L1 lockboxes + the mainnet CCIP DVN adapter deployed **BARE** via the real `CloneSendSideDeployer` constructor (roles + allowlist, **no peer yet**). **Run BEFORE `deploy-dvn-broadcaster`** — the Avax recv side bakes this adapter's address as its set-once source peer. |
| `deploy-oft-avax` | avax | The 4 Avalanche OFT adapters (OLD+NEW × USDS+sUSDS, 4/4 required DVN set). |
| `deploy-dvn-broadcaster` | avax | `CloneAvaxDvnBroadcaster.deploy()`: the whole Avax recv side via the real `RecvSideDeployer` — Avax CCIP DVN adapter (source peer = the **real** mainnet adapter from `clone.eth.json`) + CCIP & msig `DVNBroadcaster`s (4 replicas each) for the 8-of-15 gov recv topology. **Run AFTER `deploy-oft-eth`.** |
| `wire-oft` (eth part) | eth | …plus `CloneSendSideDeployer.configure()` (sets the mainnet adapter's set-once peer to the **real** Avax adapter/broadcaster, dest-gas 600k) then `handOff()` admin to the clone pause proxy (EOA). |
| `wire-bridge` | eth, avax | Wire gov send/recv sides; hand receiver to OLD relay. |
| `wire-oft` | eth, avax | Wire OFT routes, seed backing, pause old, hand off to OLD relay. |
| `deploy-l2spell` | avax | Deploy the L2 clone migration spell. |
| `migrate` | eth | Fund the L1 relay + `migrateAvax` (relays the L2 spell over LZ). |
| `deliver-migration` | eth→avax | Poll + force-deliver the relayed L2 spell (`MIGRATE_TX=…`). |
| `exec-migration` | avax | `exec(0)` the queued L2 action on the OLD relay. |
| `verify` | both | Read-only cast assertions of the L1 + L2 outcome. |
| `send-to-avax` / `deliver-to-avax` | eth / eth→avax | Round-trip out-leg + delivery. |
| `send-back` / `deliver-to-eth` | avax / avax→eth | Round-trip return-leg + delivery. |
| `gov-message` | eth→avax | Post-migration 8-of-15 gov message via the multisig wing (documented `cast` recipe; see below). |
| `reclaim` | eth | Recover leftover LZ-fee ETH from the L1 relay. |
| `all` | both | Ordered deploy + wire + deploy-l2spell + migrate (dependency-correct order). |

Targets auto-select the right RPC per chain and pass `--slow` (one tx at a time). The scripts are
idempotent, so a target that fails partway (e.g. RPC timeout) can simply be re-run.

---

## The delivery helper (`deliver.sh`)

LayerZero's executor normally delivers the relayed L2 spell (and each token-bridge message) a few
minutes after the source tx. During the real run the executor occasionally lagged, so `deliver.sh`:

1. Pulls the `PacketSent` log from the source tx and parses the packet (src/dst eid, nonce, sender,
   receiver, guid, message).
2. Polls the destination endpoint's `inboundNonce(...)` for up to ~15 min (override with
   `DELIVER_POLL=<seconds>`; `0` = force immediately).
3. If still not delivered, submits the permissionless `endpoint.lzReceive(...)` itself. If it can't
   (no `PRIVATE_KEY`, or the payload isn't DVN-verified yet), it prints the **exact** `cast send`
   command for you to run/retry.

```sh
./script/deliver.sh <SOURCE_TX_HASH> <src: eth|avax> <dst: eth|avax> [POLL_SECONDS]
```

Manual force-delivery only succeeds once the DVNs have verified the payload; if it reverts, wait a
few minutes and re-run.

> Note: `deliver.sh`'s poll uses `inboundNonce`, which on the LZ endpoint can advance when a packet
> is *committed* (verified at the ULN) but not yet *executed* (`lzReceive` not yet run). So the
> script may print "DELIVERED" while the message is only committed. Confirm real execution by the
> effect (e.g. the destination token balance, or the gov action queued on the L2 relay); if the
> effect hasn't landed, force the `lzReceive` yourself (`deliver.sh … 0`, or the printed `cast send`).

---

## Expected outcome (`make verify`)

- `[L1] chainlog USDS_OFT` → the **new** L1 USDS lockbox.
- `[L1] old USDS lockbox peer[AVAX]` → cleared (`0x0…0`).
- `[L1] USDS backing held by the NEW lockbox` → `10000e18` (`1e22`), plus any in-flight bridged amount.
- `[L2] avax USDS token ward` → new adapter `1`, old adapter `0`.
- `[L2] new avax USDS adapter owner` → the **new** L2 relay.

The round-trip: `send-to-avax` locks 1000 USDS on the new L1 lockbox and mints it on Avalanche to the
deployer; `send-back` burns on Avalanche and unlocks on L1, returning the deployer's USDS balance.

---

## Post-migration gov message (8-of-15)

This is the headline demonstration that the **hardened gov path** the migration installs actually
works: a gov message sent through the **new** L2 relay, delivered on Avalanche under the real
**8-of-15 optional-DVN recv topology**. The non-LZ threshold can be reached by **either** wing:

- **CCIP wing (verified end-to-end).** The gov send is 8-of-8 incl. the CCIP DVN adapter, which fires a
  real Chainlink CCIP message Eth→Avax; the avax CCIP adapter's `ccipReceive` fans out to its 4 CCIP
  replicas, which verify on the recv lib. 7 LZ + 4 CCIP = 11 ≥ 8 — the CCIP replicas are load-bearing
  (7 LZ alone < 8). This requires the CCIP wing to be correctly peered on BOTH sides (use the real
  `Send`/`RecvSideDeployer`; see FINDINGS §2b/§4) and the mainnet adapter prefunded (caveat (c)).
  Takes ~15–20 min for the Chainlink hop.
- **Multisig wing (instant).** As the `msigBroadcaster`'s verifier, the DEPLOYER drives its 4 replicas
  directly — no CCIP latency. Useful when you just want to exercise the recv threshold quickly.

Either way, after ≥8 optional DVNs verify, `lzReceive` queues the action on the new relay. NOTE: if the
gov recv **enforced lzReceive gas** is too low for the new relay's queue path, the LZ auto-executor's
simulation reverts — deliver permissionlessly with `deliver.sh <sendTx> eth avax 0` (force-`lzReceive`
uses a generous gas limit).

After migration the gov send config is **8-of-8** (7 LZ optional DVNs + the CCIP DVN adapter) and the
gov whitelist points `(l1Relay, AVAX_EID, newRelay)`. The recv config on the gov receiver is
**15 optional / threshold 8** = 7 AVAX gov LZ DVNs + 4 CCIP replicas + 4 msig replicas.

Because each step's output feeds the next, this is a `cast` recipe rather than a `forge --sig` (the
`make gov-message` target just prints it). With `clone.eth.json` / `clone.avax.json` loaded into
shell vars (`ETHCCIP`, `L1RELAY`, `SENDER`, `NEWRELAY`, `MSIGBC`, `ENDPOINT`, `AVAX_EID=30106`):

1. **Prefund the mainnet CCIP DVN adapter** so its `assignJob` `ccipSend` succeeds (send is 8-of-8
   *incl. CCIP*; the adapter must hold native to pay the Chainlink CCIP router — see caveat (c)):
   ```sh
   cast send $ETHCCIP --value 0.001ether --rpc-url $MAINNET_RPC_URL --private-key $PK
   ```
2. **Send the gov message through the new relay.** Pick any `(target, targetData)`; quote the fee off
   the gov sender, then call `relayEVM` on the L1 relay (the deployer is a ward, and the relay already
   holds LZ-fee ETH from `migrate`). Capture the send **tx hash**.
3. **Parse the packet** from the send tx (header + payloadHash) — `deliver.sh <sendTx> eth avax 0`
   prints the parsed `srcEid/sender/nonce/guid/message`; the 81-byte packet header is
   `0x01 ++ nonce(8) ++ srcEid(4) ++ sender(32) ++ dstEid(4) ++ receiver(32)` and the payloadHash is
   `keccak256(guid ++ message)`.
4. **Attest the multisig wing** — as the msig broadcaster's verifier (the DEPLOYER), fill its 4
   replicas on the recv lib:
   ```sh
   cast send $MSIGBC 'verify(bytes,bytes32,uint64)' <packetHeader81> <payloadHash> <confirmations> \
     --rpc-url $AVALANCHE_RPC_URL --private-key $PK
   ```
   The 7 LZ recv DVNs attest automatically within a few minutes; 7 LZ + 4 msig = 11 ≥ 8.
5. **Deliver permissionlessly** once ≥ 8 optional DVNs have submitted:
   ```sh
   cast send $ENDPOINT 'lzReceive((uint32,bytes32,uint64),address,bytes32,bytes,bytes)' \
     "($ETH_EID,$SENDER_B32,$NONCE)" $NEWRELAY $GUID $MESSAGE 0x \
     --rpc-url $AVALANCHE_RPC_URL --private-key $PK
   ```
   The new relay **queues** the action (the new relay carries a 1-day timelock), proving the 8-of-15
   gov path delivered and executed `lzReceive` end-to-end. The CCIP wing (real Chainlink CCIP
   delivery) is slower/costlier; the **msig wing is the intended demonstration**.

---

## Key caveats

- **(a) EIP-170 / optimizer.** The migration lib is large; `foundry.toml` already sets
  `optimizer = true, optimizer_runs = 200`. Don't disable it or deployment hits the 24 KB code-size limit.
- **(b) Executor lag.** If a relayed message doesn't land within a few minutes, use
  `make deliver-migration` / `deliver.sh` to force-deliver. This is expected, not a failure.
- **(c) ⭐ Prefund the mainnet CCIP DVN adapter BEFORE the first POST-migration gov message (NOT before
  `migrate`).** After migration the gov **send** config is 8-of-8 *including the CCIP DVN adapter*, so
  any gov send runs the CCIP adapter's `assignJob` → `ccipSend`, which must pay the Chainlink CCIP
  router in native; a freshly-deployed adapter holds 0 native and the send reverts unless it is
  prefunded (~0.001 ETH is ample; observed need ~0.00031 ETH), and `quoteTx` does **not** surface this
  (the shortfall only bites at execution). **`migrateAvax` itself does NOT need it:** the migration
  relays its L2 spell (`relayToL2`, ~L140) BEFORE it swaps the send DVN set (`setUlnConfig`, ~L191), so
  the migration's own relay goes out under the *pre-migration* send config (the 4-of-7 LZ set, no
  CCIP). The CCIP adapter is first exercised by a *subsequent* gov message. Fund it
  (`cast send <ethCcipAdapter> --value 0.001ether …`) before `make gov-message`. This is the single
  most important operational item for the hardened gov bridge.
- **(c2) Round-trip via `cast` if the scripted `send` reverts empty.** The `OftSendLike.send`
  interface must declare the exact `(MessagingReceipt, OFTReceipt)` return structs; an earlier
  `(bytes,bytes)` return caused forge to revert with empty data while ABI-decoding the return even
  though the on-chain send succeeded. It's fixed in `CloneAvaxRunMigration.s.sol`, but if you hit a
  similar empty revert, drive the round-trip with `cast` directly (mint/approve/`quoteSend`/`send`
  with a ~25% native-fee buffer — excess refunds to you) since a raw `cast send` doesn't decode the
  return. OFT DVN verification on the destination takes a few minutes; the packet commits first
  (`inboundPayloadHash != 0`) and only then can `lzReceive` succeed — retry `deliver.sh` until it
  lands (a premature force-deliver reverts with `0x7182306f`, ULN-still-verifying).
- **(d) Cleanup.** `make reclaim` returns leftover LZ-fee ETH from the clone L1 gov relay to your
  deployer once you're done.
- **Fresh start.** The committed `clone.*.json` are a *previous* run's addresses. Always
  `make clean-state` before your own run, or you'll read someone else's deployment.

---

## Validate without broadcasting

```sh
forge build                                              # clean compile
MAINNET_RPC_URL=… AVALANCHE_RPC_URL=… \
  forge test --match-contract CloneAvax                  # fork tests (archive RPCs needed here)
make -n all                                              # dry-run the whole sequence
```

The fork tests pin historical blocks and therefore require **archive-capable** RPCs; the migration
capstone (`CloneAvaxMigrationTest`) is the authoritative end-to-end check.
