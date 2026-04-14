// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { OptionsBuilder } from "layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { LZInit, UlnConfig, ExecutorConfig, RateLimitConfig, OFTAdapterLike } from "deploy/LZInit.sol";

interface ChainlogReadLike {
    function getAddress(bytes32) external view returns (address);
}

/*** Read-only interfaces for state verification ***/

interface EndpointReadLike {
    function getSendLibrary(address oapp, uint32 eid) external view returns (address);
    function getReceiveLibrary(address oapp, uint32 eid) external view returns (address lib, bool isDefault);
    function getConfig(address oapp, address lib, uint32 eid, uint32 configType) external view returns (bytes memory);
}

interface GovSenderReadLike {
    function peers(uint32 eid) external view returns (bytes32);
    function canCallTarget(address srcSender, uint32 dstEid, bytes32 dstTarget) external view returns (bool);
}

interface OFTReadLike {
    function peers(uint32 eid) external view returns (bytes32);
    function token() external view returns (address);
    function outboundRateLimits(uint32 eid) external view returns (uint128 lastUpdated, uint48 window, uint256 amountInFlight, uint256 limit);
    function inboundRateLimits(uint32 eid) external view returns (uint128 lastUpdated, uint48 window, uint256 amountInFlight, uint256 limit);
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
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

    // Fake addresses for new remote contracts
    address govOAppReceiver;
    address l2GovRelay;
    address usdsMintBurn;

    // Reusable configs
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

        // Set up fake remote addresses
        govOAppReceiver     = makeAddr("govOAppReceiver");
        l2GovRelay          = makeAddr("l2GovRelay");
        usdsMintBurn        = makeAddr("usdsMintBurn");

        // Build executor config
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
    //  initGovOappSender
    // =====================

    function test_initGovOappSender() public {
        vm.startPrank(PAUSE_PROXY);
        LZInit.initGovOappSender(
            ENDPOINT,
            DST_EID,
            govOAppReceiver,
            l2GovRelay,
            SEND_LIB,
            execCfg,
            govUlnCfg
        );
        vm.stopPrank();

        assertEq(GovSenderReadLike(GOV_SENDER).peers(DST_EID), bytes32(uint256(uint160(govOAppReceiver))), "govSender peer");
        assertEq(EndpointReadLike(ENDPOINT).getSendLibrary(GOV_SENDER, DST_EID), SEND_LIB, "govSender send lib");

        bytes memory rawExecCfg = EndpointReadLike(ENDPOINT).getConfig(GOV_SENDER, SEND_LIB, DST_EID, 1);
        (uint32 maxMsgSize, address exec) = abi.decode(rawExecCfg, (uint32, address));
        assertEq(maxMsgSize, 10000, "govSender executor maxMessageSize");
        assertEq(exec, EXECUTOR, "govSender executor address");

        _verifyUlnConfig(EndpointReadLike(ENDPOINT).getConfig(GOV_SENDER, SEND_LIB, DST_EID, 2), govUlnCfg, "govSender send ULN");

        assertTrue(
            GovSenderReadLike(GOV_SENDER).canCallTarget(L1_GOV_RELAY, DST_EID, bytes32(uint256(uint160(l2GovRelay)))),
            "canCallTarget l1GovRelay -> l2GovRelay"
        );
    }

    // ========================
    //  initOFTAdapter
    // ========================

    function test_initOFTAdapter() public {
        uint48  inboundWindow  = 1 days;
        uint256 inboundLimit   = 5_000_000e18;
        uint48  outboundWindow = 1 days;
        uint256 outboundLimit  = 5_000_000e18;
        uint128 optionsGas     = 130_000;

        vm.startPrank(PAUSE_PROXY);
        LZInit.initOFTAdapter(
            ENDPOINT,
            USDS_OFT,
            DST_EID,
            usdsMintBurn,
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

        assertEq(OFTReadLike(USDS_OFT).peers(DST_EID), bytes32(uint256(uint160(usdsMintBurn))), "oft peer");
        assertEq(EndpointReadLike(ENDPOINT).getSendLibrary(USDS_OFT, DST_EID), SEND_LIB, "oft send lib");

        (address rl, bool isDefault) = EndpointReadLike(ENDPOINT).getReceiveLibrary(USDS_OFT, DST_EID);
        assertEq(rl, RECV_LIB, "oft recv lib");
        assertFalse(isDefault, "oft recv lib should be explicitly set");

        bytes memory rawExecCfg = EndpointReadLike(ENDPOINT).getConfig(USDS_OFT, SEND_LIB, DST_EID, 1);
        (uint32 maxMsgSize, address exec) = abi.decode(rawExecCfg, (uint32, address));
        assertEq(maxMsgSize, 10000, "oft executor maxMessageSize");
        assertEq(exec, EXECUTOR, "oft executor address");

        _verifyUlnConfig(EndpointReadLike(ENDPOINT).getConfig(USDS_OFT, SEND_LIB, DST_EID, 2), oftSendUlnCfg, "oft send ULN");
        _verifyUlnConfig(EndpointReadLike(ENDPOINT).getConfig(USDS_OFT, RECV_LIB, DST_EID, 2), oftRecvUlnCfg, "oft recv ULN");

        (, uint48 ibWindow,, uint256 ibLimit) = OFTReadLike(USDS_OFT).inboundRateLimits(DST_EID);
        assertEq(ibWindow, inboundWindow, "inbound window");
        assertEq(ibLimit,  inboundLimit,  "inbound limit");

        (, uint48 obWindow,, uint256 obLimit) = OFTReadLike(USDS_OFT).outboundRateLimits(DST_EID);
        assertEq(obWindow, outboundWindow, "outbound window");
        assertEq(obLimit,  outboundLimit,  "outbound limit");

        bytes memory expectedOpts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(optionsGas, 0);
        assertEq(OFTReadLike(USDS_OFT).enforcedOptions(DST_EID, 1), expectedOpts, "enforced options SEND");
        assertEq(OFTReadLike(USDS_OFT).enforcedOptions(DST_EID, 2), expectedOpts, "enforced options SEND_AND_CALL");
    }

    // ==================================
    //  initSusdsBridge
    // ==================================

    // External helper for vm.expectRevert (LZInit functions are internal/inlined)
    function callInitSusdsBridge(
        address oftAdapter, address endpoint, uint32 dstEid, bytes32 expectedPeer,
        address expectedOwner, address expectedToken, uint8 expectedRlAccountingType,
        uint48 inboundWindow, uint256 inboundLimit, uint48 outboundWindow, uint256 outboundLimit
    ) external {
        LZInit.initSusdsBridge(
            oftAdapter, endpoint, dstEid, expectedPeer,
            expectedOwner, expectedToken, expectedRlAccountingType,
            inboundWindow, inboundLimit, outboundWindow, outboundLimit
        );
    }

    function test_initSusdsBridge() public {
        uint32  avaxEid = 30106;
        bytes32 peer    = OFTReadLike(SUSDS_OFT).peers(avaxEid);
        address token   = OFTReadLike(SUSDS_OFT).token();

        // --- Sanity check reverts ---

        vm.expectRevert("LZInit/owner-mismatch");
        this.callInitSusdsBridge(SUSDS_OFT, ENDPOINT, avaxEid, peer, address(0xdead), token, 0, 1 days, 1e18, 1 days, 1e18);

        vm.expectRevert("LZInit/endpoint-mismatch");
        this.callInitSusdsBridge(SUSDS_OFT, address(0xdead), avaxEid, peer, PAUSE_PROXY, token, 0, 1 days, 1e18, 1 days, 1e18);

        vm.expectRevert("LZInit/peer-mismatch");
        this.callInitSusdsBridge(SUSDS_OFT, ENDPOINT, avaxEid, bytes32(uint256(1)), PAUSE_PROXY, token, 0, 1 days, 1e18, 1 days, 1e18);

        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("paused()"), abi.encode(true));
        vm.expectRevert("LZInit/paused");
        this.callInitSusdsBridge(SUSDS_OFT, ENDPOINT, avaxEid, peer, PAUSE_PROXY, token, 0, 1 days, 1e18, 1 days, 1e18);
        vm.clearMockedCalls();

        vm.expectRevert("LZInit/token-mismatch");
        this.callInitSusdsBridge(SUSDS_OFT, ENDPOINT, avaxEid, peer, PAUSE_PROXY, address(0xdead), 0, 1 days, 1e18, 1 days, 1e18);

        vm.mockCall(ENDPOINT, abi.encodeWithSignature("delegates(address)", SUSDS_OFT), abi.encode(address(0xdead)));
        vm.expectRevert("LZInit/delegate-mismatch");
        this.callInitSusdsBridge(SUSDS_OFT, ENDPOINT, avaxEid, peer, PAUSE_PROXY, token, 0, 1 days, 1e18, 1 days, 1e18);
        vm.clearMockedCalls();

        vm.expectRevert("LZInit/rl-accounting-mismatch");
        this.callInitSusdsBridge(SUSDS_OFT, ENDPOINT, avaxEid, peer, PAUSE_PROXY, token, 99, 1 days, 1e18, 1 days, 1e18);

        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("outboundRateLimits(uint32)", avaxEid), abi.encode(uint128(0), uint48(1 days), uint256(0), uint256(1e18)));
        vm.expectRevert("LZInit/outbound-rl-nonzero");
        this.callInitSusdsBridge(SUSDS_OFT, ENDPOINT, avaxEid, peer, PAUSE_PROXY, token, 0, 1 days, 1e18, 1 days, 1e18);
        vm.clearMockedCalls();

        vm.mockCall(SUSDS_OFT, abi.encodeWithSignature("inboundRateLimits(uint32)", avaxEid), abi.encode(uint128(0), uint48(1 days), uint256(0), uint256(1e18)));
        vm.expectRevert("LZInit/inbound-rl-nonzero");
        this.callInitSusdsBridge(SUSDS_OFT, ENDPOINT, avaxEid, peer, PAUSE_PROXY, token, 0, 1 days, 1e18, 1 days, 1e18);
        vm.clearMockedCalls();

        // --- Happy path ---

        uint48  inboundWindow  = 1 days;
        uint256 inboundLimit   = 2_000_000e18;
        uint48  outboundWindow = 1 days;
        uint256 outboundLimit  = 2_000_000e18;

        vm.startPrank(PAUSE_PROXY);
        LZInit.initSusdsBridge(
            SUSDS_OFT, ENDPOINT, avaxEid, peer,
            PAUSE_PROXY, token, 0,
            inboundWindow, inboundLimit, outboundWindow, outboundLimit
        );
        vm.stopPrank();

        (, uint48 ibWindow,, uint256 ibLimit) = OFTReadLike(SUSDS_OFT).inboundRateLimits(avaxEid);
        assertEq(ibWindow, inboundWindow, "inbound window");
        assertEq(ibLimit,  inboundLimit,  "inbound limit");

        (, uint48 obWindow,, uint256 obLimit) = OFTReadLike(SUSDS_OFT).outboundRateLimits(avaxEid);
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
            EndpointReadLike(ENDPOINT).getSendLibrary(SPARK_PROXY, DST_EID),
            SEND_LIB,
            "lzSender send lib mismatch"
        );

        bytes memory rawExecCfg = EndpointReadLike(ENDPOINT).getConfig(SPARK_PROXY, SEND_LIB, DST_EID, 1);
        (uint32 maxMsgSize, address exec) = abi.decode(rawExecCfg, (uint32, address));
        assertEq(maxMsgSize, 10000, "lzSender executor maxMessageSize mismatch");
        assertEq(exec, EXECUTOR, "lzSender executor address mismatch");

        bytes memory rawSendUln = EndpointReadLike(ENDPOINT).getConfig(SPARK_PROXY, SEND_LIB, DST_EID, 2);
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
