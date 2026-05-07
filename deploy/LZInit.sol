// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

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

struct RateLimits {
    uint48  inboundWindow;
    uint256 inboundLimit;
    uint48  outboundWindow;
    uint256 outboundLimit;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct TxParams {
    uint32  dstEid;
    bytes32 dstTarget;
    bytes   dstCallData;
    bytes   extraOptions;
}

// Note: DVN arrays in `sendUlnCfg` must be strictly ascending by address.
struct GovConfig {
    address        peer;
    address        sendLib;
    ExecutorConfig execCfg;
    UlnConfig      sendUlnCfg;
    address        l2GovRelay;
}

// Note: DVN arrays in each UlnConfig must be strictly ascending by address.
struct OftConfig {
    address        peer;
    address        sendLib;
    ExecutorConfig execCfg;
    UlnConfig      sendUlnCfg;
    address        recvLib;
    UlnConfig      recvUlnCfg;
    uint128        optionsGas;
}

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
    function endpoint() external view returns (address);
}

interface GovOAppSenderLike is OAppLike {
    function setCanCallTarget(address srcSender, uint32 dstEid, bytes32 dstTarget, bool canCall) external;
    function quoteTx(TxParams calldata params, bool payInLzToken) external view returns (MessagingFee memory);
}

interface L2GovernanceRelayLike {
    function relay(address target, bytes calldata targetData) external;
}

interface L1GovernanceRelayLike {
    function relayEVM(
        uint32                dstEid,
        address               l2GovernanceRelay,
        address               target,
        bytes        calldata targetData,
        bytes        calldata extraOptions,
        MessagingFee calldata fee,
        address               refundAddress
    ) external payable;
}

interface OFTAdapterLike is OAppLike {
    function setRateLimits(RateLimitConfig[] calldata inbound, RateLimitConfig[] calldata outbound) external;
    function setEnforcedOptions(EnforcedOptionParam[] calldata opts) external;
    function unpause() external;
    function owner() external view returns (address);
    function token() external view returns (address);
    function paused() external view returns (bool);
    function outboundRateLimits(uint32 eid) external view returns (uint128, uint48, uint256, uint256);
    function inboundRateLimits(uint32 eid) external view returns (uint128, uint48, uint256, uint256);
    function rateLimitAccountingType() external view returns (uint8);
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
}

library LZInit {

    ChainlogLike internal constant chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    uint32 internal constant EXECUTOR_CONFIG_TYPE = 1;
    uint32 internal constant ULN_CONFIG_TYPE      = 2;

    uint16 internal constant MSG_TYPE_SEND          = 1;
    uint16 internal constant MSG_TYPE_SEND_AND_CALL = 2;

    // ==================================
    //  Configuration functions
    // ==================================

    /// @notice Connect LZ_GOV_SENDER to a new remote peer and whitelist
    ///         LZ_GOV_RELAY. The remote peer (a GovernanceOAppReceiver) and
    ///         the L2GovernanceRelay must have been configured by the deployer
    ///         beforehand.
    /// @dev    L1-only.
    function wireGovPeer(uint32 remoteEid, GovConfig memory cfg) internal {
        address govOappSender = chainlog.getAddress("LZ_GOV_SENDER");

        _wireSend({
            endpoint:     OAppLike(govOappSender).endpoint(),
            oappSender:   govOappSender,
            remoteEid:    remoteEid,
            oappReceiver: cfg.peer,
            sendLib:      cfg.sendLib,
            execCfg:      cfg.execCfg,
            sendUlnCfg:   cfg.sendUlnCfg
        });

        GovOAppSenderLike(govOappSender).setCanCallTarget({
            srcSender: chainlog.getAddress("LZ_GOV_RELAY"),
            dstEid:    remoteEid,
            dstTarget: bytes32(uint256(uint160(cfg.l2GovRelay))),
            canCall:   true
        });
    }

    /// @notice Connect a local OFT adapter to a new remote peer. The remote
    ///         OFT adapter must have been pre-configured by the deployer and
    ///         its ownership transferred to the L2GovernanceRelay beforehand.
    /// @dev    Also usable on L2 via LZL2Spell + relayToL2.
    function wireOftPeer(
        address           oft,
        uint32            remoteEid,
        OftConfig  memory cfg,
        RateLimits memory rateLimits
    ) internal {
        address endpoint = OAppLike(oft).endpoint();

        _wireSend({
            endpoint:     endpoint,
            oappSender:   oft,
            remoteEid:    remoteEid,
            oappReceiver: cfg.peer,
            sendLib:      cfg.sendLib,
            execCfg:      cfg.execCfg,
            sendUlnCfg:   cfg.sendUlnCfg
        });

        EndpointLike(endpoint).setReceiveLibrary({
            oapp:        oft,
            eid:         remoteEid,
            newLib:      cfg.recvLib,
            gracePeriod: 0
        });

        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam(remoteEid, ULN_CONFIG_TYPE, abi.encode(cfg.recvUlnCfg));
        EndpointLike(endpoint).setConfig(oft, cfg.recvLib, recvParams);

        bytes memory options = _encodeLzReceiveOptions(cfg.optionsGas);
        EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](2);
        opts[0] = EnforcedOptionParam(remoteEid, MSG_TYPE_SEND,          options);
        opts[1] = EnforcedOptionParam(remoteEid, MSG_TYPE_SEND_AND_CALL, options);
        OFTAdapterLike(oft).setEnforcedOptions(opts);

        updateRateLimits(oft, remoteEid, rateLimits);
    }

    /// @notice Activate an OFT adapter owned by governance (PAUSE_PROXY on L1,
    ///         L2GovernanceRelay on L2) by setting non-zero rate limits.
    ///         Verifies the on-chain state was configured as expected before
    ///         flipping the limits on.
    /// @dev    Also usable on L2 via LZL2Spell + relayToL2.
    function activateOft(
        address           oft,
        uint32            remoteEid,
        OftConfig  memory cfg,
        RateLimits memory rateLimits,
        uint8             rlAccountingType,
        address           token,
        address           owner
    ) internal {
        _verifyOftConfig(oft, remoteEid, cfg, rlAccountingType, token, owner);
        updateRateLimits(oft, remoteEid, rateLimits);
    }

    /// @notice Update rate limits on an OFT adapter for a given destination.
    /// @dev    Also usable on L2 via LZL2Spell + relayToL2.
    function updateRateLimits(address oft, uint32 remoteEid, RateLimits memory rateLimits) internal {
        RateLimitConfig[] memory inboundCfg  = new RateLimitConfig[](1);
        RateLimitConfig[] memory outboundCfg = new RateLimitConfig[](1);
        inboundCfg[0]  = RateLimitConfig(remoteEid, rateLimits.inboundWindow,  rateLimits.inboundLimit);
        outboundCfg[0] = RateLimitConfig(remoteEid, rateLimits.outboundWindow, rateLimits.outboundLimit);
        OFTAdapterLike(oft).setRateLimits(inboundCfg, outboundCfg);
    }

    /// @notice Update the ULN (DVN) config for an OApp's send or receive library for a given remote eid.
    /// @dev    Also usable on L2 via LZL2Spell + relayToL2.
    function setUlnConfig(
        address          oapp,
        uint32           remoteEid,
        address          lib,
        UlnConfig memory ulnCfg
    ) internal {
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam(remoteEid, ULN_CONFIG_TYPE, abi.encode(ulnCfg));
        EndpointLike(OAppLike(oapp).endpoint()).setConfig(oapp, lib, params);
    }

    /// @notice Unpause an OFT adapter.
    /// @dev    Also usable on L2 via LZL2Spell + relayToL2.
    function unpauseOft(address oft) internal {
        OFTAdapterLike(oft).unpause();
    }

    // ==================================
    //  Relay (L1 → L2)
    // ==================================

    /// @notice Relay an arbitrary call to an LZL2Spell on a destination chain.
    /// @dev    L1-only. LZ_GOV_RELAY must be:
    ///         - whitelisted on LZ_GOV_SENDER for (remoteEid, l2GovRelay), and
    ///         - pre-funded with at least the quoted `fee.nativeFee`.
    ///         LZL2Spell must be deployed on the destination chain.
    function relayToL2(
        uint32        remoteEid,
        address       l2GovRelay,
        address       l2Spell,
        bytes  memory targetData,
        uint128       gas,
        uint256       maxFee
    ) internal {
        address relay = chainlog.getAddress("LZ_GOV_RELAY");

        bytes memory extraOptions = _encodeLzReceiveOptions(gas);

        MessagingFee memory fee = GovOAppSenderLike(chainlog.getAddress("LZ_GOV_SENDER")).quoteTx({
            params: TxParams({
                dstEid:       remoteEid,
                dstTarget:    bytes32(uint256(uint160(l2GovRelay))),
                dstCallData:  abi.encodeCall(L2GovernanceRelayLike.relay, (l2Spell, targetData)),
                extraOptions: extraOptions
            }),
            payInLzToken: false
        });

        require(fee.lzTokenFee == 0,            "LZInit/lz-token-fee-nonzero");
        require(fee.nativeFee <= maxFee,        "LZInit/fee-exceeds-max");
        require(relay.balance >= fee.nativeFee, "LZInit/insufficient-relay-balance");

        L1GovernanceRelayLike(relay).relayEVM({
            dstEid:            remoteEid,
            l2GovernanceRelay: l2GovRelay,
            target:            l2Spell,
            targetData:        targetData,
            extraOptions:      extraOptions,
            fee:               fee,
            refundAddress:     relay
        });
    }

    // --- Private helpers ---

    function _wireSend(
        address               endpoint,
        address               oappSender,
        uint32                remoteEid,
        address               oappReceiver,
        address               sendLib,
        ExecutorConfig memory execCfg,
        UlnConfig      memory sendUlnCfg
    ) private {
        OAppLike(oappSender).setPeer(remoteEid, bytes32(uint256(uint160(oappReceiver))));
        EndpointLike(endpoint).setSendLibrary(oappSender, remoteEid, sendLib);

        SetConfigParam[] memory sendParams = new SetConfigParam[](2);
        sendParams[0] = SetConfigParam(remoteEid, EXECUTOR_CONFIG_TYPE, abi.encode(execCfg));
        sendParams[1] = SetConfigParam(remoteEid, ULN_CONFIG_TYPE,      abi.encode(sendUlnCfg));
        EndpointLike(endpoint).setConfig(oappSender, sendLib, sendParams);
    }

    /// @dev Equivalent to OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, 0).
    function _encodeLzReceiveOptions(uint128 gas) private pure returns (bytes memory) {
        return abi.encodePacked(
            hex"0003",  // OPTIONS_TYPE_3
            uint8(1),   // WORKER_ID (executor)
            uint16(17), // option data length (1 byte option type + 16 bytes gas)
            uint8(1),   // OPTION_TYPE_LZRECEIVE
            gas
        );
    }

    function _verifyOftConfig(
        address          oft,
        uint32           remoteEid,
        OftConfig memory cfg,
        uint8            rlAccountingType,
        address          token,
        address          owner
    ) private view {
        OFTAdapterLike oft_ = OFTAdapterLike(oft);
        EndpointLike   ep   = EndpointLike(oft_.endpoint());

        require(oft_.peers(remoteEid)             == bytes32(uint256(uint160(cfg.peer))), "LZInit/peer-mismatch");
        require(!oft_.paused(),                                                        "LZInit/paused");
        require(oft_.rateLimitAccountingType() == rlAccountingType,                    "LZInit/rl-accounting-mismatch");
        require(oft_.token()                   == token,                               "LZInit/token-mismatch");
        require(oft_.owner()                   == owner,                               "LZInit/owner-mismatch");
        require(ep.delegates(oft)              == owner,                               "LZInit/delegate-mismatch");

        (,,, uint256 outLimit) = oft_.outboundRateLimits(remoteEid);
        (,,, uint256 inLimit)  = oft_.inboundRateLimits(remoteEid);
        require(outLimit == 0, "LZInit/outbound-rl-nonzero");
        require(inLimit  == 0, "LZInit/inbound-rl-nonzero");

        require(ep.getSendLibrary(oft, remoteEid) == cfg.sendLib, "LZInit/send-lib-mismatch");
        (address recvLib,) = ep.getReceiveLibrary(oft, remoteEid);
        require(recvLib == cfg.recvLib, "LZInit/recv-lib-mismatch");

        require(keccak256(ep.getConfig(oft, cfg.sendLib, remoteEid, EXECUTOR_CONFIG_TYPE)) == keccak256(abi.encode(cfg.execCfg)),    "LZInit/exec-cfg-mismatch");
        require(keccak256(ep.getConfig(oft, cfg.sendLib, remoteEid, ULN_CONFIG_TYPE))      == keccak256(abi.encode(cfg.sendUlnCfg)), "LZInit/send-uln-mismatch");
        require(keccak256(ep.getConfig(oft, cfg.recvLib, remoteEid, ULN_CONFIG_TYPE))      == keccak256(abi.encode(cfg.recvUlnCfg)), "LZInit/recv-uln-mismatch");

        bytes memory expectedOptions = _encodeLzReceiveOptions(cfg.optionsGas);
        require(keccak256(oft_.enforcedOptions(remoteEid, MSG_TYPE_SEND))          == keccak256(expectedOptions), "LZInit/enforced-send-mismatch");
        require(keccak256(oft_.enforcedOptions(remoteEid, MSG_TYPE_SEND_AND_CALL)) == keccak256(expectedOptions), "LZInit/enforced-send-and-call-mismatch");
    }

}
