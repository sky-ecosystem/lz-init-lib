# LZ Init Library

Library for Sky governance spells to help manage SkyLink and its extension to new chains.

This repository provides general-purpose library functions (`LZInit.sol`) plus one-off helpers for specific migrations (the Avalanche hardening migration being the current example), intended to be imported and called from a governance spell. It does not contain deployment scripts: deploying and pre-configuring newly deployed remote contracts is the responsibility of the deployer and is assumed to happen separately, before the spell runs.

## General-Purpose Library (`LZInit.sol`)

### Configuration Functions

- **`wireGovPeer`** - Connect LZ_GOV_SENDER to a new remote peer and whitelist LZ_GOV_RELAY. The remote peer (a GovernanceOAppReceiver) and the L2GovernanceRelay will have been configured by the deployer beforehand. Verifies the shared CCIP DVN adapter is routed to the new chain (assumed to have been wired separately via `LZDVNInit.wireCCIPDVN` in [`sky-ecosystem/lz-gov-dvns-deploy`](https://github.com/sky-ecosystem/lz-gov-dvns-deploy)).
- **`wireOftPeer`** - Connect a local OFT adapter to a new remote peer. Configures the OFT locally to support the new peer and sets its rate limits. In the case of a new remote, the remote OFT adapter will have been configured by the deployer before its ownership is transferred to the L2GovernanceRelay. Also usable on L2 via `LZL2Spell` + `relayToL2`.
- **`activateOft`** - Activate an OFT adapter owned by governance (PAUSE_PROXY on L1, L2GovernanceRelay on L2) by setting non-zero per-eid rate limits. Verifies the on-chain state was configured as expected before flipping the limits on. Also usable on L2 via `LZL2Spell` + `relayToL2`.
- **`updateGlobalRateLimits`** - Set an OFT's global (`SENTINEL_EID`) rate-limit cap, the L1 lockbox's (`SkyOFTAdapter`) aggregate limit across all remotes, on top of the per-eid buckets. L1-lockbox only (L2 remote OFTs have no global cap).
- **`updateRateLimits`** - Update rate limits on an OFT adapter for a given destination. Also usable on L2 via `LZL2Spell` + `relayToL2`.
- **`setUlnConfig`** - Update the ULN (DVN) config for an OApp's send or receive library for a given remote eid. Also usable on L2 via `LZL2Spell` + `relayToL2`.
- **`unpauseOft`** - Unpause an OFT adapter. Also usable on L2 via `LZL2Spell` + `relayToL2`.
- **`activateSsrForwarder`** - Whitelist an SSR oracle forwarder on the shared CCIP DVN adapter it uses as a DVN. Verifies the forwarder's on-chain config was configured as expected and the CCIP DVN adapter was routed to the destination chain (assumed wired via `LZDVNInit.wireCCIPDVN`), before granting the whitelist. L1-only.

### Relay (L1 → L2)

- **`relayToL2`** - Forward an arbitrary call to an `LZL2Spell` on a destination chain via the LZ governance bridge. Spell authors construct `targetData` with `abi.encodeCall(LZL2Spell.x, (...))`.

### L2 Spell (`LZL2Spell.sol`)

Deployed once per L2, delegatecalled by `L2GovernanceRelay`. Exposes `wireOftPeer`, `activateOft`, `updateRateLimits`, `setUlnConfig`, and `unpauseOft` for remote execution via `relayToL2`, plus `multicall` to bundle several of these into a single relayed message.

### Disclaimer: ordering of relayed calls

LZ does not guarantee the execution order of relayed messages. If a spell relays more than one message and order matters for safety, bundle the L2-side work into a single message via `LZL2Spell.multicall` and/or split the work across multiple spells.

## Illustrative Examples

> **Disclaimer:** the examples below are illustrative and intended to help understand the structure of the library; they are not definitive templates. They generally assume simplified preconditions for conciseness and no guarantee is made that any is suitable as-is. Each scenario should be carefully analysed against the actual on-chain state and the specifics of the change being made; depending on those, the required sequencing may differ and/or additional safeguards beyond what's shown may be needed.

The examples below assume Avalanche and Plasma each have USDS and sUSDS OFTs wired to L1, but not to each other.

### Unpausing OFTs after an emergency pause

If USDS OFTs on L1 and Avalanche have been paused, a spell is required to unpause them:

- `unpauseOft(USDS_OFT)` for the L1 side
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2Spell.unpauseOft, (AVAX_USDS_OFT)), ...)` for the Avalanche OFT

### Increasing rate limits

- `updateRateLimits(USDS_OFT, AVAX_EID, ...)` for the L1 side
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2Spell.updateRateLimits, (AVAX_USDS_OFT, ETH_EID, ...)), ...)` for the Avalanche side

### Reducing rate limits and unpausing after an emergency pause

Bundle the L2 calls into one relayed message so users can't bridge at the old higher limit between the two L2 ops, in case these get executed out of order:

- `updateRateLimits(USDS_OFT, AVAX_EID, ...)` for the L1 side
- `unpauseOft(USDS_OFT)` for the L1 side
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2Spell.multicall, (calls)), ...)` for the Avalanche side, where `calls = [encodeCall(updateRateLimits, ...), encodeCall(unpauseOft, ...)]`

### Migrating to a new DVN set

#### OFT bridge

For simplicity we assume the new DVN set is a superset of the old required set. Otherwise, messages sent during the wait window between Spell 1 and Spell 2 may not be verifiable on the receive side and could be stuck; a different sequence would be required.

Spell 1 (update sending sides):

- `setUlnConfig(USDS_OFT, AVAX_EID, ETH_SEND_LIB, newUlnCfg)` - L1 send (Eth→Avax)
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2Spell.setUlnConfig, (AVAX_USDS_OFT, ETH_EID, AVAX_SEND_LIB, newUlnCfg)), ...)` - L2 send (Avax→Eth)

(wait long enough for any old-signed in-flight messages to settle against the still-old receive side)

Spell 2 (update receiving sides):

- `setUlnConfig(USDS_OFT, AVAX_EID, ETH_RECV_LIB, newUlnCfg)` - L1 receive (Avax→Eth)
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2Spell.setUlnConfig, (AVAX_USDS_OFT, ETH_EID, AVAX_RECV_LIB, newUlnCfg)), ...)` - L2 receive (Eth→Avax)

#### Governance bridge

A quirk in LZ's off-chain DVN tooling makes the single-spell form fail in practice, so the migration is split across two.

Spell 1 (update receive side):

- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2Spell.setUlnConfig, (AVAX_GOV_RECEIVER, ETH_EID, AVAX_RECV_LIB, newUlnCfg)), ...)` - L2 receive (Eth→Avax)

(wait for the L2 update to land; halt gov bridge messaging until Spell 2 executes)

Spell 2 (update send side):

- `setUlnConfig(LZ_GOV_SENDER, AVAX_EID, ETH_SEND_LIB, newUlnCfg)` - L1 send (Eth→Avax)

### Activating a previously wired OFT

If sUSDS OFTs on L1 and Avalanche have been wired together and had their ownership and LZ delegate transferred to Sky, but their rate limits are still 0, a spell is required to activate them:

- `activateOft(SUSDS_OFT, AVAX_EID, ...)` - activate the L1 side
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2Spell.activateOft, (AVAX_SUSDS_OFT, ...)), ...)` - activate the Avalanche side

### Wiring two existing remotes together

If two EVM remotes (e.g. Avalanche and Plasma) are each wired to L1 for USDS and sUSDS but not to one another, an L1 spell is required to wire them together:

- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2Spell.wireOftPeer, (AVAX_USDS_OFT, PLASMA_EID, ...)), ...)` - wire Avalanche's USDS to Plasma
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2Spell.wireOftPeer, (AVAX_SUSDS_OFT, PLASMA_EID, ...)), ...)` - wire Avalanche's sUSDS to Plasma
- `relayToL2(PLASMA_EID, ..., abi.encodeCall(LZL2Spell.wireOftPeer, (PLASMA_USDS_OFT, AVAX_EID, ...)), ...)` - wire Plasma's USDS to Avalanche
- `relayToL2(PLASMA_EID, ..., abi.encodeCall(LZL2Spell.wireOftPeer, (PLASMA_SUSDS_OFT, AVAX_EID, ...)), ...)` - wire Plasma's sUSDS to Avalanche

### Onboarding an SSR oracle bridge to a new chain

A new SSR oracle bridge is an L1 forwarder → remote receiver → SSR oracle. Given the deployer has deployed and configured those contracts, and the shared CCIP DVN adapter is already routed to that chain, an L1 spell whitelists the forwarder on the adapter:

- `activateSsrForwarder(SSR_FORWARDER, REMOTE_EID, cfg)` - verify the L1 forwarder and the adapter's route to the chain, then whitelist it on the shared adapter

### Expanding SkyLink to a new chain

To add Base as a new remote for both USDS and sUSDS, after the deployer has deployed and pre-configured Base's `GovernanceOAppReceiver`, `L2GovernanceRelay`, and OFT adapters, an L1 spell calls:

- `LZDVNInit.wireCCIPDVN(LZ_GOV_CCIP_DVN_ADAPTER, ...)` - route the shared CCIP DVN adapter to Base (sister lib `lz-gov-dvns-deploy`); `wireGovPeer` verifies this route is set
- `wireGovPeer(BASE_EID, ...)` - add Base as a destination for `LZ_GOV_SENDER`
- `wireOftPeer(USDS_OFT, BASE_EID, ...)` - connect L1 USDS to Base
- `wireOftPeer(SUSDS_OFT, BASE_EID, ...)` - connect L1 sUSDS to Base
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2Spell.wireOftPeer, (AVAX_USDS_OFT, BASE_EID, ...)), ...)` - wire Avalanche USDS to Base
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2Spell.wireOftPeer, (AVAX_SUSDS_OFT, BASE_EID, ...)), ...)` - wire Avalanche sUSDS to Base
- `relayToL2(PLASMA_EID, ..., abi.encodeCall(LZL2Spell.wireOftPeer, (PLASMA_USDS_OFT, BASE_EID, ...)), ...)` - wire Plasma USDS to Base
- `relayToL2(PLASMA_EID, ..., abi.encodeCall(LZL2Spell.wireOftPeer, (PLASMA_SUSDS_OFT, BASE_EID, ...)), ...)` - wire Plasma sUSDS to Base

## One-off Migration Helpers

Helpers for specific, single-use migrations, each built on the `LZInit` primitives as its own pair of files (an L1 `*Init` library + an L2 spell). The Avalanche hardening migration is the current example.

### Avalanche hardening migration (`LZAvaxMigrationInit.sol` + `LZAvaxMigrationL2Spell.sol`)

`migrateAvax` (L1) + the `migrateAvaxRemote` it relays to Avalanche move the Sky↔Avalanche bridges to a hardened setup in a single spell:

- **Gov bridge** → new DVN set and a new delay/freezer `L2GovernanceRelay`.
- **USDS bridge** → new OFT V2 adapters (L1 + Avalanche); the Avalanche backing is moved from the old L1 adapter to the new one, and the old adapter stays live for Solana.
- **sUSDS bridge** → new OFT V2 adapters (L1 + Avalanche); the old ones are retired.

Preconditions (deployer): the new relay and the new OFT V2 adapters (USDS + sUSDS, on both L1 and Avalanche) are deployed and pre-configured (peer, libs, DVNs, enforced options, fees off), and the new Avalanche adapters are owned by the **old** relay until the spell hands them over.

Avalanche is expected to be the first L2 brought up on the V2 OFTs. If it isn't, it is assumed that the earlier L2's spell either hasn't updated the chainlog yet, or updated it consistently, with `USDS_OFT`/`SUSDS_OFT` pointing to the new V2 OFTs and the legacy key (`legacyCLKey`, e.g. `USDS_OFT_SOLANA`) to the old OFT. Under that assumption the spell still works, just redundantly: `migrateAvax`'s checks re-verify some of the already-checked state and the chainlog writes rewrite the same values, while the Avalanche route is set fresh and the global caps overwritten. The global-cap inputs must then be the system-wide totals across every L2 on the new lockbox supported so far (excluding Solana, which stays on the old USDS adapter).

#### Deployment model: embedded (default) or linked

By default the spell calls `LZAvaxMigrationInit.migrateAvax(m)`, embedding the migration in the spell. No prior deployment or linker setup is needed.

If the spell is too large to embed it, call `LZAvaxMigrationInit.migrateAvaxLinked(m)` instead (same arguments and behaviour) and link against a pre-deployed copy of the library:

1. Deploy the library (self-contained, no further linking required):
   ```shell
   forge create deploy/LZAvaxMigrationInit.sol:LZAvaxMigrationInit --rpc-url <mainnet_rpc> --private-key <key> --verify
   ```
2. In the spell repo's `foundry.toml`, link the deployed address (the source path must match its import path in that repo):
   ```toml
   libraries = ["<path>/LZAvaxMigrationInit.sol:LZAvaxMigrationInit:0x<deployed_address>"]
   ```

The Avalanche half is unaffected either way.

## Build

```shell
forge build
```

## Test

```shell
MAINNET_RPC_URL=<mainnet_rpc> AVALANCHE_RPC_URL=<avalanche_rpc> forge test
```

Tests fork mainnet and Avalanche at pinned historical blocks, so both RPCs must be archive-capable. `MAINNET_RPC_URL` is required (used internally by `xchain-helpers`); `AVALANCHE_RPC_URL` is optional and falls back to forge-std's default if unset.
