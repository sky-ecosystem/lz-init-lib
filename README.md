# LZ Init Library

Reusable Solidity library for LayerZero configuration actions in Sky/Maker governance spells. Imported by Ethereum spells to standardize and de-duplicate the wiring of new remote chain SkyLink deployments.

## Functions

- `initGovSender` — Wire GovernanceOAppSender to a new remote chain (setPeer, send/receive libraries, ULN/executor configs, setCanCallTarget for L1GovernanceRelay)
- `initOFTAdapter` — Wire an OFT adapter (USDS or sUSDS) to a new remote chain (setPeer, send/receive libraries, ULN/executor configs, rate limits, enforced options). Also used for L2 routing (existing remote → new remote).
- `whitelistStarGovernance` — Allow a Star subproxy (e.g. Spark) to govern a remote chain via the LZ governance bridge
- `whitelistSSRForwarder` — Allow the SSR oracle forwarder to push savings rate data to a remote chain
- `initSusdsBridge` — Activate a pre-configured sUSDS OFT adapter by setting rate limits. For the first sUSDS deployment where the adapter has been deployed and fully configured by the deployer (peer, libraries, configs, enforced options) but rate limits are at zero. Includes sanity checks (owner, delegate, peer, token, paused state, rate limits at zero, accounting type).

## TBDs

- [ ] `initGovSender`: should `setReceiveLibrary` and receive-direction `setConfig` be included? The GovernanceOAppSender is send-only, so a receive library is arguably unnecessary. However, the active on-chain GovSender has both explicitly set for Solana (EID 30168). The Pullup and Dewiz manuals omit them, Sidestream includes them (flagged as "to be confirmed by LayerZero"). Need to decide whether to match the current on-chain config or skip these calls.
- [ ] Should `initOFTAdapter` enforce that `enforcedOptions` are set for both `msgType=1` (SEND) and `msgType=2` (SEND_AND_CALL), or leave this to the caller? The actual deployed mainnet config uses both, but the Pullup and Dewiz manuals only show `msgType=1`.
- [ ] Should `initGovSender` and `initOFTAdapter` read reference configs on-chain (e.g. `endpoint.getSendLibrary(existingAdapter, refDstEid)`) to derive defaults, or require all params to be passed explicitly? The manuals show both patterns — Pullup/Dewiz read from reference, Sidestream hardcodes values.
- [ ] Executor `maxMessageSize` varies: Sidestream uses 10,000 for GovSender and 1,000 for OFT on Avalanche. Should this be a parameter or derived from reference?
- [ ] Should the library handle the one-off sUSDS SkyOFTAdapter deployment on Ethereum (Dewiz Section 6.0 / 7.0), or is that out of scope?
- [ ] Confirm the exact struct layout for config parameters — should the library define its own config structs or re-export LZ types?
- [ ] L2 routing: confirm whether L2 spells can import and use the same `initOFTAdapter` function, or if a separate wrapper is needed for the governance relay execution context.

## Build

```shell
forge build
```

## Test

```shell
forge test
```
