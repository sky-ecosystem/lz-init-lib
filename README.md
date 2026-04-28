# LZ Init Library

Reusable Solidity library for LayerZero configuration in Sky governance spells. Standardizes the wiring and management of SkyLink deployments across chains.

## Library Functions (`LZInit.sol`)

### L1 Functions

- **`wireGovPeer`** — Connect LZ_GOV_SENDER to a new remote peer and whitelist LZ_GOV_RELAY. The remote peer (a GovernanceOAppReceiver) and the L2GovernanceRelay will have been configured by a deployer beforehand.
- **`wireOftPeer`** — Connect a local OFT adapter to a new remote peer. Configures the OFT locally to support the new peer and sets its rate limits. In the case of a new remote, the remote OFT adapter will have been configured by a deployer before its ownership is transferred to the L2GovernanceRelay. Also usable on L2 via `LZL2Spell` + `relayToL2`.
- **`activateOft`** — Activate an OFT adapter owned by governance (PAUSE_PROXY on L1, L2GovernanceRelay on L2) by setting non-zero rate limits. Verifies the on-chain state was configured as expected before flipping the limits on. Also usable on L2 via `LZL2Spell` + `relayToL2`.
- **`updateRateLimits`** — Update rate limits on an OFT adapter for a given destination. Also usable on L2 via `LZL2Spell` + `relayToL2`.
- **`unpauseOft`** — Unpause an OFT adapter. Also usable on L2 via `LZL2Spell` + `relayToL2`.

### Relay (L1 → L2)

- **`relayToL2`** — Forward an arbitrary call to an `LZL2Spell` on a destination chain via the LZ governance bridge. Spell authors construct `targetData` with `abi.encodeCall(LZL2SpellLike.x, (...))`.

## L2 Spell (`LZL2Spell.sol`)

Deployed once per L2, delegatecalled by `L2GovernanceRelay`. Exposes `wireOftPeer`, `activateOft`, `updateRateLimits`, and `unpauseOft` for remote execution via `relayToL2`.

## Build

```shell
forge build
```

## Test

```shell
MAINNET_RPC_URL=<mainnet_rpc> forge test
```

Tests fork mainnet and Avalanche at pinned historical blocks, so both RPCs must be archive-capable. Set `MAINNET_RPC_URL` for the mainnet fork; if `AVALANCHE_RPC_URL` is unset, forge-std's built-in default (`https://api.avax.network/ext/bc/C/rpc`) is used.
