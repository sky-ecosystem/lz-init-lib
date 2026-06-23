// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import {
    LZInit,
    UlnConfig,
    ExecutorConfig,
    SetConfigParam,
    EnforcedOptionParam,
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

import { SkyOFTAdapter, SkyOFTAdapterMintBurn, SkyOFTCore, ERC1967Proxy } from "./mocks/SkyOFTAdaptersFlat.sol";  // sky-ecosystem/sky-oapp-oft@sky-oft-v2
import { SendSideDeployer, CCIPDVNAdapter }                    from "./mocks/SendSideDeployerFlat.sol"; // sky-ecosystem/lz-gov-dvns-deploy@dev

interface ChainlogReadLike { function getAddress(bytes32) external view returns (address); }
interface ChainlogSetLike  { function setAddress(bytes32, address) external; }
interface WardsLike        { function wards(address) external view returns (uint256); }
interface TokenLike        { function balanceOf(address) external view returns (uint256); }
interface GovSenderLike    { function canCallTarget(address, uint32, bytes32) external view returns (bool); }
interface OwnableLike      { function owner() external view returns (address); }

// Cross-chain fork test: real mainnet + Avalanche forks, the real LZ relay/endpoints, real gov
// bridge / tokens / old adapters, and the real audited V2 adapters (flattened in ./mocks) deployed
// behind UUPS proxies and fully wired against the real endpoints, as the deployer would.
contract LZAvaxMigrationInitTest is Test {

    using DomainHelpers   for *;
    using LZBridgeTesting for *;

    ChainlogReadLike constant chainlog = ChainlogReadLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    uint32 constant ETH_EID  = 30101;
    uint32 constant AVAX_EID = 30106;

    // The LZ EndpointV2 has the same address on Ethereum, Avalanche, and Base.
    address constant ENDPOINT            = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant AVAX_L2_GOV_RELAY   = 0xe928885BCe799Ed933651715608155F01abA23cA; // old relay
    address constant AVAX_GOV_RECEIVER   = 0x6fdd46947ca6903c8c159d1dF2012Bc7fC5cEeec;
    address constant AVAX_USDS           = 0x86Ff09db814ac346a7C6FE2Cd648F27706D1D470;
    address constant AVAX_SUSDS          = 0xb94D9613C7aAB11E548a327154Cc80eCa911B5c1;
    address constant AVAX_OLD_USDS_OFT   = 0x4fec40719fD9a8AE3F8E20531669DEC5962D2619;
    address constant AVAX_OLD_SUSDS_OFT  = 0x7297D4811f088FC26bC5475681405B99b41E1FF9;
    address constant OLD_L1_USDS_OFT     = 0x1e1D42781FC170EF9da004Fb735f56F0276d01B8; // V1 L1 USDS lockbox
    address constant AVAX_DVN_LZ_LABS    = 0x962F502A63F5FBeB44DC9ab932122648E8352959;
    address constant AVAX_DVN_NETHERMIND = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;

    uint128 constant OPTIONS_GAS   = 129488;          // matches the live adapters' enforced lzReceive gas (0x1fbd0)
    uint8   constant NIL_DVN_COUNT = type(uint8).max; // explicit "no DVNs" (0 would mean "inherit MessageLib default")

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
        // New Avalanche remote OFTs (mint/burn), wired for the Ethereum route, owned by the old
        // relay. Config ref is the old Avalanche USDS adapter for both (same chain-wide libs/DVNs/executor).
        avaxUsds  = _buildAvaxOft(AVAX_USDS,  AVAX_OLD_USDS_OFT, 5_000_000e18, 4_000_000e18);
        avaxSusds = _buildAvaxOft(AVAX_SUSDS, AVAX_OLD_USDS_OFT, 3_000_000e18, 2_000_000e18);
    }

    // ====================================================================================
    //  Real-adapter deploy + wiring helpers
    // ====================================================================================

    // type-3 lzReceive option, identical bytes to LZInit._encodeLzReceiveOptions(gas).
    function _encodeOpts(uint128 gas) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"0003", uint8(1), uint16(17), uint8(1), gas);
    }

    // A minimal, valid ULN config reusing a real DVN from `refOft`'s live `eid` send config (so the
    // endpoint's ULN302 accepts it and `_verifyOftConfig`'s requiredDVNCount!=0 / confirmations!=0 hold).
    function _ulnFromRef(address refOft, address sendLib, uint32 eid) internal view returns (UlnConfig memory uln) {
        UlnConfig memory ref = abi.decode(EndpointLike(ENDPOINT).getConfig(refOft, sendLib, eid, 2), (UlnConfig));
        address dvn = ref.requiredDVNs.length > 0 ? ref.requiredDVNs[0] : ref.optionalDVNs[0];
        address[] memory req = new address[](1);
        req[0] = dvn;
        uln = UlnConfig({
            confirmations: 15, requiredDVNCount: 1, optionalDVNCount: NIL_DVN_COUNT,
            optionalDVNThreshold: 0, requiredDVNs: req, optionalDVNs: new address[](0)
        });
    }

    // Deploy a real SkyOFT adapter (lockbox on L1, mint/burn on L2) behind a UUPS proxy and fully wire
    // it for `remoteEid` against the real endpoint, copying the live libraries + executor config from
    // `refOft` (the corresponding old adapter). Leaves it owned + delegated by `finalOwner`.
    function _deploySkyOft(
        bool    lockbox,
        address token_,
        uint32  remoteEid,
        address refOft,
        address peerAddr,
        address finalOwner
    ) internal returns (address oft, OftConfig memory cfg) {
        address impl = lockbox
            ? address(new SkyOFTAdapter(token_, ENDPOINT))
            : address(new SkyOFTAdapterMintBurn(token_, ENDPOINT));
        // initialize(delegate = this): owner = delegate = this, so the test can wire it.
        oft = address(new ERC1967Proxy(impl, abi.encodeWithSignature("initialize(address)", address(this))));

        address sendLib       = EndpointLike(ENDPOINT).getSendLibrary(refOft, remoteEid);
        (address recvLib,)    = EndpointLike(ENDPOINT).getReceiveLibrary(refOft, remoteEid);
        ExecutorConfig memory exec = abi.decode(EndpointLike(ENDPOINT).getConfig(refOft, sendLib, remoteEid, 1), (ExecutorConfig));
        UlnConfig memory uln  = _ulnFromRef(refOft, sendLib, remoteEid);

        EndpointLike(ENDPOINT).setSendLibrary(oft, remoteEid, sendLib);
        EndpointLike(ENDPOINT).setReceiveLibrary(oft, remoteEid, recvLib, 0);

        SetConfigParam[] memory sendParams = new SetConfigParam[](2);
        sendParams[0] = SetConfigParam(remoteEid, 1, abi.encode(exec));
        sendParams[1] = SetConfigParam(remoteEid, 2, abi.encode(uln));
        EndpointLike(ENDPOINT).setConfig(oft, sendLib, sendParams);

        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam(remoteEid, 2, abi.encode(uln));
        EndpointLike(ENDPOINT).setConfig(oft, recvLib, recvParams);

        EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](2);
        opts[0] = EnforcedOptionParam(remoteEid, 1, _encodeOpts(OPTIONS_GAS));
        opts[1] = EnforcedOptionParam(remoteEid, 2, _encodeOpts(OPTIONS_GAS));
        OFTAdapterLike(oft).setEnforcedOptions(opts);
        OFTAdapterLike(oft).setPeer(remoteEid, bytes32(uint256(uint160(peerAddr))));

        cfg = OftConfig({
            peer: peerAddr, sendLib: sendLib, execCfg: exec, sendUlnCfg: uln,
            recvLib: recvLib, recvUlnCfg: uln, optionsGas: OPTIONS_GAS
        });

        SkyOFTCore(oft).setDelegate(finalOwner);
        SkyOFTCore(oft).transferOwnership(finalOwner);
    }

    // New Avalanche remote OFT (mint/burn), wired for the Ethereum route, owned by the old relay. To relay.
    function _buildAvaxOft(address token_, address refOft, uint256 inLimit, uint256 outLimit)
        internal returns (OftActivation memory a)
    {
        (address oft, OftConfig memory cfg) =
            _deploySkyOft(false, token_, ETH_EID, refOft, makeAddr("l1adapter"), AVAX_L2_GOV_RELAY);
        a = OftActivation({
            oft: oft,
            cfg: cfg,
            rateLimits: RateLimits({inboundWindow: 1 days, inboundLimit: inLimit, outboundWindow: 1 days, outboundLimit: outLimit}),
            rlAccountingType: 0
        });
    }

    // New L1 lockbox adapter (owned by the pause proxy) + the matching OftConfig for migrateAvax.
    function _buildOft(address token_, address refOft) internal returns (address oft, OftConfig memory cfg) {
        (oft, cfg) = _deploySkyOft(true, token_, AVAX_EID, refOft, makeAddr("l2peer"), PAUSE_PROXY);
    }

    // limit field (4th) of the stored rate-limit bucket.
    function _outLimit(address oft, uint32 eid) internal view returns (uint256 l) { (,,, l) = OFTAdapterLike(oft).outboundRateLimits(eid); }
    function _inLimit(address oft, uint32 eid)  internal view returns (uint256 l) { (,,, l) = OFTAdapterLike(oft).inboundRateLimits(eid); }

    function _relaySpell(bytes memory data) internal {
        mainnet.selectFork();
        vm.deal(GOV_RELAY, 1 ether);
        vm.startPrank(PAUSE_PROXY);
        LZInit.relayToL2(AVAX_EID, AVAX_L2_GOV_RELAY, address(l2Spell), data, 800_000, 1 ether);
        vm.stopPrank();
        bridge.relayMessagesToDestination(true, GOV_SENDER, AVAX_GOV_RECEIVER);
    }

    // --- migrateAvaxRemote: Avalanche side via the relay ---

    function test_migrateAvaxRemote() public {
        address[] memory dvns = new address[](2);
        dvns[0] = AVAX_DVN_LZ_LABS; dvns[1] = AVAX_DVN_NETHERMIND; // sorted ascending
        UlnConfig memory recvUln = UlnConfig({
            confirmations: 15, requiredDVNCount: 2, optionalDVNCount: NIL_DVN_COUNT,
            optionalDVNThreshold: 0, requiredDVNs: dvns, optionalDVNs: new address[](0)
        });

        _relaySpell(abi.encodeCall(
            LZAvaxMigrationL2Spell.migrateAvaxRemote,
            (recvUln, newRelay, avaxUsds, avaxSusds)
        ));

        bridge.destination.selectFork();

        // Gov receiver's receive DVN set updated (read from whatever recv lib it uses).
        (address recvLib,) = EndpointLike(ENDPOINT).getReceiveLibrary(AVAX_GOV_RECEIVER, ETH_EID);
        UlnConfig memory got = abi.decode(
            EndpointLike(ENDPOINT).getConfig(AVAX_GOV_RECEIVER, recvLib, ETH_EID, 2), (UlnConfig)
        );
        assertEq(got.requiredDVNCount, 2);
        assertEq(got.requiredDVNs[0], AVAX_DVN_LZ_LABS);
        assertEq(got.requiredDVNs[1], AVAX_DVN_NETHERMIND);

        // New remote OFTs activated for the Ethereum route (per-eid rate limits flipped on).
        assertEq(_inLimit(avaxUsds.oft,   ETH_EID), 5_000_000e18);
        assertEq(_outLimit(avaxUsds.oft,  ETH_EID), 4_000_000e18);
        assertEq(_inLimit(avaxSusds.oft,  ETH_EID), 3_000_000e18);
        assertEq(_outLimit(avaxSusds.oft, ETH_EID), 2_000_000e18);

        // Token authority handed over.
        assertEq(WardsLike(AVAX_USDS).wards(avaxUsds.oft),        1);
        assertEq(WardsLike(AVAX_USDS).wards(AVAX_OLD_USDS_OFT),   0);
        assertEq(WardsLike(AVAX_USDS).wards(newRelay),            1);
        assertEq(WardsLike(AVAX_USDS).wards(AVAX_L2_GOV_RELAY),   0);
        assertEq(WardsLike(AVAX_SUSDS).wards(avaxSusds.oft),      1);
        assertEq(WardsLike(AVAX_SUSDS).wards(AVAX_OLD_SUSDS_OFT), 0);
        assertEq(WardsLike(AVAX_SUSDS).wards(newRelay),           1);
        assertEq(WardsLike(AVAX_SUSDS).wards(AVAX_L2_GOV_RELAY),  0);

        // Delegate + ownership handed to the new relay (gov receiver + both adapters).
        assertEq(OwnableLike(AVAX_GOV_RECEIVER).owner(),          newRelay);
        assertEq(OFTAdapterLike(avaxUsds.oft).owner(),            newRelay);
        assertEq(EndpointLike(ENDPOINT).delegates(avaxUsds.oft),  newRelay);
        assertEq(OFTAdapterLike(avaxSusds.oft).owner(),           newRelay);
        assertEq(EndpointLike(ENDPOINT).delegates(avaxSusds.oft), newRelay);
    }

    // --- migrateAvax: full L1 spell (funding / chainlog / whitelist) + relay to Avalanche ---

    function _doMigrateAvax() internal returns (address newUsds, address newSusds) {
        AvaxMigration memory m;
        (m, newUsds, newSusds) = _buildMigration({ccipHandedOff: true});
        vm.deal(GOV_RELAY, 1 ether);
        vm.startPrank(PAUSE_PROXY);
        LZAvaxMigrationInit.migrateAvax(m);
        vm.stopPrank();
    }

    // External boundary so vm.expectRevert can catch the (pre-auth) sanity-check reverts.
    function runMigration(AvaxMigration memory m) external {
        LZAvaxMigrationInit.migrateAvax(m);
    }

    function _buildMigration(bool ccipHandedOff)
        internal
        returns (AvaxMigration memory m, address newUsds, address newSusds)
    {
        return _buildMigration({ccipMsgLibRole: true, ccipAllowlisted: true, ccipHandedOff: ccipHandedOff});
    }

    // Builds the AvaxMigration. The flags toggle each CCIP adapter role grant individually, to
    // exercise the send-side sanity checks: `ccipMsgLibRole` (send lib's MESSAGE_LIB_ROLE),
    // `ccipAllowlisted` (gov sender on the ALLOWLIST), `ccipHandedOff` (admin handed to pause proxy).
    function _buildMigration(bool ccipMsgLibRole, bool ccipAllowlisted, bool ccipHandedOff)
        internal
        returns (AvaxMigration memory m, address newUsds, address newSusds)
    {
        OftConfig memory usdsCfg;
        OftConfig memory susdsCfg;
        // Config ref is the old L1 USDS lockbox for both (same chain-wide libs/DVNs/executor).
        (newUsds,  usdsCfg)  = _buildOft(chainlog.getAddress("USDS"),  OLD_L1_USDS_OFT);
        (newSusds, susdsCfg) = _buildOft(chainlog.getAddress("SUSDS"), OLD_L1_USDS_OFT);

        UlnConfig memory recvUln = UlnConfig({
            confirmations: 15, requiredDVNCount: 2, optionalDVNCount: NIL_DVN_COUNT,
            optionalDVNThreshold: 0, requiredDVNs: new address[](2), optionalDVNs: new address[](0)
        });
        recvUln.requiredDVNs[0] = AVAX_DVN_LZ_LABS;
        recvUln.requiredDVNs[1] = AVAX_DVN_NETHERMIND;

        {
        address sendLib = EndpointLike(OAppLike(GOV_SENDER).endpoint()).getSendLibrary(GOV_SENDER, AVAX_EID);
        // New gov send DVN set: reuse the current optional set (full overlap, passes the guard).
        UlnConfig memory cfg = UlnLike(sendLib).getAppUlnConfig(GOV_SENDER, AVAX_EID);

        // Deploy + role-configure the CCIP DVN adapter via SendSideDeployer, then hand off
        // to the pause proxy, exactly as production does. Flags steer the send-side sanity checks:
        //   ccipMsgLibRole : grant MESSAGE_LIB_ROLE to the real send lib (else a decoy lib)
        //   ccipAllowlisted: allowlist the gov sender (else a decoy OApp; allowlistSize stays 1)
        //   ccipHandedOff  : transfer DEFAULT_ADMIN_ROLE to the pause proxy
        address[] memory allow = new address[](1);
        allow[0] = ccipAllowlisted ? GOV_SENDER : makeAddr("decoyOApp");
        SendSideDeployer dep = new SendSideDeployer(ccipMsgLibRole ? sendLib : makeAddr("decoyLib"), allow);
        if (ccipHandedOff) dep.handOff(new address[](0));

        // Splice the adapter into the (sorted) send-side optional DVN set so migrateAvax can index it out.
        (cfg.optionalDVNs, m.ccipDvnIndex) = _insertSorted(cfg.optionalDVNs, address(dep.adapter()));
        cfg.optionalDVNCount = uint8(cfg.optionalDVNs.length);
        m.sendUlnCfg = cfg;
        }
        m.newL2GovRelay   = newRelay;
        m.usds          = OftActivation({oft: newUsds,  cfg: usdsCfg,  rateLimits: _zeroRL(), rlAccountingType: 0});
        m.usdsGlobalLimits = _zeroRL();
        m.legacyCLKey   = "USDS_OFT_SOLANA";
        m.susds         = OftActivation({oft: newSusds, cfg: susdsCfg, rateLimits: _zeroRL(), rlAccountingType: 0});
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

        (address newUsds, address newSusds) = _doMigrateAvax();

        // Chainlog repointed; old USDS adapter kept under the Solana key.
        assertEq(chainlog.getAddress("USDS_OFT"),        newUsds);
        assertEq(chainlog.getAddress("USDS_OFT_SOLANA"), oldUsds);
        assertEq(chainlog.getAddress("SUSDS_OFT"),       newSusds);

        // USDS backing moved old -> new (frozen Avalanche supply); old keeps the rest (Solana).
        assertEq(TokenLike(USDS).balanceOf(newUsds), 10571537000000000000);
        assertEq(TokenLike(USDS).balanceOf(oldUsds), oldUsdsBalBefore - 10571537000000000000);

        // Old USDS adapter's Avalanche route severed (peer cleared); gov-relay whitelist swapped.
        assertEq(OFTAdapterLike(oldUsds).peers(AVAX_EID), bytes32(0));
        assertTrue (GovSenderLike(GOV_SENDER).canCallTarget(GOV_RELAY, AVAX_EID, bytes32(uint256(uint160(newRelay)))));
        assertFalse(GovSenderLike(GOV_SENDER).canCallTarget(GOV_RELAY, AVAX_EID, bytes32(uint256(uint160(AVAX_L2_GOV_RELAY)))));

        // Deliver the relayed Avalanche half and spot-check it executed.
        bridge.relayMessagesToDestination(true, GOV_SENDER, AVAX_GOV_RECEIVER);
        bridge.destination.selectFork();
        assertEq(WardsLike(AVAX_USDS).wards(avaxUsds.oft),     1);
        assertEq(WardsLike(AVAX_USDS).wards(AVAX_L2_GOV_RELAY), 0);
        assertEq(OwnableLike(AVAX_GOV_RECEIVER).owner(), newRelay);
        // Old adapters (hardcoded constants) were denied.
        assertEq(WardsLike(AVAX_USDS).wards(AVAX_OLD_USDS_OFT),   0);
        assertEq(WardsLike(AVAX_SUSDS).wards(AVAX_OLD_SUSDS_OFT), 0);
    }

    // Avalanche need not be the first L2 brought up on the V2 OFTs. Simulate a prior Base migration
    // (its route + global cap already live on both adapters, chainlog already repointed) and confirm
    // migrateAvax still succeeds: the global caps are overwritten despite being already non-zero, the
    // Avalanche route is set fresh while the Base route is untouched, the chainlog rewrites are
    // idempotent, and funding still drains the hardcoded legacy lockbox.
    function test_migrateAvax_notFirstL2() public {
        mainnet.selectFork();
        address USDS            = chainlog.getAddress("USDS");
        uint256 legacyBalBefore = TokenLike(USDS).balanceOf(OLD_L1_USDS_OFT);

        (AvaxMigration memory m, address newUsds, address newSusds) = _buildMigration({ccipHandedOff: true});
        // Non-zero Avalanche per-eid limits and system-wide (Base + Avalanche) global caps.
        m.usds.rateLimits   = RateLimits({inboundWindow: 1 days, inboundLimit: 5_000_000e18,  outboundWindow: 1 days, outboundLimit: 4_000_000e18});
        m.susds.rateLimits  = RateLimits({inboundWindow: 1 days, inboundLimit: 11_000_000e18, outboundWindow: 1 days, outboundLimit: 10_000_000e18});
        m.usdsGlobalLimits  = RateLimits({inboundWindow: 1 days, inboundLimit: 9_000_000e18,  outboundWindow: 1 days, outboundLimit: 8_000_000e18});
        m.susdsGlobalLimits = RateLimits({inboundWindow: 1 days, inboundLimit: 7_000_000e18,  outboundWindow: 1 days, outboundLimit: 6_000_000e18});

        // --- A prior Base migration already brought these OFTs up (distinct values throughout) ---
        uint32 BASE_EID = 30184;
        _presetRoute(newUsds,  BASE_EID, 3_000_000e18,  2_000_000e18);   // Base route live (untouched by migration)
        _presetRoute(newSusds, BASE_EID, 13_000_000e18, 12_000_000e18);
        _presetRoute(newUsds,  OFTAdapterLike(newUsds).SENTINEL_EID(),  15_000_000e18, 14_000_000e18); // Base-era global cap (overwritten)
        _presetRoute(newSusds, OFTAdapterLike(newSusds).SENTINEL_EID(), 17_000_000e18, 16_000_000e18);
        vm.startPrank(PAUSE_PROXY);
        ChainlogSetLike(address(chainlog)).setAddress("USDS_OFT",        newUsds);
        ChainlogSetLike(address(chainlog)).setAddress("SUSDS_OFT",       newSusds);
        ChainlogSetLike(address(chainlog)).setAddress("USDS_OFT_SOLANA", OLD_L1_USDS_OFT);
        vm.stopPrank();

        // --- Avalanche migration runs second ---
        vm.deal(GOV_RELAY, 1 ether);
        vm.startPrank(PAUSE_PROXY);
        LZAvaxMigrationInit.migrateAvax(m);
        vm.stopPrank();

        // Global caps overwritten with the new system-wide totals, despite the pre-existing non-zero caps.
        assertEq(_inLimit(newUsds,   OFTAdapterLike(newUsds).SENTINEL_EID()),  9_000_000e18);
        assertEq(_outLimit(newUsds,  OFTAdapterLike(newUsds).SENTINEL_EID()),  8_000_000e18);
        assertEq(_inLimit(newSusds,  OFTAdapterLike(newSusds).SENTINEL_EID()), 7_000_000e18);
        assertEq(_outLimit(newSusds, OFTAdapterLike(newSusds).SENTINEL_EID()), 6_000_000e18);

        // Avalanche routes set fresh; the pre-existing Base routes are left untouched.
        assertEq(_inLimit(newUsds,   AVAX_EID), 5_000_000e18);
        assertEq(_outLimit(newUsds,  AVAX_EID), 4_000_000e18);
        assertEq(_inLimit(newSusds,  AVAX_EID), 11_000_000e18);
        assertEq(_outLimit(newSusds, AVAX_EID), 10_000_000e18);
        assertEq(_inLimit(newUsds,   BASE_EID), 3_000_000e18);
        assertEq(_outLimit(newUsds,  BASE_EID), 2_000_000e18);
        assertEq(_inLimit(newSusds,  BASE_EID), 13_000_000e18);
        assertEq(_outLimit(newSusds, BASE_EID), 12_000_000e18);

        // Chainlog rewrites are idempotent: the same values land again.
        assertEq(chainlog.getAddress("USDS_OFT"),        newUsds);
        assertEq(chainlog.getAddress("SUSDS_OFT"),       newSusds);
        assertEq(chainlog.getAddress("USDS_OFT_SOLANA"), OLD_L1_USDS_OFT);

        // Funding still drains the hardcoded legacy lockbox, regardless of the already-repointed USDS_OFT.
        assertEq(TokenLike(USDS).balanceOf(newUsds),         10571537000000000000);
        assertEq(TokenLike(USDS).balanceOf(OLD_L1_USDS_OFT), legacyBalBefore - 10571537000000000000);
    }

    // Pre-set a rate-limit bucket on a new lockbox as the pause proxy (owner), simulating a prior spell.
    function _presetRoute(address oft, uint32 eid, uint256 inLimit, uint256 outLimit) internal {
        RateLimitConfig[] memory inb = new RateLimitConfig[](1);
        RateLimitConfig[] memory out = new RateLimitConfig[](1);
        inb[0] = RateLimitConfig({eid: eid, window: 1 days, limit: inLimit});
        out[0] = RateLimitConfig({eid: eid, window: 1 days, limit: outLimit});
        vm.prank(PAUSE_PROXY);
        OFTAdapterLike(oft).setRateLimits(inb, out);
    }

    function test_migrateAvax_revertsIfInsufficientDvnOverlap() public {
        mainnet.selectFork();
        (AvaxMigration memory m,,) = _buildMigration({ccipHandedOff: true});
        // A new optional set overlapping the current on-chain set by fewer than MIN_DVN_OVERLAP fails
        // the guard. One below-range / one match / one above-range (sorted) also drives every arm of
        // the two-pointer merge: '<' (++i), '==' (match), '>' (++j).
        address sendLib = EndpointLike(OAppLike(GOV_SENDER).endpoint()).getSendLibrary(GOV_SENDER, AVAX_EID);
        address[] memory oldOpt = UlnLike(sendLib).getAppUlnConfig(GOV_SENDER, AVAX_EID).optionalDVNs;
        address[] memory dvns = new address[](3);
        dvns[0] = address(0x1);               // below all real DVNs
        dvns[1] = oldOpt[0];                   // a match
        dvns[2] = address(type(uint160).max);  // above all real DVNs
        m.sendUlnCfg.optionalDVNs = dvns;
        vm.expectRevert(bytes("LZAvaxMigrationInit/insufficient-dvn-overlap"));
        this.runMigration(m);
    }

    function test_migrateAvax_revertsIfCcipSendLibMissingRole() public {
        mainnet.selectFork();
        (AvaxMigration memory m,,) = _buildMigration({ccipMsgLibRole: false, ccipAllowlisted: true, ccipHandedOff: true});
        vm.expectRevert(bytes("LZAvaxMigrationInit/ccip-sendlib-missing-role"));
        this.runMigration(m);
    }

    function test_migrateAvax_revertsIfCcipGovSenderNotAllowlisted() public {
        mainnet.selectFork();
        (AvaxMigration memory m,,) = _buildMigration({ccipMsgLibRole: true, ccipAllowlisted: false, ccipHandedOff: true});
        vm.expectRevert(bytes("LZAvaxMigrationInit/ccip-gov-sender-not-allowlisted"));
        this.runMigration(m);
    }

    function test_migrateAvax_revertsIfCcipAdminNotHandedOff() public {
        mainnet.selectFork();
        (AvaxMigration memory m,,) = _buildMigration({ccipHandedOff: false});
        vm.expectRevert(bytes("LZAvaxMigrationInit/ccip-admin-not-handed-off"));
        this.runMigration(m);
    }

    function test_migrateAvax_revertsIfCcipAllowlistNotSingleton() public {
        mainnet.selectFork();
        (AvaxMigration memory m,,) = _buildMigration({ccipHandedOff: true});
        // A second allowlisted OApp (e.g. a testing one not revoked on handoff) trips the check.
        // Post-handoff the pause proxy holds DEFAULT_ADMIN_ROLE, so it grants the extra allowlist.
        vm.prank(PAUSE_PROXY);
        CCIPDVNAdapter(payable(m.sendUlnCfg.optionalDVNs[m.ccipDvnIndex])).grantRole(keccak256("ALLOWLIST"), address(0xBEEF));
        vm.expectRevert(bytes("LZAvaxMigrationInit/ccip-allowlist-not-singleton"));
        this.runMigration(m);
    }

    function test_migrateAvax_revertsIfCcipIndexOutOfBounds() public {
        mainnet.selectFork();
        (AvaxMigration memory m,,) = _buildMigration({ccipHandedOff: true});
        // An index past the end of the optional DVN set panics on access, so a bogus index can't
        // sneak past the membership requirement.
        m.ccipDvnIndex = m.sendUlnCfg.optionalDVNs.length;
        vm.expectRevert(stdError.indexOOBError);
        this.runMigration(m);
    }
}
