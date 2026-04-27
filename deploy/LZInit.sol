// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

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

/// @dev DVN arrays in each UlnConfig must be strictly ascending by address.
struct OftConfig {
    bytes32   peer;
    address   owner;
    address   token;
    uint8     rlAccountingType;
    address   sendLib;
    address   recvLib;
    UlnConfig sendUlnCfg;
    UlnConfig recvUlnCfg;
    uint128   optionsGas;
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
    function getSendLibrary(address oapp, uint32 eid) external view returns (address);
    function getReceiveLibrary(address oapp, uint32 eid) external view returns (address, bool);
    function getConfig(address oapp, address lib, uint32 eid, uint32 configType) external view returns (bytes memory);
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

interface LZL2SpellLike {
    function wireOftPeer(
        address endpoint, address oft, uint32 dstEid, address peer,
        address sendLib, address recvLib, ExecutorConfig memory execCfg,
        UlnConfig memory sendUlnCfg, UlnConfig memory recvUlnCfg,
        uint48 inboundWindow, uint256 inboundLimit, uint48 outboundWindow, uint256 outboundLimit,
        uint128 optionsGas
    ) external;
    function activateOft(
        address oft, address endpoint, uint32 dstEid,
        OftConfig memory expected,
        uint48 inboundWindow, uint256 inboundLimit, uint48 outboundWindow, uint256 outboundLimit
    ) external;
    function updateRateLimits(
        address oft, uint32 dstEid,
        uint48 inboundWindow, uint256 inboundLimit, uint48 outboundWindow, uint256 outboundLimit
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
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
}

/*** Library ***/

library LZInit {

    ChainlogLike internal constant chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    uint32 internal constant EXECUTOR_CONFIG_TYPE = 1;
    uint32 internal constant ULN_CONFIG_TYPE      = 2;

    uint16 internal constant MSG_TYPE_SEND          = 1;
    uint16 internal constant MSG_TYPE_SEND_AND_CALL = 2;

    // ==================================
    //  L1 functions
    // ==================================

    /// @notice Add a governance route from LZ_GOV_SENDER to a new remote chain.
    function addGovRoute(
        address        endpoint,
        uint32         dstEid,
        address        peer,
        address        l2GovRelay,
        address        sendLib,
        ExecutorConfig memory execCfg,
        UlnConfig      memory sendUlnCfg
    ) internal {
        address govOappSender = chainlog.getAddress("LZ_GOV_SENDER");

        _wireSend(endpoint, govOappSender, dstEid, peer, sendLib, execCfg, sendUlnCfg);

        GovOAppSenderLike(govOappSender).setCanCallTarget(
            chainlog.getAddress("LZ_GOV_RELAY"),
            dstEid,
            bytes32(uint256(uint160(l2GovRelay))),
            true
        );
    }

    /// @notice Connect a local OFT adapter to a new remote peer. In the case
    ///         of a new remote, the other side will have been configured by
    ///         a deployer before its ownership is transferred to the
    ///         L2GovernanceRelay.
    /// @dev    Also usable on L2 via relayWireOftPeer.
    function wireOftPeer(
        address        endpoint,
        address        oft,
        uint32         dstEid,
        address        peer,
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
        _wireSend(endpoint, oft, dstEid, peer, sendLib, execCfg, sendUlnCfg);

        EndpointLike(endpoint).setReceiveLibrary(oft, dstEid, recvLib, 0);

        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam(dstEid, ULN_CONFIG_TYPE, abi.encode(recvUlnCfg));
        EndpointLike(endpoint).setConfig(oft, recvLib, recvParams);

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
        OFTAdapterLike(oft).setEnforcedOptions(opts);

        updateRateLimits(oft, dstEid, inboundWindow, inboundLimit, outboundWindow, outboundLimit);
    }

    /// @notice Activate an OFT adapter owned by governance (PAUSE_PROXY on L1,
    ///         L2GovernanceRelay on L2) by setting non-zero rate limits.
    ///         Verifies the on-chain state was configured as expected before
    ///         flipping the limits on.
    /// @dev    Also usable on L2 via relayActivateOft.
    function activateOft(
        address oft,
        address endpoint,
        uint32  dstEid,
        OftConfig memory expected,
        uint48  inboundWindow,
        uint256 inboundLimit,
        uint48  outboundWindow,
        uint256 outboundLimit
    ) internal {
        _verifyOftConfig(oft, endpoint, dstEid, expected);
        updateRateLimits(oft, dstEid, inboundWindow, inboundLimit, outboundWindow, outboundLimit);
    }

    /// @notice Update rate limits on an OFT adapter for a given destination.
    function updateRateLimits(
        address oft,
        uint32  dstEid,
        uint48  inboundWindow,
        uint256 inboundLimit,
        uint48  outboundWindow,
        uint256 outboundLimit
    ) internal {
        RateLimitConfig[] memory inboundCfg  = new RateLimitConfig[](1);
        RateLimitConfig[] memory outboundCfg = new RateLimitConfig[](1);
        inboundCfg[0]  = RateLimitConfig(dstEid, inboundWindow,  inboundLimit);
        outboundCfg[0] = RateLimitConfig(dstEid, outboundWindow, outboundLimit);
        OFTAdapterLike(oft).setRateLimits(inboundCfg, outboundCfg);
    }

    // ==================================
    //  Relay functions (L1 → L2)
    // ==================================

    /// @notice Relay a wireOftPeer call to an L2 via the LZ governance bridge.
    /// @dev    LZ_GOV_RELAY must be whitelisted on LZ_GOV_SENDER for (dstEid, l2GovRelay).
    ///         LZL2Spell must be deployed on the destination chain.
    function relayWireOftPeer(
        uint32         dstEid,
        address        l2GovRelay,
        address        l2Spell,
        bytes   memory extraOptions,
        MessagingFee   memory fee,
        address        refundAddress,
        address        l2Endpoint,
        address        l2Oft,
        uint32         newDstEid,
        address        peer,
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
        bytes memory targetData = abi.encodeCall(
            LZL2SpellLike.wireOftPeer,
            (
                l2Endpoint, l2Oft, newDstEid, peer,
                sendLib, recvLib, execCfg, sendUlnCfg, recvUlnCfg,
                inboundWindow, inboundLimit, outboundWindow, outboundLimit, optionsGas
            )
        );

        L1GovernanceRelayLike(chainlog.getAddress("LZ_GOV_RELAY")).relayEVM{value: fee.nativeFee}(
            dstEid, l2GovRelay, l2Spell, targetData, extraOptions, fee, refundAddress
        );
    }

    /// @notice Relay an activateOft call to an L2 via the LZ governance bridge.
    /// @dev    LZ_GOV_RELAY must be whitelisted on LZ_GOV_SENDER for (dstEid, l2GovRelay).
    ///         LZL2Spell must be deployed on the destination chain.
    function relayActivateOft(
        uint32         dstEid,
        address        l2GovRelay,
        address        l2Spell,
        bytes   memory extraOptions,
        MessagingFee   memory fee,
        address        refundAddress,
        address        l2Oft,
        address        l2Endpoint,
        uint32         targetDstEid,
        OftConfig memory expected,
        uint48         inboundWindow,
        uint256        inboundLimit,
        uint48         outboundWindow,
        uint256        outboundLimit
    ) internal {
        bytes memory targetData = abi.encodeCall(
            LZL2SpellLike.activateOft,
            (
                l2Oft, l2Endpoint, targetDstEid, expected,
                inboundWindow, inboundLimit, outboundWindow, outboundLimit
            )
        );

        L1GovernanceRelayLike(chainlog.getAddress("LZ_GOV_RELAY")).relayEVM{value: fee.nativeFee}(
            dstEid, l2GovRelay, l2Spell, targetData, extraOptions, fee, refundAddress
        );
    }

    /// @notice Relay an updateRateLimits call to an L2 via the LZ governance bridge.
    /// @dev    LZ_GOV_RELAY must be whitelisted on LZ_GOV_SENDER for (dstEid, l2GovRelay).
    ///         LZL2Spell must be deployed on the destination chain.
    function relayUpdateRateLimits(
        uint32         dstEid,
        address        l2GovRelay,
        address        l2Spell,
        bytes   memory extraOptions,
        MessagingFee   memory fee,
        address        refundAddress,
        address        l2Oft,
        uint32         targetDstEid,
        uint48         inboundWindow,
        uint256        inboundLimit,
        uint48         outboundWindow,
        uint256        outboundLimit
    ) internal {
        bytes memory targetData = abi.encodeCall(
            LZL2SpellLike.updateRateLimits,
            (l2Oft, targetDstEid, inboundWindow, inboundLimit, outboundWindow, outboundLimit)
        );

        L1GovernanceRelayLike(chainlog.getAddress("LZ_GOV_RELAY")).relayEVM{value: fee.nativeFee}(
            dstEid, l2GovRelay, l2Spell, targetData, extraOptions, fee, refundAddress
        );
    }

    // ==================================
    //  Star subproxy functions
    // ==================================

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

    function _verifyOftConfig(
        address oft,
        address endpoint,
        uint32  dstEid,
        OftConfig memory e
    ) private view {
        OFTAdapterLike oft_ = OFTAdapterLike(oft);

        require(oft_.owner()       == e.owner,  "LZInit/owner-mismatch");
        require(oft_.endpoint()    == endpoint, "LZInit/endpoint-mismatch");
        require(oft_.peers(dstEid) == e.peer,   "LZInit/peer-mismatch");
        require(!oft_.paused(),                 "LZInit/paused");
        require(oft_.token()       == e.token,  "LZInit/token-mismatch");
        require(
            EndpointLike(endpoint).delegates(address(oft_)) == e.owner,
            "LZInit/delegate-mismatch"
        );
        require(
            oft_.rateLimitAccountingType() == e.rlAccountingType,
            "LZInit/rl-accounting-mismatch"
        );

        (,,, uint256 outLimit) = oft_.outboundRateLimits(dstEid);
        (,,, uint256 inLimit)  = oft_.inboundRateLimits(dstEid);
        require(outLimit == 0, "LZInit/outbound-rl-nonzero");
        require(inLimit  == 0, "LZInit/inbound-rl-nonzero");

        require(EndpointLike(endpoint).getSendLibrary(address(oft_), dstEid) == e.sendLib, "LZInit/send-lib-mismatch");
        (address recvLib,) = EndpointLike(endpoint).getReceiveLibrary(address(oft_), dstEid);
        require(recvLib == e.recvLib, "LZInit/recv-lib-mismatch");

        bytes memory sendUlnRaw = EndpointLike(endpoint).getConfig(address(oft_), e.sendLib, dstEid, ULN_CONFIG_TYPE);
        bytes memory recvUlnRaw = EndpointLike(endpoint).getConfig(address(oft_), e.recvLib, dstEid, ULN_CONFIG_TYPE);
        require(keccak256(sendUlnRaw) == keccak256(abi.encode(e.sendUlnCfg)), "LZInit/send-uln-mismatch");
        require(keccak256(recvUlnRaw) == keccak256(abi.encode(e.recvUlnCfg)), "LZInit/recv-uln-mismatch");

        bytes memory expectedOptions = abi.encodePacked(hex"0003", uint8(1), uint16(17), uint8(1), e.optionsGas);
        require(keccak256(oft_.enforcedOptions(dstEid, MSG_TYPE_SEND))          == keccak256(expectedOptions), "LZInit/enforced-send-mismatch");
        require(keccak256(oft_.enforcedOptions(dstEid, MSG_TYPE_SEND_AND_CALL)) == keccak256(expectedOptions), "LZInit/enforced-send-and-call-mismatch");
    }

}
