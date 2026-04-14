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

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

interface EndpointLike {
    function setSendLibrary(address oapp, uint32 eid, address newLib) external;
    function setReceiveLibrary(address oapp, uint32 eid, address newLib, uint256 gracePeriod) external;
    function setConfig(address oapp, address lib, SetConfigParam[] calldata params) external;
    function delegates(address oapp) external view returns (address);
}

interface OAppLike {
    function setPeer(uint32 eid, bytes32 peer) external;
    function peers(uint32 eid) external view returns (bytes32);
}

interface GovOAppSenderLike is OAppLike {
    function setCanCallTarget(address srcSender, uint32 dstEid, bytes32 dstTarget, bool canCall) external;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

interface L1GovernanceRelayLike {
    function relayEVM(
        uint32         dstEid,
        address        l2GovernanceRelay,
        address        target,
        bytes calldata targetData,
        bytes calldata extraOptions,
        MessagingFee calldata fee,
        address        refundAddress
    ) external payable;
}

interface L2InitOFTAdapterSpellLike {
    function execute(
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
    ) external;
}

interface OFTAdapterLike is OAppLike {
    function setRateLimits(RateLimitConfig[] calldata inbound, RateLimitConfig[] calldata outbound) external;
    function setEnforcedOptions(EnforcedOptionParam[] calldata opts) external;
    function owner() external view returns (address);
    function endpoint() external view returns (address);
    function token() external view returns (address);
    function paused() external view returns (bool);
    function outboundRateLimits(uint32 eid) external view returns (uint128, uint48, uint256, uint256);
    function inboundRateLimits(uint32 eid) external view returns (uint128, uint48, uint256, uint256);
    function rateLimitAccountingType() external view returns (uint8);
}

/*** Library ***/

library LZInit {

    ChainlogLike internal constant chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    uint32 internal constant EXECUTOR_CONFIG_TYPE = 1;
    uint32 internal constant ULN_CONFIG_TYPE      = 2;

    uint16 internal constant MSG_TYPE_SEND          = 1;
    uint16 internal constant MSG_TYPE_SEND_AND_CALL = 2;

    /**
     * @notice Activate a pre-configured sUSDS OFT adapter by setting non-zero rate limits.
     * @dev    The adapter must be fully configured (peer, libraries, configs, enforced options)
     *         with rate limits at zero and ownership transferred to governance.
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

    /// @notice Wire GovernanceOAppSender to a new remote chain.
    function initGovOappSender(
        address        endpoint,
        uint32         dstEid,
        address        govOAppReceiver,
        address        l2GovRelay,
        address        sendLib,
        ExecutorConfig memory execCfg,
        UlnConfig      memory sendUlnCfg
    ) internal {
        address govOappSender = chainlog.getAddress("LZ_GOV_SENDER");

        _wireSend(endpoint, govOappSender, dstEid, govOAppReceiver, sendLib, execCfg, sendUlnCfg);

        GovOAppSenderLike(govOappSender).setCanCallTarget(
            chainlog.getAddress("LZ_GOV_RELAY"),
            dstEid,
            bytes32(uint256(uint160(l2GovRelay))),
            true
        );
    }

    /**
     * @notice Wire an OFT adapter to a new remote chain (bidirectional token bridging).
     * @dev    Also usable for L2 routing via relayInitOFTAdapter (wiring L2 OFT peers to new remote chains).
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
        _wireSend(endpoint, oftAdapter, dstEid, remoteMintBurn, sendLib, execCfg, sendUlnCfg);

        EndpointLike(endpoint).setReceiveLibrary(oftAdapter, dstEid, recvLib, 0);

        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam(dstEid, ULN_CONFIG_TYPE, abi.encode(recvUlnCfg));
        EndpointLike(endpoint).setConfig(oftAdapter, recvLib, recvParams);

        RateLimitConfig[] memory inboundCfg  = new RateLimitConfig[](1);
        RateLimitConfig[] memory outboundCfg = new RateLimitConfig[](1);
        inboundCfg[0]  = RateLimitConfig(dstEid, inboundWindow,  inboundLimit);
        outboundCfg[0] = RateLimitConfig(dstEid, outboundWindow, outboundLimit);
        OFTAdapterLike(oftAdapter).setRateLimits(inboundCfg, outboundCfg);

        // Equivalent to OptionsBuilder.newOptions().addExecutorLzReceiveOption(optionsGas, 0)
        bytes memory options = abi.encodePacked(
            hex"0003",  // OPTIONS_TYPE_3
            uint8(1),   // WORKER_ID (executor)
            uint16(17), // option data length
            uint8(1),   // OPTION_TYPE_LZRECEIVE
            optionsGas
        );
        EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](2);
        opts[0] = EnforcedOptionParam(dstEid, MSG_TYPE_SEND,          options);
        opts[1] = EnforcedOptionParam(dstEid, MSG_TYPE_SEND_AND_CALL, options);
        OFTAdapterLike(oftAdapter).setEnforcedOptions(opts);
    }

    /**
     * @notice Relay an initOFTAdapter call to an L2 via the LZ governance bridge.
     * @dev    L1GovernanceRelay must be whitelisted on GovOAppSender for (dstEid, l2GovRelay).
     *         L2InitOFTAdapterSpell must be deployed on the destination chain.
     */
    function relayInitOFTAdapter(
        uint32         dstEid,
        address        l2GovRelay,
        address        l2Spell,
        address        l2Endpoint,
        address        l2OftAdapter,
        uint32         newDstEid,
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
        uint128        optionsGas,
        bytes   memory extraOptions,
        MessagingFee   memory fee,
        address        refundAddress
    ) internal {
        bytes memory targetData = abi.encodeCall(
            L2InitOFTAdapterSpellLike.execute,
            (
                l2Endpoint, l2OftAdapter, newDstEid, remoteMintBurn,
                sendLib, recvLib, execCfg, sendUlnCfg, recvUlnCfg,
                inboundWindow, inboundLimit, outboundWindow, outboundLimit, optionsGas
            )
        );

        L1GovernanceRelayLike(chainlog.getAddress("LZ_GOV_RELAY")).relayEVM{value: fee.nativeFee}(
            dstEid,
            l2GovRelay,
            l2Spell,
            targetData,
            extraOptions,
            fee,
            refundAddress
        );
    }

    /// @notice Configure the LZ endpoint for a non-OApp sender (e.g. Star subproxy using LZForwarder).
    function initLZSender(
        address        endpoint,
        address        sender,
        uint32         dstEid,
        address        sendLib,
        ExecutorConfig memory execCfg,
        UlnConfig      memory sendUlnCfg
    ) internal {
        _wireEndpointSend(endpoint, sender, dstEid, sendLib, execCfg, sendUlnCfg);
    }

    // --- Private helpers ---

    function _wireSend(
        address        endpoint,
        address        oappSender,
        uint32         dstEid,
        address        oappReceiver,
        address        sendLib,
        ExecutorConfig memory execCfg,
        UlnConfig      memory sendUlnCfg
    ) private {
        OAppLike(oappSender).setPeer(dstEid, bytes32(uint256(uint160(oappReceiver))));
        _wireEndpointSend(endpoint, oappSender, dstEid, sendLib, execCfg, sendUlnCfg);
    }

    function _wireEndpointSend(
        address        endpoint,
        address        sender,
        uint32         dstEid,
        address        sendLib,
        ExecutorConfig memory execCfg,
        UlnConfig      memory sendUlnCfg
    ) private {
        EndpointLike(endpoint).setSendLibrary(sender, dstEid, sendLib);

        SetConfigParam[] memory sendParams = new SetConfigParam[](2);
        sendParams[0] = SetConfigParam(dstEid, EXECUTOR_CONFIG_TYPE, abi.encode(execCfg));
        sendParams[1] = SetConfigParam(dstEid, ULN_CONFIG_TYPE,      abi.encode(sendUlnCfg));
        EndpointLike(endpoint).setConfig(sender, sendLib, sendParams);
    }

}
