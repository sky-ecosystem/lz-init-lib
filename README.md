# LZ Init Library

Library for Sky governance spells to help manage SkyLink and its extension to new chains.

This repository provides library functions (`LZInit.sol`) intended to be imported and called from a governance spell. It does not contain deployment scripts: deploying and pre-configuring newly deployed remote contracts is the responsibility of the deployer and is assumed to happen separately, before the spell runs.

## Library Functions (`LZInit.sol`)

### Configuration Functions

- **`wireGovPeer`** — Connect LZ_GOV_SENDER to a new remote peer and whitelist LZ_GOV_RELAY. The remote peer (a GovernanceOAppReceiver) and the L2GovernanceRelay will have been configured by the deployer beforehand.
- **`wireOftPeer`** — Connect a local OFT adapter to a new remote peer. Configures the OFT locally to support the new peer and sets its rate limits. In the case of a new remote, the remote OFT adapter will have been configured by the deployer before its ownership is transferred to the L2GovernanceRelay. Also usable on L2 via `LZL2Spell` + `relayToL2`.
- **`activateOft`** — Activate an OFT adapter owned by governance (PAUSE_PROXY on L1, L2GovernanceRelay on L2) by setting non-zero rate limits. Verifies the on-chain state was configured as expected before flipping the limits on. Also usable on L2 via `LZL2Spell` + `relayToL2`.
- **`updateRateLimits`** — Update rate limits on an OFT adapter for a given destination. Also usable on L2 via `LZL2Spell` + `relayToL2`.
- **`unpauseOft`** — Unpause an OFT adapter. Also usable on L2 via `LZL2Spell` + `relayToL2`.

### Relay (L1 → L2)

- **`relayToL2`** — Forward an arbitrary call to an `LZL2Spell` on a destination chain via the LZ governance bridge. Spell authors construct `targetData` with `abi.encodeCall(LZL2SpellLike.x, (...))`.

## L2 Spell (`LZL2Spell.sol`)

Deployed once per L2, delegatecalled by `L2GovernanceRelay`. Exposes `wireOftPeer`, `activateOft`, `updateRateLimits`, and `unpauseOft` for remote execution via `relayToL2`.

## Use Cases

The use cases below assume Avalanche and Plasma each have USDS and sUSDS OFTs wired to L1, but not to each other.

### Unpausing OFTs after an emergency pause

If USDS OFTs on L1 and Avalanche have been paused, a spell is required to unpause them:

- `unpauseOft(USDS_OFT)` for the L1 side
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2SpellLike.unpauseOft, (AVAX_USDS_OFT)))` for the Avalanche OFT

### Increasing rate limits

- `updateRateLimits(USDS_OFT, AVAX_EID, ...)` for the L1 side
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2SpellLike.updateRateLimits, (AVAX_USDS_OFT, ETH_EID, ...)))` for the Avalanche side

### Activating a previously wired OFT

If sUSDS OFTs on L1 and Avalanche have been wired together and had their ownership and LZ delegate transferred to Sky, but their rate limits are still 0, a spell is required to activate them:

- `activateOft(SUSDS_OFT, AVAX_EID, ...)` — activate the L1 side
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2SpellLike.activateOft, (AVAX_SUSDS_OFT, ...)))` — activate the Avalanche side

### Wiring two existing remotes together

If two EVM remotes (e.g. Avalanche and Plasma) are each wired to L1 for USDS and sUSDS but not to one another, an L1 spell is required to wire them together:

- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2SpellLike.wireOftPeer, (AVAX_USDS_OFT, PLASMA_EID, ...)))` — wire Avalanche's USDS to Plasma
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2SpellLike.wireOftPeer, (AVAX_SUSDS_OFT, PLASMA_EID, ...)))` — wire Avalanche's sUSDS to Plasma
- `relayToL2(PLASMA_EID, ..., abi.encodeCall(LZL2SpellLike.wireOftPeer, (PLASMA_USDS_OFT, AVAX_EID, ...)))` — wire Plasma's USDS to Avalanche
- `relayToL2(PLASMA_EID, ..., abi.encodeCall(LZL2SpellLike.wireOftPeer, (PLASMA_SUSDS_OFT, AVAX_EID, ...)))` — wire Plasma's sUSDS to Avalanche

### Expanding SkyLink to a new chain

To add Base as a new remote for both USDS and sUSDS, after the deployer has deployed and pre-configured Base's `GovernanceOAppReceiver`, `L2GovernanceRelay`, and OFT adapters, an L1 spell calls:

- `wireGovPeer(BASE_EID, ...)` — add Base as a destination for `LZ_GOV_SENDER`
- `wireOftPeer(USDS_OFT, BASE_EID, ...)` — connect L1 USDS to Base
- `wireOftPeer(SUSDS_OFT, BASE_EID, ...)` — connect L1 sUSDS to Base
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2SpellLike.wireOftPeer, (AVAX_USDS_OFT, BASE_EID, ...)))` — wire Avalanche USDS to Base
- `relayToL2(AVAX_EID, ..., abi.encodeCall(LZL2SpellLike.wireOftPeer, (AVAX_SUSDS_OFT, BASE_EID, ...)))` — wire Avalanche sUSDS to Base
- `relayToL2(PLASMA_EID, ..., abi.encodeCall(LZL2SpellLike.wireOftPeer, (PLASMA_USDS_OFT, BASE_EID, ...)))` — wire Plasma USDS to Base
- `relayToL2(PLASMA_EID, ..., abi.encodeCall(LZL2SpellLike.wireOftPeer, (PLASMA_SUSDS_OFT, BASE_EID, ...)))` — wire Plasma sUSDS to Base

## Build

```shell
forge build
```

## Test

```shell
MAINNET_RPC_URL=<mainnet_rpc> forge test
```

Tests fork mainnet and Avalanche at pinned historical blocks, so both RPCs must be archive-capable. Set `MAINNET_RPC_URL` for the mainnet fork; if `AVALANCHE_RPC_URL` is unset, forge-std's built-in default (`https://api.avax.network/ext/bc/C/rpc`) is used.
