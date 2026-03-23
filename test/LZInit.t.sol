// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { LZInit, UlnConfig, ExecutorConfig, RateLimitConfig, OFTAdapterLike } from "deploy/LZInit.sol";

/*** Read-only interfaces for state verification ***/

interface EndpointReadLike {
    function getSendLibrary(address oapp, uint32 eid) external view returns (address);
    function getReceiveLibrary(address oapp, uint32 eid) external view returns (address lib, bool isDefault);
    function getConfig(address oapp, address lib, uint32 eid, uint32 configType) external view returns (bytes memory);
    function delegates(address oapp) external view returns (address);
}

interface PeerReadLike {
    function peers(uint32 eid) external view returns (bytes32);
}

interface GovSenderReadLike {
    function peers(uint32 eid) external view returns (bytes32);
    function canCallTarget(address srcSender, uint32 dstEid, bytes32 dstTarget) external view returns (bool);
    function owner() external view returns (address);
}

interface OFTReadLike {
    function peers(uint32 eid) external view returns (bytes32);
    function owner() external view returns (address);
    function token() external view returns (address);
    function outboundRateLimits(uint32 eid) external view returns (uint128 lastUpdated, uint48 window, uint256 amountInFlight, uint256 limit);
    function inboundRateLimits(uint32 eid) external view returns (uint128 lastUpdated, uint48 window, uint256 amountInFlight, uint256 limit);
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
}

/*** Test contract ***/

contract LZInitTest is Test {

    // --- Ethereum mainnet addresses ---
    address constant ENDPOINT    = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant GOV_SENDER  = 0x27FC1DD771817b53bE48Dc28789533BEa53C9CCA;
    address constant USDS_OFT    = 0x1e1D42781FC170EF9da004Fb735f56F0276d01B8;
    address constant L1_GOV_RELAY = 0x2beBFe397D497b66cB14461cB6ee467b4C3B7D61;
    address constant GOV_OWNER   = 0xBE8E3e3618f7474F8cB1d074A26afFef007E98FB; // MCD_PAUSE_PROXY
    address constant SEND_LIB    = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1; // SendUln302
    address constant RECV_LIB    = 0xc02Ab410f0734EFa3F14628780e6e695156024C2; // ReceiveUln302
    address constant EXECUTOR    = 0x173272739Bd7Aa6e4e214714048a9fE699453059;

    // Ethereum DVN addresses (sorted — required by UlnConfig)
    address constant DVN_P2P              = 0x06559EE34D85a88317Bf0bfE307444116c631b67;
    address constant DVN_DEUTSCHE_TELEKOM = 0x373a6E5c0C4E89E24819f00AA37ea370917AAfF4;
    address constant DVN_HORIZEN          = 0x380275805876Ff19055EA900CDb2B46a94ecF20D;
    address constant DVN_LUGANODES        = 0x58249a2Ec05c1978bF21DF1f5eC1847e42455CF4;
    address constant DVN_LZ_LABS          = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
    address constant DVN_CANARY           = 0xa4fE5A5B9A846458a70Cd0748228aED3bF65c2cd;
    address constant DVN_NETHERMIND       = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;

    // Test target — use a hypothetical new chain
    uint32 constant DST_EID = 30184; // Base

    // Fake addresses for new remote contracts
    address govOAppReceiver;
    address l2GovRelay;
    address usdsMintBurn;
    address lzGovBridgeReceiver;
    address starSubproxy;
    address ssrForwarder;

    // Reusable configs
    ExecutorConfig execCfg;
    UlnConfig      sendUlnCfg;
    UlnConfig      recvUlnCfg;

    function setUp() public {
        vm.createSelectFork("mainnet");

        // Set up fake remote addresses
        govOAppReceiver     = makeAddr("govOAppReceiver");
        l2GovRelay          = makeAddr("l2GovRelay");
        usdsMintBurn        = makeAddr("usdsMintBurn");
        lzGovBridgeReceiver = makeAddr("lzGovBridgeReceiver");
        starSubproxy        = makeAddr("starSubproxy");
        ssrForwarder        = makeAddr("ssrForwarder");

        // Build executor config (matching existing Solana config)
        execCfg = ExecutorConfig({
            maxMessageSize: 10000,
            executor:       EXECUTOR
        });

        // Build send ULN config (Ethereum → Remote, 15 confirmations)
        // Using explicit requiredDVNs to avoid LZ endpoint merging with defaults.
        // When requiredDVNCount=0, getConfig resolves to the default required DVNs,
        // making verification unpredictable. Use requiredDVNCount > 0 for deterministic tests.
        address[] memory sendRequiredDVNs = new address[](2);
        sendRequiredDVNs[0] = DVN_LZ_LABS;
        sendRequiredDVNs[1] = DVN_NETHERMIND;

        address[] memory sendOptionalDVNs = new address[](5);
        sendOptionalDVNs[0] = DVN_P2P;
        sendOptionalDVNs[1] = DVN_DEUTSCHE_TELEKOM;
        sendOptionalDVNs[2] = DVN_HORIZEN;
        sendOptionalDVNs[3] = DVN_LUGANODES;
        sendOptionalDVNs[4] = DVN_CANARY;

        sendUlnCfg = UlnConfig({
            confirmations:        15,
            requiredDVNCount:     2,
            optionalDVNCount:     5,
            optionalDVNThreshold: 3,
            requiredDVNs:         sendRequiredDVNs,
            optionalDVNs:         sendOptionalDVNs
        });

        // Build receive ULN config (Remote → Ethereum, 12 confirmations, 2 required DVNs)
        address[] memory recvRequiredDVNs = new address[](2);
        recvRequiredDVNs[0] = DVN_LZ_LABS;
        recvRequiredDVNs[1] = DVN_NETHERMIND;

        recvUlnCfg = UlnConfig({
            confirmations:        12,
            requiredDVNCount:     2,
            optionalDVNCount:     0,
            optionalDVNThreshold: 0,
            requiredDVNs:         recvRequiredDVNs,
            optionalDVNs:         new address[](0)
        });
    }

    // =====================
    //  initGovSender tests
    // =====================

    function test_initGovSender() public {
        vm.startPrank(GOV_OWNER);
        LZInit.initGovSender(
            ENDPOINT,
            GOV_SENDER,
            DST_EID,
            govOAppReceiver,
            L1_GOV_RELAY,
            l2GovRelay,
            SEND_LIB,
            RECV_LIB,
            execCfg,
            sendUlnCfg,
            recvUlnCfg
        );
        vm.stopPrank();

        _verifyGovSenderState();
    }

    function _verifyGovSenderState() internal view {
        // 1. Verify peer
        bytes32 expectedPeer = bytes32(uint256(uint160(govOAppReceiver)));
        assertEq(GovSenderReadLike(GOV_SENDER).peers(DST_EID), expectedPeer, "govSender peer mismatch");

        // 2. Verify send library
        assertEq(
            EndpointReadLike(ENDPOINT).getSendLibrary(GOV_SENDER, DST_EID),
            SEND_LIB,
            "govSender send lib mismatch"
        );

        // 3. Verify receive library
        (address rl, bool isDefault) = EndpointReadLike(ENDPOINT).getReceiveLibrary(GOV_SENDER, DST_EID);
        assertEq(rl, RECV_LIB, "govSender recv lib mismatch");
        assertFalse(isDefault, "govSender recv lib should be explicitly set");

        // 4. Verify send executor config
        bytes memory rawExecCfg = EndpointReadLike(ENDPOINT).getConfig(GOV_SENDER, SEND_LIB, DST_EID, 1);
        (uint32 maxMsgSize, address exec) = abi.decode(rawExecCfg, (uint32, address));
        assertEq(maxMsgSize, 10000, "executor maxMessageSize mismatch");
        assertEq(exec, EXECUTOR, "executor address mismatch");

        // 5. Verify send ULN config
        bytes memory rawSendUln = EndpointReadLike(ENDPOINT).getConfig(GOV_SENDER, SEND_LIB, DST_EID, 2);
        _verifyUlnConfig(rawSendUln, sendUlnCfg, "govSender send ULN");

        // 6. Verify receive ULN config
        bytes memory rawRecvUln = EndpointReadLike(ENDPOINT).getConfig(GOV_SENDER, RECV_LIB, DST_EID, 2);
        _verifyUlnConfig(rawRecvUln, recvUlnCfg, "govSender recv ULN");

        // 7. Verify canCallTarget (L1GovRelay → L2GovRelay)
        assertTrue(
            GovSenderReadLike(GOV_SENDER).canCallTarget(
                L1_GOV_RELAY,
                DST_EID,
                bytes32(uint256(uint160(l2GovRelay)))
            ),
            "canCallTarget l1GovRelay -> l2GovRelay should be true"
        );
    }

    // ========================
    //  initOFTAdapter tests
    // ========================

    function test_initOFTAdapter() public {
        uint48  inboundWindow  = 1 days;
        uint256 inboundLimit   = 5_000_000e18;
        uint48  outboundWindow = 1 days;
        uint256 outboundLimit  = 5_000_000e18;
        uint128 optionsGas     = 130_000;

        vm.startPrank(GOV_OWNER);
        LZInit.initOFTAdapter(
            ENDPOINT,
            USDS_OFT,
            DST_EID,
            usdsMintBurn,
            SEND_LIB,
            RECV_LIB,
            execCfg,
            sendUlnCfg,
            recvUlnCfg,
            inboundWindow,
            inboundLimit,
            outboundWindow,
            outboundLimit,
            optionsGas
        );
        vm.stopPrank();

        _verifyOFTAdapterState(inboundWindow, inboundLimit, outboundWindow, outboundLimit, optionsGas);
    }

    function _verifyOFTAdapterState(
        uint48  inboundWindow,
        uint256 inboundLimit,
        uint48  outboundWindow,
        uint256 outboundLimit,
        uint128 optionsGas
    ) internal view {
        // 1. Verify peer
        bytes32 expectedPeer = bytes32(uint256(uint160(usdsMintBurn)));
        assertEq(OFTReadLike(USDS_OFT).peers(DST_EID), expectedPeer, "oft peer mismatch");

        // 2. Verify send library
        assertEq(
            EndpointReadLike(ENDPOINT).getSendLibrary(USDS_OFT, DST_EID),
            SEND_LIB,
            "oft send lib mismatch"
        );

        // 3. Verify receive library
        (address rl, bool isDefault) = EndpointReadLike(ENDPOINT).getReceiveLibrary(USDS_OFT, DST_EID);
        assertEq(rl, RECV_LIB, "oft recv lib mismatch");
        assertFalse(isDefault, "oft recv lib should be explicitly set");

        // 4. Verify send executor config
        bytes memory rawExecCfg = EndpointReadLike(ENDPOINT).getConfig(USDS_OFT, SEND_LIB, DST_EID, 1);
        (uint32 maxMsgSize, address exec) = abi.decode(rawExecCfg, (uint32, address));
        assertEq(maxMsgSize, 10000, "oft executor maxMessageSize mismatch");
        assertEq(exec, EXECUTOR, "oft executor address mismatch");

        // 5. Verify send ULN config
        bytes memory rawSendUln = EndpointReadLike(ENDPOINT).getConfig(USDS_OFT, SEND_LIB, DST_EID, 2);
        _verifyUlnConfig(rawSendUln, sendUlnCfg, "oft send ULN");

        // 6. Verify receive ULN config
        bytes memory rawRecvUln = EndpointReadLike(ENDPOINT).getConfig(USDS_OFT, RECV_LIB, DST_EID, 2);
        _verifyUlnConfig(rawRecvUln, recvUlnCfg, "oft recv ULN");

        // 7. Verify inbound rate limits
        (, uint48 ibWindow,, uint256 ibLimit) = OFTReadLike(USDS_OFT).inboundRateLimits(DST_EID);
        assertEq(ibWindow, inboundWindow, "inbound rate limit window mismatch");
        assertEq(ibLimit,  inboundLimit,  "inbound rate limit amount mismatch");

        // 8. Verify outbound rate limits
        (, uint48 obWindow,, uint256 obLimit) = OFTReadLike(USDS_OFT).outboundRateLimits(DST_EID);
        assertEq(obWindow, outboundWindow, "outbound rate limit window mismatch");
        assertEq(obLimit,  outboundLimit,  "outbound rate limit amount mismatch");

        // 9. Verify enforced options — SEND (msgType=1)
        bytes memory optsSend = OFTReadLike(USDS_OFT).enforcedOptions(DST_EID, 1);
        bytes memory expectedOpts = _buildLzReceiveOptions(optionsGas);
        assertEq(optsSend, expectedOpts, "enforced options SEND mismatch");

        // 10. Verify enforced options — SEND_AND_CALL (msgType=2)
        bytes memory optsSendCall = OFTReadLike(USDS_OFT).enforcedOptions(DST_EID, 2);
        assertEq(optsSendCall, expectedOpts, "enforced options SEND_AND_CALL mismatch");
    }

    // ==================================
    //  whitelistStarGovernance tests
    // ==================================

    function test_whitelistStarGovernance() public {
        vm.prank(GOV_OWNER);
        LZInit.whitelistStarGovernance(
            GOV_SENDER,
            starSubproxy,
            DST_EID,
            lzGovBridgeReceiver
        );

        assertTrue(
            GovSenderReadLike(GOV_SENDER).canCallTarget(
                starSubproxy,
                DST_EID,
                bytes32(uint256(uint160(lzGovBridgeReceiver)))
            ),
            "canCallTarget starSubproxy should be true"
        );
    }

    // ==================================
    //  whitelistSSRForwarder tests
    // ==================================

    function test_whitelistSSRForwarder() public {
        vm.prank(GOV_OWNER);
        LZInit.whitelistSSRForwarder(
            GOV_SENDER,
            ssrForwarder,
            DST_EID,
            lzGovBridgeReceiver
        );

        assertTrue(
            GovSenderReadLike(GOV_SENDER).canCallTarget(
                ssrForwarder,
                DST_EID,
                bytes32(uint256(uint160(lzGovBridgeReceiver)))
            ),
            "canCallTarget ssrForwarder should be true"
        );
    }

    // ==================================
    //  initSusdsBridge tests
    // ==================================

    function test_initSusdsBridge() public {
        // Simulate the deployer pre-configuring the USDS OFT adapter for a new EID
        // (standing in for sUSDS which isn't deployed yet). The deployer sets everything
        // except rate limits (left at 0), then transfers ownership back.
        // We use the existing USDS_OFT for this test since sUSDS adapter doesn't exist.

        uint32 testEid = 30106; // Avalanche
        bytes32 fakePeer = bytes32(uint256(uint160(makeAddr("susdsMintBurn"))));

        // Step 1: "Deployer" pre-configures (peer, libraries, configs) but leaves rate limits at 0
        vm.startPrank(GOV_OWNER);
        OFTAdapterLike(USDS_OFT).setPeer(testEid, fakePeer);
        vm.stopPrank();

        // Step 2: Verify rate limits are at 0 (bridge is "off")
        (,,, uint256 outLimit) = OFTReadLike(USDS_OFT).outboundRateLimits(testEid);
        (,,, uint256 inLimit)  = OFTReadLike(USDS_OFT).inboundRateLimits(testEid);
        assertEq(outLimit, 0);
        assertEq(inLimit, 0);

        // Step 3: Spell activates the bridge via initSusdsBridge
        uint48  inboundWindow  = 1 days;
        uint256 inboundLimit   = 2_000_000e18;
        uint48  outboundWindow = 1 days;
        uint256 outboundLimit  = 2_000_000e18;

        // Use startPrank because the library makes multiple external calls
        vm.startPrank(GOV_OWNER);
        LZInit.initSusdsBridge(
            USDS_OFT,
            ENDPOINT,
            testEid,
            fakePeer,
            GOV_OWNER,
            OFTReadLike(USDS_OFT).token(),
            0,  // expectedRlAccountingType = Net
            inboundWindow,
            inboundLimit,
            outboundWindow,
            outboundLimit
        );
        vm.stopPrank();

        // Step 4: Verify rate limits are now set (bridge is "on")
        (, uint48 ibWindow,, uint256 ibLimit) = OFTReadLike(USDS_OFT).inboundRateLimits(testEid);
        assertEq(ibWindow, inboundWindow, "inbound window mismatch");
        assertEq(ibLimit,  inboundLimit,  "inbound limit mismatch");

        (, uint48 obWindow,, uint256 obLimit) = OFTReadLike(USDS_OFT).outboundRateLimits(testEid);
        assertEq(obWindow, outboundWindow, "outbound window mismatch");
        assertEq(obLimit,  outboundLimit,  "outbound limit mismatch");
    }

    // Revert tests use an external helper because vm.expectRevert only works with
    // external calls, and LZInit functions are internal (inlined into the caller).
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

    function test_initSusdsBridge_revert_ownerMismatch() public {
        uint32 testEid = 30106;
        bytes32 fakePeer = bytes32(uint256(uint160(makeAddr("susdsMintBurn"))));
        address token = OFTReadLike(USDS_OFT).token();

        vm.prank(GOV_OWNER);
        OFTAdapterLike(USDS_OFT).setPeer(testEid, fakePeer);

        vm.expectRevert("LZInit/owner-mismatch");
        this.callInitSusdsBridge(
            USDS_OFT, ENDPOINT, testEid, fakePeer,
            address(0xdead), // wrong owner
            token, 0,
            1 days, 1e18, 1 days, 1e18
        );
    }

    function test_initSusdsBridge_revert_peerMismatch() public {
        uint32 testEid = 30106;
        bytes32 fakePeer = bytes32(uint256(uint160(makeAddr("susdsMintBurn"))));
        address token = OFTReadLike(USDS_OFT).token();

        vm.prank(GOV_OWNER);
        OFTAdapterLike(USDS_OFT).setPeer(testEid, fakePeer);

        vm.expectRevert("LZInit/peer-mismatch");
        this.callInitSusdsBridge(
            USDS_OFT, ENDPOINT, testEid,
            bytes32(uint256(1)), // wrong peer
            GOV_OWNER, token, 0,
            1 days, 1e18, 1 days, 1e18
        );
    }

    function test_initSusdsBridge_revert_rateLimitsNonzero() public {
        uint32 testEid = 30106;
        bytes32 fakePeer = bytes32(uint256(uint160(makeAddr("susdsMintBurn"))));
        address token = OFTReadLike(USDS_OFT).token();

        // Pre-configure with non-zero rate limits
        vm.startPrank(GOV_OWNER);
        OFTAdapterLike(USDS_OFT).setPeer(testEid, fakePeer);

        RateLimitConfig[] memory inCfg  = new RateLimitConfig[](1);
        RateLimitConfig[] memory outCfg = new RateLimitConfig[](1);
        inCfg[0]  = RateLimitConfig(testEid, 1 days, 1e18);
        outCfg[0] = RateLimitConfig(testEid, 1 days, 1e18);
        OFTAdapterLike(USDS_OFT).setRateLimits(inCfg, outCfg);
        vm.stopPrank();

        vm.expectRevert("LZInit/outbound-rl-nonzero");
        this.callInitSusdsBridge(
            USDS_OFT, ENDPOINT, testEid, fakePeer,
            GOV_OWNER, token, 0,
            1 days, 2e18, 1 days, 2e18
        );
    }

    // ==================================
    //  Combined spell test
    // ==================================

    function test_fullSpell() public {
        uint48  inboundWindow  = 1 days;
        uint256 inboundLimit   = 5_000_000e18;
        uint48  outboundWindow = 1 days;
        uint256 outboundLimit  = 5_000_000e18;
        uint128 optionsGas     = 130_000;

        vm.startPrank(GOV_OWNER);

        // 1. Wire governance bridge
        LZInit.initGovSender(
            ENDPOINT, GOV_SENDER, DST_EID, govOAppReceiver,
            L1_GOV_RELAY, l2GovRelay, SEND_LIB, RECV_LIB,
            execCfg, sendUlnCfg, recvUlnCfg
        );

        // 2. Wire USDS OFT adapter
        LZInit.initOFTAdapter(
            ENDPOINT, USDS_OFT, DST_EID, usdsMintBurn,
            SEND_LIB, RECV_LIB, execCfg, sendUlnCfg, recvUlnCfg,
            inboundWindow, inboundLimit, outboundWindow, outboundLimit, optionsGas
        );

        // 3. Whitelist Star governance
        LZInit.whitelistStarGovernance(GOV_SENDER, starSubproxy, DST_EID, lzGovBridgeReceiver);

        // 4. Whitelist SSR forwarder
        LZInit.whitelistSSRForwarder(GOV_SENDER, ssrForwarder, DST_EID, lzGovBridgeReceiver);

        vm.stopPrank();

        // Verify all state
        _verifyGovSenderState();
        _verifyOFTAdapterState(inboundWindow, inboundLimit, outboundWindow, outboundLimit, optionsGas);

        // Verify whitelist entries
        assertTrue(
            GovSenderReadLike(GOV_SENDER).canCallTarget(
                starSubproxy, DST_EID, bytes32(uint256(uint160(lzGovBridgeReceiver)))
            )
        );
        assertTrue(
            GovSenderReadLike(GOV_SENDER).canCallTarget(
                ssrForwarder, DST_EID, bytes32(uint256(uint160(lzGovBridgeReceiver)))
            )
        );
    }

    // ==================================
    //  Helpers
    // ==================================

    function _verifyUlnConfig(bytes memory rawUln, UlnConfig memory expected, string memory label) internal pure {
        // abi.encode(UlnConfig) wraps the struct with an offset pointer since it has dynamic fields.
        // Decode using the struct type directly to handle this correctly.
        UlnConfig memory decoded = abi.decode(rawUln, (UlnConfig));

        assertEq(decoded.confirmations,        expected.confirmations,        string.concat(label, ": confirmations"));
        assertEq(decoded.requiredDVNCount,     expected.requiredDVNCount,     string.concat(label, ": requiredDVNCount"));
        assertEq(decoded.optionalDVNCount,     expected.optionalDVNCount,     string.concat(label, ": optionalDVNCount"));
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

    /// @dev Mirrors LZInit._buildLzReceiveOptions for test verification
    function _buildLzReceiveOptions(uint128 _gas) internal pure returns (bytes memory) {
        return abi.encodePacked(
            hex"0003",
            uint8(1),
            uint16(17),
            uint8(1),
            _gas
        );
    }
}
