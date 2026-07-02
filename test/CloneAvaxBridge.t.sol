// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import {
    SetConfigParam,
    UlnConfig,
    ExecutorConfig,
    EnforcedOptionParam,
    EndpointLike,
    UlnLike,
    OAppLike
} from "deploy/LZInit.sol";

import {
    GovernanceOAppSender,
    GovernanceOAppReceiver,
    L1GovernanceRelay
} from "./mocks/GovBridgeFlat.sol";
import { L2GovernanceRelay } from "./mocks/L2GovernanceRelay.sol";

import { FakeChainlog, TestERC20, TestMintBurnERC20 } from "script/CloneHelpers.sol";

interface GovSenderLike {
    function setPeer(uint32 eid, bytes32 peer) external;
    function peers(uint32 eid) external view returns (bytes32);
    function endpoint() external view returns (address);
    function owner() external view returns (address);
    function setCanCallTarget(address srcSender, uint32 dstEid, bytes32 dstTarget, bool canCall) external;
    function canCallTarget(address srcSender, uint32 dstEid, bytes32 dstTarget) external view returns (bool);
    function setEnforcedOptions(EnforcedOptionParam[] calldata opts) external;
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
}
interface GovReceiverLike {
    function peers(uint32 eid) external view returns (bytes32);
    function endpoint() external view returns (address);
    function owner() external view returns (address);
    function setDelegate(address delegate) external;
    function transferOwnership(address newOwner) external;
}
interface WardsLike { function wards(address) external view returns (uint256); }
interface RelayViewLike {
    function l1Eid() external view returns (uint32);
    function l2Oapp() external view returns (address);
    function l1GovernanceRelay() external view returns (address);
    function delay() external view returns (uint256);
    function gracePeriod() external view returns (uint256);
}

/// @notice Fork validation for the Eth<->Avax gov-bridge clone (script/CloneAvaxBridge.s.sol).
///         Replicates the script's deploy + wire logic in-process against a mainnet fork and an
///         avalanche fork (no broadcast, no JSON), then asserts the resulting topology matches
///         what a real run would produce.
contract CloneAvaxBridgeTest is Test {

    address constant OWNER    = 0x54eAde20f7DD1A67624626A3DB9408185eD0039e;
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    uint32  constant ETH_EID  = 30101;
    uint32  constant AVAX_EID = 30106;

    address constant ETH_SEND_LIB  = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    address constant ETH_EXECUTOR  = 0x173272739Bd7Aa6e4e214714048a9fE699453059;
    address constant AVAX_RECV_LIB = 0xbf3521d309642FA9B1c91A08609505BA09752c61;

    uint64  constant CONFIRMATIONS = 15;
    uint8   constant NIL_DVN_COUNT = type(uint8).max;
    uint128 constant LZRECEIVE_GAS = 130_000;
    uint16  constant MSG_TYPE_SEND = 1;

    uint256 ethFork;
    uint256 avaxFork;

    // deployed addresses
    address chainlog;
    address ethUsds;
    address ethSusds;
    address sender;
    address l1Relay;

    address avaxUsds;
    address avaxSusds;
    address receiver;
    address oldRelay;
    address newRelay;

    function setUp() public {
        string memory ethUrl  = vm.envOr("MAINNET_RPC_URL",  string("https://mainnet.gateway.tenderly.co/2syedDjd1QEAB1G6W0uHdY"));
        string memory avaxUrl = vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc"));

        ethFork  = vm.createFork(ethUrl);
        avaxFork = vm.createSelectFork(avaxUrl);

        // ---- AVAX side deploy (needs sender addr for the receiver peer; we deploy sender on
        //      the eth fork first, but the receiver only needs the sender ADDRESS, so we deploy
        //      the eth pieces first, capture `sender`, then build avax) ----
        vm.selectFork(ethFork);
        _deployEth();

        vm.selectFork(avaxFork);
        _deployAvax();

        // ---- wire both sides now that cross addresses are known ----
        vm.selectFork(ethFork);
        _wireEth();

        vm.selectFork(avaxFork);
        _wireAvax();
    }

    // ============================================================================
    //  Deploy (mirrors CloneAvaxBridge._deployEth / _deployAvax)
    // ============================================================================

    function _deployEth() internal {
        vm.startPrank(OWNER);
        chainlog = address(new FakeChainlog());
        ethUsds  = address(new TestERC20("Fake USDS", "fUSDS"));
        ethSusds = address(new TestERC20("Fake sUSDS", "fsUSDS"));
        sender   = address(new GovernanceOAppSender(ENDPOINT, OWNER));
        L1GovernanceRelay relay = new L1GovernanceRelay();
        relay.file("l1Oapp", sender);
        l1Relay = address(relay);

        FakeChainlog(chainlog).setAddress("MCD_PAUSE_PROXY", OWNER);
        FakeChainlog(chainlog).setAddress("LZ_GOV_SENDER",   sender);
        FakeChainlog(chainlog).setAddress("LZ_GOV_RELAY",    l1Relay);
        FakeChainlog(chainlog).setAddress("USDS",            ethUsds);
        FakeChainlog(chainlog).setAddress("SUSDS",           ethSusds);
        vm.stopPrank();
    }

    function _deployAvax() internal {
        vm.startPrank(OWNER);
        avaxUsds  = address(new TestMintBurnERC20("Fake USDS", "fUSDS"));
        avaxSusds = address(new TestMintBurnERC20("Fake sUSDS", "fsUSDS"));
        receiver  = address(new GovernanceOAppReceiver(
            ETH_EID, bytes32(uint256(uint160(sender))), ENDPOINT, OWNER
        ));
        oldRelay = address(new L2GovernanceRelay(ETH_EID, receiver, address(0), 0, 7 days, new address[](0)));
        newRelay = address(new L2GovernanceRelay(ETH_EID, receiver, l1Relay, 1 days, 7 days, new address[](0)));
        vm.stopPrank();
    }

    // ============================================================================
    //  Wire (mirrors CloneAvaxBridge._wireEth / _wireAvax)
    // ============================================================================

    function _wireEth() internal {
        vm.startPrank(OWNER);
        GovSenderLike(sender).setPeer(AVAX_EID, bytes32(uint256(uint160(receiver))));
        EndpointLike(ENDPOINT).setSendLibrary(sender, AVAX_EID, ETH_SEND_LIB);

        SetConfigParam[] memory sendParams = new SetConfigParam[](2);
        sendParams[0] = SetConfigParam(AVAX_EID, 1, abi.encode(ExecutorConfig({maxMessageSize: 10000, executor: ETH_EXECUTOR})));
        sendParams[1] = SetConfigParam(AVAX_EID, 2, abi.encode(_ethSendUlnCfg()));
        EndpointLike(ENDPOINT).setConfig(sender, ETH_SEND_LIB, sendParams);

        EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](1);
        opts[0] = EnforcedOptionParam(AVAX_EID, MSG_TYPE_SEND, _encodeOpts(LZRECEIVE_GAS));
        GovSenderLike(sender).setEnforcedOptions(opts);

        GovSenderLike(sender).setCanCallTarget(l1Relay, AVAX_EID, bytes32(uint256(uint160(newRelay))), true);
        vm.stopPrank();
    }

    function _wireAvax() internal {
        vm.startPrank(OWNER);
        EndpointLike(ENDPOINT).setReceiveLibrary(receiver, ETH_EID, AVAX_RECV_LIB, 0);
        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam(ETH_EID, 2, abi.encode(_avaxRecvUlnCfg()));
        EndpointLike(ENDPOINT).setConfig(receiver, AVAX_RECV_LIB, recvParams);

        GovReceiverLike(receiver).setDelegate(oldRelay);
        GovReceiverLike(receiver).transferOwnership(oldRelay);
        vm.stopPrank();
    }

    function _ethSendUlnCfg() internal pure returns (UlnConfig memory) {
        address[] memory dvns = new address[](7);
        dvns[0] = 0x06559EE34D85a88317Bf0bfE307444116c631b67;
        dvns[1] = 0x373a6E5c0C4E89E24819f00AA37ea370917AAfF4;
        dvns[2] = 0x380275805876Ff19055EA900CDb2B46a94ecF20D;
        dvns[3] = 0x58249a2Ec05c1978bF21DF1f5eC1847e42455CF4;
        dvns[4] = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
        dvns[5] = 0xa4fE5A5B9A846458a70Cd0748228aED3bF65c2cd;
        dvns[6] = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
        return UlnConfig({confirmations: CONFIRMATIONS, requiredDVNCount: NIL_DVN_COUNT, optionalDVNCount: 7,
            optionalDVNThreshold: 4, requiredDVNs: new address[](0), optionalDVNs: dvns});
    }
    function _avaxRecvUlnCfg() internal pure returns (UlnConfig memory) {
        address[] memory dvns = new address[](7);
        dvns[0] = 0x07C05EaB7716AcB6f83ebF6268F8EECDA8892Ba1;
        dvns[1] = 0x962F502A63F5FBeB44DC9ab932122648E8352959;
        dvns[2] = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
        dvns[3] = 0xbe57e9E7d9eB16B92C6383792aBe28D64a18c0F1;
        dvns[4] = 0xcC49E6fca014c77E1Eb604351cc1E08C84511760;
        dvns[5] = 0xE4193136B92bA91402313e95347c8e9FAD8d27d0;
        dvns[6] = 0xE94aE34DfCC87A61836938641444080B98402c75;
        return UlnConfig({confirmations: CONFIRMATIONS, requiredDVNCount: NIL_DVN_COUNT, optionalDVNCount: 7,
            optionalDVNThreshold: 4, requiredDVNs: new address[](0), optionalDVNs: dvns});
    }
    function _encodeOpts(uint128 gas) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"0003", uint8(1), uint16(17), uint8(1), gas);
    }

    // ============================================================================
    //  Assertions
    // ============================================================================

    function test_eth_side() public {
        vm.selectFork(ethFork);

        // deployed & owned
        assertTrue(sender != address(0) && l1Relay != address(0), "eth deployed");
        assertEq(GovSenderLike(sender).owner(), OWNER, "sender owner");
        assertEq(GovSenderLike(sender).endpoint(), ENDPOINT, "sender endpoint");
        assertEq(WardsLike(l1Relay).wards(OWNER), 1, "l1relay ward owner");

        // l1 relay points at sender
        assertEq(address(GovBridgeSenderRef(l1Relay).l1Oapp()), sender, "l1Oapp");

        // peer wired to avax receiver
        assertEq(GovSenderLike(sender).peers(AVAX_EID), bytes32(uint256(uint160(receiver))), "send peer");

        // send lib + configs
        assertEq(EndpointLike(ENDPOINT).getSendLibrary(sender, AVAX_EID), ETH_SEND_LIB, "send lib");
        assertFalse(EndpointLike(ENDPOINT).isDefaultSendLibrary(sender, AVAX_EID), "send lib not default");

        ExecutorConfig memory ex = abi.decode(
            EndpointLike(ENDPOINT).getConfig(sender, ETH_SEND_LIB, AVAX_EID, 1), (ExecutorConfig)
        );
        assertEq(ex.executor, ETH_EXECUTOR, "executor");
        assertEq(ex.maxMessageSize, 10000, "maxMsgSize");

        UlnConfig memory uln = UlnLike(ETH_SEND_LIB).getAppUlnConfig(sender, AVAX_EID);
        assertEq(keccak256(abi.encode(uln)), keccak256(abi.encode(_ethSendUlnCfg())), "send uln");
        assertEq(uln.confirmations, CONFIRMATIONS, "send conf");
        assertEq(uln.optionalDVNCount, 7, "send optional dvns");
        assertEq(uln.optionalDVNThreshold, 4, "send optional threshold");

        // enforced option
        assertEq(
            keccak256(GovSenderLike(sender).enforcedOptions(AVAX_EID, MSG_TYPE_SEND)),
            keccak256(_encodeOpts(LZRECEIVE_GAS)),
            "enforced opt"
        );

        // relay whitelist swapped to NEW relay
        assertTrue(GovSenderLike(sender).canCallTarget(l1Relay, AVAX_EID, bytes32(uint256(uint160(newRelay)))), "canCall new");

        // fake chainlog reads back seeded values
        assertEq(FakeChainlog(chainlog).getAddress("LZ_GOV_SENDER"), sender,   "cl sender");
        assertEq(FakeChainlog(chainlog).getAddress("LZ_GOV_RELAY"),  l1Relay,  "cl relay");
        assertEq(FakeChainlog(chainlog).getAddress("USDS"),          ethUsds,  "cl usds");
        assertEq(FakeChainlog(chainlog).getAddress("SUSDS"),         ethSusds, "cl susds");
        assertEq(FakeChainlog(chainlog).getAddress("MCD_PAUSE_PROXY"), OWNER,  "cl pause");

        // fake L1 tokens are mintable plain ERC20s
        vm.prank(OWNER);
        TestERC20(ethUsds).mint(OWNER, 1e18);
        assertEq(TestERC20(ethUsds).balanceOf(OWNER), 1e18, "usds mint");
    }

    function test_avax_side() public {
        vm.selectFork(avaxFork);

        assertTrue(receiver != address(0) && oldRelay != address(0) && newRelay != address(0), "avax deployed");

        // receiver seeded with sender peer for ETH_EID
        assertEq(GovReceiverLike(receiver).peers(ETH_EID), bytes32(uint256(uint160(sender))), "recv peer");
        assertEq(GovReceiverLike(receiver).endpoint(), ENDPOINT, "recv endpoint");

        // recv lib + uln
        (address recvLib, bool isDefault) = EndpointLike(ENDPOINT).getReceiveLibrary(receiver, ETH_EID);
        assertEq(recvLib, AVAX_RECV_LIB, "recv lib");
        assertFalse(isDefault, "recv lib not default");

        UlnConfig memory uln = UlnLike(AVAX_RECV_LIB).getAppUlnConfig(receiver, ETH_EID);
        assertEq(keccak256(abi.encode(uln)), keccak256(abi.encode(_avaxRecvUlnCfg())), "recv uln");
        assertEq(uln.confirmations, CONFIRMATIONS, "recv conf");
        assertEq(uln.optionalDVNCount, 7, "recv optional dvns");
        assertEq(uln.optionalDVNThreshold, 4, "recv optional threshold");

        // receiver owned + delegated by the OLD relay
        assertEq(GovReceiverLike(receiver).owner(), oldRelay, "recv owner = old relay");
        assertEq(EndpointLike(ENDPOINT).delegates(receiver), oldRelay, "recv delegate = old relay");

        // relay wiring
        assertEq(RelayViewLike(oldRelay).l1Eid(), ETH_EID, "old relay eid");
        assertEq(RelayViewLike(oldRelay).l2Oapp(), receiver, "old relay oapp");
        assertEq(RelayViewLike(newRelay).l1Eid(), ETH_EID, "new relay eid");
        assertEq(RelayViewLike(newRelay).l2Oapp(), receiver, "new relay oapp");
        assertEq(RelayViewLike(newRelay).l1GovernanceRelay(), l1Relay, "new relay l1 counterpart");
        assertEq(RelayViewLike(newRelay).delay(), 1 days, "new relay delay");

        // avax tokens are ward-gated mint/burn
        vm.prank(OWNER);
        TestMintBurnERC20(avaxUsds).mint(OWNER, 1e18);
        assertEq(TestMintBurnERC20(avaxUsds).balanceOf(OWNER), 1e18, "avax usds mint");
        assertEq(WardsLike(avaxUsds).wards(OWNER), 1, "avax usds ward");
        vm.prank(address(0xBEEF));
        vm.expectRevert("TestMintBurn/not-authed");
        TestMintBurnERC20(avaxUsds).mint(address(0xBEEF), 1e18);
    }
}

interface GovBridgeSenderRef { function l1Oapp() external view returns (address); }
