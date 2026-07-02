# AVAX migration — real-chain clone experiment: findings

Ran the Avalanche hardening migration end-to-end against a fully independent CLONE of the Sky
LZ setup on **real Ethereum mainnet + real Avalanche C-chain** (fake tokens/bridge, own deployer),
**now with the full production DVN topology**: gov recv **15 optional / threshold 8**, gov send
**8-of-8 (incl. the CCIP DVN adapter)**, and the OFT adapters on the **4/4 required** production DVN
set. See `README.md` for how to reproduce. Net real cost: single-digit USD (relay LZ-fee reclaimed).

## The hardened DVN topology, on real chains
The migration installs and this run verified on-chain:
- **Gov RECEIVER (Avalanche): 15 optional DVNs, threshold 8** = 7 AVAX gov LZ DVNs + 4 CCIP-wing
  replicas + 4 multisig-wing replicas (sorted ascending). The 8 non-LZ replicas are spawned by two
  `DVNBroadcaster`s (`CloneAvaxDvnBroadcaster.s.sol`): the CCIP broadcaster's verifier is the Avax
  CCIP DVN adapter (driven by attestations arriving over Chainlink CCIP from the mainnet CCIP
  adapter); the msig broadcaster's verifier is the multisig (here the DEPLOYER), which drives its 4
  replicas directly.
- **Gov SENDER (mainnet): 8 optional DVNs, threshold 8** = the pre-existing 7 optional LZ DVNs with
  the mainnet **CCIP DVN adapter** inserted (sorted) as the 8th. Every gov message now REQUIRES a
  CCIP attestation to send.
- **OFT adapters (both chains): 4/4 required DVNs**, confirmations 15, on all four new lockboxes.

## 1. The migration logic is correct
`migrateAvax` / `migrateAvaxRemote` produced the exact expected outcome on real chains under the full
topology — chainlog repoint, backing split (10k→new / 90k→old lockbox), old peer cleared + rate
limits zeroed, gov whitelist swapped OLD→NEW, gov send upgraded to 8-of-8, gov recv overwritten to
15/8, and on Avalanche the token wards + ownership/delegate moved to the new relay. The USDS
round-trip (L1→Avax→L1) reconciled to zero net. **No bug in the migration itself.**

## 2. ⭐ Headline: the hardened 8-of-15 gov path works, delivered via the MULTISIG WING
After migration, a fresh gov message through the NEW relay was delivered on Avalanche under the real
15-optional/threshold-8 recv set. The 7 LZ recv DVNs attest automatically; to reach threshold the
**multisig wing** was driven directly: as the msig broadcaster's verifier, the DEPLOYER called
`msigBroadcaster.verify(packetHeader81, payloadHash, confirmations)`, which fans out to its 4
replicas' `receiveLib.verify(...)` (7 LZ + 4 msig = 11 ≥ 8). Once threshold was met the **real LZ
executor delivered `lzReceive` automatically** (no manual force-delivery needed) and the new relay
**queued** the gov action (`actionsCount` 0→1; the action sits Queued because the new relay carries a
1-day timelock — the queue is the proof lzReceive executed under 8-of-15). This proves the hardened
gov path is live end-to-end and the non-LZ (multisig) wing alone reaches the threshold.
- Send tx `0xdc892ae8…cfcf93` (through the new relay, 8/8 send incl. CCIP);
  msig-wing attest `0xb7911979…5f9c6a` (`msigBroadcaster.verify`, filled the 4 msig replicas).
- **LZ Scan on the send tx confirms 11/15 SUCCEEDED = 7 LZ DVNs + 4 msig replicas; the 4 CCIP-wing
  replicas are stuck `WAITING`.** Threshold was met by the msig wing alone. See #2b — the CCIP wing
  did NOT merely go unused, it is BROKEN in this clone.

## 2b. ⭐ CORRECTION — the CCIP wing is BROKEN in this clone (set-once placeholder peer on the recv adapter)
An earlier version of this doc said the CCIP wing was "slower/costlier and not required." That
understated it. The CCIP send **did** fire on mainnet (send tx `0xdc89…` emits `CCIPSendRequested`
from onRamp `0xafd31c0c…`, sender = mainnet CCIP adapter `0x0ae5c432…`, payloadHash `0fb5a2d9…`;
adapter funded ~0.00069 ETH), the message committed on Avax — and then **`ccipReceive` on the avax
CCIP adapter reverted**. Chainlink CCIP marks it **execution state 3 = FAILURE** (messageId
`0x24a9c472…`, failed exec tx `0x11d1c8c7…` on off-ramp `0xe5f21f43…`).
- **Revert = `CCIPDVNAdapter_UntrustedPeer(uint64 chainSelector, bytes peer)` (selector `0x0b4f78c2`)**,
  thrown in `_assertPeer` (`SendSideDeployerFlat.sol:3271`): `ccipReceive` checks
  `keccak256(message.sender) == keccak256(srcConfig[sourceChainSelector].peer)`.
- **On-chain proof:** the avax adapter's `srcConfig[ETH selector].peer == 0x…dead` (the placeholder),
  not the real mainnet adapter `0x0ae5c432…`. So every CCIP attestation from mainnet bounces.
- **Why:** `setDstConfig` sets `srcConfig[chainSelector].peer` in the SAME **set-once** call
  (`:3172-3174`, guarded by `dstConfig[eid].chainSelector == 0`). The hand-rolled
  `CloneAvaxDvnBroadcaster.deploy()` ran `setDstConfig(ETH, sel, peer=clone.eth.json.ccipAdapter)`
  while the mainnet adapter did not yet exist, so it wrote the `0xdead` placeholder. The FINDINGS-#4
  placeholder-clear dance only corrected the **mainnet** adapter's peer (its send target), never the
  **avax** adapter's recv peer — and set-once means it can never be fixed on this adapter.
- **This is the audit's set-once hazard (row 7) realized on the RECV side, and exactly the divergence
  that using the real `RecvSideDeployer` with correct adapter ordering prevents.**
- **Fix requires a fresh deploy** (set-once cannot be rewritten): deploy BOTH CCIP adapters first, then
  wire each other's real address as the peer (adapters before `setDstConfig`), then re-run a gov
  message — only then will the 4 CCIP replicas verify and the 8-of-15 clear via the CCIP wing. The
  working multisig wing masked this; had the recv config *required* CCIP replicas to reach threshold,
  the gov message would NOT have delivered.

### ✅ FIXED & VERIFIED ON REAL CHAINS (re-run using the real Send/RecvSideDeployer)
The clone was fully re-deployed with the production `SendSideDeployer` / `RecvSideDeployer` (vendored in
`test/mocks/GovCcipSideDeployers.sol`) in the correct order (bare mainnet adapter → `RecvSideDeployer`
with the real mainnet peer → `configure()`+`handOff()`), and the whole flow re-run end-to-end. Results:
- **avax adapter `srcConfig[ETH].peer` == the REAL mainnet CCIP adapter** (`0xfB9119b2…`), **not `0xdead`**;
  mainnet `dstConfig[AVAX].peer` == real avax adapter (`0x76dfbB00…`), dest-gas **600k** (was 200k).
- A post-migration gov message (send tx `0xf7d8b169…`) fired both a LZ `PacketSent` and a Chainlink
  `CCIPSendRequested`; the CCIP message hopped Eth→Avax and **`ccipReceive` SUCCEEDED** — all **4 CCIP
  replicas verified in one Avax tx `0xa68a2e78…`** (the analogue of the tx that previously reverted
  state-3). LZ Scan: **`QUORUM_REACHED`, 11/15 SUCCEEDED = 7 LZ DVNs + 4 CCIP replicas**.
- **The CCIP wing was load-bearing:** 7 LZ alone < 8, so the 4 CCIP replicas were required to reach
  threshold. The **multisig wing was NOT driven** this time. `lzReceive` then queued the gov action on
  the new relay (`actionsCount` 0→1). USDS round-trip (Eth→Avax→Eth) reconciled to zero.
- Operational note: the LZ **auto-executor's gas-limited `lzReceive` simulation reverted** on the new
  relay's queue path (recv enforced gas `LZRECEIVE_GAS` too low for the queue), so delivery needed a
  permissionless force-`lzReceive` (generous gas). Same operational class as #6; a clone-gas tuning
  item, not a migration bug — but worth raising the enforced lzReceive gas for gov messages.

## 3. ⭐ CCIP DVN must be prefunded before the FIRST post-migration gov message (and `quoteTx` hides it)
After migration the gov **send** config is 8-of-8 **including the CCIP DVN adapter**, so any gov send
runs the mainnet CCIP adapter's `assignJob` → `ccipSend`, which must pay the Chainlink CCIP router in
native. A freshly-deployed adapter holds 0 native and 0 accrued send-lib fees, so the send reverts
inside `assignJob` unless prefunded (~0.001 ETH covers it; observed shortfall ~0.00031 ETH).
Critically, `quoteTx` returns a low fee (~0.00034 ETH) and does **not** surface the prefunding
requirement — it only bites at execution.
- **The migration ITSELF does NOT need CCIP funding** (correcting an earlier overstatement).
  `migrateAvax` relays the L2 spell (`relayToL2`, ~line 140) BEFORE it upgrades the send DVN set
  (`setUlnConfig`, ~line 191), so the migration's own relay goes out under the *pre-migration* send
  config — the current 4-of-7 LZ set, **no CCIP**. The CCIP adapter enters the send config only after
  the relay and is first invoked by a *subsequent* gov message. Verified by code order + the clone's
  pre-migration `_ethSendUlnCfg` (4-of-7, no CCIP).
- The re-run observation that "unfunded CCIP reverts `migrateAvax`" was a **re-run/partial-state
  artifact**: a partially-applied prior `migrate` had already installed the 8/8 CCIP send config, so
  the re-run's relay used it. On a clean one-shot migration (the real spell path) the relay never
  touches CCIP. (The genuine migration-revert seen mid-run was the JSON-key-clobber script bug, since
  fixed.)
- **Implication:** governance/ops must prefund the mainnet CCIP DVN adapter (or let it accrue
  send-lib fees) before the **first post-migration gov message**. The migration spell itself does not
  require it. This is the single most important operational item for the hardened gov bridge.

## 4. Deploy ORDER: both CCIP adapters' peers are SET-ONCE — use the real deployers (FIXED)
`CCIPDVNAdapter.setDstConfig` sets `(chainSelector, peer)` for a destination **once** and never
overwrites it, and it writes BOTH the `dstConfig` peer (send target) AND the `srcConfig` peer (the
`ccipReceive` sender check) in that one call. Each adapter's peer is the *other* adapter — a mutual
dependency. The **production `SendSideDeployer` / `RecvSideDeployer` resolve this correctly**, and the
clone now uses them (vendored verbatim in `test/mocks/GovCcipSideDeployers.sol`; the send side as
`CloneSendSideDeployer`, differing only in a parameterized `handOff` pause-proxy):
- **`SendSideDeployer` splits deploy from wiring.** Its constructor deploys the mainnet adapter BARE
  (roles + allowlist, no peer); the peer is set later by `configure()`. So the mainnet adapter can be
  deployed FIRST with no dependency.
- **`RecvSideDeployer`'s constructor takes the source adapter** and bakes the REAL mainnet adapter as
  the Avax adapter's `srcConfig` peer — so it runs AFTER the bare mainnet adapter exists.
- **Then `CloneSendSideDeployer.configure()`** (in `wire-oft`) sets the mainnet adapter's `dstConfig`
  peer to the REAL Avax adapter, and `handOff()` moves admin to the clone pause proxy (EOA).

Correct order, now baked into the `Makefile` and README:
`deploy-oft-eth` (bare mainnet adapter) → `deploy-oft-avax` → `deploy-dvn-broadcaster` (RecvSideDeployer,
real mainnet peer) → `wire-oft` (configure + handoff). No placeholder is ever written on either side.
- This REPLACES the earlier hand-rolled "seed a `0xdead` placeholder then clear it" dance, which only
  ever fixed the mainnet (send) peer and left the Avax (recv) peer permanently pointing at `0xdead` —
  the confirmed cause of the broken CCIP wing (§2b).
- Storage-key quirk: an adapter stores its config at `eid % 30000` (AVAX 30106 → 106, ETH 30101 →
  101). Read it there, not at the raw eid, when verifying with `cast`.
- Also set the mainnet adapter's dest-gas to **600k** (`CCIP_RECV_GAS`, matching the production
  reference) so the Avax `ccipReceive` has budget to fan out to its 4 replicas; the earlier 200k was a
  latent second bug that would have caused out-of-gas even after the peer was fixed.

## 4b. ⭐ Enforced `lzReceive` gas too low → gov messages don't auto-deliver (ACTIONABLE for ops)
Even with ≥8 DVNs verified (QUORUM_REACHED), a post-migration gov message did NOT auto-deliver: the LZ
executor's gas-limited `lzReceive` **simulation reverted** (LZ Scan `status: FAILED — "Executor
transaction simulation reverted"`), because the gov receiver's enforced `lzReceive` gas
(`LZRECEIVE_GAS`) is too low for the new relay's action-**queue** path (which does storage writes). The
packet was correctly committed; only the executor's auto-delivery step balked. A permissionless
`endpoint.lzReceive(...)` (via `deliver.sh <sendTx> eth avax 0`, which uses a generous gas limit) then
succeeded and queued the action.
- **Implication for the real spell:** size the gov recv **enforced lzReceive gas** to cover the L2
  relay's queue path, or every gov message will silently sit committed-but-undelivered until someone
  force-delivers it. Not a migration-logic bug; a config/ops item. Distinct from #6 (executor *lag*):
  here the executor *never* delivers because its simulation reverts, not because it's slow.

## 4c. sUSDS bridging is opened asymmetrically by the migration inputs (verify the real spell's params)
The clone's migration inputs (`CloneAvaxRunMigration._buildMigration`) activate the **new** sUSDS OFTs
but set the **L1 (Ethereum) new sUSDS lockbox rate limits to `RateLimits(0,0,0,0)`** (per-eid AND
global), while the **Avax new sUSDS m/b gets real limits (3M in / 2M out)** — and USDS gets 5M/4M on
both sides. Consequences observed on real chains:
- A sUSDS send from L1 reverts **`RateLimitExceeded` (`0xa74c1c5f`)** at `send()` — note `quoteSend()`
  (a view) does NOT check limits, so it returns a fee and hides the problem until execution.
- The asymmetry is a **footgun**: if a real deployment opens the Avax sUSDS side (outbound > 0) but
  leaves the L1 side at 0, the bridge will **accept Avax→Eth sends it cannot deliver** (the L1 inbound
  limit rejects the `lzReceive`), stranding value in flight.
- Once the L1 sUSDS limits are opened (the L1 lockbox is owned by the deployer/pause-proxy, so a plain
  `setRateLimits` suffices — no gov message), the full sUSDS round-trip reconciles to zero
  (Eth→Avax mint 1000e18, Avax→Eth burn + unlock, back to 0).
- **This is a clone-input choice, not migration-lib behavior** — but whoever authors the real spell
  must set the intended sUSDS rate limits deliberately and symmetrically (or intentionally keep sUSDS
  L1 closed, matching the abandoned-L1-sUSDS-OFT posture). Only USDS was opened for bridging here.

## 5. EIP-170 only passes with the optimizer — and `forge test` doesn't catch it
`SkyOFTAdapter` compiles to ~31 KB unoptimized (limit 24,576), so `forge script --broadcast` refuses
to deploy it; `forge test` never enforces EIP-170, so the fork tests pass silently. `optimizer=200`
drops it under the limit. Production compiles optimized so it ships fine — but a size regression
would pass every test and fail only at deploy. `foundry.toml` here now sets the optimizer on.

## 6. Real LayerZero delivery is not instant / can stall at the executor
For the cross-chain messages the DVNs verified/committed the packet on the destination in a few
minutes, but the LZ executor sometimes lagged. Delivery had to be finalized via a permissionless
`endpoint.lzReceive(...)` (see `deliver.sh`). Operationally, the migration's L2 spell (and any gov
message) may sit committed-but-unexecuted until someone delivers it.

## 7. The lib + deploy tooling are hardcoded to production (reusability limit, not a bug)
`LZInit` (and thus the migration) bakes the production chainlog as a constant, and `SendSideDeployer`
resolves the pause proxy from that same hardcoded chainlog. So the migration + its tooling can only
be exercised against production or a fork of it; a non-prod/clone run needs the parameterized
`LZAvaxMigrationCloneInit` + `CloneEnv` used here (CCIP admin granted to the deployer directly).

## Minor / clone-setup notes (all real-broadcast-only; forks never surfaced these)
- **JSON key clobbering (fixed).** `_writeAvaxSpell` (deployL2Spell) re-serialized `clone.avax.json`
  from a fixed key list and DROPPED the DVN-broadcaster keys (`avaxCcipAdapter`, `ccip/msigBroadcaster`,
  `ccip/msigReplicas`), so the later `migrateAvax` reverted "run chunk 3 first". Fixed by having
  `_writeAvaxSpell` preserve those keys. (A colleague running strictly in the documented order after
  this fix won't hit it.)
- **`OftSendLike.send` return type (fixed).** It declared `(bytes,bytes)` but the OFT returns
  `(MessagingReceipt, OFTReceipt)`; forge reverts with empty data decoding the return even though the
  on-chain send SUCCEEDED, so `send-to-avax` / `send-back` failed. Fixed to the real structs; if you
  still hit an empty revert, drive the round-trip with `cast` (a raw send doesn't decode the return).
- On `--slow` mainnet broadcasts we hit `replacement transaction underpriced` mid-batch, leaving a
  script half-applied (some setters landed, others didn't). Twice this left state incomplete on real
  chains: (a) the mainnet gov-bridge `deploy()` landed the contracts + `MCD_PAUSE_PROXY` but not the
  later `FakeChainlog.setAddress(LZ_GOV_SENDER/RELAY/USDS/SUSDS)` calls (migration then read 0x0 for
  the gov sender); (b) the gov-bridge SEND `wire()` landed `setSendLibrary`+`setConfig` but not
  `setPeer`/`setEnforcedOptions`/`setCanCallTarget` AND the ULN send config (so `_checkDvnOverlap`
  saw an empty current set). Both were completed with the documented `cast` setters. The OFT L1 wire
  broadcasts WITHOUT `--slow` (one batch) to avoid this; re-running a `--slow` bridge `wire()` after a
  partial land can revert on `setSendLibrary` (already set) — prefer completing residual setters by hand.
- **`deliver.sh` committed-vs-executed (FIXED).** Its poll originally used `inboundNonce`, which
  advances when a packet is COMMITTED at the ULN but not yet EXECUTED (`lzReceive` not run) — so it
  printed "DELIVERED" for a committed-but-unexecuted packet and never force-delivered, and the
  dependent `execQueued` then reverted `invalid-action-id`. Fixed to poll **`lazyInboundNonce`**
  (advances on `lzReceive` execution). A force `lzReceive` before ≥threshold DVNs have verified still
  reverts `0x7182306f` (ULN verifying) — retry until committed.
- CCIP `CCIPDVNAdapterFeeLib.initialize()` reverts on a real deploy (hardhat-deploy `proxied` slot
  already sentinel) though it inits cleanly under `forge test`/`new` — handled with try/catch.
- Clone-scaffold invariants (both confirm migration expectations): the pre-migration gov whitelist
  must target the OLD relay, and the OLD L2 relay must be deployed with `l1GovernanceRelay` set (else
  the relayed spell reverts `bad-message-auth`).

## Bottom line
Migration logic verified on real chains under the full production DVN topology (8-of-15 recv, 8/8
send incl. CCIP, 4/4 OFT). Using the production `Send`/`RecvSideDeployer` in the correct order, the
hardened gov path now executes end-to-end **via the CCIP wing** — a post-migration gov message reached
its 8-of-15 threshold with 7 LZ DVNs + **4 CCIP replicas (load-bearing; multisig wing not used)**, the
CCIP `ccipReceive` succeeded on Avax, and `lzReceive` queued the action (§2b ✅). The earlier
`0xdead` set-once placeholder that silently killed the CCIP wing is gone. Action items for the real
spell: **#3 (prefund the mainnet CCIP DVN before the first post-migration gov message; `quoteTx` won't
warn you — the migration spell itself does not need it)**; ensure the gov recv **enforced lzReceive gas**
is high enough for the new relay's queue path (else messages need a permissionless force-`lzReceive`).
**#4 (deploy order via the real deployers)** is baked into the Makefile; **#5–#7** are process notes.
