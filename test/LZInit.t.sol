// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { OptionsBuilder } from "layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {
    LZInit,
    UlnConfig,
    ExecutorConfig,
    OftConfig,
    GovConfig,
    ForwarderConfig,
    RateLimits,
    SetConfigParam,
    EnforcedOptionParam,
    EndpointLike,
    UlnLike,
    OAppLike,
    OFTAdapterLike
} from "deploy/LZInit.sol";

// Real audited contracts (flattened). See each mock's header for provenance.
import { SkyOFTAdapter, ERC1967Proxy } from "./mocks/SkyOFTAdaptersFlat.sol";
import { SSROracleForwarderLZ } from "./mocks/SSROracleForwarderLZFlat.sol";
import { SendSideDeployer, CCIPDVNCfg, CCIPDVNAdapter } from "./mocks/SendSideDeployerFlat.sol";

interface ChainlogReadLike {
    function getAddress(bytes32) external view returns (address);
}

interface GovSenderLike {
    function canCallTarget(address srcSender, uint32 dstEid, bytes32 dstTarget) external view returns (bool);
}

interface SkyOFTLike {
    function pause() external;
    function setPauser(address pauser, bool canPause) external;
}

// SSR forwarder setters, used to pre-configure it in the test.
interface FwdLike {
    function setPeer(uint32 eid, bytes32 peer) external;
    function setDelegate(address delegate) external;
    function transferOwnership(address newOwner) external;
    function setEnforcedOptions(EnforcedOptionParam[] calldata opts) external;
}

contract LZInitTest is Test {

    using OptionsBuilder for bytes;

    ChainlogReadLike constant chainlog = ChainlogReadLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    // --- Ethereum mainnet addresses (LZ infra, not in chainlog) ---
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant SEND_LIB = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1; // SendUln302
    address constant RECV_LIB = 0xc02Ab410f0734EFa3F14628780e6e695156024C2; // ReceiveUln302
    address constant EXECUTOR = 0x173272739Bd7Aa6e4e214714048a9fE699453059;

    address PAUSE_PROXY;  // MCD_PAUSE_PROXY
    address GOV_SENDER;   // LZ_GOV_SENDER
    address L1_GOV_RELAY; // LZ_GOV_RELAY
    address USDS_OFT;
    address SUSDS_OFT;

    // Ethereum DVN addresses (sorted — required by UlnConfig)
    address constant DVN_P2P              = 0x06559EE34D85a88317Bf0bfE307444116c631b67;
    address constant DVN_DEUTSCHE_TELEKOM = 0x373a6E5c0C4E89E24819f00AA37ea370917AAfF4;
    address constant DVN_HORIZEN          = 0x380275805876Ff19055EA900CDb2B46a94ecF20D;
    address constant DVN_LUGANODES        = 0x58249a2Ec05c1978bF21DF1f5eC1847e42455CF4;
    address constant DVN_LZ_LABS          = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
    address constant DVN_CANARY           = 0xa4fE5A5B9A846458a70Cd0748228aED3bF65c2cd;
    address constant DVN_NETHERMIND       = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;

    uint32 constant DST_EID  = 30184; // Base (new remote)
    uint32 constant AVAX_EID = 30106;

    // SSR oracle forwarder activation: the forwarder is a send-only OApp that uses the shared CCIP DVN adapter as one of its optional DVNs
    uint64  constant BASE_CCIP_SELECTOR = 15971525489660198786;
    uint128 constant FWD_OPTIONS_GAS    = 100_000;
    uint128 constant FWD_COMPOSE_GAS    = 200_000;
    uint16  constant MSG_TYPE_SEND      = 1;
    bytes32 constant ALLOWLIST          = keccak256("ALLOWLIST");
    address constant FWD_RECEIVER       = address(0xBEEF); // opaque L2 receiver / oracle
    address constant FWD_OTHER_DVN      = address(0x10);   // opaque second optional DVN

    address govPeer;
    address l2GovRelay;
    address oftPeer;

    SSROracleForwarderLZ ssrFwd;
    address              ssrCcipAdapter;

    ExecutorConfig execCfg;
    UlnConfig      govUlnCfg;     // 4-of-7 optional for governance OApp
    UlnConfig      oftSendUlnCfg; // 2-of-2 required for OFT send
    UlnConfig      oftRecvUlnCfg; // 2-of-2 required for OFT receive

    function setUp() public {
        // Pinned to the block where SUSDS_OFT was configured for Avalanche, still with 0 rate limits.
        vm.createSelectFork(getChain("mainnet").rpcUrl, 24871363);

        PAUSE_PROXY  = chainlog.getAddress("MCD_PAUSE_PROXY");
        GOV_SENDER   = chainlog.getAddress("LZ_GOV_SENDER");
        L1_GOV_RELAY = chainlog.getAddress("LZ_GOV_RELAY");
        USDS_OFT     = chainlog.getAddress("USDS_OFT");
        SUSDS_OFT    = chainlog.getAddress("SUSDS_OFT");

        govPeer     = makeAddr("govPeer");
        l2GovRelay  = makeAddr("l2GovRelay");
        oftPeer     = makeAddr("oftPeer");

        execCfg = ExecutorConfig({
            maxMessageSize: 10000,
            executor:       EXECUTOR
        });

        // Gov OApp ULN config: 0 required (NIL=255 overrides defaults) + 7 optional, threshold 4
        address[] memory govOptionalDVNs = new address[](7);
        govOptionalDVNs[0] = DVN_P2P;
        govOptionalDVNs[1] = DVN_DEUTSCHE_TELEKOM;
        govOptionalDVNs[2] = DVN_HORIZEN;
        govOptionalDVNs[3] = DVN_LUGANODES;
        govOptionalDVNs[4] = DVN_LZ_LABS;
        govOptionalDVNs[5] = DVN_CANARY;
        govOptionalDVNs[6] = DVN_NETHERMIND;

        govUlnCfg = UlnConfig({
            confirmations:        15,
            requiredDVNCount:     255,  // NIL_DVN_COUNT: explicit zero (overrides defaults)
            optionalDVNCount:     7,
            optionalDVNThreshold: 4,
            requiredDVNs:         new address[](0),
            optionalDVNs:         govOptionalDVNs
        });

        // OFT ULN configs: 2-of-2 required (matching production)
        address[] memory oftRequiredDVNs = new address[](2);
        oftRequiredDVNs[0] = DVN_LZ_LABS;
        oftRequiredDVNs[1] = DVN_NETHERMIND;

        oftSendUlnCfg = UlnConfig({
            confirmations:        15,
            requiredDVNCount:     2,
            optionalDVNCount:     0,
            optionalDVNThreshold: 0,
            requiredDVNs:         oftRequiredDVNs,
            optionalDVNs:         new address[](0)
        });

        oftRecvUlnCfg = UlnConfig({
            confirmations:        12,
            requiredDVNCount:     2,
            optionalDVNCount:     0,
            optionalDVNThreshold: 0,
            requiredDVNs:         oftRequiredDVNs,
            optionalDVNs:         new address[](0)
        });
    }

    // ==================================
    //  wireGovPeer
    // ==================================

    // External wrapper so vm.expectRevert catches reverts from the inlined library call.
    function callWireGovPeer(uint32 remoteEid, GovConfig memory cfg) external {
        LZInit.wireGovPeer(remoteEid, cfg);
    }

    function test_wireGovPeer() public {
        // Shared CCIP DVN adapter with a route wired for DST_EID (dstConfig + receiveLibs), spliced into
        // the gov sender's optional DVN set as the CCIP arm.
        SendSideDeployer dep = new SendSideDeployer(SEND_LIB, new address[](0));
        dep.configure(CCIPDVNCfg({
            remoteEid:               DST_EID,
            remoteCcipChainSelector: BASE_CCIP_SELECTOR,
            remoteCcipAdapter:       makeAddr("remoteCcipAdapter"),
            remoteCcipBroadcaster:   makeAddr("remoteCcipBroadcaster"),
            sendLib:                 SEND_LIB,
            multiplierBps:           0,
            gas:                     200_000
        }));
        address ccip = address(dep.adapter());

        UlnConfig memory uln = govUlnCfg;
        uint256 idx;
        (uln.optionalDVNs, idx) = _insertSorted(uln.optionalDVNs, ccip);
        uln.optionalDVNCount    = uint8(uln.optionalDVNs.length);
        GovConfig memory cfg = GovConfig({
            peer:         govPeer,
            sendLib:      SEND_LIB,
            execCfg:      execCfg,
            sendUlnCfg:   uln,
            ccipDvnIndex: idx,
            l2GovRelay:   l2GovRelay
        });

        cfg.ccipDvnIndex = uln.optionalDVNs.length;
        vm.expectRevert(stdError.indexOOBError);
        this.callWireGovPeer(DST_EID, cfg);
        cfg.ccipDvnIndex = idx;

        vm.mockCall(ccip, abi.encodeWithSignature("dstConfig(uint32)", DST_EID % 30000), abi.encode(uint64(0), uint16(0), bytes(""), uint256(0)));
        vm.expectRevert("LZInit/ccip-route-unset");
        this.callWireGovPeer(DST_EID, cfg);
        vm.clearMockedCalls();

        vm.mockCall(ccip, abi.encodeWithSignature("receiveLibs(address,uint32)", SEND_LIB, DST_EID), abi.encode(bytes32(0)));
        vm.expectRevert("LZInit/ccip-recv-lib-unset");
        this.callWireGovPeer(DST_EID, cfg);
        vm.clearMockedCalls();

        // --- Happy path ---
        vm.startPrank(PAUSE_PROXY);
        LZInit.wireGovPeer(DST_EID, cfg);
        vm.stopPrank();

        assertEq(OAppLike(GOV_SENDER).peers(DST_EID), bytes32(uint256(uint160(govPeer))));
        assertEq(EndpointLike(ENDPOINT).getSendLibrary(GOV_SENDER, DST_EID), SEND_LIB);

        bytes memory rawExecCfg = EndpointLike(ENDPOINT).getConfig(GOV_SENDER, SEND_LIB, DST_EID, 1);
        (uint32 maxMsgSize, address exec) = abi.decode(rawExecCfg, (uint32, address));
        assertEq(maxMsgSize, 10000);
        assertEq(exec, EXECUTOR);

        _verifyUlnConfig(EndpointLike(ENDPOINT).getConfig(GOV_SENDER, SEND_LIB, DST_EID, 2), uln);

        assertTrue(
            GovSenderLike(GOV_SENDER).canCallTarget(L1_GOV_RELAY, DST_EID, bytes32(uint256(uint160(l2GovRelay)))));
    }

    function test_wireGovPeer_skipsCcipWhenSentinel() public {
        GovConfig memory cfg = GovConfig({
            peer:         govPeer,
            sendLib:      SEND_LIB,
            execCfg:      execCfg,
            sendUlnCfg:   govUlnCfg,
            ccipDvnIndex: type(uint256).max,
            l2GovRelay:   l2GovRelay
        });

        vm.startPrank(PAUSE_PROXY);
        LZInit.wireGovPeer(DST_EID, cfg);
        vm.stopPrank();

        assertEq(OAppLike(GOV_SENDER).peers(DST_EID), bytes32(uint256(uint160(govPeer))));
        assertTrue(
            GovSenderLike(GOV_SENDER).canCallTarget(L1_GOV_RELAY, DST_EID, bytes32(uint256(uint160(l2GovRelay)))));
    }

    // Inserts `x` into the ascending-sorted `arr`, returning the new array and `x`'s index.
    function _insertSorted(address[] memory arr, address x) internal pure returns (address[] memory out, uint256 idx) {
        out = new address[](arr.length + 1);
        idx = arr.length;
        for (uint256 i; i < arr.length; ++i) {
            if (x < arr[i]) { idx = i; break; }
        }
        for (uint256 i; i < idx; ++i)            out[i]     = arr[i];
        out[idx] = x;
        for (uint256 i = idx; i < arr.length; ++i) out[i + 1] = arr[i];
    }

    // ==================================
    //  wireOftPeer
    // ==================================

    // External helper for vm.expectRevert (LZInit functions are internal/inlined)
    function callWireOftPeer(
        address           oft,
        uint32            remoteEid,
        OftConfig  memory cfg,
        RateLimits memory rateLimits
    ) external {
        LZInit.wireOftPeer(oft, remoteEid, cfg, rateLimits);
    }

    function test_wireOftPeer() public {
        OftConfig memory cfg = OftConfig({
            peer:       oftPeer,
            sendLib:    SEND_LIB,
            execCfg:    execCfg,
            sendUlnCfg: oftSendUlnCfg,
            recvLib:    RECV_LIB,
            recvUlnCfg: oftRecvUlnCfg,
            optionsGas: 130_000
        });
        RateLimits memory rl = RateLimits({
            inboundWindow:  1 days,
            inboundLimit:   5_000_000e18,
            outboundWindow: 1 days + 1,
            outboundLimit:  5_000_000e18 + 1
        });

        // Already-wired peer (USDS_OFT is wired to AVAX_EID at the pinned block).
        vm.expectRevert("LZInit/already-wired");
        this.callWireOftPeer(USDS_OFT, AVAX_EID, cfg, rl);

        vm.startPrank(PAUSE_PROXY);
        LZInit.wireOftPeer(USDS_OFT, DST_EID, cfg, rl);
        vm.stopPrank();

        assertEq(OFTAdapterLike(USDS_OFT).peers(DST_EID), bytes32(uint256(uint160(oftPeer))));
        assertEq(EndpointLike(ENDPOINT).getSendLibrary(USDS_OFT, DST_EID), SEND_LIB);

        (address recvLib, bool isDefault) = EndpointLike(ENDPOINT).getReceiveLibrary(USDS_OFT, DST_EID);
        assertEq(recvLib, RECV_LIB);
        assertFalse(isDefault);

        bytes memory rawExecCfg = EndpointLike(ENDPOINT).getConfig(USDS_OFT, SEND_LIB, DST_EID, 1);
        (uint32 maxMsgSize, address exec) = abi.decode(rawExecCfg, (uint32, address));
        assertEq(maxMsgSize, 10000);
        assertEq(exec, EXECUTOR);

        _verifyUlnConfig(EndpointLike(ENDPOINT).getConfig(USDS_OFT, SEND_LIB, DST_EID, 2), oftSendUlnCfg);
        _verifyUlnConfig(EndpointLike(ENDPOINT).getConfig(USDS_OFT, RECV_LIB, DST_EID, 2), oftRecvUlnCfg);

        (, uint48 ibWindow,, uint256 ibLimit) = OFTAdapterLike(USDS_OFT).inboundRateLimits(DST_EID);
        assertEq(ibWindow, rl.inboundWindow);
        assertEq(ibLimit,  rl.inboundLimit);

        (, uint48 obWindow,, uint256 obLimit) = OFTAdapterLike(USDS_OFT).outboundRateLimits(DST_EID);
        assertEq(obWindow, rl.outboundWindow);
        assertEq(obLimit,  rl.outboundLimit);

        bytes memory expectedOpts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(cfg.optionsGas, 0);
        assertEq(OFTAdapterLike(USDS_OFT).enforcedOptions(DST_EID, 1), expectedOpts);
        assertEq(OFTAdapterLike(USDS_OFT).enforcedOptions(DST_EID, 2), expectedOpts);
    }

    // ==================================
    //  activateOft
    // ==================================

    // External helper for vm.expectRevert (LZInit functions are internal/inlined)
    function callActivateOft(
        address           oft,
        address           oftImp,
        uint32            remoteEid,
        OftConfig  memory cfg,
        RateLimits memory rateLimits,
        uint8             rlAccountingType,
        address           token,
        address           owner
    ) external {
        LZInit.activateOft(oft, oftImp, remoteEid, cfg, rateLimits, rlAccountingType, token, owner, ENDPOINT);
    }

    /// @dev The live adapters are the non-upgradeable V1 generation, so `getImplementation` is mocked.
    function _loadExpectedConfig(address oft, uint32 remoteEid) internal returns (
        OftConfig memory cfg,
        uint8            rlAccountingType,
        address          oftImp,
        address          token,
        address          owner
    ) {
        oftImp = makeAddr("oftImp");
        vm.mockCall(oft, abi.encodeWithSignature("getImplementation()"), abi.encode(oftImp));
        OFTAdapterLike oft_ = OFTAdapterLike(oft);
        EndpointLike   ep   = EndpointLike(oft_.endpoint());
        cfg.peer       = address(uint160(uint256(oft_.peers(remoteEid))));
        cfg.sendLib    = ep.getSendLibrary(oft, remoteEid);
        (cfg.recvLib,) = ep.getReceiveLibrary(oft, remoteEid);
        cfg.execCfg    = abi.decode(ep.getConfig(oft, cfg.sendLib, remoteEid, 1), (ExecutorConfig));
        cfg.sendUlnCfg = UlnLike(cfg.sendLib).getAppUlnConfig(oft, remoteEid);
        cfg.recvUlnCfg = UlnLike(cfg.recvLib).getAppUlnConfig(oft, remoteEid);
        cfg.optionsGas = 130_000;

        rlAccountingType = oft_.rateLimitAccountingType();
        token            = oft_.token();
        owner            = oft_.owner();
    }

    function test_activateOft() public {
        RateLimits memory rl = RateLimits({
            inboundWindow:  1 days,
            inboundLimit:   5_000_000e18,
            outboundWindow: 1 days + 1,
            outboundLimit:  5_000_000e18 + 1
        });

        OftConfig memory cfg;
        uint8   rlAt;
        address imp;
        address token;
        address owner;

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.expectRevert("LZInit/oft-imp-mismatch");
        this.callActivateOft(SUSDS_OFT, address(0xdead), AVAX_EID, cfg, rl, rlAt, token, owner);

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        cfg.peer = address(0xdead);
        vm.expectRevert("LZInit/peer-mismatch");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("paused()"), abi.encode(true));
        vm.expectRevert("LZInit/paused");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.expectRevert("LZInit/rl-accounting-mismatch");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, 99, token, owner);

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.expectRevert("LZInit/token-mismatch");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, address(0xdead), owner);

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.expectRevert("LZInit/owner-mismatch");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, address(0xdead));

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.mockCall(ENDPOINT, abi.encodeWithSignature("delegates(address)", SUSDS_OFT), abi.encode(address(0xdead)));
        vm.expectRevert("LZInit/delegate-mismatch");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("msgInspector()"), abi.encode(address(0xdead)));
        vm.expectRevert("LZInit/msg-inspector-nonzero");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("defaultFeeBps()"), abi.encode(uint16(1)));
        vm.expectRevert("LZInit/default-fee-nonzero");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("feeBps(uint32)", AVAX_EID), abi.encode(uint16(1), false));
        vm.expectRevert("LZInit/fee-nonzero");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("feeBps(uint32)", AVAX_EID), abi.encode(uint16(0), true));
        vm.expectRevert("LZInit/fee-nonzero");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("outboundRateLimits(uint32)", AVAX_EID), abi.encode(uint128(0), uint48(1 days), uint256(0), uint256(1e18)));
        vm.expectRevert("LZInit/outbound-rl-nonzero");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("inboundRateLimits(uint32)", AVAX_EID), abi.encode(uint128(0), uint48(1 days), uint256(0), uint256(1e18)));
        vm.expectRevert("LZInit/inbound-rl-nonzero");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        cfg.sendLib = address(0xdead);
        vm.expectRevert("LZInit/send-lib-mismatch");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.mockCall(ENDPOINT, abi.encodeWithSignature("isDefaultSendLibrary(address,uint32)", SUSDS_OFT, AVAX_EID), abi.encode(true));
        vm.expectRevert("LZInit/send-lib-default");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        cfg.recvLib = address(0xdead);
        vm.expectRevert("LZInit/recv-lib-mismatch");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.mockCall(ENDPOINT, abi.encodeWithSignature("getReceiveLibrary(address,uint32)", SUSDS_OFT, AVAX_EID), abi.encode(cfg.recvLib, true));
        vm.expectRevert("LZInit/recv-lib-default");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.mockCall(ENDPOINT, abi.encodeWithSignature("receiveLibraryTimeout(address,uint32)", SUSDS_OFT, AVAX_EID), abi.encode(address(0xdead), uint256(block.number + 100)));
        vm.expectRevert("LZInit/recv-lib-timeout-active");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        cfg.execCfg.maxMessageSize += 1;
        vm.expectRevert("LZInit/exec-cfg-mismatch");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        cfg.sendUlnCfg.confirmations += 1;
        vm.expectRevert("LZInit/send-uln-mismatch");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        cfg.sendUlnCfg.confirmations = 0;
        vm.mockCall(SEND_LIB, abi.encodeWithSignature("getAppUlnConfig(address,uint32)", SUSDS_OFT, AVAX_EID), abi.encode(cfg.sendUlnCfg));
        vm.expectRevert("LZInit/send-uln-conf-default");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        cfg.sendUlnCfg.requiredDVNCount = 0;
        vm.mockCall(SEND_LIB, abi.encodeWithSignature("getAppUlnConfig(address,uint32)", SUSDS_OFT, AVAX_EID), abi.encode(cfg.sendUlnCfg));
        vm.expectRevert("LZInit/send-uln-req-default");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        cfg.recvUlnCfg.confirmations += 1;
        vm.expectRevert("LZInit/recv-uln-mismatch");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        cfg.recvUlnCfg.confirmations = 0;
        vm.mockCall(RECV_LIB, abi.encodeWithSignature("getAppUlnConfig(address,uint32)", SUSDS_OFT, AVAX_EID), abi.encode(cfg.recvUlnCfg));
        vm.expectRevert("LZInit/recv-uln-conf-default");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        cfg.recvUlnCfg.requiredDVNCount = 0;
        vm.mockCall(RECV_LIB, abi.encodeWithSignature("getAppUlnConfig(address,uint32)", SUSDS_OFT, AVAX_EID), abi.encode(cfg.recvUlnCfg));
        vm.expectRevert("LZInit/recv-uln-req-default");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        cfg.optionsGas += 1;
        vm.expectRevert("LZInit/enforced-send-mismatch");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);

        // Mock only MSG_TYPE_SEND_AND_CALL (=2) to a bad value so MSG_TYPE_SEND (=1) still matches.
        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("enforcedOptions(uint32,uint16)", AVAX_EID, uint16(2)), abi.encode(bytes("bad")));
        vm.expectRevert("LZInit/enforced-send-and-call-mismatch");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);
        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("endpoint()"), abi.encode(address(0xdead)));
        vm.expectRevert("LZInit/endpoint-mismatch");
        this.callActivateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner);
        vm.clearMockedCalls();

        // --- Happy path ---

        (cfg, rlAt, imp, token, owner) = _loadExpectedConfig(SUSDS_OFT, AVAX_EID);

        vm.startPrank(PAUSE_PROXY);
        LZInit.activateOft(SUSDS_OFT, imp, AVAX_EID, cfg, rl, rlAt, token, owner, ENDPOINT);
        vm.stopPrank();

        (, uint48 ibWindow,, uint256 ibLimit) = OFTAdapterLike(SUSDS_OFT).inboundRateLimits(AVAX_EID);
        assertEq(ibWindow, rl.inboundWindow);
        assertEq(ibLimit,  rl.inboundLimit);

        (, uint48 obWindow,, uint256 obLimit) = OFTAdapterLike(SUSDS_OFT).outboundRateLimits(AVAX_EID);
        assertEq(obWindow, rl.outboundWindow);
        assertEq(obLimit,  rl.outboundLimit);
    }

    // ==================================
    //  updateRateLimits
    // ==================================

    function test_updateRateLimits() public {
        (, uint48 ibWindow,, uint256 ibLimit) = OFTAdapterLike(USDS_OFT).inboundRateLimits(AVAX_EID);
        assertEq(ibWindow, 1 days);
        assertEq(ibLimit,  5_000_000e18);
        (, uint48 obWindow,, uint256 obLimit) = OFTAdapterLike(USDS_OFT).outboundRateLimits(AVAX_EID);
        assertEq(obWindow, 1 days);
        assertEq(obLimit,  5_000_000e18);

        RateLimits memory rl = RateLimits({
            inboundWindow:  1 days,
            inboundLimit:   10_000_000e18,
            outboundWindow: 1 days + 1,
            outboundLimit:  10_000_000e18 + 1
        });

        vm.startPrank(PAUSE_PROXY);
        LZInit.updateRateLimits(USDS_OFT, AVAX_EID, rl);
        vm.stopPrank();

        (, ibWindow,, ibLimit) = OFTAdapterLike(USDS_OFT).inboundRateLimits(AVAX_EID);
        assertEq(ibWindow, rl.inboundWindow);
        assertEq(ibLimit,  rl.inboundLimit);

        (, obWindow,, obLimit) = OFTAdapterLike(USDS_OFT).outboundRateLimits(AVAX_EID);
        assertEq(obWindow, rl.outboundWindow);
        assertEq(obLimit,  rl.outboundLimit);
    }

    // ==================================
    //  updateGlobalRateLimits
    // ==================================

    function test_updateGlobalRateLimits() public {
        address impl = address(new SkyOFTAdapter(chainlog.getAddress("USDS"), ENDPOINT));
        address oft  = address(new ERC1967Proxy(impl, abi.encodeWithSignature("initialize(address)", address(this))));

        RateLimits memory grl = RateLimits({
            inboundWindow:  1 days,
            inboundLimit:   9_000_000e18,
            outboundWindow: 1 days + 1,
            outboundLimit:  8_000_000e18
        });
        LZInit.updateGlobalRateLimits(oft, grl);

        uint32 sentinel = OFTAdapterLike(oft).SENTINEL_EID();
        (, uint48 ibWindow,, uint256 ibLimit) = OFTAdapterLike(oft).inboundRateLimits(sentinel);
        assertEq(ibWindow, grl.inboundWindow);
        assertEq(ibLimit,  grl.inboundLimit);
        (, uint48 obWindow,, uint256 obLimit) = OFTAdapterLike(oft).outboundRateLimits(sentinel);
        assertEq(obWindow, grl.outboundWindow);
        assertEq(obLimit,  grl.outboundLimit);
    }

    // ==================================
    //  setUlnConfig
    // ==================================

    function test_setUlnConfig() public {
        // Sanity: USDS_OFT is wired to AVAX_EID with the production 2-of-2 (LZ Labs + Nethermind) send config.
        UlnConfig memory current = abi.decode(
            EndpointLike(ENDPOINT).getConfig(USDS_OFT, SEND_LIB, AVAX_EID, 2),
            (UlnConfig)
        );
        assertEq(current.confirmations,    15);
        assertEq(current.requiredDVNCount, 2);
        assertEq(current.optionalDVNCount, 0);

        // Migrate to a 4-of-4 required DVN set: {Horizen, LZ Labs, Canary, Nethermind} (sorted by address).
        address[] memory newRequiredDVNs = new address[](4);
        newRequiredDVNs[0] = DVN_HORIZEN;
        newRequiredDVNs[1] = DVN_LZ_LABS;
        newRequiredDVNs[2] = DVN_CANARY;
        newRequiredDVNs[3] = DVN_NETHERMIND;

        UlnConfig memory newCfg = UlnConfig({
            confirmations:        15,
            requiredDVNCount:     4,
            optionalDVNCount:     0,
            optionalDVNThreshold: 0,
            requiredDVNs:         newRequiredDVNs,
            optionalDVNs:         new address[](0)
        });

        vm.startPrank(PAUSE_PROXY);
        LZInit.setUlnConfig(USDS_OFT, AVAX_EID, SEND_LIB, newCfg);
        vm.stopPrank();

        _verifyUlnConfig(EndpointLike(ENDPOINT).getConfig(USDS_OFT, SEND_LIB, AVAX_EID, 2), newCfg);
    }

    // ==================================
    //  unpauseOft
    // ==================================

    function test_unpauseOft() public {
        vm.prank(PAUSE_PROXY);
        SkyOFTLike(USDS_OFT).setPauser(address(this), true);
        SkyOFTLike(USDS_OFT).pause();
        assertTrue(OFTAdapterLike(USDS_OFT).paused());

        vm.prank(PAUSE_PROXY);
        LZInit.unpauseOft(USDS_OFT);

        assertFalse(OFTAdapterLike(USDS_OFT).paused());
    }

    // ==================================
    //  activateSsrForwarder
    // ==================================

    // External wrapper so vm.expectRevert catches reverts from the inlined library call.
    function callActivateSsr(uint32 remoteEid, ForwarderConfig memory cfg) external {
        LZInit.activateSsrForwarder(address(ssrFwd), remoteEid, cfg);
    }

    function test_activateSsrForwarder() public {
        _deploySsrForwarder();

        ForwarderConfig memory cfg;

        cfg = _loadFwdCfg();
        vm.mockCall(address(ssrFwd), abi.encodeWithSignature("endpoint()"), abi.encode(address(0xdead)));
        vm.expectRevert("LZInit/endpoint-mismatch");
        this.callActivateSsr(DST_EID, cfg);
        vm.clearMockedCalls();

        cfg = _loadFwdCfg();
        vm.expectRevert("LZInit/dst-eid-mismatch");
        this.callActivateSsr(AVAX_EID, cfg);

        cfg = _loadFwdCfg();
        vm.mockCall(address(ssrFwd), abi.encodeWithSignature("susds()"), abi.encode(address(0xdead)));
        vm.expectRevert("LZInit/susds-mismatch");
        this.callActivateSsr(DST_EID, cfg);
        vm.clearMockedCalls();

        cfg = _loadFwdCfg();
        cfg.peer = address(0xdead);
        vm.expectRevert("LZInit/peer-mismatch");
        this.callActivateSsr(DST_EID, cfg);

        cfg = _loadFwdCfg();
        vm.mockCall(address(ssrFwd), abi.encodeWithSignature("owner()"), abi.encode(address(0xdead)));
        vm.expectRevert("LZInit/owner-mismatch");
        this.callActivateSsr(DST_EID, cfg);
        vm.clearMockedCalls();

        cfg = _loadFwdCfg();
        vm.mockCall(ENDPOINT, abi.encodeWithSignature("delegates(address)", address(ssrFwd)), abi.encode(address(0xdead)));
        vm.expectRevert("LZInit/delegate-mismatch");
        this.callActivateSsr(DST_EID, cfg);
        vm.clearMockedCalls();

        cfg = _loadFwdCfg();
        cfg.sendLib = address(0xdead);
        vm.expectRevert("LZInit/send-lib-mismatch");
        this.callActivateSsr(DST_EID, cfg);

        cfg = _loadFwdCfg();
        vm.mockCall(ENDPOINT, abi.encodeWithSignature("isDefaultSendLibrary(address,uint32)", address(ssrFwd), DST_EID), abi.encode(true));
        vm.expectRevert("LZInit/send-lib-default");
        this.callActivateSsr(DST_EID, cfg);
        vm.clearMockedCalls();

        cfg = _loadFwdCfg();
        cfg.execCfg.maxMessageSize += 1;
        vm.expectRevert("LZInit/exec-cfg-mismatch");
        this.callActivateSsr(DST_EID, cfg);

        cfg = _loadFwdCfg();
        cfg.sendUlnCfg.confirmations += 1;
        vm.expectRevert("LZInit/send-uln-mismatch");
        this.callActivateSsr(DST_EID, cfg);

        cfg = _loadFwdCfg();
        cfg.sendUlnCfg.confirmations = 0;
        vm.mockCall(SEND_LIB, abi.encodeWithSignature("getAppUlnConfig(address,uint32)", address(ssrFwd), DST_EID), abi.encode(cfg.sendUlnCfg));
        vm.expectRevert("LZInit/send-uln-conf-default");
        this.callActivateSsr(DST_EID, cfg);
        vm.clearMockedCalls();

        cfg = _loadFwdCfg();
        cfg.sendUlnCfg.requiredDVNCount = 0;
        vm.mockCall(SEND_LIB, abi.encodeWithSignature("getAppUlnConfig(address,uint32)", address(ssrFwd), DST_EID), abi.encode(cfg.sendUlnCfg));
        vm.expectRevert("LZInit/send-uln-req-default");
        this.callActivateSsr(DST_EID, cfg);
        vm.clearMockedCalls();

        cfg = _loadFwdCfg();
        cfg.sendUlnCfg.optionalDVNCount = 0;
        vm.mockCall(SEND_LIB, abi.encodeWithSignature("getAppUlnConfig(address,uint32)", address(ssrFwd), DST_EID), abi.encode(cfg.sendUlnCfg));
        vm.expectRevert("LZInit/send-uln-opt-default");
        this.callActivateSsr(DST_EID, cfg);
        vm.clearMockedCalls();

        cfg = _loadFwdCfg();
        cfg.optionsGas += 1;
        vm.expectRevert("LZInit/enforced-send-mismatch");
        this.callActivateSsr(DST_EID, cfg);

        cfg = _loadFwdCfg();
        cfg.composeGas += 1;
        vm.expectRevert("LZInit/enforced-send-mismatch");
        this.callActivateSsr(DST_EID, cfg);

        // An index past the end of the optional DVN set panics, so a bogus index can't sneak past
        // the membership requirement.
        cfg = _loadFwdCfg();
        cfg.ccipDvnIndex = cfg.sendUlnCfg.optionalDVNs.length;
        vm.expectRevert(stdError.indexOOBError);
        this.callActivateSsr(DST_EID, cfg);

        cfg = _loadFwdCfg();
        vm.mockCall(ssrCcipAdapter, abi.encodeWithSignature("dstConfig(uint32)", DST_EID % 30000), abi.encode(uint64(0), uint16(0), bytes(""), uint256(0)));
        vm.expectRevert("LZInit/ccip-route-unset");
        this.callActivateSsr(DST_EID, cfg);
        vm.clearMockedCalls();

        cfg = _loadFwdCfg();
        vm.mockCall(ssrCcipAdapter, abi.encodeWithSignature("receiveLibs(address,uint32)", SEND_LIB, DST_EID), abi.encode(bytes32(0)));
        vm.expectRevert("LZInit/ccip-recv-lib-unset");
        this.callActivateSsr(DST_EID, cfg);
        vm.clearMockedCalls();

        // Sentinel index: pure config sanity check, no route assertion and no whitelist grant.
        cfg = _loadFwdCfg();
        cfg.ccipDvnIndex = type(uint256).max;
        LZInit.activateSsrForwarder(address(ssrFwd), DST_EID, cfg);
        assertFalse(CCIPDVNAdapter(payable(ssrCcipAdapter)).hasRole(ALLOWLIST, address(ssrFwd)));

        // --- Happy path ---
        cfg = _loadFwdCfg();
        assertFalse(CCIPDVNAdapter(payable(ssrCcipAdapter)).hasRole(ALLOWLIST, address(ssrFwd)));

        vm.startPrank(PAUSE_PROXY);
        LZInit.activateSsrForwarder(address(ssrFwd), DST_EID, cfg);
        vm.stopPrank();

        assertTrue(CCIPDVNAdapter(payable(ssrCcipAdapter)).hasRole(ALLOWLIST, address(ssrFwd)));
    }

    // Deploy + pre-configure a real SSR forwarder and the shared CCIP DVN adapter exactly as the
    // deployer/gov-bridge bring-up would, leaving only the whitelist grant for the spell.
    function _deploySsrForwarder() internal {
        // Shared CCIP DVN adapter: route for DST_EID, admin handed to the pause proxy. A decoy keeps
        // allowlistSize > 0 so the forwarder is not implicitly whitelisted before the spell.
        address[] memory allow = new address[](1);
        allow[0] = makeAddr("govSenderDecoy");
        SendSideDeployer dep = new SendSideDeployer(SEND_LIB, allow);
        dep.configure(CCIPDVNCfg({
            remoteEid:               DST_EID,
            remoteCcipChainSelector: BASE_CCIP_SELECTOR,
            remoteCcipAdapter:       makeAddr("remoteCcipAdapter"),
            remoteCcipBroadcaster:   makeAddr("remoteCcipBroadcaster"),
            sendLib:                 SEND_LIB,
            multiplierBps:           0,
            gas:                     200_000
        }));
        dep.handOff(new address[](0));
        ssrCcipAdapter = address(dep.adapter());

        // Forwarder: test starts as owner/delegate, wires the send side with the CCIP adapter in the
        // optional DVN set + enforced options, then hands owner + delegate to the pause proxy.
        ssrFwd = new SSROracleForwarderLZ({
            _susds:    chainlog.getAddress("SUSDS"),
            _l2Oracle: FWD_RECEIVER,
            _endpoint: ENDPOINT,
            _delegate: address(this),
            _owner:    address(this),
            _dstEid:   DST_EID
        });

        FwdLike f = FwdLike(address(ssrFwd));
        f.setPeer(DST_EID, bytes32(uint256(uint160(FWD_RECEIVER))));
        EndpointLike(ENDPOINT).setSendLibrary(address(ssrFwd), DST_EID, SEND_LIB);

        address[] memory opt = _sortedPair(FWD_OTHER_DVN, ssrCcipAdapter);
        UlnConfig memory uln = UlnConfig({
            confirmations:        15,
            requiredDVNCount:     255,  // NIL: explicitly no required DVNs
            optionalDVNCount:     2,
            optionalDVNThreshold: 2,
            requiredDVNs:         new address[](0),
            optionalDVNs:         opt
        });
        SetConfigParam[] memory p = new SetConfigParam[](2);
        p[0] = SetConfigParam(DST_EID, 1, abi.encode(ExecutorConfig({ maxMessageSize: 10000, executor: EXECUTOR })));
        p[1] = SetConfigParam(DST_EID, 2, abi.encode(uln));
        EndpointLike(ENDPOINT).setConfig(address(ssrFwd), SEND_LIB, p);

        EnforcedOptionParam[] memory eo = new EnforcedOptionParam[](1);
        eo[0] = EnforcedOptionParam({
            eid:     DST_EID,
            msgType: MSG_TYPE_SEND,
            options: OptionsBuilder.newOptions()
                .addExecutorLzReceiveOption(FWD_OPTIONS_GAS, 0)
                .addExecutorLzComposeOption(0, FWD_COMPOSE_GAS, 0)
        });
        f.setEnforcedOptions(eo);

        f.setDelegate(PAUSE_PROXY);
        f.transferOwnership(PAUSE_PROXY);
    }

    function _loadFwdCfg() internal view returns (ForwarderConfig memory cfg) {
        cfg.peer         = FWD_RECEIVER;
        cfg.sendLib      = SEND_LIB;
        cfg.execCfg      = abi.decode(EndpointLike(ENDPOINT).getConfig(address(ssrFwd), SEND_LIB, DST_EID, 1), (ExecutorConfig));
        cfg.sendUlnCfg   = UlnLike(SEND_LIB).getAppUlnConfig(address(ssrFwd), DST_EID);
        cfg.optionsGas   = FWD_OPTIONS_GAS;
        cfg.composeGas   = FWD_COMPOSE_GAS;
        cfg.ccipDvnIndex = cfg.sendUlnCfg.optionalDVNs[0] == ssrCcipAdapter ? 0 : 1;
    }

    function _sortedPair(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        (out[0], out[1]) = a < b ? (a, b) : (b, a);
    }

    // ==================================
    //  Helpers
    // ==================================

    function _verifyUlnConfig(bytes memory rawUln, UlnConfig memory expected) internal pure {
        UlnConfig memory decoded = abi.decode(rawUln, (UlnConfig));

        // NIL_DVN_COUNT (255) resolves to 0 in getConfig
        uint8 expectedRequired = expected.requiredDVNCount == 255 ? 0 : expected.requiredDVNCount;
        uint8 expectedOptional = expected.optionalDVNCount == 255 ? 0 : expected.optionalDVNCount;

        assertEq(decoded.confirmations,        expected.confirmations);
        assertEq(decoded.requiredDVNCount,     expectedRequired);
        assertEq(decoded.optionalDVNCount,     expectedOptional);
        assertEq(decoded.optionalDVNThreshold, expected.optionalDVNThreshold);
        assertEq(decoded.requiredDVNs.length,  expected.requiredDVNs.length);
        for (uint256 i = 0; i < decoded.requiredDVNs.length; i++) {
            assertEq(decoded.requiredDVNs[i], expected.requiredDVNs[i]);
        }
        assertEq(decoded.optionalDVNs.length, expected.optionalDVNs.length);
        for (uint256 i = 0; i < decoded.optionalDVNs.length; i++) {
            assertEq(decoded.optionalDVNs[i], expected.optionalDVNs[i]);
        }
    }

}
