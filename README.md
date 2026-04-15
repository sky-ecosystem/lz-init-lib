# LZ Init Library

Reusable Solidity library for LayerZero configuration in Sky governance spells. Standardizes the wiring and management of SkyLink deployments across chains.

## Library Functions (`LZInit.sol`)

### L1 Functions

- **`addGovRoute`** — Add a governance route from LZ_GOV_SENDER to a new remote chain. Sets the peer, send library, DVN/executor config, and whitelists the L1GovernanceRelay via setCanCallTarget.
- **`addOftRoute`** — Add a new OFT route from the local chain to a remote chain. Sets the peer, send/receive libraries, DVN/executor configs, enforced options, and rate limits. Also usable on L2 via `relayAddOftRoute`.
- **`activateOft`** — Activate a deployer-configured OFT adapter by setting non-zero rate limits. Includes sanity checks (owner, delegate, peer, token, paused, rate limits at zero, accounting type). Also usable on L2 via `relayActivateOft`.
- **`updateRateLimits`** — Update rate limits on an OFT adapter for a given destination.

### Relay Functions (L1 → L2)

Each relay function encodes a call to the corresponding `LZL2Spell` function and sends it via the LZ governance bridge.

- **`relayAddOftRoute`**
- **`relayActivateOft`**
- **`relayUpdateRateLimits`**

### Star Subproxy

- **`initLZSender`** — Configure the LZ endpoint for a non-OApp sender (e.g. Star subproxy using LZForwarder).

## L2 Spell (`LZL2Spell.sol`)

Deployed once per L2, delegatecalled by `L2GovernanceRelay`. Exposes `addOftRoute`, `activateOft`, and `updateRateLimits` for remote execution via relay.

## Build

```shell
forge build
```

## Test

```shell
MAINNET_RPC_URL=<mainnet_rpc> forge test
```
