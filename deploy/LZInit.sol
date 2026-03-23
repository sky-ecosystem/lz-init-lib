// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

/*** Structs — importable by spells ***/

struct SetConfigParam {
    uint32 eid;
    uint32 configType;
    bytes  config;
}

struct UlnConfig {
    uint64    confirmations;
    uint8     requiredDVNCount;
    uint8     optionalDVNCount;
    uint8     optionalDVNThreshold;
    address[] requiredDVNs;
    address[] optionalDVNs;
}

struct ExecutorConfig {
    uint32  maxMessageSize;
    address executor;
}

struct RateLimitConfig {
    uint32  eid;
    uint48  window;
    uint256 limit;
}

struct EnforcedOptionParam {
    uint32 eid;
    uint16 msgType;
    bytes  options;
}

/*** Interfaces ***/

interface EndpointLike {
    function setSendLibrary(address oapp, uint32 eid, address newLib) external;
    function setReceiveLibrary(address oapp, uint32 eid, address newLib, uint256 gracePeriod) external;
    function setConfig(address oapp, address lib, SetConfigParam[] calldata params) external;
    function delegates(address oapp) external view returns (address);
}

interface GovOAppSenderLike {
    function setPeer(uint32 eid, bytes32 peer) external;
    function setCanCallTarget(address srcSender, uint32 dstEid, bytes32 dstTarget, bool canCall) external;
}

interface OFTAdapterLike {
    function setPeer(uint32 eid, bytes32 peer) external;
    function setRateLimits(RateLimitConfig[] calldata inbound, RateLimitConfig[] calldata outbound) external;
    function setEnforcedOptions(EnforcedOptionParam[] calldata opts) external;
    function owner() external view returns (address);
    function endpoint() external view returns (address);
    function peers(uint32 eid) external view returns (bytes32);
    function token() external view returns (address);
    function paused() external view returns (bool);
    function outboundRateLimits(uint32 eid) external view returns (uint128, uint48, uint256, uint256);
    function inboundRateLimits(uint32 eid) external view returns (uint128, uint48, uint256, uint256);
    function rateLimitAccountingType() external view returns (uint8);
}

/*** Library ***/

library LZInit {

    uint32 internal constant EXECUTOR_CONFIG_TYPE = 1;
    uint32 internal constant ULN_CONFIG_TYPE      = 2;

    uint16 internal constant MSG_TYPE_SEND          = 1;
    uint16 internal constant MSG_TYPE_SEND_AND_CALL = 2;

    /**
     * @notice Activate the sUSDS bridge by setting rate limits on a pre-configured OFT adapter.
     * @dev This function is intended for the first sUSDS deployment scenario where the
     *      SkyOFTAdapter (sUSDS) on Ethereum has been deployed and fully configured by the
     *      deployer (peer, send/receive libraries, ULN/executor configs, enforced options)
     *      and ownership has been transferred to governance. The bridge is "off" because
     *      rate limits are at zero. This function activates it by setting non-zero rate limits.
     *
     *      Sanity checks verify the adapter's pre-configuration before activation:
     *        - owner and delegate match the expected governance address
     *        - endpoint matches
     *        - peer is set correctly for the destination EID
     *        - token is the expected sUSDS address
     *        - adapter is not paused
     *        - rate limits are currently zero (not yet activated)
     *        - rate limit accounting type matches
     *
     * @param oftAdapter         The sUSDS SkyOFTAdapter address on Ethereum.
     * @param endpoint           The Ethereum EndpointV2 address.
     * @param dstEid             The destination chain's LZ endpoint ID.
     * @param expectedPeer       The expected peer (remote SkyOFTAdapterMintBurn) as bytes32.
     * @param expectedOwner      The expected owner (e.g. MCD_PAUSE_PROXY).
     * @param expectedToken      The expected sUSDS token address.
     * @param expectedRlAccountingType The expected rate limit accounting type (0=Net, 1=Gross).
     * @param inboundWindow      Rate limit window for inbound transfers (seconds).
     * @param inboundLimit       Rate limit max amount for inbound transfers (wei).
     * @param outboundWindow     Rate limit window for outbound transfers (seconds).
     * @param outboundLimit      Rate limit max amount for outbound transfers (wei).
     */
    function initSusdsBridge(
        address oftAdapter,
        address endpoint,
        uint32  dstEid,
        bytes32 expectedPeer,
        address expectedOwner,
        address expectedToken,
        uint8   expectedRlAccountingType,
        uint48  inboundWindow,
        uint256 inboundLimit,
        uint48  outboundWindow,
        uint256 outboundLimit
    ) internal {
        // --- Sanity checks ---
        OFTAdapterLike oft = OFTAdapterLike(oftAdapter);

        require(oft.owner()          == expectedOwner,  "LZInit/owner-mismatch");
        require(oft.endpoint()       == endpoint,       "LZInit/endpoint-mismatch");
        require(oft.peers(dstEid)    == expectedPeer,   "LZInit/peer-mismatch");
        require(!oft.paused(),                           "LZInit/paused");
        require(oft.token()          == expectedToken,  "LZInit/token-mismatch");

        require(
            EndpointLike(endpoint).delegates(oftAdapter) == expectedOwner,
            "LZInit/delegate-mismatch"
        );

        (,,, uint256 outLimit) = oft.outboundRateLimits(dstEid);
        (,,, uint256 inLimit)  = oft.inboundRateLimits(dstEid);
        require(outLimit == 0, "LZInit/outbound-rl-nonzero");
        require(inLimit  == 0, "LZInit/inbound-rl-nonzero");

        require(
            oft.rateLimitAccountingType() == expectedRlAccountingType,
            "LZInit/rl-accounting-mismatch"
        );

        // --- Activate bridge by setting rate limits ---
        RateLimitConfig[] memory inboundCfg  = new RateLimitConfig[](1);
        RateLimitConfig[] memory outboundCfg = new RateLimitConfig[](1);
        inboundCfg[0]  = RateLimitConfig(dstEid, inboundWindow,  inboundLimit);
        outboundCfg[0] = RateLimitConfig(dstEid, outboundWindow, outboundLimit);
        oft.setRateLimits(inboundCfg, outboundCfg);
    }

    /**
     * @notice Wire GovernanceOAppSender to a new remote chain.
     * @dev Performs all Ethereum-side configuration needed for the governance bridge
     *      to reach a new remote chain:
     *        1. setPeer
     *        2. setSendLibrary
     *        3. setReceiveLibrary   (see note below)
     *        4. setConfig           (send: executor + ULN)
     *        5. setConfig           (receive: ULN)  (see note below)
     *        6. setCanCallTarget    (l1GovRelay → l2GovRelay)
     *
     *      NOTE: Steps 3 and 5 (receive library and receive-direction config) are included
     *      to match the active on-chain GovernanceOAppSender configuration for existing
     *      destinations. The GovernanceOAppSender is send-only, so these may not be
     *      strictly required — TBD whether they should be kept or removed.
     *
     * @param endpoint       The Ethereum EndpointV2 address.
     * @param govOappSender      The GovernanceOAppSender address.
     * @param dstEid         The destination chain's LZ endpoint ID.
     * @param govOAppReceiver The GovernanceOAppReceiver address on the remote chain.
     * @param l1GovRelay     The L1GovernanceRelay address on Ethereum.
     * @param l2GovRelay     The L2GovernanceRelay address on the remote chain.
     * @param sendLib        The send library (e.g. SendUln302) on Ethereum.
     * @param recvLib        The receive library (e.g. ReceiveUln302) on Ethereum.
     * @param execCfg        Executor config for the send direction.
     * @param sendUlnCfg     ULN config for the send direction (Ethereum → Remote).
     * @param recvUlnCfg     ULN config for the receive direction (Remote → Ethereum).
     */
    function initGovOappSender(
        address        endpoint,
        address        govOappSender,
        uint32         dstEid,
        address        govOAppReceiver,
        address        l1GovRelay,
        address        l2GovRelay,
        address        sendLib,
        address        recvLib,
        ExecutorConfig memory execCfg,
        UlnConfig      memory sendUlnCfg,
        UlnConfig      memory recvUlnCfg
    ) internal {
        // 1. Set peer
        GovOAppSenderLike(govOappSender).setPeer(dstEid, _addressToBytes32(govOAppReceiver));

        // 2. Set send library
        EndpointLike(endpoint).setSendLibrary(govOappSender, dstEid, sendLib);

        // 3. Set receive library
        //    NOTE: The GovSender is send-only — TBD whether this is needed.
        //    Included to match the active on-chain configuration.
        EndpointLike(endpoint).setReceiveLibrary(govOappSender, dstEid, recvLib, 0);

        // 4. Set send-direction config (executor + ULN)
        SetConfigParam[] memory sendParams = new SetConfigParam[](2);
        sendParams[0] = SetConfigParam(dstEid, EXECUTOR_CONFIG_TYPE, abi.encode(execCfg));
        sendParams[1] = SetConfigParam(dstEid, ULN_CONFIG_TYPE,      abi.encode(sendUlnCfg));
        EndpointLike(endpoint).setConfig(govOappSender, sendLib, sendParams);

        // 5. Set receive-direction config (ULN only — no executor on receive side)
        //    NOTE: TBD whether this is needed (see step 3 note).
        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam(dstEid, ULN_CONFIG_TYPE, abi.encode(recvUlnCfg));
        EndpointLike(endpoint).setConfig(govOappSender, recvLib, recvParams);

        // 6. Whitelist L1GovernanceRelay → L2GovernanceRelay
        GovOAppSenderLike(govOappSender).setCanCallTarget(
            l1GovRelay,
            dstEid,
            _addressToBytes32(l2GovRelay),
            true
        );
    }

    /**
     * @notice Wire an OFT adapter to a new remote chain.
     * @dev Performs all configuration needed for bidirectional token bridging:
     *        1. setPeer
     *        2. setSendLibrary
     *        3. setReceiveLibrary
     *        4. setConfig           (send: executor + ULN)
     *        5. setConfig           (receive: ULN)
     *        6. setRateLimits       (inbound + outbound)
     *        7. setEnforcedOptions  (SEND + SEND_AND_CALL)
     *
     *      This function is also used for L2 routing — existing remote chains
     *      can call it to wire OFT peers to new remote chains (evm-evm only).
     *
     * @param endpoint       The EndpointV2 address (Ethereum or L2).
     * @param oftAdapter     The SkyOFTAdapter or SkyOFTAdapterMintBurn address.
     * @param dstEid         The destination chain's LZ endpoint ID.
     * @param remoteMintBurn The peer OFT adapter address on the destination chain.
     * @param sendLib        The send library (e.g. SendUln302).
     * @param recvLib        The receive library (e.g. ReceiveUln302).
     * @param execCfg        Executor config for the send direction.
     * @param sendUlnCfg     ULN config for the send direction.
     * @param recvUlnCfg     ULN config for the receive direction (confirmations may differ).
     * @param inboundWindow  Rate limit window for inbound transfers (seconds).
     * @param inboundLimit   Rate limit max amount for inbound transfers (wei).
     * @param outboundWindow Rate limit window for outbound transfers (seconds).
     * @param outboundLimit  Rate limit max amount for outbound transfers (wei).
     * @param optionsGas     Gas limit for lzReceive on the destination chain.
     *                       Applied to both SEND and SEND_AND_CALL message types.
     */
    function initOFTAdapter(
        address        endpoint,
        address        oftAdapter,
        uint32         dstEid,
        address        remoteMintBurn,
        address        sendLib,
        address        recvLib,
        ExecutorConfig memory execCfg,
        UlnConfig      memory sendUlnCfg,
        UlnConfig      memory recvUlnCfg,
        uint48         inboundWindow,
        uint256        inboundLimit,
        uint48         outboundWindow,
        uint256        outboundLimit,
        uint128        optionsGas
    ) internal {
        // 1. Set peer
        OFTAdapterLike(oftAdapter).setPeer(dstEid, _addressToBytes32(remoteMintBurn));

        // 2. Set send library
        EndpointLike(endpoint).setSendLibrary(oftAdapter, dstEid, sendLib);

        // 3. Set receive library (gracePeriod = 0 for new destinations)
        EndpointLike(endpoint).setReceiveLibrary(oftAdapter, dstEid, recvLib, 0);

        // 4. Set send-direction config (executor + ULN)
        SetConfigParam[] memory sendParams = new SetConfigParam[](2);
        sendParams[0] = SetConfigParam(dstEid, EXECUTOR_CONFIG_TYPE, abi.encode(execCfg));
        sendParams[1] = SetConfigParam(dstEid, ULN_CONFIG_TYPE,      abi.encode(sendUlnCfg));
        EndpointLike(endpoint).setConfig(oftAdapter, sendLib, sendParams);

        // 5. Set receive-direction config (ULN only — confirmations may differ from send)
        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam(dstEid, ULN_CONFIG_TYPE, abi.encode(recvUlnCfg));
        EndpointLike(endpoint).setConfig(oftAdapter, recvLib, recvParams);

        // 6. Set rate limits (inbound + outbound for this destination)
        RateLimitConfig[] memory inboundCfg  = new RateLimitConfig[](1);
        RateLimitConfig[] memory outboundCfg = new RateLimitConfig[](1);
        inboundCfg[0]  = RateLimitConfig(dstEid, inboundWindow,  inboundLimit);
        outboundCfg[0] = RateLimitConfig(dstEid, outboundWindow, outboundLimit);
        OFTAdapterLike(oftAdapter).setRateLimits(inboundCfg, outboundCfg);

        // 7. Set enforced options for both SEND and SEND_AND_CALL message types
        bytes memory options = _buildLzReceiveOptions(optionsGas);
        EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](2);
        opts[0] = EnforcedOptionParam(dstEid, MSG_TYPE_SEND,          options);
        opts[1] = EnforcedOptionParam(dstEid, MSG_TYPE_SEND_AND_CALL, options);
        OFTAdapterLike(oftAdapter).setEnforcedOptions(opts);
    }

    // TODO: Add logic that performs the L1 relay call (via L1GovernanceRelay / LZGovBridgeForwarder)
    //       to execute initOFTAdapter on an L2. This would standardize the Ethereum-side spell action
    //       for L2 routing — i.e., sending a cross-chain governance message that calls initOFTAdapter
    //       on an existing remote chain to wire it to a new remote chain.

    // TODO: Add a standardized L2 spell contract (or helper) that receives the relayed governance call
    //       and invokes initOFTAdapter with the appropriate parameters on the L2 side. This ensures
    //       the L2 spell format is also consistent across deployments.

    /**
     * @notice Allow a Star subproxy to govern a remote chain via the LZ governance bridge.
     * @dev Whitelists the subproxy to call the LZGovBridgeReceiver on the remote chain
     *      through the GovernanceOAppSender. The GovSender peer for dstEid must already
     *      be set (via initGovOappSender or a previous spell).
     *
     *      On the remote chain, the LZGovBridgeReceiver is deployed with:
     *        - govOappReceiver = GovernanceOAppReceiver
     *        - srcEid = 30101 (Ethereum)
     *        - srcAuthority = starSubproxy (this address)
     *        - target = Executor
     *
     * @param govOappSender          The GovernanceOAppSender address on Ethereum.
     * @param starSubproxy       The Star's subproxy address on Ethereum (e.g. L1_SPARK_PROXY).
     * @param dstEid             The destination chain's LZ endpoint ID.
     * @param lzGovBridgeReceiver The LZGovBridgeReceiver address on the remote chain.
     */
    function whitelistStarGovernance(
        address govOappSender,
        address starSubproxy,
        uint32  dstEid,
        address lzGovBridgeReceiver
    ) internal {
        GovOAppSenderLike(govOappSender).setCanCallTarget(
            starSubproxy,
            dstEid,
            _addressToBytes32(lzGovBridgeReceiver),
            true
        );
    }

    /**
     * @notice Allow an SSR oracle forwarder to push savings rate data to a remote chain.
     * @dev Whitelists the SSROracleForwarderLZGovBridge to call the LZGovBridgeReceiver
     *      on the remote chain through the GovernanceOAppSender. The GovSender peer for
     *      dstEid must already be set (via initGovOappSender or a previous spell).
     *
     *      On the remote chain, the LZGovBridgeReceiver is deployed with:
     *        - govOappReceiver = GovernanceOAppReceiver
     *        - srcEid = 30101 (Ethereum)
     *        - srcAuthority = ssrForwarder (this address)
     *        - target = SSRAuthOracle
     *
     * @param govOappSender          The GovernanceOAppSender address on Ethereum.
     * @param ssrForwarder       The SSROracleForwarderLZGovBridge address on Ethereum.
     * @param dstEid             The destination chain's LZ endpoint ID.
     * @param lzGovBridgeReceiver The LZGovBridgeReceiver address on the remote chain.
     */
    function whitelistSSRForwarder(
        address govOappSender,
        address ssrForwarder,
        uint32  dstEid,
        address lzGovBridgeReceiver
    ) internal {
        GovOAppSenderLike(govOappSender).setCanCallTarget(
            ssrForwarder,
            dstEid,
            _addressToBytes32(lzGovBridgeReceiver),
            true
        );
    }

    // --- Internal helpers ---

    function _addressToBytes32(address _addr) private pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    /**
     * @dev Build LZ enforced options bytes for an executor lzReceive option.
     *      Equivalent to: OptionsBuilder.newOptions().addExecutorLzReceiveOption(_gas, 0)
     */
    function _buildLzReceiveOptions(uint128 _gas) private pure returns (bytes memory) {
        return abi.encodePacked(
            hex"0003",  // OPTIONS_TYPE_3
            uint8(1),   // WORKER_ID (executor)
            uint16(17), // option data length (1 byte optionType + 16 bytes gas)
            uint8(1),   // OPTION_TYPE_LZRECEIVE
            _gas        // uint128 gas
        );
    }
}
