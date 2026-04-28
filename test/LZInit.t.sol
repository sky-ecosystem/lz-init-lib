// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { OptionsBuilder } from "layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { LZInit, UlnConfig, ExecutorConfig, OftConfig, EndpointLike, OFTAdapterLike, OAppLike } from "deploy/LZInit.sol";

interface ChainlogReadLike {
    function getAddress(bytes32) external view returns (address);
}

interface GovSenderLike {
    function canCallTarget(address srcSender, uint32 dstEid, bytes32 dstTarget) external view returns (bool);
}

/*** Test contract ***/

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

    uint32 constant DST_EID = 30184; // Base (new remote)

    address govPeer;
    address l2GovRelay;
    address oftPeer;

    ExecutorConfig execCfg;
    UlnConfig      govUlnCfg;   // 4-of-7 optional for governance OApp
    UlnConfig      oftSendUlnCfg; // 2-of-2 required for OFT send
    UlnConfig      oftRecvUlnCfg; // 2-of-2 required for OFT receive

    function setUp() public {
        // Pinned to the block where SUSDS_OFT was configured for Avalanche, still with 0 rate limits.
        vm.createSelectFork("mainnet", 24871363);

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

    // =====================
    //  wireGovPeer
    // =====================

    function test_wireGovPeer() public {
        vm.startPrank(PAUSE_PROXY);
        LZInit.wireGovPeer(
            ENDPOINT,
            DST_EID,
            govPeer,
            l2GovRelay,
            SEND_LIB,
            execCfg,
            govUlnCfg
        );
        vm.stopPrank();

        assertEq(OAppLike(GOV_SENDER).peers(DST_EID), bytes32(uint256(uint160(govPeer))), "govSender peer");
        assertEq(EndpointLike(ENDPOINT).getSendLibrary(GOV_SENDER, DST_EID), SEND_LIB, "govSender send lib");

        bytes memory rawExecCfg = EndpointLike(ENDPOINT).getConfig(GOV_SENDER, SEND_LIB, DST_EID, 1);
        (uint32 maxMsgSize, address exec) = abi.decode(rawExecCfg, (uint32, address));
        assertEq(maxMsgSize, 10000, "govSender executor maxMessageSize");
        assertEq(exec, EXECUTOR, "govSender executor address");

        _verifyUlnConfig(EndpointLike(ENDPOINT).getConfig(GOV_SENDER, SEND_LIB, DST_EID, 2), govUlnCfg, "govSender send ULN");

        assertTrue(
            GovSenderLike(GOV_SENDER).canCallTarget(L1_GOV_RELAY, DST_EID, bytes32(uint256(uint160(l2GovRelay)))),
            "canCallTarget l1GovRelay -> l2GovRelay"
        );
    }

    // ========================
    //  wireOftPeer
    // ========================

    function test_wireOftPeer() public {
        uint48  inboundWindow  = 1 days;
        uint256 inboundLimit   = 5_000_000e18;
        uint48  outboundWindow = 1 days;
        uint256 outboundLimit  = 5_000_000e18;
        uint128 optionsGas     = 130_000;

        vm.startPrank(PAUSE_PROXY);
        LZInit.wireOftPeer(
            ENDPOINT,
            USDS_OFT,
            DST_EID,
            oftPeer,
            SEND_LIB,
            RECV_LIB,
            execCfg,
            oftSendUlnCfg,
            oftRecvUlnCfg,
            inboundWindow,
            inboundLimit,
            outboundWindow,
            outboundLimit,
            optionsGas
        );
        vm.stopPrank();

        assertEq(OFTAdapterLike(USDS_OFT).peers(DST_EID), bytes32(uint256(uint160(oftPeer))), "oft peer");
        assertEq(EndpointLike(ENDPOINT).getSendLibrary(USDS_OFT, DST_EID), SEND_LIB, "oft send lib");

        (address rl, bool isDefault) = EndpointLike(ENDPOINT).getReceiveLibrary(USDS_OFT, DST_EID);
        assertEq(rl, RECV_LIB, "oft recv lib");
        assertFalse(isDefault, "oft recv lib should be explicitly set");

        bytes memory rawExecCfg = EndpointLike(ENDPOINT).getConfig(USDS_OFT, SEND_LIB, DST_EID, 1);
        (uint32 maxMsgSize, address exec) = abi.decode(rawExecCfg, (uint32, address));
        assertEq(maxMsgSize, 10000, "oft executor maxMessageSize");
        assertEq(exec, EXECUTOR, "oft executor address");

        _verifyUlnConfig(EndpointLike(ENDPOINT).getConfig(USDS_OFT, SEND_LIB, DST_EID, 2), oftSendUlnCfg, "oft send ULN");
        _verifyUlnConfig(EndpointLike(ENDPOINT).getConfig(USDS_OFT, RECV_LIB, DST_EID, 2), oftRecvUlnCfg, "oft recv ULN");

        (, uint48 ibWindow,, uint256 ibLimit) = OFTAdapterLike(USDS_OFT).inboundRateLimits(DST_EID);
        assertEq(ibWindow, inboundWindow, "inbound window");
        assertEq(ibLimit,  inboundLimit,  "inbound limit");

        (, uint48 obWindow,, uint256 obLimit) = OFTAdapterLike(USDS_OFT).outboundRateLimits(DST_EID);
        assertEq(obWindow, outboundWindow, "outbound window");
        assertEq(obLimit,  outboundLimit,  "outbound limit");

        bytes memory expectedOpts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(optionsGas, 0);
        assertEq(OFTAdapterLike(USDS_OFT).enforcedOptions(DST_EID, 1), expectedOpts, "enforced options SEND");
        assertEq(OFTAdapterLike(USDS_OFT).enforcedOptions(DST_EID, 2), expectedOpts, "enforced options SEND_AND_CALL");
    }

    // ==================================
    //  activateOft
    // ==================================

    // External helper for vm.expectRevert (LZInit functions are internal/inlined)
    function callActivateOft(
        address oft,
        address endpoint,
        uint32  dstEid,
        OftConfig memory expected,
        uint48  inboundWindow,
        uint256 inboundLimit,
        uint48  outboundWindow,
        uint256 outboundLimit
    ) external {
        LZInit.activateOft(
            oft, endpoint, dstEid, expected,
            inboundWindow, inboundLimit, outboundWindow, outboundLimit
        );
    }

    function _loadExpectedConfig(address oft, uint32 dstEid) internal view returns (OftConfig memory e) {
        OFTAdapterLike oft_ = OFTAdapterLike(oft);
        e.peer             = oft_.peers(dstEid);
        e.owner            = oft_.owner();
        e.token            = oft_.token();
        e.rlAccountingType = oft_.rateLimitAccountingType();
        e.sendLib          = EndpointLike(ENDPOINT).getSendLibrary(oft, dstEid);
        (e.recvLib,)       = EndpointLike(ENDPOINT).getReceiveLibrary(oft, dstEid);
        bytes memory sendRaw = EndpointLike(ENDPOINT).getConfig(oft, e.sendLib, dstEid, 2);
        bytes memory recvRaw = EndpointLike(ENDPOINT).getConfig(oft, e.recvLib, dstEid, 2);
        e.sendUlnCfg = abi.decode(sendRaw, (UlnConfig));
        e.recvUlnCfg = abi.decode(recvRaw, (UlnConfig));
        e.optionsGas = 130_000;
    }

    function test_activateOft() public {
        uint32  avaxEid = 30106;

        uint48  inboundWindow  = 1 days;
        uint256 inboundLimit   = 2_000_000e18;
        uint48  outboundWindow = 1 days;
        uint256 outboundLimit  = 2_000_000e18;

        OftConfig memory bad;

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        bad.owner = address(0xdead);
        vm.expectRevert("LZInit/owner-mismatch");
        this.callActivateOft(SUSDS_OFT, ENDPOINT, avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        vm.expectRevert("LZInit/endpoint-mismatch");
        this.callActivateOft(SUSDS_OFT, address(0xdead), avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        bad.peer = bytes32(uint256(1));
        vm.expectRevert("LZInit/peer-mismatch");
        this.callActivateOft(SUSDS_OFT, ENDPOINT, avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("paused()"), abi.encode(true));
        vm.expectRevert("LZInit/paused");
        this.callActivateOft(SUSDS_OFT, ENDPOINT, avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);
        vm.clearMockedCalls();

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        bad.token = address(0xdead);
        vm.expectRevert("LZInit/token-mismatch");
        this.callActivateOft(SUSDS_OFT, ENDPOINT, avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        vm.mockCall(ENDPOINT, abi.encodeWithSignature("delegates(address)", SUSDS_OFT), abi.encode(address(0xdead)));
        vm.expectRevert("LZInit/delegate-mismatch");
        this.callActivateOft(SUSDS_OFT, ENDPOINT, avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);
        vm.clearMockedCalls();

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        bad.rlAccountingType = 99;
        vm.expectRevert("LZInit/rl-accounting-mismatch");
        this.callActivateOft(SUSDS_OFT, ENDPOINT, avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("outboundRateLimits(uint32)", avaxEid), abi.encode(uint128(0), uint48(1 days), uint256(0), uint256(1e18)));
        vm.expectRevert("LZInit/outbound-rl-nonzero");
        this.callActivateOft(SUSDS_OFT, ENDPOINT, avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);
        vm.clearMockedCalls();

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("inboundRateLimits(uint32)", avaxEid), abi.encode(uint128(0), uint48(1 days), uint256(0), uint256(1e18)));
        vm.expectRevert("LZInit/inbound-rl-nonzero");
        this.callActivateOft(SUSDS_OFT, ENDPOINT, avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);
        vm.clearMockedCalls();

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        bad.sendLib = address(0xdead);
        vm.expectRevert("LZInit/send-lib-mismatch");
        this.callActivateOft(SUSDS_OFT, ENDPOINT, avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        bad.recvLib = address(0xdead);
        vm.expectRevert("LZInit/recv-lib-mismatch");
        this.callActivateOft(SUSDS_OFT, ENDPOINT, avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        bad.sendUlnCfg.confirmations += 1;
        vm.expectRevert("LZInit/send-uln-mismatch");
        this.callActivateOft(SUSDS_OFT, ENDPOINT, avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        bad.recvUlnCfg.confirmations += 1;
        vm.expectRevert("LZInit/recv-uln-mismatch");
        this.callActivateOft(SUSDS_OFT, ENDPOINT, avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);

        bad = _loadExpectedConfig(SUSDS_OFT, avaxEid);
        bad.optionsGas += 1;
        vm.expectRevert("LZInit/enforced-send-mismatch");
        this.callActivateOft(SUSDS_OFT, ENDPOINT, avaxEid, bad, inboundWindow, inboundLimit, outboundWindow, outboundLimit);

        // --- Happy path ---

        OftConfig memory expected = _loadExpectedConfig(SUSDS_OFT, avaxEid);

        vm.startPrank(PAUSE_PROXY);
        LZInit.activateOft(
            SUSDS_OFT, ENDPOINT, avaxEid, expected,
            inboundWindow, inboundLimit, outboundWindow, outboundLimit
        );
        vm.stopPrank();

        (, uint48 ibWindow,, uint256 ibLimit) = OFTAdapterLike(SUSDS_OFT).inboundRateLimits(avaxEid);
        assertEq(ibWindow, inboundWindow, "inbound window");
        assertEq(ibLimit,  inboundLimit,  "inbound limit");

        (, uint48 obWindow,, uint256 obLimit) = OFTAdapterLike(SUSDS_OFT).outboundRateLimits(avaxEid);
        assertEq(obWindow, outboundWindow, "outbound window");
        assertEq(obLimit,  outboundLimit,  "outbound limit");
    }

    // ==================================
    //  initLZSender
    // ==================================

    function test_initLZSender() public {
        address SPARK_PROXY = chainlog.getAddress("SPARK_SUBPROXY");

        // Spell executes through the Star subproxy, which authorizes endpoint config for itself.
        vm.startPrank(SPARK_PROXY);
        LZInit.initLZSender(
            ENDPOINT,
            SPARK_PROXY,
            DST_EID,
            SEND_LIB,
            execCfg,
            govUlnCfg
        );
        vm.stopPrank();

        assertEq(
            EndpointLike(ENDPOINT).getSendLibrary(SPARK_PROXY, DST_EID),
            SEND_LIB,
            "lzSender send lib"
        );

        bytes memory rawExecCfg = EndpointLike(ENDPOINT).getConfig(SPARK_PROXY, SEND_LIB, DST_EID, 1);
        (uint32 maxMsgSize, address exec) = abi.decode(rawExecCfg, (uint32, address));
        assertEq(maxMsgSize, 10000, "lzSender executor maxMessageSize");
        assertEq(exec, EXECUTOR, "lzSender executor address");

        bytes memory rawSendUln = EndpointLike(ENDPOINT).getConfig(SPARK_PROXY, SEND_LIB, DST_EID, 2);
        _verifyUlnConfig(rawSendUln, govUlnCfg, "lzSender send ULN");
    }

    // ==================================
    //  Helpers
    // ==================================

    function _verifyUlnConfig(bytes memory rawUln, UlnConfig memory expected, string memory label) internal pure {
        UlnConfig memory decoded = abi.decode(rawUln, (UlnConfig));

        // NIL_DVN_COUNT (255) resolves to 0 in getConfig
        uint8 expectedRequired = expected.requiredDVNCount == 255 ? 0 : expected.requiredDVNCount;
        uint8 expectedOptional = expected.optionalDVNCount == 255 ? 0 : expected.optionalDVNCount;

        assertEq(decoded.confirmations,        expected.confirmations,        string.concat(label, ": confirmations"));
        assertEq(decoded.requiredDVNCount,     expectedRequired,              string.concat(label, ": requiredDVNCount"));
        assertEq(decoded.optionalDVNCount,     expectedOptional,              string.concat(label, ": optionalDVNCount"));
        assertEq(decoded.optionalDVNThreshold, expected.optionalDVNThreshold, string.concat(label, ": optionalDVNThreshold"));
        assertEq(decoded.requiredDVNs.length,  expected.requiredDVNs.length,  string.concat(label, ": requiredDVNs length"));
        for (uint256 i = 0; i < decoded.requiredDVNs.length; i++) {
            assertEq(decoded.requiredDVNs[i], expected.requiredDVNs[i], string.concat(label, ": requiredDVN"));
        }
        assertEq(decoded.optionalDVNs.length, expected.optionalDVNs.length, string.concat(label, ": optionalDVNs length"));
        for (uint256 i = 0; i < decoded.optionalDVNs.length; i++) {
            assertEq(decoded.optionalDVNs[i], expected.optionalDVNs[i], string.concat(label, ": optionalDVN"));
        }
    }

}
