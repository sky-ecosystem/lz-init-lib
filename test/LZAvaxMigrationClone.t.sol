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
    AvaxMigration,
    OftActivation
} from "deploy/LZAvaxMigrationInit.sol";
import { LZAvaxMigrationCloneInit, CloneEnv } from "deploy/LZAvaxMigrationCloneInit.sol";

import { Bridge }                from "xchain-helpers/testing/Bridge.sol";
import { Domain, DomainHelpers } from "xchain-helpers/testing/Domain.sol";
import { LZBridgeTesting }       from "xchain-helpers/testing/bridges/LZBridgeTesting.sol";

import { SkyOFTAdapter, SkyOFTAdapterMintBurn, SkyOFTCore, ERC1967Proxy, SendParam, MessagingFee } from "./mocks/SkyOFTAdaptersFlat.sol";
import { SendSideDeployer, CCIPDVNCfg, CCIPDVNAdapter } from "./mocks/SendSideDeployerFlat.sol";
import { L2GovernanceRelay } from "./mocks/L2GovernanceRelay.sol";

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
    function setAddress(bytes32, address) external;
}
interface TokenLike {
    function balanceOf(address) external view returns (uint256);
    function wards(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}
interface GovSenderLike  { function canCallTarget(address, uint32, bytes32) external view returns (bool); }
interface OwnableLike    { function owner() external view returns (address); }

// ============================================================================================
//  A trivial chainlog backed by a mapping: no auth, so setAddress can be called by anyone
//  (the clone lib calls it as the pause proxy). Seeded in setUp with the REAL production
//  addresses for every key the clone lib reads.
// ============================================================================================
contract MockChainlog {
    mapping(bytes32 => address) public addrs;
    function getAddress(bytes32 key) external view returns (address) { return addrs[key]; }
    function setAddress(bytes32 key, address addr) external { addrs[key] = addr; }
}

// ============================================================================================
//  Clone L2 spell: delegatecalled by the (old) L2GovernanceRelay, exactly like the real
//  LZAvaxMigrationL2Spell, but it calls the CLONE lib and threads a CloneEnv it holds in its
//  own (immutable-ish) storage. The relayed calldata carries the SAME 4-arg selector the
//  clone lib's migrateAvax encodes (migrateAvaxRemote(recvUlnCfg,newRelay,avaxUsds,avaxSusds)),
//  so this spell must expose that exact signature and supply the env itself.
//
//  NOTE: because this runs under delegatecall from the relay, only immutables and code are
//  read from the spell's own account; storage reads hit the relay's storage. So the CloneEnv
//  is encoded into the spell's bytecode via immutables (address fields) rather than storage.
// ============================================================================================
contract LZAvaxMigrationCloneL2Spell {
    address immutable chainlog;
    address immutable oldAvaxGovRelay;
    address immutable avaxGovReceiver;
    address immutable avaxUsds_;
    address immutable avaxSusds_;
    address immutable oldAvaxUsdsOft;
    address immutable oldAvaxSusdsOft;
    address immutable oldL1UsdsOft;
    uint256 immutable avaxUsdsBacking;

    constructor(CloneEnv memory e) {
        chainlog        = e.chainlog;
        oldAvaxGovRelay = e.oldAvaxGovRelay;
        avaxGovReceiver = e.avaxGovReceiver;
        avaxUsds_       = e.avaxUsds;
        avaxSusds_      = e.avaxSusds;
        oldAvaxUsdsOft  = e.oldAvaxUsdsOft;
        oldAvaxSusdsOft = e.oldAvaxSusdsOft;
        oldL1UsdsOft    = e.oldL1UsdsOft;
        avaxUsdsBacking = e.avaxUsdsBacking;
    }

    function migrateAvaxRemote(
        UlnConfig     memory recvUlnCfg,
        address              newRelay,
        OftActivation memory avaxUsds,
        OftActivation memory avaxSusds
    ) external {
        CloneEnv memory e = CloneEnv({
            chainlog:        chainlog,
            oldAvaxGovRelay: oldAvaxGovRelay,
            avaxGovReceiver: avaxGovReceiver,
            avaxUsds:        avaxUsds_,
            avaxSusds:       avaxSusds_,
            oldAvaxUsdsOft:  oldAvaxUsdsOft,
            oldAvaxSusdsOft: oldAvaxSusdsOft,
            oldL1UsdsOft:    oldL1UsdsOft,
            avaxUsdsBacking: avaxUsdsBacking
        });
        LZAvaxMigrationCloneInit.migrateAvaxRemote(recvUlnCfg, newRelay, avaxUsds, avaxSusds, e);
    }
}

// Cross-chain fork test proving the CLONE-parameterized migration reproduces the real one's
// outcome, driven entirely through LZAvaxMigrationCloneInit + a CloneEnv (never the hardcoded
// lib). Machinery mirrors LZAvaxMigrationInit.t.sol; the only substantive difference is that
// chainlog reads/writes hit a MockChainlog seeded with the real production addresses, and the
// production constants are supplied via CloneEnv.
contract LZAvaxMigrationCloneTest is Test {

    using DomainHelpers   for *;
    using LZBridgeTesting for *;

    ChainlogLike constant realChainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    uint32 constant ETH_EID  = 30101;
    uint32 constant AVAX_EID = 30106;

    address constant ENDPOINT           = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant OLD_AVAX_GOV_RELAY = 0xe928885BCe799Ed933651715608155F01abA23cA;
    address constant AVAX_GOV_RECEIVER  = 0x6fdd46947ca6903c8c159d1dF2012Bc7fC5cEeec;
    address constant AVAX_USDS          = 0x86Ff09db814ac346a7C6FE2Cd648F27706D1D470;
    address constant AVAX_SUSDS         = 0xb94D9613C7aAB11E548a327154Cc80eCa911B5c1;
    address constant OLD_AVAX_USDS_OFT  = 0x4fec40719fD9a8AE3F8E20531669DEC5962D2619;
    address constant OLD_AVAX_SUSDS_OFT = 0x7297D4811f088FC26bC5475681405B99b41E1FF9;
    address constant OLD_L1_USDS_OFT    = 0x1e1D42781FC170EF9da004Fb735f56F0276d01B8;
    address constant OLD_L1_SUSDS_OFT   = 0x85A3FE4DA2a6cB98A5bdF62458B0dB8471B9f0f1;

    uint256 constant AVAX_USDS_BACKING  = 10571537000000000000;

    address constant ETH_DVN_HORIZEN     = 0x380275805876Ff19055EA900CDb2B46a94ecF20D;
    address constant ETH_DVN_LZ_LABS     = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
    address constant ETH_DVN_CANARY      = 0xa4fE5A5B9A846458a70Cd0748228aED3bF65c2cd;
    address constant ETH_DVN_NETHERMIND  = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
    address constant AVAX_DVN_HORIZEN    = 0x07C05EaB7716AcB6f83ebF6268F8EECDA8892Ba1;
    address constant AVAX_DVN_LZ_LABS    = 0x962F502A63F5FBeB44DC9ab932122648E8352959;
    address constant AVAX_DVN_NETHERMIND = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
    address constant AVAX_DVN_CANARY     = 0xcC49E6fca014c77E1Eb604351cc1E08C84511760;

    uint128 constant OPTIONS_GAS   = 129488;
    uint8   constant NIL_DVN_COUNT = type(uint8).max;
    uint64  constant AVAX_CCIP_SELECTOR = 6433500567565415381;

    address PAUSE_PROXY;
    address GOV_SENDER;
    address GOV_RELAY;
    address USDS;
    address SUSDS;

    Domain    mainnet;
    Bridge    bridge;
    LZAvaxMigrationCloneL2Spell l2Spell;

    MockChainlog mockCL;   // clone's fake chainlog (seeded with real prod addresses)
    CloneEnv     env;      // clone env (real prod addresses)

    address newRelay;
    OftActivation avaxUsds;
    OftActivation avaxSusds;
    address   newUsdsOft;
    address   newSusdsOft;
    OftConfig usdsLockboxCfg;
    OftConfig susdsLockboxCfg;
    UlnConfig newRecvUln;

    function setUp() public {
        mainnet     = getChain("mainnet").createSelectFork(25337000);
        PAUSE_PROXY = realChainlog.getAddress("MCD_PAUSE_PROXY");
        GOV_SENDER  = realChainlog.getAddress("LZ_GOV_SENDER");
        GOV_RELAY   = realChainlog.getAddress("LZ_GOV_RELAY");
        USDS        = realChainlog.getAddress("USDS");
        SUSDS       = realChainlog.getAddress("SUSDS");

        // --- The clone's fake chainlog, seeded with the REAL production addresses ---
        mockCL = new MockChainlog();
        mockCL.setAddress("LZ_GOV_SENDER",   GOV_SENDER);
        mockCL.setAddress("LZ_GOV_RELAY",    GOV_RELAY);
        mockCL.setAddress("MCD_PAUSE_PROXY", PAUSE_PROXY);
        mockCL.setAddress("USDS",            USDS);
        mockCL.setAddress("SUSDS",           SUSDS);
        mockCL.setAddress("USDS_OFT",        OLD_L1_USDS_OFT);
        mockCL.setAddress("SUSDS_OFT",       OLD_L1_SUSDS_OFT);

        // --- The clone env with the REAL production addresses ---
        env = CloneEnv({
            chainlog:        address(mockCL),
            oldAvaxGovRelay: OLD_AVAX_GOV_RELAY,
            avaxGovReceiver: AVAX_GOV_RECEIVER,
            avaxUsds:        AVAX_USDS,
            avaxSusds:       AVAX_SUSDS,
            oldAvaxUsdsOft:  OLD_AVAX_USDS_OFT,
            oldAvaxSusdsOft: OLD_AVAX_SUSDS_OFT,
            oldL1UsdsOft:    OLD_L1_USDS_OFT,
            avaxUsdsBacking: AVAX_USDS_BACKING
        });

        Domain memory avalanche = getChain("avalanche").createFork(88200000);
        bridge = LZBridgeTesting.createLZBridge(mainnet, avalanche);

        bridge.destination.selectFork();
        l2Spell   = new LZAvaxMigrationCloneL2Spell(env);
        newRelay  = address(new L2GovernanceRelay(ETH_EID, AVAX_GOV_RECEIVER, GOV_RELAY, 1 days, 7 days, new address[](0)));
        address avaxUsdsOft  = _deployOftProxy(false, AVAX_USDS);
        address avaxSusdsOft = _deployOftProxy(false, AVAX_SUSDS);
        newRecvUln = _readRecvUln(AVAX_GOV_RECEIVER, ETH_EID);
        for (uint160 i; i < 8; ++i) newRecvUln.optionalDVNs.push(address(type(uint160).max - 8 + i));
        newRecvUln.optionalDVNCount     = uint8(newRecvUln.optionalDVNs.length);
        newRecvUln.optionalDVNThreshold = 8;

        mainnet.selectFork();
        newUsdsOft  = _deployOftProxy(true, USDS);
        newSusdsOft = _deployOftProxy(true, SUSDS);
        usdsLockboxCfg  = _wireOft(newUsdsOft,  AVAX_EID, OLD_L1_USDS_OFT,  _ethOftDvns(), avaxUsdsOft,  PAUSE_PROXY);
        susdsLockboxCfg = _wireOft(newSusdsOft, AVAX_EID, OLD_L1_SUSDS_OFT, _ethOftDvns(), avaxSusdsOft, PAUSE_PROXY);

        bridge.destination.selectFork();
        avaxUsds = OftActivation({
            oft: avaxUsdsOft,
            cfg: _wireOft(avaxUsdsOft, ETH_EID, OLD_AVAX_USDS_OFT, _avaxOftDvns(), newUsdsOft, OLD_AVAX_GOV_RELAY),
            rateLimits: RateLimits({inboundWindow: 1 hours, inboundLimit: 5_000_000e18, outboundWindow: 2 hours, outboundLimit: 4_000_000e18}),
            rlAccountingType: 0
        });
        avaxSusds = OftActivation({
            oft: avaxSusdsOft,
            cfg: _wireOft(avaxSusdsOft, ETH_EID, OLD_AVAX_SUSDS_OFT, _avaxOftDvns(), newSusdsOft, OLD_AVAX_GOV_RELAY),
            rateLimits: RateLimits({inboundWindow: 3 hours, inboundLimit: 3_000_000e18, outboundWindow: 4 hours, outboundLimit: 2_000_000e18}),
            rlAccountingType: 0
        });
    }

    // ====================================================================================
    //  Real-adapter deploy + wiring helpers (copied from LZAvaxMigrationInit.t.sol)
    // ====================================================================================

    function _encodeOpts(uint128 gas) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"0003", uint8(1), uint16(17), uint8(1), gas);
    }

    function _ethOftDvns() internal pure returns (address[] memory d) {
        d = new address[](4);
        (d[0], d[1], d[2], d[3]) = (ETH_DVN_HORIZEN, ETH_DVN_LZ_LABS, ETH_DVN_CANARY, ETH_DVN_NETHERMIND);
    }
    function _avaxOftDvns() internal pure returns (address[] memory d) {
        d = new address[](4);
        (d[0], d[1], d[2], d[3]) = (AVAX_DVN_HORIZEN, AVAX_DVN_LZ_LABS, AVAX_DVN_NETHERMIND, AVAX_DVN_CANARY);
    }

    function _readRecvUln(address oapp, uint32 srcEid) internal view returns (UlnConfig memory) {
        (address recvLib,) = EndpointLike(ENDPOINT).getReceiveLibrary(oapp, srcEid);
        return UlnLike(recvLib).getAppUlnConfig(oapp, srcEid);
    }

    function _deployOftProxy(bool lockbox, address token_) internal returns (address oft) {
        address impl = lockbox
            ? address(new SkyOFTAdapter(token_, ENDPOINT))
            : address(new SkyOFTAdapterMintBurn(token_, ENDPOINT));
        oft = address(new ERC1967Proxy(impl, abi.encodeWithSignature("initialize(address)", address(this))));
    }

    function _wireOft(address oft, uint32 remoteEid, address refOft, address[] memory dvns, address peer, address finalOwner)
        internal returns (OftConfig memory cfg)
    {
        address sendLib       = EndpointLike(ENDPOINT).getSendLibrary(refOft, remoteEid);
        (address recvLib,)    = EndpointLike(ENDPOINT).getReceiveLibrary(refOft, remoteEid);
        ExecutorConfig memory exec = abi.decode(EndpointLike(ENDPOINT).getConfig(refOft, sendLib, remoteEid, 1), (ExecutorConfig));
        UlnConfig memory uln  = UlnConfig({
            confirmations: 15, requiredDVNCount: uint8(dvns.length), optionalDVNCount: NIL_DVN_COUNT,
            optionalDVNThreshold: 0, requiredDVNs: dvns, optionalDVNs: new address[](0)
        });

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
        OFTAdapterLike(oft).setPeer(remoteEid, bytes32(uint256(uint160(peer))));

        cfg = OftConfig({
            peer: peer, sendLib: sendLib, execCfg: exec, sendUlnCfg: uln,
            recvLib: recvLib, recvUlnCfg: uln, optionsGas: OPTIONS_GAS
        });

        SkyOFTCore(oft).setDelegate(finalOwner);
        SkyOFTCore(oft).transferOwnership(finalOwner);
    }

    function _outLimit(address oft, uint32 eid) internal view returns (uint256 l) { (,,, l) = OFTAdapterLike(oft).outboundRateLimits(eid); }
    function _inLimit(address oft, uint32 eid)  internal view returns (uint256 l) { (,,, l) = OFTAdapterLike(oft).inboundRateLimits(eid); }
    function _outWindow(address oft, uint32 eid) internal view returns (uint48 w) { (, w,,) = OFTAdapterLike(oft).outboundRateLimits(eid); }
    function _inWindow(address oft, uint32 eid)  internal view returns (uint48 w) { (, w,,) = OFTAdapterLike(oft).inboundRateLimits(eid); }

    // External boundary so migrateAvax executes as the pause proxy (via startPrank), exactly
    // like the existing test drives the real lib. Drives the CLONE lib + CloneEnv.
    function runMigration(AvaxMigration memory m) external {
        LZAvaxMigrationCloneInit.migrateAvax(m, env);
    }

    function _buildMigration() internal returns (AvaxMigration memory m) {
        {
        address sendLib = EndpointLike(OAppLike(GOV_SENDER).endpoint()).getSendLibrary(GOV_SENDER, AVAX_EID);
        UlnConfig memory cfg = UlnLike(sendLib).getAppUlnConfig(GOV_SENDER, AVAX_EID);

        address[] memory allow = new address[](1);
        allow[0] = GOV_SENDER;
        SendSideDeployer dep = new SendSideDeployer(sendLib, allow);
        dep.configure(CCIPDVNCfg({
            remoteEid:               AVAX_EID,
            remoteCcipChainSelector: AVAX_CCIP_SELECTOR,
            remoteCcipAdapter:       makeAddr("avaxCcipAdapter"),
            remoteCcipBroadcaster:   makeAddr("avaxCcipBroadcaster"),
            sendLib:                 sendLib,
            multiplierBps:           0,
            gas:                     200_000
        }));
        dep.handOff(new address[](0));

        (cfg.optionalDVNs, m.ccipDvnIndex) = _insertSorted(cfg.optionalDVNs, address(dep.adapter()));
        cfg.optionalDVNCount = uint8(cfg.optionalDVNs.length);
        m.sendUlnCfg = cfg;
        }
        m.newL2GovRelay     = newRelay;
        m.ccipAllowlistSize = 1;
        m.usds              = OftActivation({oft: newUsdsOft,  cfg: usdsLockboxCfg,  rateLimits: _zeroRL(), rlAccountingType: 0});
        m.usdsGlobalLimits  = _zeroRL();
        m.legacyCLKey       = "USDS_OFT_SOLANA";
        m.susds             = OftActivation({oft: newSusdsOft, cfg: susdsLockboxCfg, rateLimits: _zeroRL(), rlAccountingType: 0});
        m.susdsGlobalLimits = _zeroRL();
        m.recvUlnCfg        = newRecvUln;
        m.avaxUsds          = avaxUsds;
        m.avaxSusds         = avaxSusds;
        m.l2Spell           = address(l2Spell);
        m.gas               = 800_000;
        m.maxFee            = 1 ether;
    }

    function _zeroRL() internal pure returns (RateLimits memory r) {}

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

    // ====================================================================================
    //  The clone must reproduce the SAME migration outcome as the real one.
    //  Post-conditions mirror LZAvaxMigrationInit.t.sol test_migrateAvax exactly, except
    //  chainlog reads/writes target the MockChainlog.
    // ====================================================================================
    function test_migrateAvax_clone() public {
        mainnet.selectFork();
        address oldUsds = mockCL.getAddress("USDS_OFT");  // == OLD_L1_USDS_OFT, real lockbox
        assertEq(oldUsds, OLD_L1_USDS_OFT);
        uint256 oldUsdsBalBefore   = TokenLike(USDS).balanceOf(oldUsds);
        bytes32 oldSusdsPeerBefore = OFTAdapterLike(OLD_L1_SUSDS_OFT).peers(AVAX_EID);

        AvaxMigration memory m = _buildMigration();
        vm.deal(GOV_RELAY, 1 ether);
        vm.startPrank(PAUSE_PROXY);
        LZAvaxMigrationCloneInit.migrateAvax(m, env);
        vm.stopPrank();

        // USDS swap: backing moved old -> new; old keeps the rest.
        assertEq(TokenLike(USDS).balanceOf(newUsdsOft), AVAX_USDS_BACKING);
        assertEq(TokenLike(USDS).balanceOf(oldUsds), oldUsdsBalBefore - AVAX_USDS_BACKING);

        // USDS swap: old adapter's Avalanche route severed.
        assertEq(OFTAdapterLike(oldUsds).peers(AVAX_EID), bytes32(0));
        assertEq(_inLimit(oldUsds,  AVAX_EID), 0);
        assertEq(_outLimit(oldUsds, AVAX_EID), 0);

        // USDS swap: chainlog (mock) repointed, old adapter kept under the Solana key.
        assertEq(mockCL.getAddress("USDS_OFT"),        newUsdsOft);
        assertEq(mockCL.getAddress("USDS_OFT_SOLANA"), oldUsds);

        // sUSDS swap: chainlog repointed; old adapter's Avalanche route intact.
        assertEq(mockCL.getAddress("SUSDS_OFT"),       newSusdsOft);
        assertEq(OFTAdapterLike(OLD_L1_SUSDS_OFT).peers(AVAX_EID), oldSusdsPeerBefore);

        // Gov bridge: new send DVN set installed + relay whitelist swapped.
        address sendLib = EndpointLike(OAppLike(GOV_SENDER).endpoint()).getSendLibrary(GOV_SENDER, AVAX_EID);
        assertEq(keccak256(abi.encode(UlnLike(sendLib).getAppUlnConfig(GOV_SENDER, AVAX_EID))),
                 keccak256(abi.encode(m.sendUlnCfg)));
        assertTrue (GovSenderLike(GOV_SENDER).canCallTarget(GOV_RELAY, AVAX_EID, bytes32(uint256(uint160(newRelay)))));
        assertFalse(GovSenderLike(GOV_SENDER).canCallTarget(GOV_RELAY, AVAX_EID, bytes32(uint256(uint160(OLD_AVAX_GOV_RELAY)))));

        // Deliver + run the relayed Avalanche half.
        bridge.relayMessagesToDestination(true, GOV_SENDER, AVAX_GOV_RECEIVER);
        bridge.destination.selectFork();

        // New remote OFTs activated for the Ethereum route.
        assertEq(_inLimit(avaxUsds.oft,    ETH_EID), avaxUsds.rateLimits.inboundLimit);
        assertEq(_inWindow(avaxUsds.oft,   ETH_EID), avaxUsds.rateLimits.inboundWindow);
        assertEq(_outLimit(avaxUsds.oft,   ETH_EID), avaxUsds.rateLimits.outboundLimit);
        assertEq(_outWindow(avaxUsds.oft,  ETH_EID), avaxUsds.rateLimits.outboundWindow);
        assertEq(_inLimit(avaxSusds.oft,   ETH_EID), avaxSusds.rateLimits.inboundLimit);
        assertEq(_inWindow(avaxSusds.oft,  ETH_EID), avaxSusds.rateLimits.inboundWindow);
        assertEq(_outLimit(avaxSusds.oft,  ETH_EID), avaxSusds.rateLimits.outboundLimit);
        assertEq(_outWindow(avaxSusds.oft, ETH_EID), avaxSusds.rateLimits.outboundWindow);

        // Gov receiver holds the migration's target recv config.
        assertEq(keccak256(abi.encode(_readRecvUln(AVAX_GOV_RECEIVER, ETH_EID))), keccak256(abi.encode(newRecvUln)));

        // Token authority moved from the old OFTs to the new OFTs.
        assertEq(TokenLike(AVAX_USDS).wards(avaxUsds.oft),        1);
        assertEq(TokenLike(AVAX_SUSDS).wards(avaxSusds.oft),      1);
        assertEq(TokenLike(AVAX_USDS).wards(OLD_AVAX_USDS_OFT),   0);
        assertEq(TokenLike(AVAX_SUSDS).wards(OLD_AVAX_SUSDS_OFT), 0);

        // Token authority moved from the old relay to the new relay.
        assertEq(TokenLike(AVAX_USDS).wards(newRelay),           1);
        assertEq(TokenLike(AVAX_SUSDS).wards(newRelay),          1);
        assertEq(TokenLike(AVAX_USDS).wards(OLD_AVAX_GOV_RELAY),  0);
        assertEq(TokenLike(AVAX_SUSDS).wards(OLD_AVAX_GOV_RELAY), 0);

        // Delegate + ownership moved to the new relay.
        assertEq(OwnableLike(AVAX_GOV_RECEIVER).owner(),              newRelay);
        assertEq(EndpointLike(ENDPOINT).delegates(AVAX_GOV_RECEIVER), newRelay);
        assertEq(OFTAdapterLike(avaxUsds.oft).owner(),                newRelay);
        assertEq(EndpointLike(ENDPOINT).delegates(avaxUsds.oft),      newRelay);
        assertEq(OFTAdapterLike(avaxSusds.oft).owner(),               newRelay);
        assertEq(EndpointLike(ENDPOINT).delegates(avaxSusds.oft),     newRelay);
    }
}
