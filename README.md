# LZ Init Library

Reusable Solidity library for LayerZero configuration in Sky governance spells. Standardizes the wiring and management of SkyLink deployments across chains.

## Library Functions (`LZInit.sol`)

### L1 Functions

- **`wireGovPeer`** — Connect LZ_GOV_SENDER to a new remote peer and whitelist LZ_GOV_RELAY. The remote peer (a GovernanceOAppReceiver) and the L2GovernanceRelay will have been configured by a deployer beforehand.
- **`wireOftPeer`** — Connect a local OFT adapter to a new remote peer. Configures the OFT locally to support the new peer and sets its rate limits. In the case of a new remote, the remote OFT adapter will have been configured by a deployer before its ownership is transferred to the L2GovernanceRelay. Also usable on L2 via `relayWireOftPeer`.
- **`activateOft`** — Activate an OFT adapter owned by governance (PAUSE_PROXY on L1, L2GovernanceRelay on L2) by setting non-zero rate limits. Verifies the on-chain state was configured as expected before flipping the limits on. Also usable on L2 via `relayActivateOft`.
- **`updateRateLimits`** — Update rate limits on an OFT adapter for a given destination.

### Relay Functions (L1 → L2)

Each relay function encodes a call to the corresponding `LZL2Spell` function and sends it via the LZ governance bridge.

- **`relayWireOftPeer`**
- **`relayActivateOft`**
- **`relayUpdateRateLimits`**

### Star Subproxy

- **`initLZSender`** — Configure the LZ endpoint for a non-OApp sender (e.g. Star subproxy using LZForwarder).

## L2 Spell (`LZL2Spell.sol`)

Deployed once per L2, delegatecalled by `L2GovernanceRelay`. Exposes `wireOftPeer`, `activateOft`, and `updateRateLimits` for remote execution via relay.

## Build

```shell
forge build
```

## Test

```shell
MAINNET_RPC_URL=<mainnet_rpc> forge test
```

Tests fork mainnet and Avalanche at pinned historical blocks, so both RPCs must be archive-capable. Set `MAINNET_RPC_URL` for the mainnet fork; if `AVALANCHE_RPC_URL` is unset, forge-std's built-in default (`https://api.avax.network/ext/bc/C/rpc`) is used.
