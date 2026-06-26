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

import { SkyOFTAdapter, SkyOFTAdapterMintBurn, SkyOFTCore, ERC1967Proxy, SendParam, MessagingFee } from "./mocks/SkyOFTAdaptersFlat.sol";
import { SendSideDeployer, CCIPDVNCfg, CCIPDVNAdapter } from "./mocks/SendSideDeployerFlat.sol";
import { L2GovernanceRelay } from "./mocks/L2GovernanceRelay.sol";

interface ChainlogReadLike { function getAddress(bytes32) external view returns (address); }
interface ChainlogSetLike  { function setAddress(bytes32, address) external; }
interface WardsLike        { function wards(address) external view returns (uint256); }
interface TokenLike        { function balanceOf(address) external view returns (uint256); function approve(address spender, uint256 amount) external returns (bool); }
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
    address constant OLD_L1_SUSDS_OFT    = 0x85A3FE4DA2a6cB98A5bdF62458B0dB8471B9f0f1; // V1 L1 sUSDS lockbox

    address constant ETH_DVN_HORIZEN     = 0x380275805876Ff19055EA900CDb2B46a94ecF20D;
    address constant ETH_DVN_LZ_LABS     = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
    address constant ETH_DVN_CANARY      = 0xa4fE5A5B9A846458a70Cd0748228aED3bF65c2cd;
    address constant ETH_DVN_NETHERMIND  = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
    address constant AVAX_DVN_HORIZEN    = 0x07C05EaB7716AcB6f83ebF6268F8EECDA8892Ba1;
    address constant AVAX_DVN_LZ_LABS    = 0x962F502A63F5FBeB44DC9ab932122648E8352959;
    address constant AVAX_DVN_NETHERMIND = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
    address constant AVAX_DVN_CANARY     = 0xcC49E6fca014c77E1Eb604351cc1E08C84511760;

    uint128 constant OPTIONS_GAS   = 129488;          // matches the live adapters' enforced lzReceive gas (0x1fbd0)
    uint8   constant NIL_DVN_COUNT = type(uint8).max; // explicit "no DVNs" (0 would mean "inherit MessageLib default")
    uint64  constant AVAX_CCIP_SELECTOR = 6433500567565415381; // Chainlink CCIP chain selector for Avalanche C-Chain

    address PAUSE_PROXY;
    address GOV_SENDER;
    address GOV_RELAY;

    Domain    mainnet;
    Bridge    bridge;
    LZAvaxMigrationL2Spell l2Spell;

    address newRelay;
    // New Avalanche remote OFTs (owned by the old relay until the spell hands them over).
    OftActivation avaxUsds;
    OftActivation avaxSusds;
    // New L1 lockboxes (owned by the pause proxy) + their configs for migrateAvax.
    address   newUsdsOft;
    address   newSusdsOft;
    OftConfig usdsLockboxCfg;
    OftConfig susdsLockboxCfg;
    // The gov receiver's current live receive ULN (read in setUp); the migration re-installs it.
    UlnConfig govRecvUln;

    function setUp() public {
        mainnet     = getChain("mainnet").createSelectFork(25337000);
        PAUSE_PROXY = chainlog.getAddress("MCD_PAUSE_PROXY");
        GOV_SENDER  = chainlog.getAddress("LZ_GOV_SENDER");
        GOV_RELAY   = chainlog.getAddress("LZ_GOV_RELAY");

        Domain memory avalanche = getChain("avalanche").createFork(88200000);
        bridge = LZBridgeTesting.createLZBridge(mainnet, avalanche);

        // Deploy every new adapter proxy first, so the deployer can then wire the real mutual peers
        // (each L1 lockbox and its L2 remote reference the other), exactly as production would. Both the
        // L1 and L2 OFT sides use the same 4/4 required LZ-aligned DVN set (per chain).
        bridge.destination.selectFork();
        l2Spell   = new LZAvaxMigrationL2Spell();
        newRelay  = address(new L2GovernanceRelay(ETH_EID, AVAX_GOV_RECEIVER, GOV_RELAY, 1 days, 7 days, new address[](0)));
        address avaxUsdsOft  = _deployOftProxy(false, AVAX_USDS);
        address avaxSusdsOft = _deployOftProxy(false, AVAX_SUSDS);
        // The migration re-installs the gov receiver's current 4-of-7 optional recv set unchanged.
        govRecvUln = _readRecvUln(AVAX_GOV_RECEIVER, ETH_EID);

        mainnet.selectFork();
        newUsdsOft  = _deployOftProxy(true, chainlog.getAddress("USDS"));
        newSusdsOft = _deployOftProxy(true, chainlog.getAddress("SUSDS"));
        // L1 lockboxes: wired for the Avalanche route to their remote adapter, owned by the pause proxy.
        // Libs/executor copied from each token's old L1 adapter; DVNs are the 4/4 Ethereum set.
        usdsLockboxCfg  = _wireOft(newUsdsOft,  AVAX_EID, OLD_L1_USDS_OFT,  _ethOftDvns(), avaxUsdsOft,  PAUSE_PROXY);
        susdsLockboxCfg = _wireOft(newSusdsOft, AVAX_EID, OLD_L1_SUSDS_OFT, _ethOftDvns(), avaxSusdsOft, PAUSE_PROXY);

        // Avalanche remote OFTs (mint/burn): wired for the Ethereum route to their L1 lockbox, owned by
        // the old relay until the spell hands them over. Libs/executor from each token's old Avalanche
        // adapter; DVNs are the 4/4 Avalanche set.
        bridge.destination.selectFork();
        avaxUsds = OftActivation({
            oft: avaxUsdsOft,
            cfg: _wireOft(avaxUsdsOft, ETH_EID, AVAX_OLD_USDS_OFT, _avaxOftDvns(), newUsdsOft, AVAX_L2_GOV_RELAY),
            rateLimits: RateLimits({inboundWindow: 1 days, inboundLimit: 5_000_000e18, outboundWindow: 1 days, outboundLimit: 4_000_000e18}),
            rlAccountingType: 0
        });
        avaxSusds = OftActivation({
            oft: avaxSusdsOft,
            cfg: _wireOft(avaxSusdsOft, ETH_EID, AVAX_OLD_SUSDS_OFT, _avaxOftDvns(), newSusdsOft, AVAX_L2_GOV_RELAY),
            rateLimits: RateLimits({inboundWindow: 1 days, inboundLimit: 3_000_000e18, outboundWindow: 1 days, outboundLimit: 2_000_000e18}),
            rlAccountingType: 0
        });
    }

    // ====================================================================================
    //  Real-adapter deploy + wiring helpers
    // ====================================================================================

    // type-3 lzReceive option, identical bytes to LZInit._encodeLzReceiveOptions(gas).
    function _encodeOpts(uint128 gas) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"0003", uint8(1), uint16(17), uint8(1), gas);
    }

    // The token OFT's 4/4 required DVN set on each chain (sorted ascending, as ULN302 requires).
    function _ethOftDvns() internal pure returns (address[] memory d) {
        d = new address[](4);
        (d[0], d[1], d[2], d[3]) = (ETH_DVN_HORIZEN, ETH_DVN_LZ_LABS, ETH_DVN_CANARY, ETH_DVN_NETHERMIND);
    }
    function _avaxOftDvns() internal pure returns (address[] memory d) {
        d = new address[](4);
        (d[0], d[1], d[2], d[3]) = (AVAX_DVN_HORIZEN, AVAX_DVN_LZ_LABS, AVAX_DVN_NETHERMIND, AVAX_DVN_CANARY);
    }

    // The OApp's live receive ULN config for `srcEid`, as the app set it (raw, so the NIL required-DVN
    // sentinel round-trips; getConfig would normalize it to 0 = "inherit MessageLib default").
    function _readRecvUln(address oapp, uint32 srcEid) internal view returns (UlnConfig memory) {
        (address recvLib,) = EndpointLike(ENDPOINT).getReceiveLibrary(oapp, srcEid);
        return UlnLike(recvLib).getAppUlnConfig(oapp, srcEid);
    }

    // Deploy a SkyOFT adapter proxy (lockbox on L1, mint/burn on L2), initialized with the test as
    // owner + delegate so it can be wired. Unwired until _wireOft (peers need the counterpart deployed).
    function _deployOftProxy(bool lockbox, address token_) internal returns (address oft) {
        address impl = lockbox
            ? address(new SkyOFTAdapter(token_, ENDPOINT))
            : address(new SkyOFTAdapterMintBurn(token_, ENDPOINT));
        oft = address(new ERC1967Proxy(impl, abi.encodeWithSignature("initialize(address)", address(this))));
    }

    // Wire `oft` for `remoteEid` against the real endpoint: libraries + executor config copied from
    // `refOft` (the corresponding old adapter), a 4/4-required ULN over `dvns`, enforced options, and
    // `peer`. Leaves it owned + delegated by `finalOwner`. Returns the matching OftConfig.
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

    // limit field (4th) of the stored rate-limit bucket.
    function _outLimit(address oft, uint32 eid) internal view returns (uint256 l) { (,,, l) = OFTAdapterLike(oft).outboundRateLimits(eid); }
    function _inLimit(address oft, uint32 eid)  internal view returns (uint256 l) { (,,, l) = OFTAdapterLike(oft).inboundRateLimits(eid); }

    // --- migrateAvaxRemote: Avalanche side via the relay ---

    function test_migrateAvaxRemote() public {
        mainnet.selectFork();
        vm.deal(GOV_RELAY, 1 ether);
        vm.startPrank(PAUSE_PROXY);
        LZInit.relayToL2(AVAX_EID, AVAX_L2_GOV_RELAY, address(l2Spell),
            abi.encodeCall(LZAvaxMigrationL2Spell.migrateAvaxRemote, (govRecvUln, newRelay, avaxUsds, avaxSusds)),
            800_000, 1 ether);
        vm.stopPrank();
        bridge.relayMessagesToDestination(true, GOV_SENDER, AVAX_GOV_RECEIVER);

        bridge.destination.selectFork();

        // Gov receiver's receive DVN set installed: the live 4-of-7 optional set, unchanged. Prod
        // hardening additionally inserts 4 CCIP + 4 multisig DVNReplica slots (see lz-dvn-broadcaster);
        // force-delivery here bypasses recv verification, so the replica fan-out isn't modeled.
        UlnConfig memory got = _readRecvUln(AVAX_GOV_RECEIVER, ETH_EID);
        assertEq(got.optionalDVNCount,     7);
        assertEq(got.optionalDVNThreshold, 4);
        assertEq(got.requiredDVNCount,     govRecvUln.requiredDVNCount);  // 4-of-7 optional set round-trips

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

    // External boundary so vm.expectRevert can catch the (pre-auth) sanity-check reverts.
    function runMigration(AvaxMigration memory m) external {
        LZAvaxMigrationInit.migrateAvax(m);
    }

    function _buildMigration(bool ccipHandedOff) internal returns (AvaxMigration memory m) {
        return _buildMigration({ccipMsgLibRole: true, ccipAllowlisted: true, ccipHandedOff: ccipHandedOff});
    }

    // Builds the AvaxMigration over the setUp-deployed adapters. The flags toggle each CCIP adapter
    // role grant individually, to exercise the send-side sanity checks: `ccipMsgLibRole` (send lib's
    // MESSAGE_LIB_ROLE), `ccipAllowlisted` (gov sender on the ALLOWLIST), `ccipHandedOff` (admin handed
    // to pause proxy).
    function _buildMigration(bool ccipMsgLibRole, bool ccipAllowlisted, bool ccipHandedOff)
        internal
        returns (AvaxMigration memory m)
    {
        {
        address sendLib = EndpointLike(OAppLike(GOV_SENDER).endpoint()).getSendLibrary(GOV_SENDER, AVAX_EID);
        // New gov send DVN set: reuse the current optional set (full overlap, passes the guard).
        UlnConfig memory cfg = UlnLike(sendLib).getAppUlnConfig(GOV_SENDER, AVAX_EID);

        // Deploy, configure CCIP routing, then hand off to the pause proxy, exactly as production
        // does. Flags steer the send-side sanity checks:
        //   ccipMsgLibRole : grant MESSAGE_LIB_ROLE to the real send lib (else a decoy lib)
        //   ccipAllowlisted: allowlist the gov sender (else a decoy OApp; allowlistSize stays 1)
        //   ccipHandedOff  : transfer DEFAULT_ADMIN_ROLE to the pause proxy
        address depSendLib = ccipMsgLibRole ? sendLib : makeAddr("decoyLib");
        address[] memory allow = new address[](1);
        allow[0] = ccipAllowlisted ? GOV_SENDER : makeAddr("decoyOApp");
        SendSideDeployer dep = new SendSideDeployer(depSendLib, allow);
        // Avalanche routing; the remote CCIP adapter/broadcaster are opaque here (force-delivery skips
        // CCIP-side verification), they only need to be set.
        dep.configure(CCIPDVNCfg({
            remoteEid:               AVAX_EID,
            remoteCcipChainSelector: AVAX_CCIP_SELECTOR,
            remoteCcipAdapter:       makeAddr("avaxCcipAdapter"),
            remoteCcipBroadcaster:   makeAddr("avaxCcipBroadcaster"),
            sendLib:                 depSendLib,
            multiplierBps:           0,
            gas:                     200_000
        }));
        if (ccipHandedOff) dep.handOff(new address[](0));

        // Splice the adapter into the (sorted) send-side optional DVN set so migrateAvax can index it out.
        (cfg.optionalDVNs, m.ccipDvnIndex) = _insertSorted(cfg.optionalDVNs, address(dep.adapter()));
        cfg.optionalDVNCount = uint8(cfg.optionalDVNs.length);
        m.sendUlnCfg = cfg;
        }
        m.newL2GovRelay   = newRelay;
        m.ccipAllowlistSize = 1;  // SendSideDeployer allowlists exactly the gov sender
        m.usds          = OftActivation({oft: newUsdsOft,  cfg: usdsLockboxCfg,  rateLimits: _zeroRL(), rlAccountingType: 0});
        m.usdsGlobalLimits = _zeroRL();
        m.legacyCLKey   = "USDS_OFT_SOLANA";
        m.susds         = OftActivation({oft: newSusdsOft, cfg: susdsLockboxCfg, rateLimits: _zeroRL(), rlAccountingType: 0});
        m.susdsGlobalLimits = _zeroRL();
        m.recvUlnCfg      = govRecvUln;
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

        AvaxMigration memory m = _buildMigration({ccipHandedOff: true});
        vm.deal(GOV_RELAY, 1 ether);
        vm.startPrank(PAUSE_PROXY);
        LZAvaxMigrationInit.migrateAvax(m);
        vm.stopPrank();

        // Chainlog repointed; old USDS adapter kept under the Solana key.
        assertEq(chainlog.getAddress("USDS_OFT"),        newUsdsOft);
        assertEq(chainlog.getAddress("USDS_OFT_SOLANA"), oldUsds);
        assertEq(chainlog.getAddress("SUSDS_OFT"),       newSusdsOft);

        // USDS backing moved old -> new (frozen Avalanche supply); old keeps the rest (Solana).
        assertEq(TokenLike(USDS).balanceOf(newUsdsOft), 10571537000000000000);
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

    // --- e2e: bridge USDS L1 -> Avalanche through the migrated adapters ---

    // Build + run with the given USDS rate limits, then relay the Avalanche half; leaves the fork on Avalanche.
    function _migrateAvaxWithUsdsLimits(RateLimits memory perEidLimits, RateLimits memory globalLimits) internal {
        mainnet.selectFork();
        AvaxMigration memory m = _buildMigration({ccipHandedOff: true});
        m.usds.rateLimits  = perEidLimits;
        m.usdsGlobalLimits = globalLimits;
        vm.deal(GOV_RELAY, 1 ether);
        vm.startPrank(PAUSE_PROXY);
        LZAvaxMigrationInit.migrateAvax(m);
        vm.stopPrank();
        bridge.relayMessagesToDestination(true, GOV_SENDER, AVAX_GOV_RECEIVER);
    }

    // USDS -> Avalanche send params: full amount, no slippage, enforced options apply (empty extraOptions).
    function _usdsSendParam(address to, uint256 amount) internal pure returns (SendParam memory) {
        return SendParam({
            dstEid: AVAX_EID, to: bytes32(uint256(uint160(to))), amountLD: amount, minAmountLD: amount,
            extraOptions: "", composeMsg: "", oftCmd: ""
        });
    }

    function test_migrateAvax_e2eUsdsBridge() public {
        mainnet.selectFork();
        address USDS = chainlog.getAddress("USDS");
        RateLimits memory perEidLimits = RateLimits({inboundWindow: 1 days, inboundLimit: 5_000_000e18, outboundWindow: 1 days, outboundLimit: 4_000_000e18});
        RateLimits memory globalLimits = RateLimits({inboundWindow: 1 days, inboundLimit: 9_000_000e18, outboundWindow: 1 days, outboundLimit: 8_000_000e18});
        _migrateAvaxWithUsdsLimits(perEidLimits, globalLimits);

        mainnet.selectFork();  // the L1 send happens here; the relay helper left us on Avalanche
        address user   = makeAddr("bridgeUser");
        uint256 amount = 1000e18;  // within both outbound caps
        deal(USDS, user, amount);
        vm.deal(user, 10 ether);

        SendParam memory sp = _usdsSendParam(user, amount);
        vm.startPrank(user);
        TokenLike(USDS).approve(newUsdsOft, amount);
        MessagingFee memory fee = SkyOFTAdapter(newUsdsOft).quoteSend(sp, false);
        SkyOFTAdapter(newUsdsOft).send{value: fee.nativeFee}(sp, fee, user);
        vm.stopPrank();

        // Locked on top of the migrated backing.
        assertEq(TokenLike(USDS).balanceOf(user),    0);
        assertEq(TokenLike(USDS).balanceOf(newUsdsOft), 10571537000000000000 + amount);

        bridge.relayMessagesToDestination(true, newUsdsOft, avaxUsds.oft);
        bridge.destination.selectFork();
        assertEq(TokenLike(AVAX_USDS).balanceOf(user), amount);
    }

    // The global (SENTINEL) outbound cap binds even when the per-eid cap is permissive.
    function test_migrateAvax_e2eRevertsOverGlobalCap() public {
        mainnet.selectFork();
        address USDS = chainlog.getAddress("USDS");
        RateLimits memory perEidLimits = RateLimits({inboundWindow: 1 days, inboundLimit: 5_000_000e18, outboundWindow: 1 days, outboundLimit: 5_000_000e18});
        RateLimits memory globalLimits = RateLimits({inboundWindow: 1 days, inboundLimit: 9_000_000e18, outboundWindow: 1 days, outboundLimit: 100e18});
        _migrateAvaxWithUsdsLimits(perEidLimits, globalLimits);

        mainnet.selectFork();
        address user   = makeAddr("capUser");
        uint256 amount = 1000e18;  // within per-eid (5M) but over the global (100) outbound cap
        deal(USDS, user, amount);
        vm.deal(user, 10 ether);

        SendParam memory sp = _usdsSendParam(user, amount);
        vm.startPrank(user);
        TokenLike(USDS).approve(newUsdsOft, amount);
        MessagingFee memory fee = SkyOFTAdapter(newUsdsOft).quoteSend(sp, false);
        vm.expectRevert(bytes4(keccak256("RateLimitExceeded()")));
        SkyOFTAdapter(newUsdsOft).send{value: fee.nativeFee}(sp, fee, user);
        vm.stopPrank();
    }

    // --- e2e: drive a governance message L1 -> Avalanche through the migrated gov bridge ---

    // A post-migration gov message routes through the new send DVN set (CCIP adapter spliced in) and the
    // swapped whitelist into the new L2 relay. The migration's own L2 half uses the old config, so this is
    // the only path exercising the new gov send config. Force-delivery skips the off-chain DVN verification.
    function test_migrateAvax_e2eGovMessage() public {
        mainnet.selectFork();
        AvaxMigration memory m = _buildMigration({ccipHandedOff: true});
        address ccipAdapter = m.sendUlnCfg.optionalDVNs[m.ccipDvnIndex];
        vm.deal(GOV_RELAY, 1 ether);
        vm.startPrank(PAUSE_PROXY);
        LZAvaxMigrationInit.migrateAvax(m);
        vm.stopPrank();
        bridge.relayMessagesToDestination(true, GOV_SENDER, AVAX_GOV_RECEIVER);  // run the Avalanche half
        mainnet.selectFork();

        // The CCIP adapter funds its outbound ccipSend from its own balance during assignJob.
        vm.deal(ccipAdapter, 1 ether);

        address       target     = makeAddr("govAction");  // a queued action's target is opaque to the relay
        bytes memory  targetData = hex"c0ffee";
        vm.deal(GOV_RELAY, 100 ether);
        vm.startPrank(PAUSE_PROXY);
        LZInit.relayToL2(AVAX_EID, newRelay, target, targetData, 800_000, 50 ether);
        vm.stopPrank();

        bridge.relayMessagesToDestination(true, GOV_SENDER, AVAX_GOV_RECEIVER);
        bridge.destination.selectFork();

        // Routed through the new send config + swapped whitelist: the relay queued the exact payload.
        L2GovernanceRelay.Action memory action = L2GovernanceRelay(newRelay).getActionById(0);
        assertEq(action.target,     target);
        assertEq(action.targetData, targetData);
        assertEq(uint8(L2GovernanceRelay(newRelay).getActionState(0)), uint8(L2GovernanceRelay.ActionState.Queued));

        // Executes after the timelock.
        vm.warp(block.timestamp + 1 days + 1);
        L2GovernanceRelay(newRelay).exec(0);
        assertEq(uint8(L2GovernanceRelay(newRelay).getActionState(0)), uint8(L2GovernanceRelay.ActionState.Executed));
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

        AvaxMigration memory m = _buildMigration({ccipHandedOff: true});
        // Non-zero Avalanche per-eid limits and system-wide (Base + Avalanche) global caps.
        m.usds.rateLimits   = RateLimits({inboundWindow: 1 days, inboundLimit: 5_000_000e18,  outboundWindow: 1 days, outboundLimit: 4_000_000e18});
        m.susds.rateLimits  = RateLimits({inboundWindow: 1 days, inboundLimit: 11_000_000e18, outboundWindow: 1 days, outboundLimit: 10_000_000e18});
        m.usdsGlobalLimits  = RateLimits({inboundWindow: 1 days, inboundLimit: 9_000_000e18,  outboundWindow: 1 days, outboundLimit: 8_000_000e18});
        m.susdsGlobalLimits = RateLimits({inboundWindow: 1 days, inboundLimit: 7_000_000e18,  outboundWindow: 1 days, outboundLimit: 6_000_000e18});

        // --- A prior Base migration already brought these OFTs up (distinct values throughout) ---
        uint32 BASE_EID = 30184;
        _presetRoute(newUsdsOft,  BASE_EID, 3_000_000e18,  2_000_000e18);   // Base route live (untouched by migration)
        _presetRoute(newSusdsOft, BASE_EID, 13_000_000e18, 12_000_000e18);
        _presetRoute(newUsdsOft,  OFTAdapterLike(newUsdsOft).SENTINEL_EID(),  15_000_000e18, 14_000_000e18); // Base-era global cap (overwritten)
        _presetRoute(newSusdsOft, OFTAdapterLike(newSusdsOft).SENTINEL_EID(), 17_000_000e18, 16_000_000e18);
        vm.startPrank(PAUSE_PROXY);
        ChainlogSetLike(address(chainlog)).setAddress("USDS_OFT",        newUsdsOft);
        ChainlogSetLike(address(chainlog)).setAddress("SUSDS_OFT",       newSusdsOft);
        ChainlogSetLike(address(chainlog)).setAddress("USDS_OFT_SOLANA", OLD_L1_USDS_OFT);
        vm.stopPrank();

        // --- Avalanche migration runs second ---
        vm.deal(GOV_RELAY, 1 ether);
        vm.startPrank(PAUSE_PROXY);
        LZAvaxMigrationInit.migrateAvax(m);
        vm.stopPrank();

        // Global caps overwritten with the new system-wide totals, despite the pre-existing non-zero caps.
        assertEq(_inLimit(newUsdsOft,   OFTAdapterLike(newUsdsOft).SENTINEL_EID()),  9_000_000e18);
        assertEq(_outLimit(newUsdsOft,  OFTAdapterLike(newUsdsOft).SENTINEL_EID()),  8_000_000e18);
        assertEq(_inLimit(newSusdsOft,  OFTAdapterLike(newSusdsOft).SENTINEL_EID()), 7_000_000e18);
        assertEq(_outLimit(newSusdsOft, OFTAdapterLike(newSusdsOft).SENTINEL_EID()), 6_000_000e18);

        // Avalanche routes set fresh; the pre-existing Base routes are left untouched.
        assertEq(_inLimit(newUsdsOft,   AVAX_EID), 5_000_000e18);
        assertEq(_outLimit(newUsdsOft,  AVAX_EID), 4_000_000e18);
        assertEq(_inLimit(newSusdsOft,  AVAX_EID), 11_000_000e18);
        assertEq(_outLimit(newSusdsOft, AVAX_EID), 10_000_000e18);
        assertEq(_inLimit(newUsdsOft,   BASE_EID), 3_000_000e18);
        assertEq(_outLimit(newUsdsOft,  BASE_EID), 2_000_000e18);
        assertEq(_inLimit(newSusdsOft,  BASE_EID), 13_000_000e18);
        assertEq(_outLimit(newSusdsOft, BASE_EID), 12_000_000e18);

        // Chainlog rewrites are idempotent: the same values land again.
        assertEq(chainlog.getAddress("USDS_OFT"),        newUsdsOft);
        assertEq(chainlog.getAddress("SUSDS_OFT"),       newSusdsOft);
        assertEq(chainlog.getAddress("USDS_OFT_SOLANA"), OLD_L1_USDS_OFT);

        // Funding still drains the hardcoded legacy lockbox, regardless of the already-repointed USDS_OFT.
        assertEq(TokenLike(USDS).balanceOf(newUsdsOft),         10571537000000000000);
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
        AvaxMigration memory m = _buildMigration({ccipHandedOff: true});
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
        AvaxMigration memory m = _buildMigration({ccipMsgLibRole: false, ccipAllowlisted: true, ccipHandedOff: true});
        vm.expectRevert(bytes("LZAvaxMigrationInit/ccip-sendlib-missing-role"));
        this.runMigration(m);
    }

    function test_migrateAvax_revertsIfCcipGovSenderNotAllowlisted() public {
        mainnet.selectFork();
        AvaxMigration memory m = _buildMigration({ccipMsgLibRole: true, ccipAllowlisted: false, ccipHandedOff: true});
        vm.expectRevert(bytes("LZAvaxMigrationInit/ccip-gov-sender-not-allowlisted"));
        this.runMigration(m);
    }

    function test_migrateAvax_revertsIfCcipAdminNotHandedOff() public {
        mainnet.selectFork();
        AvaxMigration memory m = _buildMigration({ccipHandedOff: false});
        vm.expectRevert(bytes("LZAvaxMigrationInit/ccip-admin-not-handed-off"));
        this.runMigration(m);
    }

    function test_migrateAvax_revertsIfCcipAllowlistSizeMismatch() public {
        mainnet.selectFork();
        AvaxMigration memory m = _buildMigration({ccipHandedOff: true});  // expects size 1
        // A second allowlisted OApp (size 2) no longer matches the expected size.
        vm.prank(PAUSE_PROXY);
        CCIPDVNAdapter(payable(m.sendUlnCfg.optionalDVNs[m.ccipDvnIndex])).grantRole(keccak256("ALLOWLIST"), address(0xBEEF));
        vm.expectRevert(bytes("LZAvaxMigrationInit/ccip-allowlist-size-mismatch"));
        this.runMigration(m);
    }

    function test_migrateAvax_acceptsLargerCcipAllowlist() public {
        // A Star sharing the CCIP adapter adds a second allowlisted entry; the spell passes the
        // matching expected size (e.g. 2) instead of assuming a singleton.
        mainnet.selectFork();
        AvaxMigration memory m = _buildMigration({ccipHandedOff: true});
        m.ccipAllowlistSize = 2;
        vm.prank(PAUSE_PROXY);
        CCIPDVNAdapter(payable(m.sendUlnCfg.optionalDVNs[m.ccipDvnIndex])).grantRole(keccak256("ALLOWLIST"), address(0xBEEF));

        vm.deal(GOV_RELAY, 1 ether);
        vm.startPrank(PAUSE_PROXY);
        LZAvaxMigrationInit.migrateAvax(m);  // does not revert
        vm.stopPrank();

        assertEq(chainlog.getAddress("USDS_OFT"), m.usds.oft);  // proof it ran to completion
    }

    function test_migrateAvax_revertsIfCcipIndexOutOfBounds() public {
        mainnet.selectFork();
        AvaxMigration memory m = _buildMigration({ccipHandedOff: true});
        // An index past the end of the optional DVN set panics on access, so a bogus index can't
        // sneak past the membership requirement.
        m.ccipDvnIndex = m.sendUlnCfg.optionalDVNs.length;
        vm.expectRevert(stdError.indexOOBError);
        this.runMigration(m);
    }
}

