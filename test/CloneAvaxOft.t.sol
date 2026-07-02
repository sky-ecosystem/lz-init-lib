// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import {
    SetConfigParam,
    UlnConfig,
    ExecutorConfig,
    EnforcedOptionParam,
    RateLimitConfig,
    EndpointLike,
    UlnLike,
    OAppLike,
    OFTAdapterLike
} from "deploy/LZInit.sol";

import {
    SkyOFTAdapter,
    SkyOFTAdapterMintBurn,
    SkyOFTCore,
    ERC1967Proxy
} from "./mocks/SkyOFTAdaptersFlat.sol";
import {
    CCIPDVNCfg,
    CCIPDVNAdapter,
    CCIPDVNAdapterFeeLib,
    LZDVNInit
} from "./mocks/SendSideDeployerFlat.sol";

import {
    GovernanceOAppSender,
    GovernanceOAppReceiver,
    L1GovernanceRelay
} from "./mocks/GovBridgeFlat.sol";
import { L2GovernanceRelay } from "./mocks/L2GovernanceRelay.sol";

import { FakeChainlog, TestERC20, TestMintBurnERC20 } from "script/CloneHelpers.sol";

interface WardsLike { function wards(address) external view returns (uint256); }
interface PauserLike { function pausers(address) external view returns (bool); }
interface AccessLike {
    function hasRole(bytes32, address) external view returns (bool);
    function allowlistSize() external view returns (uint64);
}
interface CCIPAdapterAdminLike {
    function grantRole(bytes32 role, address account) external;
    function setWorkerFeeLib(address workerFeeLib) external;
    function setDefaultMultiplierBps(uint16 multiplierBps) external;
}
interface FeeLibLike {
    function initialize() external;
    function renounceOwnership() external;
}

/// @notice Fork validation for the Eth<->Avax OFT + CCIP clone (script/CloneAvaxOft.s.sol).
///         Replicates the script's deploy + wire logic in-process against a mainnet fork and an
///         avalanche fork (no broadcast, no JSON), on top of an in-process chunk-1 gov-bridge +
///         fake-token + fake-chainlog scaffold, then asserts the resulting OFT topology matches
///         the production AVAX setup + the migration's activateOft preconditions.
contract CloneAvaxOftTest is Test {

    address constant OWNER    = 0x54eAde20f7DD1A67624626A3DB9408185eD0039e;
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    uint32  constant ETH_EID  = 30101;
    uint32  constant AVAX_EID = 30106;

    address constant ETH_SEND_LIB = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    address constant ETH_RECV_LIB = 0xc02Ab410f0734EFa3F14628780e6e695156024C2;
    address constant ETH_EXECUTOR = 0x173272739Bd7Aa6e4e214714048a9fE699453059;

    address constant AVAX_SEND_LIB = 0x197D1333DEA5Fe0D6600E9b396c7f1B1cFCc558a;
    address constant AVAX_RECV_LIB = 0xbf3521d309642FA9B1c91A08609505BA09752c61;
    address constant REF_AVAX_OFT  = 0x4fec40719fD9a8AE3F8E20531669DEC5962D2619;

    uint128 constant OPTIONS_GAS   = 130_000;
    uint64  constant CONFIRMATIONS = 15;
    uint8   constant NIL_DVN_COUNT = type(uint8).max;

    // Production 4/4 required OFT DVN sets (ascending).
    address constant ETH_DVN_HORIZEN    = 0x380275805876Ff19055EA900CDb2B46a94ecF20D;
    address constant ETH_DVN_LZ_LABS    = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
    address constant ETH_DVN_CANARY     = 0xa4fE5A5B9A846458a70Cd0748228aED3bF65c2cd;
    address constant ETH_DVN_NETHERMIND = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
    address constant AVAX_DVN_HORIZEN    = 0x07C05EaB7716AcB6f83ebF6268F8EECDA8892Ba1;
    address constant AVAX_DVN_LZ_LABS    = 0x962F502A63F5FBeB44DC9ab932122648E8352959;
    address constant AVAX_DVN_NETHERMIND = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
    address constant AVAX_DVN_CANARY     = 0xcC49E6fca014c77E1Eb604351cc1E08C84511760;

    uint64  constant AVAX_CCIP_SELECTOR = 6433500567565415381;
    address constant CCIP_ROUTER         = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    uint16  constant CCIP_MULTIPLIER_BPS = 10_000;

    // Real production pause proxy — the address SendSideDeployer.handOff (which we DELIBERATELY do NOT
    // use) would have handed CCIP admin to. We deploy the adapter directly so the clone EOA is admin;
    // assert admin did NOT land here.
    address constant REAL_PAUSE_PROXY = 0xBE8E3e3618f7474F8cB1d074A26afFef007E98FB;

    uint256 constant AVAX_USDS_BACKING = 10_000e18;
    uint256 constant L1_USDS_BACKING   = 100_000e18;
    address constant AVAX_HOLDER       = 0x000000000000000000000000000000000000dEaD;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");
    bytes32 constant ALLOWLIST          = keccak256("ALLOWLIST");
    bytes32 constant MESSAGE_LIB_ROLE   = keccak256("MESSAGE_LIB_ROLE");

    uint256 ethFork;
    uint256 avaxFork;

    // chunk-1 scaffold
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

    // chunk-2 OFT + CCIP
    address l1OldUsds;
    address l1OldSusds;
    address l1NewUsds;
    address l1NewSusds;
    address ccipAdapter;

    address avaxOldUsds;
    address avaxOldSusds;
    address avaxNewUsds;
    address avaxNewSusds;

    function setUp() public {
        string memory ethUrl  = vm.envOr("MAINNET_RPC_URL",  string("https://mainnet.gateway.tenderly.co/2syedDjd1QEAB1G6W0uHdY"));
        string memory avaxUrl = vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc"));

        ethFork  = vm.createFork(ethUrl);
        avaxFork = vm.createSelectFork(avaxUrl);

        // ---- chunk 1 scaffold (in-process) ----
        vm.selectFork(ethFork);
        _scaffoldEth();
        vm.selectFork(avaxFork);
        _scaffoldAvax();

        // ---- chunk 2 deploy on BOTH chains (adapters cross-reference each other) ----
        vm.selectFork(ethFork);
        _deployEthOft();
        vm.selectFork(avaxFork);
        _deployAvaxOft();

        // ---- chunk 2 wire ----
        vm.selectFork(ethFork);
        _wireEthOft();
        vm.selectFork(avaxFork);
        _wireAvaxOft_();
    }

    // ============================================================================
    //  chunk 1 scaffold (subset of CloneAvaxBridge)
    // ============================================================================

    function _scaffoldEth() internal {
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

    function _scaffoldAvax() internal {
        vm.startPrank(OWNER);
        avaxUsds  = address(new TestMintBurnERC20("Fake USDS", "fUSDS"));
        avaxSusds = address(new TestMintBurnERC20("Fake sUSDS", "fsUSDS"));
        receiver  = address(new GovernanceOAppReceiver(ETH_EID, bytes32(uint256(uint160(sender))), ENDPOINT, OWNER));
        oldRelay  = address(new L2GovernanceRelay(ETH_EID, receiver, address(0), 0, 7 days, new address[](0)));
        newRelay  = address(new L2GovernanceRelay(ETH_EID, receiver, l1Relay, 1 days, 7 days, new address[](0)));
        vm.stopPrank();
    }

    // ============================================================================
    //  chunk 2 deploy (mirrors CloneAvaxOft._deployEth / _deployAvax)
    // ============================================================================

    function _deployEthOft() internal {
        vm.startPrank(OWNER);
        l1OldUsds  = _lockbox(ethUsds);
        l1OldSusds = _lockbox(ethSusds);
        l1NewUsds  = _lockbox(ethUsds);
        l1NewSusds = _lockbox(ethSusds);

        ccipAdapter = _deployCcip(sender);
        vm.stopPrank();
    }

    // Mirrors CloneAvaxOft._deployCcip: deploy the CCIP adapter directly so the EOA is
    // DEFAULT_ADMIN_ROLE (constructor msg.sender) + ADMIN_ROLE (admins[0]), then configure + grant
    // the send-lib / gov-sender roles. Does NOT call SendSideDeployer.handOff (which would hand
    // admin to the real chainlog pause proxy).
    function _deployCcip(address govSender) internal returns (address) {
        CCIPDVNAdapterFeeLib feeLib = new CCIPDVNAdapterFeeLib();
        FeeLibLike(address(feeLib)).initialize();
        FeeLibLike(address(feeLib)).renounceOwnership();

        address[] memory admins = new address[](1);
        admins[0] = OWNER;
        CCIPDVNAdapter adapter = new CCIPDVNAdapter(admins, CCIP_ROUTER);

        CCIPAdapterAdminLike a = CCIPAdapterAdminLike(address(adapter));
        a.setWorkerFeeLib(address(feeLib));
        a.setDefaultMultiplierBps(CCIP_MULTIPLIER_BPS);

        LZDVNInit.wireCCIPDVN(address(adapter), CCIPDVNCfg({
            remoteEid:               AVAX_EID,
            remoteCcipChainSelector: AVAX_CCIP_SELECTOR,
            remoteCcipAdapter:       address(uint160(uint256(keccak256("avaxCcipAdapter")))),
            remoteCcipBroadcaster:   address(uint160(uint256(keccak256("avaxCcipBroadcaster")))),
            sendLib:                 ETH_SEND_LIB,
            multiplierBps:           0,
            gas:                     200_000
        }));

        a.grantRole(MESSAGE_LIB_ROLE, ETH_SEND_LIB);
        a.grantRole(ALLOWLIST,        govSender);
        return address(adapter);
    }

    function _deployAvaxOft() internal {
        vm.startPrank(OWNER);
        avaxOldUsds  = _mintBurn(avaxUsds);
        avaxOldSusds = _mintBurn(avaxSusds);
        avaxNewUsds  = _mintBurn(avaxUsds);
        avaxNewSusds = _mintBurn(avaxSusds);
        vm.stopPrank();
    }

    // ============================================================================
    //  chunk 2 wire (mirrors CloneAvaxOft._wireEth / _wireAvax)
    // ============================================================================

    function _wireEthOft() internal {
        vm.startPrank(OWNER);
        _wireL1(l1OldUsds, avaxOldUsds);
        _setRL(l1OldUsds, AVAX_EID, 5_000_000e18, 0);
        TestERC20(ethUsds).mint(l1OldUsds, L1_USDS_BACKING);

        _wireL1(l1OldSusds, avaxOldSusds);
        _pauseSelf(l1OldSusds);

        _wireL1(l1NewUsds,  avaxNewUsds);
        _wireL1(l1NewSusds, avaxNewSusds);

        FakeChainlog(chainlog).setAddress("USDS_OFT",  l1OldUsds);
        FakeChainlog(chainlog).setAddress("SUSDS_OFT", l1OldSusds);
        vm.stopPrank();
    }

    function _wireAvaxOft_() internal {
        vm.startPrank(OWNER);
        _wireAvax(avaxOldUsds,  l1OldUsds);
        _wireAvax(avaxOldSusds, l1OldSusds);
        TestMintBurnERC20(avaxUsds).rely(avaxOldUsds);
        TestMintBurnERC20(avaxSusds).rely(avaxOldSusds);
        TestMintBurnERC20(avaxUsds).rely(oldRelay);
        TestMintBurnERC20(avaxSusds).rely(oldRelay);
        _pauseSelf(avaxOldUsds);
        _pauseSelf(avaxOldSusds);
        _handToRelay(avaxOldUsds,  oldRelay);
        _handToRelay(avaxOldSusds, oldRelay);

        TestMintBurnERC20(avaxUsds).mint(AVAX_HOLDER, AVAX_USDS_BACKING);

        _wireAvax(avaxNewUsds,  l1NewUsds);
        _wireAvax(avaxNewSusds, l1NewSusds);
        _handToRelay(avaxNewUsds,  oldRelay);
        _handToRelay(avaxNewSusds, oldRelay);
        vm.stopPrank();
    }

    // ---- helpers (identical shape to the script) ----

    function _lockbox(address t) internal returns (address) {
        address impl = address(new SkyOFTAdapter(t, ENDPOINT));
        return address(new ERC1967Proxy(impl, abi.encodeWithSignature("initialize(address)", OWNER)));
    }
    function _mintBurn(address t) internal returns (address) {
        address impl = address(new SkyOFTAdapterMintBurn(t, ENDPOINT));
        return address(new ERC1967Proxy(impl, abi.encodeWithSignature("initialize(address)", OWNER)));
    }

    function _wireL1(address oft, address peer) internal {
        _wireRoute(oft, AVAX_EID, ETH_SEND_LIB, ETH_RECV_LIB, ETH_EXECUTOR, _ethOftDvns(), peer);
    }
    function _wireAvax(address oft, address peer) internal {
        address exec = abi.decode(EndpointLike(ENDPOINT).getConfig(REF_AVAX_OFT, AVAX_SEND_LIB, ETH_EID, 1), (ExecutorConfig)).executor;
        _wireRoute(oft, ETH_EID, AVAX_SEND_LIB, AVAX_RECV_LIB, exec, _avaxOftDvns(), peer);
    }

    function _wireRoute(address oft, uint32 remoteEid, address sendLib, address recvLib, address executor, address[] memory dvns, address peer) internal {
        UlnConfig memory uln = UlnConfig({
            confirmations: CONFIRMATIONS, requiredDVNCount: uint8(dvns.length), optionalDVNCount: NIL_DVN_COUNT,
            optionalDVNThreshold: 0, requiredDVNs: dvns, optionalDVNs: new address[](0)
        });
        EndpointLike(ENDPOINT).setSendLibrary(oft, remoteEid, sendLib);
        EndpointLike(ENDPOINT).setReceiveLibrary(oft, remoteEid, recvLib, 0);
        SetConfigParam[] memory sendParams = new SetConfigParam[](2);
        sendParams[0] = SetConfigParam(remoteEid, 1, abi.encode(ExecutorConfig({maxMessageSize: 10000, executor: executor})));
        sendParams[1] = SetConfigParam(remoteEid, 2, abi.encode(uln));
        EndpointLike(ENDPOINT).setConfig(oft, sendLib, sendParams);
        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam(remoteEid, 2, abi.encode(uln));
        EndpointLike(ENDPOINT).setConfig(oft, recvLib, recvParams);
        EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](2);
        opts[0] = EnforcedOptionParam(remoteEid, 1, _encodeOpts(OPTIONS_GAS));
        opts[1] = EnforcedOptionParam(remoteEid, 2, _encodeOpts(OPTIONS_GAS));
        OFTAdapterLike(oft).setEnforcedOptions(opts);
        OFTAdapterLike(oft).setPeer(remoteEid, bytes32(uint256(uint160(peer))));
    }

    function _setRL(address oft, uint32 eid, uint256 inLimit, uint256 outLimit) internal {
        RateLimitConfig[] memory inb = new RateLimitConfig[](1);
        RateLimitConfig[] memory out = new RateLimitConfig[](1);
        inb[0] = RateLimitConfig({eid: eid, window: 1 days, limit: inLimit});
        out[0] = RateLimitConfig({eid: eid, window: 1 days, limit: outLimit});
        OFTAdapterLike(oft).setRateLimits(inb, out);
    }
    function _pauseSelf(address oft) internal {
        SkyOFTCore(oft).setPauser(OWNER, true);
        SkyOFTCore(oft).pause();
    }
    function _handToRelay(address oft, address relay) internal {
        SkyOFTCore(oft).setDelegate(relay);
        SkyOFTCore(oft).transferOwnership(relay);
    }

    function _ethOftDvns() internal pure returns (address[] memory d) { d = new address[](4); (d[0], d[1], d[2], d[3]) = (ETH_DVN_HORIZEN, ETH_DVN_LZ_LABS, ETH_DVN_CANARY, ETH_DVN_NETHERMIND); }
    function _avaxOftDvns() internal pure returns (address[] memory d) { d = new address[](4); (d[0], d[1], d[2], d[3]) = (AVAX_DVN_HORIZEN, AVAX_DVN_LZ_LABS, AVAX_DVN_NETHERMIND, AVAX_DVN_CANARY); }
    function _encodeOpts(uint128 gas) internal pure returns (bytes memory) { return abi.encodePacked(hex"0003", uint8(1), uint16(17), uint8(1), gas); }

    function _outLimit(address oft, uint32 eid) internal view returns (uint256 l) { (,,, l) = OFTAdapterLike(oft).outboundRateLimits(eid); }
    function _inLimit(address oft, uint32 eid)  internal view returns (uint256 l) { (,,, l) = OFTAdapterLike(oft).inboundRateLimits(eid); }

    // ============================================================================
    //  Assertions
    // ============================================================================

    function test_l1_old_usds_lockbox() public {
        vm.selectFork(ethFork);
        assertEq(OFTAdapterLike(l1OldUsds).owner(), OWNER, "old usds owner");
        assertEq(EndpointLike(ENDPOINT).delegates(l1OldUsds), OWNER, "old usds delegate");
        assertEq(OFTAdapterLike(l1OldUsds).token(), ethUsds, "old usds token");
        assertFalse(OFTAdapterLike(l1OldUsds).paused(), "old usds not paused");
        assertEq(OFTAdapterLike(l1OldUsds).peers(AVAX_EID), bytes32(uint256(uint160(avaxOldUsds))), "old usds peer");
        assertEq(_inLimit(l1OldUsds, AVAX_EID), 5_000_000e18, "old usds inbound big");
        assertEq(_outLimit(l1OldUsds, AVAX_EID), 0, "old usds outbound frozen");
        // backing seeded, and it exceeds the avax frozen supply (so migrateLockedTokens math holds)
        assertEq(TestERC20(ethUsds).balanceOf(l1OldUsds), L1_USDS_BACKING, "old usds backing");
        assertTrue(L1_USDS_BACKING > AVAX_USDS_BACKING, "backing > avax frozen");
        _assertUln(l1OldUsds, AVAX_EID, ETH_SEND_LIB, ETH_RECV_LIB, _ethOftDvns());
    }

    function test_l1_old_susds_lockbox() public {
        vm.selectFork(ethFork);
        assertEq(OFTAdapterLike(l1OldSusds).owner(), OWNER, "old susds owner");
        assertEq(OFTAdapterLike(l1OldSusds).token(), ethSusds, "old susds token");
        assertTrue(OFTAdapterLike(l1OldSusds).paused(), "old susds PAUSED");
        assertEq(OFTAdapterLike(l1OldSusds).peers(AVAX_EID), bytes32(uint256(uint160(avaxOldSusds))), "old susds peer");
        assertEq(_inLimit(l1OldSusds, AVAX_EID), 0, "old susds inbound 0");
        assertEq(_outLimit(l1OldSusds, AVAX_EID), 0, "old susds outbound 0");
        assertEq(TestERC20(ethSusds).balanceOf(l1OldSusds), 0, "old susds no backing");
    }

    function test_l1_new_lockboxes_preactivation() public {
        vm.selectFork(ethFork);
        address[2] memory news = [l1NewUsds, l1NewSusds];
        address[2] memory peers = [avaxNewUsds, avaxNewSusds];
        for (uint256 i; i < 2; ++i) {
            address n = news[i];
            assertEq(OFTAdapterLike(n).owner(), OWNER, "new owner=EOA");
            assertEq(EndpointLike(ENDPOINT).delegates(n), OWNER, "new delegate=EOA");
            assertFalse(OFTAdapterLike(n).paused(), "new NOT paused");
            assertEq(OFTAdapterLike(n).peers(AVAX_EID), bytes32(uint256(uint160(peers[i]))), "new peer");
            // pre-activation: rate limits must be 0 per _verifyOftConfig
            assertEq(_inLimit(n, AVAX_EID), 0, "new inbound 0");
            assertEq(_outLimit(n, AVAX_EID), 0, "new outbound 0");
            // fee=0 + msgInspector=0 (fresh proxy defaults required by _verifyOftConfig)
            (uint16 feeBps, bool feeEnabled) = OFTAdapterLike(n).feeBps(AVAX_EID);
            assertEq(OFTAdapterLike(n).defaultFeeBps(), 0, "default fee 0");
            assertEq(feeBps, 0, "fee 0"); assertFalse(feeEnabled, "fee disabled");
            assertEq(OFTAdapterLike(n).msgInspector(), address(0), "no msg inspector");
            assertEq(uint8(OFTAdapterLike(n).rateLimitAccountingType()), 0, "rl accounting 0");
        }
    }

    function test_avax_old_adapters() public {
        vm.selectFork(avaxFork);
        assertEq(OFTAdapterLike(avaxOldUsds).owner(), oldRelay, "avax old usds owner=old relay");
        assertEq(EndpointLike(ENDPOINT).delegates(avaxOldUsds), oldRelay, "avax old usds delegate=old relay");
        assertEq(OFTAdapterLike(avaxOldUsds).token(), avaxUsds, "avax old usds token");
        assertTrue(OFTAdapterLike(avaxOldUsds).paused(), "avax old usds PAUSED");
        assertTrue(OFTAdapterLike(avaxOldSusds).paused(), "avax old susds PAUSED");
        assertEq(OFTAdapterLike(avaxOldUsds).peers(ETH_EID), bytes32(uint256(uint160(l1OldUsds))), "avax old usds peer");

        // token wards: old adapters + old relay relied
        assertEq(WardsLike(avaxUsds).wards(avaxOldUsds), 1, "avax usds ward old adapter");
        assertEq(WardsLike(avaxSusds).wards(avaxOldSusds), 1, "avax susds ward old adapter");
        assertEq(WardsLike(avaxUsds).wards(oldRelay), 1, "avax usds ward old relay");
        assertEq(WardsLike(avaxSusds).wards(oldRelay), 1, "avax susds ward old relay");

        // frozen avax USDS supply minted; sUSDS supply 0
        assertEq(TestMintBurnERC20(avaxUsds).balanceOf(AVAX_HOLDER), AVAX_USDS_BACKING, "frozen avax usds supply");
        assertEq(TestMintBurnERC20(avaxSusds).totalSupply(), 0, "avax susds supply 0");
        _assertUln(avaxOldUsds, ETH_EID, AVAX_SEND_LIB, AVAX_RECV_LIB, _avaxOftDvns());
    }

    function test_avax_new_adapters_preactivation() public {
        vm.selectFork(avaxFork);
        address[2] memory news = [avaxNewUsds, avaxNewSusds];
        address[2] memory peers = [l1NewUsds, l1NewSusds];
        for (uint256 i; i < 2; ++i) {
            address n = news[i];
            // owner+delegate = OLD relay (activateOft on L2 requires owner==delegate==msg.sender==OLD relay)
            assertEq(OFTAdapterLike(n).owner(), oldRelay, "avax new owner=old relay");
            assertEq(EndpointLike(ENDPOINT).delegates(n), oldRelay, "avax new delegate=old relay");
            assertFalse(OFTAdapterLike(n).paused(), "avax new NOT paused");
            assertEq(OFTAdapterLike(n).peers(ETH_EID), bytes32(uint256(uint160(peers[i]))), "avax new peer");
            assertEq(_inLimit(n, ETH_EID), 0, "avax new inbound 0");
            assertEq(_outLimit(n, ETH_EID), 0, "avax new outbound 0");
        }
        // NEW adapters NOT yet token wards (the migration relies them)
        assertEq(WardsLike(avaxUsds).wards(avaxNewUsds), 0, "avax new usds NOT ward yet");
        assertEq(WardsLike(avaxSusds).wards(avaxNewSusds), 0, "avax new susds NOT ward yet");
    }

    function test_chainlog_oft_keys() public {
        vm.selectFork(ethFork);
        assertEq(FakeChainlog(chainlog).getAddress("USDS_OFT"),  l1OldUsds,  "chainlog USDS_OFT");
        assertEq(FakeChainlog(chainlog).getAddress("SUSDS_OFT"), l1OldSusds, "chainlog SUSDS_OFT");
    }

    /// @notice The four migration CCIP sanity conditions (LZAvaxMigrationInit / CloneInit), now all
    ///         satisfied against the clone EOA (== the clone chainlog's MCD_PAUSE_PROXY = pProxy):
    ///           1. hasRole(MESSAGE_LIB_ROLE, sendLib)      == true
    ///           2. hasRole(ALLOWLIST, govSender)           == true
    ///           3. allowlistSize()                         == 1
    ///           4. hasRole(DEFAULT_ADMIN_ROLE, EOA)        == true   <- previously landed on the real
    ///                                                                   pause proxy via handOff.
    ///
    ///         BACKGROUND: SendSideDeployer.handOff() reads MCD_PAUSE_PROXY off the REAL hardcoded
    ///         chainlog and would grant admin to the real pause proxy (REAL_PAUSE_PROXY), not this
    ///         clone's EOA. We therefore deploy the CCIP adapter directly (EOA = constructor
    ///         msg.sender => DEFAULT_ADMIN_ROLE, EOA in admins => ADMIN_ROLE) and configure/grant as
    ///         the EOA, reproducing handOff's END-STATE but targeting the clone pause proxy. We also
    ///         confirm the EOA is the SOLE DEFAULT_ADMIN_ROLE holder (single-admin, like production).
    function test_ccip_precondition() public {
        vm.selectFork(ethFork);
        AccessLike ccip = AccessLike(ccipAdapter);
        // 1-3
        assertTrue(ccip.hasRole(MESSAGE_LIB_ROLE, ETH_SEND_LIB), "ccip: sendLib MESSAGE_LIB_ROLE");
        assertTrue(ccip.hasRole(ALLOWLIST, sender),              "ccip: gov sender allowlisted");
        assertEq(ccip.allowlistSize(), 1,                        "ccip: allowlist size 1");
        // 4: admin now the clone EOA (== pProxy the migration reads from the clone chainlog)
        assertTrue(ccip.hasRole(DEFAULT_ADMIN_ROLE, OWNER),      "ccip: admin -> clone EOA (pProxy)");
        assertTrue(ccip.hasRole(ADMIN_ROLE, OWNER),             "ccip: EOA has ADMIN_ROLE");
        // single-admin: neither the real pause proxy nor the adapter itself hold admin
        assertFalse(ccip.hasRole(DEFAULT_ADMIN_ROLE, REAL_PAUSE_PROXY), "ccip: real pause proxy NOT admin");
        assertFalse(ccip.hasRole(DEFAULT_ADMIN_ROLE, ccipAdapter),      "ccip: adapter self NOT admin");
        // gov sender is the ONLY allowlisted OApp
        assertFalse(ccip.hasRole(ALLOWLIST, OWNER), "ccip: EOA not allowlisted");
    }

    function _assertUln(address oapp, uint32 eid, address sendLib, address recvLib, address[] memory dvns) internal {
        (address rl,) = EndpointLike(ENDPOINT).getReceiveLibrary(oapp, eid);
        assertEq(EndpointLike(ENDPOINT).getSendLibrary(oapp, eid), sendLib, "send lib");
        assertEq(rl, recvLib, "recv lib");
        UlnConfig memory u = UlnLike(sendLib).getAppUlnConfig(oapp, eid);
        assertEq(u.requiredDVNCount, dvns.length, "required dvn count");
        assertEq(u.confirmations, CONFIRMATIONS, "confirmations");
        for (uint256 i; i < dvns.length; ++i) assertEq(u.requiredDVNs[i], dvns[i], "required dvn");
    }
}
