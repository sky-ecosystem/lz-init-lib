// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { OptionsBuilder } from "layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import {
    LZInit,
    UlnConfig,
    ExecutorConfig,
    OftConfig,
    RateLimits,
    RateLimitConfig,
    EndpointLike,
    UlnLike,
    OAppLike,
    OFTAdapterLike
} from "deploy/LZInit.sol";
import {
    LZAvaxMigrationInit,
    AvaxMigration,
    OftActivation
} from "deploy/LZAvaxMigrationInit.sol";
import { LZAvaxMigrationL2Spell } from "deploy/LZAvaxMigrationL2Spell.sol";

import { Bridge }                from "xchain-helpers/testing/Bridge.sol";
import { Domain, DomainHelpers } from "xchain-helpers/testing/Domain.sol";
import { LZBridgeTesting }       from "xchain-helpers/testing/bridges/LZBridgeTesting.sol";

interface ChainlogReadLike { function getAddress(bytes32) external view returns (address); }
interface ChainlogSetLike  { function setAddress(bytes32, address) external; }
interface WardsLike        { function wards(address) external view returns (uint256); }
interface TokenLike        { function balanceOf(address) external view returns (uint256); }
interface GovSenderLike    { function canCallTarget(address, uint32, bytes32) external view returns (bool); }
interface OwnableLike      { function owner() external view returns (address); }

// L1 CCIP DVN adapter stand-in: the migration only reads roles off it (hasRole).
contract MockCCIPDVNAdapter {
    mapping(bytes32 => mapping(address => bool)) public hasRole;
    uint64 public allowlistSize;
    function grant(bytes32 role, address account) external {
        if (hasRole[role][account]) return;
        hasRole[role][account] = true;
        if (role == keccak256("ALLOWLIST")) allowlistSize++;
    }
}

// OFT V2 adapter mock: also its own endpoint + libraries, self-reporting a config that
// satisfies `_verifyOftConfig` so activation can be exercised without the real V2 contract.
contract MockV2Adapter {
    uint32 public constant SENTINEL_EID = type(uint32).max;

    address public owner;
    address public delegate;
    address public token;
    bytes32 public peer;
    ExecutorConfig public execCfg;
    UlnConfig public uln;
    bytes public enforcedOpts;

    mapping(uint32 eid => uint256) public recordedInbound;
    mapping(uint32 eid => uint256) public recordedOutbound;

    constructor(address _owner, address _token) { owner = _owner; delegate = _owner; token = _token; }

    function configure(bytes32 _peer, ExecutorConfig memory _exec, UlnConfig memory _uln, bytes memory _opts) external {
        peer = _peer; execCfg = _exec; uln = _uln; enforcedOpts = _opts;
    }

    function setDelegate(address d) external { delegate = d; }
    function transferOwnership(address o) external { owner = o; }

    function endpoint() external view returns (address) { return address(this); }
    function peers(uint32) external view returns (bytes32) { return peer; }
    function paused() external pure returns (bool) { return false; }
    function rateLimitAccountingType() external pure returns (uint8) { return 0; }
    function msgInspector() external pure returns (address) { return address(0); }
    function defaultFeeBps() external pure returns (uint16) { return 0; }
    function feeBps(uint32) external pure returns (uint16, bool) { return (0, false); }
    function enforcedOptions(uint32, uint16) external view returns (bytes memory) { return enforcedOpts; }

    function outboundRateLimits(uint32) external pure returns (uint128, uint48, uint256, uint256) {
        return (0, 0, 0, 0);
    }
    function inboundRateLimits(uint32) external pure returns (uint128, uint48, uint256, uint256) {
        return (0, 0, 0, 0);
    }

    function delegates(address) external view returns (address) { return delegate; }
    function getSendLibrary(address, uint32) external view returns (address) { return address(this); }
    function isDefaultSendLibrary(address, uint32) external pure returns (bool) { return false; }
    function getReceiveLibrary(address, uint32) external view returns (address, bool) { return (address(this), false); }
    function receiveLibraryTimeout(address, uint32) external pure returns (address) { return address(0); }
    function getConfig(address, address, uint32, uint32 configType) external view returns (bytes memory) {
        if (configType == 1) return abi.encode(execCfg);
        return abi.encode(uln);
    }
    function getAppUlnConfig(address, uint32) external view returns (UlnConfig memory) { return uln; }

    function setRateLimits(RateLimitConfig[] calldata inbound, RateLimitConfig[] calldata outbound) external {
        recordedInbound[inbound[0].eid]   = inbound[0].limit;
        recordedOutbound[outbound[0].eid] = outbound[0].limit;
    }
}

// Hybrid fork test: real mainnet + Avalanche forks and the real LZ relay, with real gov bridge /
// tokens / old adapters; the new adapters are mocked (the audited V2 contract isn't a dep here).
contract LZAvaxMigrationInitTest is Test {

    using DomainHelpers   for *;
    using LZBridgeTesting for *;
    using OptionsBuilder  for bytes;

    ChainlogReadLike constant chainlog = ChainlogReadLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    uint32 constant ETH_EID  = 30101;
    uint32 constant AVAX_EID = 30106;

    // Real Avalanche deployment (current setup).
    address constant AVAX_ENDPOINT       = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant AVAX_L2_GOV_RELAY   = 0xe928885BCe799Ed933651715608155F01abA23cA; // old relay
    address constant AVAX_GOV_RECEIVER   = 0x6fdd46947ca6903c8c159d1dF2012Bc7fC5cEeec;
    address constant AVAX_USDS           = 0x86Ff09db814ac346a7C6FE2Cd648F27706D1D470;
    address constant AVAX_SUSDS          = 0xb94D9613C7aAB11E548a327154Cc80eCa911B5c1;
    address constant AVAX_OLD_USDS_OFT   = 0x4fec40719fD9a8AE3F8E20531669DEC5962D2619;
    address constant AVAX_OLD_SUSDS_OFT  = 0x7297D4811f088FC26bC5475681405B99b41E1FF9;
    address constant OLD_L1_USDS_OFT     = 0x1e1D42781FC170EF9da004Fb735f56F0276d01B8; // V1 L1 USDS lockbox
    address constant AVAX_DVN_LZ_LABS    = 0x962F502A63F5FBeB44DC9ab932122648E8352959;
    address constant AVAX_DVN_NETHERMIND = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;

    address PAUSE_PROXY;
    address GOV_SENDER;
    address GOV_RELAY;

    Domain    mainnet;
    Bridge    bridge;
    LZAvaxMigrationL2Spell l2Spell;

    address newRelay = makeAddr("newRelay");
    // New Avalanche remote OFTs (owned by the old relay until the spell hands them over).
    OftActivation avaxUsds;
    OftActivation avaxSusds;

    function setUp() public {
        mainnet     = getChain("mainnet").createSelectFork(25337000);
        PAUSE_PROXY = chainlog.getAddress("MCD_PAUSE_PROXY");
        GOV_SENDER  = chainlog.getAddress("LZ_GOV_SENDER");
        GOV_RELAY   = chainlog.getAddress("LZ_GOV_RELAY");

        Domain memory avalanche = getChain("avalanche").createFork(88200000);
        bridge = LZBridgeTesting.createLZBridge(mainnet, avalanche);

        bridge.destination.selectFork();
        l2Spell   = new LZAvaxMigrationL2Spell();
        avaxUsds  = _buildAvaxOft(AVAX_USDS);
        avaxSusds = _buildAvaxOft(AVAX_SUSDS);
    }

    // Deploy a remote-OFT mock on the destination fork, owned by the old relay (as the deployer
    // would leave it) and configured for the ETH_EID route. Returns the OftActivation to relay.
    function _buildAvaxOft(address token_) internal returns (OftActivation memory a) {
        address peerAddr = makeAddr("l1adapter");
        ExecutorConfig memory exec = ExecutorConfig({maxMessageSize: 10000, executor: makeAddr("avaxexec")});
        address[] memory dvns = new address[](2);
        dvns[0] = address(0x1111); dvns[1] = address(0x2222);
        UlnConfig memory uln = UlnConfig({
            confirmations: 15, requiredDVNCount: 2, optionalDVNCount: 0,
            optionalDVNThreshold: 0, requiredDVNs: dvns, optionalDVNs: new address[](0)
        });

        MockV2Adapter oft = new MockV2Adapter(AVAX_L2_GOV_RELAY, token_);  // owned by the old relay
        oft.configure(bytes32(uint256(uint160(peerAddr))), exec, uln, OptionsBuilder.newOptions().addExecutorLzReceiveOption(130_000, 0));

        a = OftActivation({
            oft: address(oft),
            cfg: OftConfig({peer: peerAddr, sendLib: address(oft), execCfg: exec, sendUlnCfg: uln, recvLib: address(oft), recvUlnCfg: uln, optionsGas: 130_000}),
            rateLimits: RateLimits({inboundWindow: 1 days, inboundLimit: 5_000_000e18, outboundWindow: 1 days, outboundLimit: 4_000_000e18}),
            rlAccountingType: 0
        });
    }

    function _relaySpell(bytes memory data) internal {
        mainnet.selectFork();
        vm.deal(GOV_RELAY, 1 ether);
        vm.startPrank(PAUSE_PROXY);
        LZInit.relayToL2(AVAX_EID, AVAX_L2_GOV_RELAY, address(l2Spell), data, 800_000, 1 ether);
        vm.stopPrank();
        bridge.relayMessagesToDestination(true, GOV_SENDER, AVAX_GOV_RECEIVER);
    }

    // --- migrateAvaxRemote: real Avalanche side via the real relay ---

    function test_migrateAvaxRemote() public {
        address[] memory dvns = new address[](2);
        dvns[0] = AVAX_DVN_LZ_LABS; dvns[1] = AVAX_DVN_NETHERMIND; // sorted ascending
        UlnConfig memory recvUln = UlnConfig({
            confirmations: 15, requiredDVNCount: 2, optionalDVNCount: 0,
            optionalDVNThreshold: 0, requiredDVNs: dvns, optionalDVNs: new address[](0)
        });

        _relaySpell(abi.encodeCall(
            LZAvaxMigrationL2Spell.migrateAvaxRemote,
            (recvUln, newRelay, avaxUsds, avaxSusds)
        ));

        bridge.destination.selectFork();
        MockV2Adapter usdsOft  = MockV2Adapter(avaxUsds.oft);
        MockV2Adapter susdsOft = MockV2Adapter(avaxSusds.oft);

        // Gov receiver's receive DVN set updated (read from whatever recv lib it uses).
        (address recvLib,) = EndpointLike(AVAX_ENDPOINT).getReceiveLibrary(AVAX_GOV_RECEIVER, ETH_EID);
        UlnConfig memory got = abi.decode(
            EndpointLike(AVAX_ENDPOINT).getConfig(AVAX_GOV_RECEIVER, recvLib, ETH_EID, 2), (UlnConfig)
        );
        assertEq(got.requiredDVNCount, 2);
        assertEq(got.requiredDVNs[0], AVAX_DVN_LZ_LABS);
        assertEq(got.requiredDVNs[1], AVAX_DVN_NETHERMIND);

        // New remote OFTs activated for the Ethereum route (per-eid rate limits flipped on).
        assertEq(usdsOft.recordedInbound(ETH_EID),   5_000_000e18);
        assertEq(usdsOft.recordedOutbound(ETH_EID),  4_000_000e18);
        assertEq(susdsOft.recordedInbound(ETH_EID),  5_000_000e18);
        assertEq(susdsOft.recordedOutbound(ETH_EID), 4_000_000e18);

        // Token authority handed over (real DSS tokens).
        assertEq(WardsLike(AVAX_USDS).wards(avaxUsds.oft),    1);
        assertEq(WardsLike(AVAX_USDS).wards(AVAX_OLD_USDS_OFT),  0);
        assertEq(WardsLike(AVAX_USDS).wards(newRelay),           1);
        assertEq(WardsLike(AVAX_USDS).wards(AVAX_L2_GOV_RELAY),  0);
        assertEq(WardsLike(AVAX_SUSDS).wards(avaxSusds.oft),  1);
        assertEq(WardsLike(AVAX_SUSDS).wards(AVAX_OLD_SUSDS_OFT), 0);
        assertEq(WardsLike(AVAX_SUSDS).wards(newRelay),          1);
        assertEq(WardsLike(AVAX_SUSDS).wards(AVAX_L2_GOV_RELAY), 0);

        // Delegate + ownership handed to the new relay (gov receiver = real, adapters = mock).
        assertEq(OwnableLike(AVAX_GOV_RECEIVER).owner(), newRelay);
        assertEq(usdsOft.owner(),     newRelay);
        assertEq(usdsOft.delegate(),  newRelay);
        assertEq(susdsOft.owner(),    newRelay);
        assertEq(susdsOft.delegate(), newRelay);
    }

    // --- migrateAvax: full L1 spell (real funding / chainlog / whitelist) + relay to Avalanche ---

    // Build the AvaxMigration and run it as the pause proxy (kept in its own frame to avoid
    // stack-too-deep). Returns the new L1 adapters for assertions.
    function _doMigrateAvax() internal returns (MockV2Adapter newUsds, MockV2Adapter newSusds) {
        AvaxMigration memory m;
        (m, newUsds, newSusds) = _buildMigration(true);
        vm.deal(GOV_RELAY, 1 ether);
        vm.startPrank(PAUSE_PROXY);
        LZAvaxMigrationInit.migrateAvax(m);
        vm.stopPrank();
    }

    // External boundary so vm.expectRevert can catch the (pre-auth) sanity-check reverts.
    function runMigration(AvaxMigration memory m) external {
        LZAvaxMigrationInit.migrateAvax(m);
    }

    // Builds the AvaxMigration. `ccipHandedOff` toggles the CCIP adapter's DEFAULT_ADMIN_ROLE
    // grant to the pause proxy, to exercise the admin-handoff sanity check.
    function _buildMigration(bool ccipHandedOff)
        internal
        returns (AvaxMigration memory m, MockV2Adapter newUsds, MockV2Adapter newSusds)
    {
        OftConfig memory usdsCfg;
        OftConfig memory susdsCfg;
        (newUsds,  usdsCfg)  = _buildOft(chainlog.getAddress("USDS"));
        (newSusds, susdsCfg) = _buildOft(chainlog.getAddress("SUSDS"));

        UlnConfig memory recvUln = UlnConfig({
            confirmations: 15, requiredDVNCount: 2, optionalDVNCount: 0,
            optionalDVNThreshold: 0, requiredDVNs: new address[](2), optionalDVNs: new address[](0)
        });
        recvUln.requiredDVNs[0] = AVAX_DVN_LZ_LABS;
        recvUln.requiredDVNs[1] = AVAX_DVN_NETHERMIND;

        {
            address sendLib = EndpointLike(OAppLike(GOV_SENDER).endpoint()).getSendLibrary(GOV_SENDER, AVAX_EID);
            // New gov send DVN set: reuse the current optional set (full overlap, passes the guard).
            UlnConfig memory cfg = UlnLike(sendLib).getAppUlnConfig(GOV_SENDER, AVAX_EID);

            // CCIP DVN adapter as the SendSideDeployer would have left it (roles granted, admin handed off).
            MockCCIPDVNAdapter ccip = new MockCCIPDVNAdapter();
            ccip.grant(keccak256("MESSAGE_LIB_ROLE"), sendLib);
            ccip.grant(keccak256("ALLOWLIST"),        GOV_SENDER);
            if (ccipHandedOff) ccip.grant(bytes32(0), PAUSE_PROXY);  // DEFAULT_ADMIN_ROLE

            // Splice it into the (sorted) send-side optional DVN set so migrateAvax can index it out.
            (cfg.optionalDVNs, m.ccipDvnIndex) = _insertSorted(cfg.optionalDVNs, address(ccip));
            cfg.optionalDVNCount = uint8(cfg.optionalDVNs.length);
            m.sendUlnCfg = cfg;
        }
        m.newL2GovRelay   = newRelay;
        m.usds          = OftActivation({oft: address(newUsds),  cfg: usdsCfg,  rateLimits: _zeroRL(), rlAccountingType: 0});
        m.usdsGlobalLimits = _zeroRL();
        m.legacyCLKey   = "USDS_OFT_SOLANA";
        m.susds         = OftActivation({oft: address(newSusds), cfg: susdsCfg, rateLimits: _zeroRL(), rlAccountingType: 0});
        m.susdsGlobalLimits = _zeroRL();
        m.recvUlnCfg      = recvUln;
        m.avaxUsds        = avaxUsds;
        m.avaxSusds       = avaxSusds;
        m.l2Spell         = address(l2Spell);
        m.gas             = 800_000;
        m.maxFee          = 1 ether;
    }

    function _zeroRL() internal pure returns (RateLimits memory r) {}

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

    function test_migrateAvax() public {
        mainnet.selectFork();
        address USDS    = chainlog.getAddress("USDS");
        address oldUsds = chainlog.getAddress("USDS_OFT");  // real lockbox, owned by PAUSE_PROXY
        uint256 oldUsdsBalBefore = TokenLike(USDS).balanceOf(oldUsds);

        (MockV2Adapter newUsds, MockV2Adapter newSusds) = _doMigrateAvax();

        // Chainlog repointed; old USDS adapter kept under the Solana key.
        assertEq(chainlog.getAddress("USDS_OFT"),        address(newUsds));
        assertEq(chainlog.getAddress("USDS_OFT_SOLANA"), oldUsds);
        assertEq(chainlog.getAddress("SUSDS_OFT"),       address(newSusds));

        // USDS backing moved old -> new (frozen Avalanche supply); old keeps the rest (Solana).
        assertEq(TokenLike(USDS).balanceOf(address(newUsds)), 10571537000000000000);
        assertEq(TokenLike(USDS).balanceOf(oldUsds), oldUsdsBalBefore - 10571537000000000000);

        // Old USDS adapter's Avalanche route severed; gov-relay whitelist swapped.
        assertEq(OFTAdapterLike(oldUsds).peers(AVAX_EID), bytes32(0));
        // Enforced options neutralized to the bare type-3 header (cannot be set back to empty).
        assertEq(OFTAdapterLike(oldUsds).enforcedOptions(AVAX_EID, 1), hex"0003");
        assertEq(OFTAdapterLike(oldUsds).enforcedOptions(AVAX_EID, 2), hex"0003");
        assertTrue (GovSenderLike(GOV_SENDER).canCallTarget(GOV_RELAY, AVAX_EID, bytes32(uint256(uint160(newRelay)))));
        assertFalse(GovSenderLike(GOV_SENDER).canCallTarget(GOV_RELAY, AVAX_EID, bytes32(uint256(uint160(AVAX_L2_GOV_RELAY)))));

        // Deliver the relayed Avalanche half and spot-check it executed.
        bridge.relayMessagesToDestination(true, GOV_SENDER, AVAX_GOV_RECEIVER);
        bridge.destination.selectFork();
        assertEq(WardsLike(AVAX_USDS).wards(avaxUsds.oft), 1);
        assertEq(WardsLike(AVAX_USDS).wards(AVAX_L2_GOV_RELAY),   0);
        assertEq(OwnableLike(AVAX_GOV_RECEIVER).owner(), newRelay);
        // Old adapters (hardcoded constants) were denied.
        assertEq(WardsLike(AVAX_USDS).wards(AVAX_OLD_USDS_OFT),   0);
        assertEq(WardsLike(AVAX_SUSDS).wards(AVAX_OLD_SUSDS_OFT), 0);
    }

    // Avalanche need not be the first L2 brought up on the V2 OFTs. Simulate a prior Base migration
    // (its route + global cap already live on both adapters, chainlog already repointed) and confirm
    // migrateAvax still succeeds: the global caps are overwritten (the old zero-assert would have
    // reverted), the Avalanche route is set fresh while the Base route is untouched, the chainlog
    // rewrites are idempotent, and funding still drains the hardcoded legacy lockbox.
    function test_migrateAvax_notFirstL2() public {
        mainnet.selectFork();
        address USDS            = chainlog.getAddress("USDS");
        uint256 legacyBalBefore = TokenLike(USDS).balanceOf(OLD_L1_USDS_OFT);

        (AvaxMigration memory m, MockV2Adapter newUsds, MockV2Adapter newSusds) = _buildMigration(true);
        // Non-zero Avalanche per-eid limits and system-wide (Base + Avalanche) global caps.
        m.usds.rateLimits   = RateLimits({inboundWindow: 1 days, inboundLimit: 5_000_000e18, outboundWindow: 1 days, outboundLimit: 4_000_000e18});
        m.susds.rateLimits  = RateLimits({inboundWindow: 1 days, inboundLimit: 5_000_000e18, outboundWindow: 1 days, outboundLimit: 4_000_000e18});
        m.usdsGlobalLimits  = RateLimits({inboundWindow: 1 days, inboundLimit: 9_000_000e18, outboundWindow: 1 days, outboundLimit: 8_000_000e18});
        m.susdsGlobalLimits = RateLimits({inboundWindow: 1 days, inboundLimit: 7_000_000e18, outboundWindow: 1 days, outboundLimit: 6_000_000e18});

        // --- A prior Base migration already brought these OFTs up ---
        uint32 BASE_EID = 30184;
        _presetRoute(newUsds,  BASE_EID, 3_000_000e18, 2_000_000e18);                  // Base route live
        _presetRoute(newSusds, BASE_EID, 1_000_000e18, 1_000_000e18);
        _presetRoute(newUsds,  newUsds.SENTINEL_EID(),  3_000_000e18, 2_000_000e18);   // Base-only global cap
        _presetRoute(newSusds, newSusds.SENTINEL_EID(), 1_000_000e18, 1_000_000e18);
        vm.startPrank(PAUSE_PROXY);
        ChainlogSetLike(address(chainlog)).setAddress("USDS_OFT",        address(newUsds));
        ChainlogSetLike(address(chainlog)).setAddress("SUSDS_OFT",       address(newSusds));
        ChainlogSetLike(address(chainlog)).setAddress("USDS_OFT_SOLANA", OLD_L1_USDS_OFT);
        vm.stopPrank();

        // --- Avalanche migration runs second ---
        vm.deal(GOV_RELAY, 1 ether);
        vm.startPrank(PAUSE_PROXY);
        LZAvaxMigrationInit.migrateAvax(m);
        vm.stopPrank();

        // Global caps overwritten with the new system-wide totals (the old zero-assert would have reverted).
        assertEq(newUsds.recordedInbound(newUsds.SENTINEL_EID()),    9_000_000e18);
        assertEq(newUsds.recordedOutbound(newUsds.SENTINEL_EID()),   8_000_000e18);
        assertEq(newSusds.recordedInbound(newSusds.SENTINEL_EID()),  7_000_000e18);
        assertEq(newSusds.recordedOutbound(newSusds.SENTINEL_EID()), 6_000_000e18);

        // Avalanche route set fresh; the pre-existing Base route is left untouched.
        assertEq(newUsds.recordedInbound(AVAX_EID),  5_000_000e18);
        assertEq(newUsds.recordedOutbound(AVAX_EID), 4_000_000e18);
        assertEq(newUsds.recordedInbound(BASE_EID),  3_000_000e18);
        assertEq(newUsds.recordedOutbound(BASE_EID), 2_000_000e18);

        // Chainlog rewrites are idempotent: the same values land again.
        assertEq(chainlog.getAddress("USDS_OFT"),        address(newUsds));
        assertEq(chainlog.getAddress("SUSDS_OFT"),       address(newSusds));
        assertEq(chainlog.getAddress("USDS_OFT_SOLANA"), OLD_L1_USDS_OFT);

        // Funding still drains the hardcoded legacy lockbox, regardless of the already-repointed USDS_OFT.
        assertEq(TokenLike(USDS).balanceOf(address(newUsds)), 10571537000000000000);
        assertEq(TokenLike(USDS).balanceOf(OLD_L1_USDS_OFT),  legacyBalBefore - 10571537000000000000);
    }

    // Simulate a prior spell having set a rate-limit bucket (per-eid or global) on a mock adapter.
    function _presetRoute(MockV2Adapter oft, uint32 eid, uint256 inLimit, uint256 outLimit) internal {
        RateLimitConfig[] memory inb = new RateLimitConfig[](1);
        RateLimitConfig[] memory out = new RateLimitConfig[](1);
        inb[0] = RateLimitConfig({eid: eid, window: 1 days, limit: inLimit});
        out[0] = RateLimitConfig({eid: eid, window: 1 days, limit: outLimit});
        oft.setRateLimits(inb, out);
    }

    function test_migrateAvax_revertsIfCcipAdminNotHandedOff() public {
        mainnet.selectFork();
        (AvaxMigration memory m,,) = _buildMigration(false);  // CCIP admin not handed off to the pause proxy
        vm.expectRevert(bytes("LZAvaxMigrationInit/ccip-admin-not-handed-off"));
        this.runMigration(m);
    }

    function test_migrateAvax_revertsIfCcipAllowlistNotSingleton() public {
        mainnet.selectFork();
        (AvaxMigration memory m,,) = _buildMigration(true);
        // A second allowlisted OApp (e.g. a testing one not revoked on handoff) trips the check.
        MockCCIPDVNAdapter(m.sendUlnCfg.optionalDVNs[m.ccipDvnIndex]).grant(keccak256("ALLOWLIST"), address(0xBEEF));
        vm.expectRevert(bytes("LZAvaxMigrationInit/ccip-allowlist-not-singleton"));
        this.runMigration(m);
    }

    // --- activateOft + updateGlobalRateLimits (mock adapter; no real V2 in the hybrid setup) ---

    function _buildV2Adapter() internal returns (MockV2Adapter oft, OftConfig memory cfg) {
        address peerAddr = makeAddr("v2peer");
        ExecutorConfig memory exec = ExecutorConfig({maxMessageSize: 10000, executor: makeAddr("exec")});

        address[] memory dvns = new address[](2);
        dvns[0] = address(0x1111); dvns[1] = address(0x2222);
        UlnConfig memory uln = UlnConfig({
            confirmations: 15, requiredDVNCount: 2, optionalDVNCount: 0,
            optionalDVNThreshold: 0, requiredDVNs: dvns, optionalDVNs: new address[](0)
        });

        oft = new MockV2Adapter(address(this), address(0x742065));
        oft.configure(bytes32(uint256(uint160(peerAddr))), exec, uln, OptionsBuilder.newOptions().addExecutorLzReceiveOption(130_000, 0));

        cfg = OftConfig({
            peer: peerAddr, sendLib: address(oft), execCfg: exec, sendUlnCfg: uln,
            recvLib: address(oft), recvUlnCfg: uln, optionsGas: 130_000
        });
    }

    // New-L1-adapter mock (owned by the pause proxy) + the matching OftConfig for migrateAvax.
    function _buildOft(address token_) internal returns (MockV2Adapter oft, OftConfig memory cfg) {
        address peerAddr = makeAddr("legpeer");
        ExecutorConfig memory exec = ExecutorConfig({maxMessageSize: 10000, executor: makeAddr("legexec")});
        address[] memory dvns = new address[](2);
        dvns[0] = address(0x1111); dvns[1] = address(0x2222);
        UlnConfig memory uln = UlnConfig({
            confirmations: 15, requiredDVNCount: 2, optionalDVNCount: 0,
            optionalDVNThreshold: 0, requiredDVNs: dvns, optionalDVNs: new address[](0)
        });

        oft = new MockV2Adapter(PAUSE_PROXY, token_);
        oft.configure(bytes32(uint256(uint160(peerAddr))), exec, uln, OptionsBuilder.newOptions().addExecutorLzReceiveOption(130_000, 0));

        cfg = OftConfig({
            peer: peerAddr, sendLib: address(oft), execCfg: exec, sendUlnCfg: uln,
            recvLib: address(oft), recvUlnCfg: uln, optionsGas: 130_000
        });
    }

    function callActivateOftV2(address oft, OftConfig memory cfg, RateLimits memory rl, RateLimits memory grl) external {
        LZInit.activateOft(oft, AVAX_EID, cfg, rl, 0, address(0x742065), address(this));
        LZInit.updateGlobalRateLimits(oft, grl);
    }

    function test_activateOft_v2_setsPerEidAndGlobalLimits() public {
        (MockV2Adapter oft, OftConfig memory cfg) = _buildV2Adapter();

        RateLimits memory rl  = RateLimits({inboundWindow: 1 days, inboundLimit: 5_000_000e18, outboundWindow: 1 days, outboundLimit: 4_000_000e18});
        RateLimits memory grl = RateLimits({inboundWindow: 1 days, inboundLimit: 9_000_000e18, outboundWindow: 1 days, outboundLimit: 8_000_000e18});

        this.callActivateOftV2(address(oft), cfg, rl, grl);

        assertEq(oft.recordedInbound(AVAX_EID),  5_000_000e18);
        assertEq(oft.recordedOutbound(AVAX_EID), 4_000_000e18);
        assertEq(oft.recordedInbound(oft.SENTINEL_EID()),  9_000_000e18);
        assertEq(oft.recordedOutbound(oft.SENTINEL_EID()), 8_000_000e18);
    }
}
