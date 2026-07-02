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
import { RecordedLogs }          from "xchain-helpers/testing/utils/RecordedLogs.sol";

import {
    SkyOFTAdapter,
    SkyOFTAdapterMintBurn,
    SkyOFTCore,
    ERC1967Proxy,
    SendParam,
    MessagingFee
} from "./mocks/SkyOFTAdaptersFlat.sol";
import {
    CCIPDVNCfg,
    CCIPDVNAdapter,
    CCIPDVNAdapterFeeLib,
    LZDVNInit
} from "./mocks/SendSideDeployerFlat.sol";
import { DVNBroadcaster } from "./mocks/DVNBroadcaster.sol";

import {
    GovernanceOAppSender,
    GovernanceOAppReceiver,
    L1GovernanceRelay
} from "./mocks/GovBridgeFlat.sol";
import { L2GovernanceRelay } from "./mocks/L2GovernanceRelay.sol";

import { FakeChainlog, TestERC20, TestMintBurnERC20 } from "script/CloneHelpers.sol";

// ---- local views ----
interface WardsLike        { function wards(address) external view returns (uint256); }
interface GovSenderLike    {
    function canCallTarget(address, uint32, bytes32) external view returns (bool);
    function setCanCallTarget(address, uint32, bytes32, bool) external;
    function setPeer(uint32, bytes32) external;
    function setEnforcedOptions(EnforcedOptionParam[] calldata) external;
}
interface GovReceiverLike  {
    function setDelegate(address) external;
    function transferOwnership(address) external;
    function owner() external view returns (address);
}
interface OwnableLike      { function owner() external view returns (address); }
interface FakeCLBalanceOf  { function balanceOf(address) external view returns (uint256); }
interface CCIPAdminLike {
    function grantRole(bytes32 role, address account) external;
    function setWorkerFeeLib(address workerFeeLib) external;
    function setDefaultMultiplierBps(uint16 multiplierBps) external;
    function adapter() external view returns (address);
}
interface FeeLibLike {
    function initialize() external;
    function renounceOwnership() external;
}
// ReceiveUln302 attestation storage: hashLookup[keccak256(header)][payloadHash][dvn] => Verification.
interface ReceiveUlnLike {
    function hashLookup(bytes32 headerHash, bytes32 payloadHash, address dvn)
        external view returns (bool submitted, uint64 confirmations);
}
// Avalanche CCIP DVN adapter setDstConfig (ICCIPDVNAdapter.DstConfigParam shape).
struct AvaxDstConfigParam {
    uint32  eid;
    uint16  multiplierBps;
    uint64  chainSelector;
    uint256 gas;
    bytes   peer;
}
interface AvaxCcipAdapterLike {
    function grantRole(bytes32 role, address account) external;
    function setWorkerFeeLib(address workerFeeLib) external;
    function setDefaultMultiplierBps(uint16 multiplierBps) external;
    function setDstConfig(AvaxDstConfigParam[] calldata) external;
}

// ============================================================================================
//  Clone L2 spell: delegatecalled by the OLD L2GovernanceRelay, threading the CloneEnv via
//  immutables (identical to LZAvaxMigrationClone.t.sol's harness — see that file for rationale).
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

// ============================================================================================
//  CAPSTONE: stand up the ENTIRE independent clone (gov bridge + fake tokens + fake chainlog +
//  all 8 OFT adapters + CCIP adapter) on real mainnet + Avalanche forks, then run the clone
//  migration against it end-to-end and bridge tokens.
//
//  The deploy/wire logic is copied faithfully from CloneAvaxBridge.s.sol / CloneAvaxOft.s.sol
//  (via their in-process mirrors CloneAvaxBridge.t.sol / CloneAvaxOft.t.sol). The migration is
//  driven through LZAvaxMigrationCloneInit + a CloneEnv, exactly like LZAvaxMigrationClone.t.sol,
//  but against the FULLY-CLONED bridge/tokens rather than the real ones.
// ============================================================================================
contract CloneAvaxMigrationTest is Test {

    using DomainHelpers   for *;
    using LZBridgeTesting for *;

    // Deployer EOA == clone pause-proxy stand-in (chunk scripts' OWNER).
    address constant OWNER    = 0x54eAde20f7DD1A67624626A3DB9408185eD0039e;
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    uint32  constant ETH_EID  = 30101;
    uint32  constant AVAX_EID = 30106;

    // --- gov-bridge (chunk 1) LZ infra ---
    address constant ETH_SEND_LIB  = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    address constant ETH_EXECUTOR  = 0x173272739Bd7Aa6e4e214714048a9fE699453059;
    address constant AVAX_RECV_LIB = 0xbf3521d309642FA9B1c91A08609505BA09752c61;

    // --- OFT (chunk 2) LZ infra ---
    address constant ETH_RECV_LIB  = 0xc02Ab410f0734EFa3F14628780e6e695156024C2;
    address constant AVAX_SEND_LIB = 0x197D1333DEA5Fe0D6600E9b396c7f1B1cFCc558a;
    address constant REF_AVAX_OFT  = 0x4fec40719fD9a8AE3F8E20531669DEC5962D2619;

    uint64  constant CONFIRMATIONS = 15;
    uint8   constant NIL_DVN_COUNT = type(uint8).max;
    uint128 constant GOV_LZRECEIVE_GAS = 130_000;
    uint128 constant OFT_OPTIONS_GAS   = 130_000;
    uint16  constant MSG_TYPE_SEND     = 1;

    // OFT DVNs (production 4-of-4 required, ascending)
    address constant ETH_DVN_HORIZEN     = 0x380275805876Ff19055EA900CDb2B46a94ecF20D;
    address constant ETH_DVN_LZ_LABS     = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
    address constant ETH_DVN_CANARY      = 0xa4fE5A5B9A846458a70Cd0748228aED3bF65c2cd;
    address constant ETH_DVN_NETHERMIND  = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
    address constant AVAX_DVN_HORIZEN    = 0x07C05EaB7716AcB6f83ebF6268F8EECDA8892Ba1;
    address constant AVAX_DVN_LZ_LABS    = 0x962F502A63F5FBeB44DC9ab932122648E8352959;
    address constant AVAX_DVN_NETHERMIND = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
    address constant AVAX_DVN_CANARY     = 0xcC49E6fca014c77E1Eb604351cc1E08C84511760;

    // CCIP
    uint64  constant AVAX_CCIP_SELECTOR  = 6433500567565415381;   // Avalanche C-Chain CCIP selector
    uint64  constant ETH_CCIP_SELECTOR   = 5009297550715157269;   // Ethereum mainnet CCIP selector
    address constant CCIP_ROUTER         = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D; // mainnet CCIP router
    address constant AVAX_CCIP_ROUTER    = 0xF4c7E640EdA248ef95972845a62bdC74237805dB; // Avalanche C-Chain CCIP router
    uint16  constant CCIP_MULTIPLIER_BPS = 10_000;
    uint256 constant N_REPLICAS          = 4;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");
    bytes32 constant ALLOWLIST          = keccak256("ALLOWLIST");
    bytes32 constant MESSAGE_LIB_ROLE   = keccak256("MESSAGE_LIB_ROLE");

    // Clone economics
    uint256 constant AVAX_USDS_BACKING = 10_000e18;   // frozen avax USDS supply -> baked backing
    uint256 constant L1_USDS_BACKING   = 100_000e18;  // OLD L1 lockbox seed (> avax frozen)
    address constant AVAX_HOLDER       = 0x000000000000000000000000000000000000dEaD;

    Domain mainnet;
    Domain avalanche;
    Bridge bridge;

    // ---- chunk 1 (gov bridge + fake tokens + fake chainlog) ----
    address chainlog;
    address ethUsds;
    address ethSusds;
    address govSender;
    address l1Relay;
    address avaxUsds;   // fake avax USDS token (mint/burn)
    address avaxSusds;  // fake avax sUSDS token (mint/burn)
    address receiver;   // gov receiver
    address oldRelay;   // OLD L2 gov relay (owns receiver pre-migration)
    address newRelay;   // NEW L2 gov relay (migration target)

    // ---- chunk 2 (OFT adapters + CCIP) ----
    address l1OldUsds;
    address l1OldSusds;
    address l1NewUsds;
    address l1NewSusds;
    address ccipAdapter;
    address avaxOldUsds;
    address avaxOldSusds;
    address avaxNewUsds;
    address avaxNewSusds;

    // ---- chunk 3 (DVN broadcaster machinery on Avalanche) ----
    address avaxCcipAdapter;             // Avalanche CCIP DVN adapter (verifier of the ccip broadcaster)
    address ccipBroadcaster;             // verifier == avaxCcipAdapter
    address msigBroadcaster;             // verifier == OWNER (multisig stand-in)
    address[] ccipReplicas;              // 4 DVNReplica slots driven by ccipBroadcaster
    address[] msigReplicas;              // 4 DVNReplica slots driven by msigBroadcaster

    // ---- migration inputs ----
    LZAvaxMigrationCloneL2Spell l2Spell;
    CloneEnv env;
    OftConfig usdsLockboxCfg;
    OftConfig susdsLockboxCfg;
    OftActivation avaxUsdsAct;
    OftActivation avaxSusdsAct;
    UlnConfig newRecvUln;

    function setUp() public {
        mainnet   = getChain("mainnet").createSelectFork(25337000);
        avalanche = getChain("avalanche").createFork(88200000);
        bridge    = LZBridgeTesting.createLZBridge(mainnet, avalanche);

        // ---- chunk 1: deploy gov bridge + fake tokens + fake chainlog on both forks ----
        mainnet.selectFork();
        _scaffoldEth();
        avalanche.selectFork();
        _scaffoldAvax();

        // ---- chunk 2 + 3: deploy OFT adapters on both forks + the DVN broadcaster machinery on
        // Avalanche. The Avax broadcaster machinery (incl. the Avax CCIP adapter) is deployed BEFORE the
        // mainnet CCIP adapter, so _deployCcip can wire the mainnet adapter's dst peer at the REAL Avax
        // CCIP adapter + broadcaster (CCIPDVNAdapter.setDstConfig sets the peer once per chainSelector).
        avalanche.selectFork();
        _deployAvaxOft();
        _deployAvaxDvnBroadcaster();
        mainnet.selectFork();
        _deployEthOft();

        // ---- chunk 1 wire ----
        mainnet.selectFork();
        _wireEthGov();
        avalanche.selectFork();
        _wireAvaxGov();

        // ---- chunk 2 wire ----
        mainnet.selectFork();
        _wireEthOft();
        avalanche.selectFork();
        _wireAvaxOft_();

        // ---- migration inputs (spell + env + activations) ----
        env = CloneEnv({
            chainlog:        chainlog,
            oldAvaxGovRelay: oldRelay,
            avaxGovReceiver: receiver,
            avaxUsds:        avaxUsds,
            avaxSusds:       avaxSusds,
            oldAvaxUsdsOft:  avaxOldUsds,
            oldAvaxSusdsOft: avaxOldSusds,
            oldL1UsdsOft:    l1OldUsds,
            avaxUsdsBacking: AVAX_USDS_BACKING
        });

        avalanche.selectFork();
        l2Spell = new LZAvaxMigrationCloneL2Spell(env);

        // recv set for the receiver: the production 8-of-15 topology =
        //   sort(7 AVAX gov LZ DVNs ++ ccipReplicas(4) ++ msigReplicas(4)), threshold 8.
        // The 4 msig replicas are exercised for real by the msig-wing assertion (they must be
        // registered on the recv ULN for ReceiveUln302.verify to accept their attestations).
        {
        address[] memory recvDvns = _sortAddrs(_concatAddrs(_concatAddrs(_avaxGovRecvDvns(), ccipReplicas), msigReplicas));
        require(recvDvns.length == 15, "recv dvn set must be 15");
        newRecvUln = UlnConfig({
            confirmations:        CONFIRMATIONS,
            requiredDVNCount:     NIL_DVN_COUNT,
            optionalDVNCount:     15,
            optionalDVNThreshold: 8,
            requiredDVNs:         new address[](0),
            optionalDVNs:         recvDvns
        });
        }

        // per-eid rate limits for the new avax adapters (chosen, distinct in/out windows+limits)
        avaxUsdsAct = OftActivation({
            oft: avaxNewUsds,
            cfg: _oftConfig(avaxNewUsds, ETH_EID, l1NewUsds, _avaxOftDvns(), AVAX_SEND_LIB, AVAX_RECV_LIB),
            rateLimits: RateLimits({inboundWindow: 1 hours, inboundLimit: 5_000_000e18, outboundWindow: 2 hours, outboundLimit: 4_000_000e18}),
            rlAccountingType: 0
        });
        avaxSusdsAct = OftActivation({
            oft: avaxNewSusds,
            cfg: _oftConfig(avaxNewSusds, ETH_EID, l1NewSusds, _avaxOftDvns(), AVAX_SEND_LIB, AVAX_RECV_LIB),
            rateLimits: RateLimits({inboundWindow: 3 hours, inboundLimit: 3_000_000e18, outboundWindow: 4 hours, outboundLimit: 2_000_000e18}),
            rlAccountingType: 0
        });
    }

    // ============================================================================
    //  chunk 1 scaffold (copied from CloneAvaxBridge.t.sol / CloneAvaxBridge.s.sol)
    // ============================================================================

    function _scaffoldEth() internal {
        vm.startPrank(OWNER);
        chainlog = address(new FakeChainlog());
        ethUsds  = address(new TestERC20("Fake USDS", "fUSDS"));
        ethSusds = address(new TestERC20("Fake sUSDS", "fsUSDS"));
        govSender = address(new GovernanceOAppSender(ENDPOINT, OWNER));
        L1GovernanceRelay relay = new L1GovernanceRelay();
        relay.file("l1Oapp", govSender);
        l1Relay = address(relay);
        FakeChainlog(chainlog).setAddress("MCD_PAUSE_PROXY", OWNER);
        FakeChainlog(chainlog).setAddress("LZ_GOV_SENDER",   govSender);
        FakeChainlog(chainlog).setAddress("LZ_GOV_RELAY",    l1Relay);
        FakeChainlog(chainlog).setAddress("USDS",            ethUsds);
        FakeChainlog(chainlog).setAddress("SUSDS",           ethSusds);
        vm.stopPrank();
    }

    function _scaffoldAvax() internal {
        vm.startPrank(OWNER);
        avaxUsds  = address(new TestMintBurnERC20("Fake USDS", "fUSDS"));
        avaxSusds = address(new TestMintBurnERC20("Fake sUSDS", "fsUSDS"));
        receiver  = address(new GovernanceOAppReceiver(ETH_EID, bytes32(uint256(uint160(govSender))), ENDPOINT, OWNER));
        // CLONE-SETUP CORRECTION (vs CloneAvaxBridge.s.sol/_deployAvax, which builds the OLD relay
        // with l1GovernanceRelay = address(0)): production's OLD Avalanche relay has its L1 counterpart
        // set to the L1 gov relay (real OLD_AVAX_GOV_RELAY.l1GovernanceRelay == 0x2beBFe...). The
        // migration relays its L2 spell through the OLD relay, and L2GovernanceRelay.messageAuth
        // requires the inbound message's srcSender == l1GovernanceRelay. With address(0) that check
        // reverts "L2GovernanceRelay/bad-message-auth". So the clone OLD relay must also point at the
        // clone L1 relay. (delay 0 keeps it the pre-timelock instance, as in the script.)
        oldRelay  = address(new L2GovernanceRelay(ETH_EID, receiver, l1Relay, 0, 7 days, new address[](0)));
        newRelay  = address(new L2GovernanceRelay(ETH_EID, receiver, l1Relay, 1 days, 7 days, new address[](0)));
        vm.stopPrank();
    }

    function _wireEthGov() internal {
        vm.startPrank(OWNER);
        GovSenderLike(govSender).setPeer(AVAX_EID, bytes32(uint256(uint160(receiver))));
        EndpointLike(ENDPOINT).setSendLibrary(govSender, AVAX_EID, ETH_SEND_LIB);
        SetConfigParam[] memory sendParams = new SetConfigParam[](2);
        sendParams[0] = SetConfigParam(AVAX_EID, 1, abi.encode(ExecutorConfig({maxMessageSize: 10000, executor: ETH_EXECUTOR})));
        sendParams[1] = SetConfigParam(AVAX_EID, 2, abi.encode(_ethGovSendUlnCfg()));
        EndpointLike(ENDPOINT).setConfig(govSender, ETH_SEND_LIB, sendParams);
        EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](1);
        opts[0] = EnforcedOptionParam(AVAX_EID, MSG_TYPE_SEND, _encodeOpts(GOV_LZRECEIVE_GAS));
        GovSenderLike(govSender).setEnforcedOptions(opts);
        // CLONE-SETUP CORRECTION (vs CloneAvaxBridge.s.sol/_wireEth, which whitelists the NEW relay):
        // production pre-migration state whitelists the L1 relay -> OLD L2 relay (see
        // LZAvaxMigrationInit.t.sol L406-407: OLD==true / NEW==false before migrateAvax). The
        // migration relays its own L2 spell THROUGH the OLD relay (migrateAvax -> _relayToL2 targets
        // e.oldAvaxGovRelay), then swaps the whitelist to NEW itself. Whitelisting only NEW here makes
        // the migration's L2 relay revert with CannotCallTarget(). So whitelist the OLD relay.
        GovSenderLike(govSender).setCanCallTarget(l1Relay, AVAX_EID, bytes32(uint256(uint160(oldRelay))), true);
        vm.stopPrank();
    }

    function _wireAvaxGov() internal {
        vm.startPrank(OWNER);
        EndpointLike(ENDPOINT).setReceiveLibrary(receiver, ETH_EID, AVAX_RECV_LIB, 0);
        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam(ETH_EID, 2, abi.encode(_avaxGovRecvUlnCfg()));
        EndpointLike(ENDPOINT).setConfig(receiver, AVAX_RECV_LIB, recvParams);
        GovReceiverLike(receiver).setDelegate(oldRelay);
        GovReceiverLike(receiver).transferOwnership(oldRelay);
        vm.stopPrank();
    }

    // ============================================================================
    //  chunk 2 deploy + wire (copied from CloneAvaxOft.t.sol / CloneAvaxOft.s.sol)
    // ============================================================================

    function _deployEthOft() internal {
        vm.startPrank(OWNER);
        l1OldUsds   = _lockbox(ethUsds);
        l1OldSusds  = _lockbox(ethSusds);
        l1NewUsds   = _lockbox(ethUsds);
        l1NewSusds  = _lockbox(ethSusds);
        ccipAdapter = _deployCcip(govSender);
        vm.stopPrank();
    }

    function _deployAvaxOft() internal {
        vm.startPrank(OWNER);
        avaxOldUsds  = _mintBurn(avaxUsds);
        avaxOldSusds = _mintBurn(avaxSusds);
        avaxNewUsds  = _mintBurn(avaxUsds);
        avaxNewSusds = _mintBurn(avaxSusds);
        vm.stopPrank();
    }

    // Chunk 3 (Avalanche): the RECV-side production DVN-Broadcaster machinery. Mirrors
    // script/CloneAvaxDvnBroadcaster.s.sol. Two broadcasters, each spawning 4 DVNReplica slots:
    //   ccip wing verifier = the Avax CCIP DVN adapter; msig wing verifier = OWNER (multisig stand-in).
    function _deployAvaxDvnBroadcaster() internal {
        vm.startPrank(OWNER);

        // Avalanche CCIP DVN adapter (OWNER == DEFAULT_ADMIN_ROLE + ADMIN_ROLE).
        CCIPDVNAdapterFeeLib feeLib = new CCIPDVNAdapterFeeLib();
        FeeLibLike(address(feeLib)).initialize();
        FeeLibLike(address(feeLib)).renounceOwnership();
        address[] memory admins = new address[](1);
        admins[0] = OWNER;
        CCIPDVNAdapter adapter = new CCIPDVNAdapter(admins, AVAX_CCIP_ROUTER);
        AvaxCcipAdapterLike a = AvaxCcipAdapterLike(address(adapter));
        a.setWorkerFeeLib(address(feeLib));
        a.setDefaultMultiplierBps(CCIP_MULTIPLIER_BPS);
        // Reverse route: point the Avax adapter at the mainnet CCIP adapter (ETH selector).
        AvaxDstConfigParam[] memory dstCfg = new AvaxDstConfigParam[](1);
        dstCfg[0] = AvaxDstConfigParam({
            eid:           ETH_EID, multiplierBps: 0, chainSelector: ETH_CCIP_SELECTOR,
            gas:           600_000, peer: abi.encode(address(uint160(uint256(keccak256("mainnetCcipAdapter")))))
        });
        a.setDstConfig(dstCfg);
        avaxCcipAdapter = address(adapter);

        // Two broadcasters, 4 replicas each.
        ccipBroadcaster = address(new DVNBroadcaster(ENDPOINT, avaxCcipAdapter, N_REPLICAS));
        msigBroadcaster = address(new DVNBroadcaster(ENDPOINT, OWNER,           N_REPLICAS));
        ccipReplicas    = DVNBroadcaster(ccipBroadcaster).getReplicas();
        msigReplicas    = DVNBroadcaster(msigBroadcaster).getReplicas();
        vm.stopPrank();

        require(ccipReplicas.length == N_REPLICAS && msigReplicas.length == N_REPLICAS, "replica count");
    }

    function _wireEthOft() internal {
        vm.startPrank(OWNER);
        // OLD L1 USDS lockbox: wired, big inbound / 0 outbound (frozen), NOT paused, holds backing.
        _wireL1(l1OldUsds, avaxOldUsds);
        _setRL(l1OldUsds, AVAX_EID, 5_000_000e18, 0);
        TestERC20(ethUsds).mint(l1OldUsds, L1_USDS_BACKING);
        // OLD L1 sUSDS lockbox: PAUSED, 0 backing.
        _wireL1(l1OldSusds, avaxOldSusds);
        _pauseSelf(l1OldSusds);
        // NEW L1 lockboxes: wired, rate limits 0, NOT paused, owner==delegate==EOA.
        _wireL1(l1NewUsds,  avaxNewUsds);
        _wireL1(l1NewSusds, avaxNewSusds);
        // Seed the fake chainlog OFT keys with the OLD L1 lockboxes.
        FakeChainlog(chainlog).setAddress("USDS_OFT",  l1OldUsds);
        FakeChainlog(chainlog).setAddress("SUSDS_OFT", l1OldSusds);
        // capture the new lockbox configs for the migration
        usdsLockboxCfg  = _oftConfig(l1NewUsds,  AVAX_EID, avaxNewUsds,  _ethOftDvns(), ETH_SEND_LIB, ETH_RECV_LIB);
        susdsLockboxCfg = _oftConfig(l1NewSusds, AVAX_EID, avaxNewSusds, _ethOftDvns(), ETH_SEND_LIB, ETH_RECV_LIB);
        vm.stopPrank();
    }

    function _wireAvaxOft_() internal {
        vm.startPrank(OWNER);
        // OLD avax adapters: wired, relied on tokens (+ old relay relied), PAUSED, owner+delegate = OLD relay.
        _wireAvaxRoute(avaxOldUsds,  l1OldUsds);
        _wireAvaxRoute(avaxOldSusds, l1OldSusds);
        TestMintBurnERC20(avaxUsds).rely(avaxOldUsds);
        TestMintBurnERC20(avaxSusds).rely(avaxOldSusds);
        TestMintBurnERC20(avaxUsds).rely(oldRelay);
        TestMintBurnERC20(avaxSusds).rely(oldRelay);
        _pauseSelf(avaxOldUsds);
        _pauseSelf(avaxOldSusds);
        _handToRelay(avaxOldUsds,  oldRelay);
        _handToRelay(avaxOldSusds, oldRelay);
        // frozen avax USDS supply
        TestMintBurnERC20(avaxUsds).mint(AVAX_HOLDER, AVAX_USDS_BACKING);
        // NEW avax adapters: wired, rate limits 0, NOT paused, owner+delegate = OLD relay; NOT yet token wards.
        _wireAvaxRoute(avaxNewUsds,  l1NewUsds);
        _wireAvaxRoute(avaxNewSusds, l1NewSusds);
        _handToRelay(avaxNewUsds,  oldRelay);
        _handToRelay(avaxNewSusds, oldRelay);
        vm.stopPrank();
    }

    // ---- OFT/CCIP helpers (copied shape from the scripts) ----

    function _lockbox(address t) internal returns (address) {
        address impl = address(new SkyOFTAdapter(t, ENDPOINT));
        return address(new ERC1967Proxy(impl, abi.encodeWithSignature("initialize(address)", OWNER)));
    }
    function _mintBurn(address t) internal returns (address) {
        address impl = address(new SkyOFTAdapterMintBurn(t, ENDPOINT));
        return address(new ERC1967Proxy(impl, abi.encodeWithSignature("initialize(address)", OWNER)));
    }

    // Deploy CCIP adapter directly so OWNER (== clone pause proxy) is DEFAULT_ADMIN_ROLE + ADMIN_ROLE
    // (we deliberately do NOT use SendSideDeployer.handOff, which reads the REAL chainlog).
    function _deployCcip(address sender_) internal returns (address) {
        CCIPDVNAdapterFeeLib feeLib = new CCIPDVNAdapterFeeLib();
        FeeLibLike(address(feeLib)).initialize();
        FeeLibLike(address(feeLib)).renounceOwnership();

        address[] memory admins = new address[](1);
        admins[0] = OWNER;
        CCIPDVNAdapter adapter = new CCIPDVNAdapter(admins, CCIP_ROUTER);
        CCIPAdminLike a = CCIPAdminLike(address(adapter));
        a.setWorkerFeeLib(address(feeLib));
        a.setDefaultMultiplierBps(CCIP_MULTIPLIER_BPS);
        // CCIP redirect (send side): point the mainnet CCIP adapter's AVAX route at the REAL Avax CCIP
        // adapter (deployed in _deployAvaxDvnBroadcaster) and set receiveLibs[ETH_SEND_LIB][AVAX] to the
        // Avax CCIP broadcaster, so mainnet gov attestations relay over CCIP into the ccip broadcaster
        // wing. (setDstConfig fixes the peer once per chainSelector; the broadcaster machinery is
        // therefore deployed first — see setUp ordering.)
        require(avaxCcipAdapter != address(0) && ccipBroadcaster != address(0), "avax ccip machinery not deployed");
        LZDVNInit.wireCCIPDVN(address(adapter), CCIPDVNCfg({
            remoteEid:               AVAX_EID,
            remoteCcipChainSelector: AVAX_CCIP_SELECTOR,
            remoteCcipAdapter:       avaxCcipAdapter,
            remoteCcipBroadcaster:   ccipBroadcaster,
            sendLib:                 ETH_SEND_LIB,
            multiplierBps:           0,
            gas:                     200_000
        }));
        a.grantRole(MESSAGE_LIB_ROLE, ETH_SEND_LIB);
        a.grantRole(ALLOWLIST,        sender_);
        return address(adapter);
    }

    function _wireL1(address oft, address peer) internal {
        _wireRoute(oft, AVAX_EID, ETH_SEND_LIB, ETH_RECV_LIB, ETH_EXECUTOR, _ethOftDvns(), peer);
    }
    function _wireAvaxRoute(address oft, address peer) internal {
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
        opts[0] = EnforcedOptionParam(remoteEid, 1, _encodeOpts(OFT_OPTIONS_GAS));
        opts[1] = EnforcedOptionParam(remoteEid, 2, _encodeOpts(OFT_OPTIONS_GAS));
        OFTAdapterLike(oft).setEnforcedOptions(opts);
        OFTAdapterLike(oft).setPeer(remoteEid, bytes32(uint256(uint160(peer))));
    }

    // Build the OftConfig the migration's activateOft verifies against, for an already-wired OFT.
    function _oftConfig(address oft, uint32 remoteEid, address peer, address[] memory dvns, address sendLib, address recvLib)
        internal view returns (OftConfig memory cfg)
    {
        ExecutorConfig memory exec = abi.decode(EndpointLike(ENDPOINT).getConfig(oft, sendLib, remoteEid, 1), (ExecutorConfig));
        UlnConfig memory uln = UlnConfig({
            confirmations: CONFIRMATIONS, requiredDVNCount: uint8(dvns.length), optionalDVNCount: NIL_DVN_COUNT,
            optionalDVNThreshold: 0, requiredDVNs: dvns, optionalDVNs: new address[](0)
        });
        cfg = OftConfig({
            peer: peer, sendLib: sendLib, execCfg: exec, sendUlnCfg: uln,
            recvLib: recvLib, recvUlnCfg: uln, optionsGas: OFT_OPTIONS_GAS
        });
    }

    function _setRL(address oft, uint32 eid, uint256 inLimit, uint256 outLimit) internal {
        RateLimitConfig[] memory inb = new RateLimitConfig[](1);
        RateLimitConfig[] memory out = new RateLimitConfig[](1);
        inb[0] = RateLimitConfig({eid: eid, window: 1 days, limit: inLimit});
        out[0] = RateLimitConfig({eid: eid, window: 1 days, limit: outLimit});
        OFTAdapterLike(oft).setRateLimits(inb, out);
    }
    function _pauseSelf(address oft) internal { SkyOFTCore(oft).setPauser(OWNER, true); SkyOFTCore(oft).pause(); }
    function _handToRelay(address oft, address relay) internal { SkyOFTCore(oft).setDelegate(relay); SkyOFTCore(oft).transferOwnership(relay); }

    function _ethOftDvns() internal pure returns (address[] memory d) { d = new address[](4); (d[0], d[1], d[2], d[3]) = (ETH_DVN_HORIZEN, ETH_DVN_LZ_LABS, ETH_DVN_CANARY, ETH_DVN_NETHERMIND); }
    function _avaxOftDvns() internal pure returns (address[] memory d) { d = new address[](4); (d[0], d[1], d[2], d[3]) = (AVAX_DVN_HORIZEN, AVAX_DVN_LZ_LABS, AVAX_DVN_NETHERMIND, AVAX_DVN_CANARY); }

    function _ethGovSendUlnCfg() internal pure returns (UlnConfig memory) {
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
    function _avaxGovRecvUlnCfg() internal pure returns (UlnConfig memory) {
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

    // The 7 AVAX gov LZ DVNs the bridge wire installed on the receiver (sorted ascending).
    function _avaxGovRecvDvns() internal pure returns (address[] memory dvns) {
        dvns = new address[](7);
        dvns[0] = 0x07C05EaB7716AcB6f83ebF6268F8EECDA8892Ba1;
        dvns[1] = 0x962F502A63F5FBeB44DC9ab932122648E8352959;
        dvns[2] = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
        dvns[3] = 0xbe57e9E7d9eB16B92C6383792aBe28D64a18c0F1;
        dvns[4] = 0xcC49E6fca014c77E1Eb604351cc1E08C84511760;
        dvns[5] = 0xE4193136B92bA91402313e95347c8e9FAD8d27d0;
        dvns[6] = 0xE94aE34DfCC87A61836938641444080B98402c75;
    }

    function _concatAddrs(address[] memory a, address[] memory b) internal pure returns (address[] memory out) {
        out = new address[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) out[i] = a[i];
        for (uint256 i; i < b.length; ++i) out[a.length + i] = b[i];
    }

    function _sortAddrs(address[] memory arr) internal pure returns (address[] memory) {
        for (uint256 i = 1; i < arr.length; ++i) {
            address key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) { arr[j] = arr[j - 1]; --j; }
            arr[j] = key;
        }
        return arr;
    }

    function _encodeOpts(uint128 gas) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"0003", uint8(1), uint16(17), uint8(1), gas);
    }

    bytes32 constant PACKET_SENT_TOPIC = keccak256("PacketSent(bytes,bytes,address)");

    // Scan RecordedLogs for the gov PacketSent (emitted on the mainnet endpoint when migrateAvax relays
    // the L2 spell) whose header targets our Avalanche gov receiver, and return its LZ v2 packet header
    // (packet[0:81]) + payloadHash (keccak256(guid || message) == keccak256(packet[81:])).
    function _captureGovPacket(address expectReceiver) internal returns (bytes memory header, bytes32 payloadHash) {
        Vm.Log[] memory logs = RecordedLogs.getLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != PACKET_SENT_TOPIC || logs[i].emitter != ENDPOINT) continue;
            (bytes memory packet,,) = abi.decode(logs[i].data, (bytes, bytes, address));
            if (packet.length < 113) continue;
            // dstEid at [45:49], receiver low-20 at [61:81]
            uint32  dstEid   = uint32(bytes4(_slice(packet, 45, 4)));
            address receiver_ = address(bytes20(_slice(packet, 61, 20)));
            if (dstEid != AVAX_EID || receiver_ != expectReceiver) continue;
            header      = _slice(packet, 0, 81);
            payloadHash = keccak256(_slice(packet, 81, packet.length - 81));
        }
        require(header.length == 81, "gov packet not captured");
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; ++i) out[i] = data[start + i];
    }

    function _inSet(address[] memory set, address x) internal pure returns (bool) {
        for (uint256 i; i < set.length; ++i) if (set[i] == x) return true;
        return false;
    }

    // Assert an OFT's send + recv ULN both carry exactly the given required DVN set (4/4, NIL optional).
    function _assertOftRequiredDvns(address oft, uint32 eid, address sendLib, address recvLib, address[] memory dvns) internal view {
        UlnConfig memory s = UlnLike(sendLib).getAppUlnConfig(oft, eid);
        UlnConfig memory r = UlnLike(recvLib).getAppUlnConfig(oft, eid);
        assertEq(s.requiredDVNCount, dvns.length, "oft send required dvn count");
        assertEq(r.requiredDVNCount, dvns.length, "oft recv required dvn count");
        for (uint256 i; i < dvns.length; ++i) {
            assertEq(s.requiredDVNs[i], dvns[i], "oft send required dvn");
            assertEq(r.requiredDVNs[i], dvns[i], "oft recv required dvn");
        }
    }
    function _readRecvUln(address oapp, uint32 srcEid) internal view returns (UlnConfig memory) {
        (address recvLib,) = EndpointLike(ENDPOINT).getReceiveLibrary(oapp, srcEid);
        return UlnLike(recvLib).getAppUlnConfig(oapp, srcEid);
    }

    function _outLimit(address oft, uint32 eid) internal view returns (uint256 l) { (,,, l) = OFTAdapterLike(oft).outboundRateLimits(eid); }
    function _inLimit(address oft, uint32 eid)  internal view returns (uint256 l) { (,,, l) = OFTAdapterLike(oft).inboundRateLimits(eid); }
    function _outWindow(address oft, uint32 eid) internal view returns (uint48 w) { (, w,,) = OFTAdapterLike(oft).outboundRateLimits(eid); }
    function _inWindow(address oft, uint32 eid)  internal view returns (uint48 w) { (, w,,) = OFTAdapterLike(oft).inboundRateLimits(eid); }

    // ============================================================================
    //  Migration builder
    // ============================================================================

    function _insertSorted(address[] memory arr, address x) internal pure returns (address[] memory out, uint256 idx) {
        out = new address[](arr.length + 1);
        idx = arr.length;
        for (uint256 i; i < arr.length; ++i) { if (x < arr[i]) { idx = i; break; } }
        for (uint256 i; i < idx; ++i)              out[i]     = arr[i];
        out[idx] = x;
        for (uint256 i = idx; i < arr.length; ++i) out[i + 1] = arr[i];
    }

    function _zeroRL() internal pure returns (RateLimits memory r) {}

    // Must run on the mainnet fork (reads the clone gov sender's send config + clone ccip adapter).
    function _buildMigration() internal view returns (AvaxMigration memory m) {
        address sendLib = EndpointLike(OAppLike(govSender).endpoint()).getSendLibrary(govSender, AVAX_EID);
        UlnConfig memory cfg = UlnLike(sendLib).getAppUlnConfig(govSender, AVAX_EID);
        (cfg.optionalDVNs, m.ccipDvnIndex) = _insertSorted(cfg.optionalDVNs, ccipAdapter);
        cfg.optionalDVNCount     = uint8(cfg.optionalDVNs.length);   // 7 gov + CCIP = 8
        cfg.optionalDVNThreshold = 8;
        m.sendUlnCfg = cfg;

        m.newL2GovRelay     = newRelay;
        m.ccipAllowlistSize = 1;
        // USDS L1 lockbox: chosen per-eid + global caps so bridging works post-activation (mirrors the
        // real e2e test: 5M/4M per-eid AVAX, 9M/8M global). Pre-activation these are 0 (verified by
        // activateOft's _verifyOftConfig); the migration sets them.
        m.usds              = OftActivation({
            oft: l1NewUsds, cfg: usdsLockboxCfg, rlAccountingType: 0,
            rateLimits: RateLimits({inboundWindow: 1 days, inboundLimit: 5_000_000e18, outboundWindow: 1 days, outboundLimit: 4_000_000e18})
        });
        m.usdsGlobalLimits  = RateLimits({inboundWindow: 1 days, inboundLimit: 9_000_000e18, outboundWindow: 1 days, outboundLimit: 8_000_000e18});
        m.legacyCLKey       = "USDS_OFT_SOLANA";
        // sUSDS L1 lockbox: left at 0 limits (no sUSDS bridging exercised here).
        m.susds             = OftActivation({oft: l1NewSusds, cfg: susdsLockboxCfg, rateLimits: _zeroRL(), rlAccountingType: 0});
        m.susdsGlobalLimits = _zeroRL();
        m.recvUlnCfg        = newRecvUln;
        m.avaxUsds          = avaxUsdsAct;
        m.avaxSusds         = avaxSusdsAct;
        m.l2Spell           = address(l2Spell);
        m.gas               = 800_000;
        m.maxFee            = 1 ether;
    }

    // OFT send params: full amount, no slippage, enforced options apply.
    function _sendParam(uint32 dstEid, address to, uint256 amount) internal pure returns (SendParam memory) {
        return SendParam({
            dstEid: dstEid, to: bytes32(uint256(uint160(to))), amountLD: amount, minAmountLD: amount,
            extraOptions: "", composeMsg: "", oftCmd: ""
        });
    }

    // ============================================================================
    //  THE capstone test
    // ============================================================================

    function test_clone_migration_end_to_end() public {
        // ---------- 1 + 2: run migrateAvax on the mainnet fork ----------
        mainnet.selectFork();
        uint256 oldUsdsBalBefore   = TestERC20(ethUsds).balanceOf(l1OldUsds);
        bytes32 oldSusdsPeerBefore = OFTAdapterLike(l1OldSusds).peers(AVAX_EID);

        AvaxMigration memory m = _buildMigration();
        vm.deal(l1Relay, 1 ether);        // fund the clone L1 relay for the LZ fee
        vm.startPrank(OWNER);             // clone pause proxy (== chainlog MCD_PAUSE_PROXY)
        LZAvaxMigrationCloneInit.migrateAvax(m, env);
        vm.stopPrank();

        // Capture the relayed gov packet (header + payloadHash) NOW, before relayMessagesToDestination
        // consumes the PacketSent log. Used later to exercise the msig broadcaster wing on Avalanche.
        (bytes memory govHeader, bytes32 govPayloadHash) = _captureGovPacket(receiver);

        // ---------- 4a: assert the L1 half ----------
        // USDS backing moved: 10_000e18 to new lockbox, remainder back to old.
        assertEq(TestERC20(ethUsds).balanceOf(l1NewUsds), AVAX_USDS_BACKING, "new usds lockbox backing");
        assertEq(TestERC20(ethUsds).balanceOf(l1OldUsds), oldUsdsBalBefore - AVAX_USDS_BACKING, "old usds lockbox remainder");
        // old L1 USDS peer[AVAX] cleared + rate limits 0.
        assertEq(OFTAdapterLike(l1OldUsds).peers(AVAX_EID), bytes32(0), "old usds peer cleared");
        assertEq(_inLimit(l1OldUsds,  AVAX_EID), 0, "old usds inbound 0");
        assertEq(_outLimit(l1OldUsds, AVAX_EID), 0, "old usds outbound 0");
        // fake chainlog repointed + legacy key -> old L1 USDS lockbox.
        assertEq(FakeChainlog(chainlog).getAddress("USDS_OFT"),        l1NewUsds,  "USDS_OFT repointed");
        assertEq(FakeChainlog(chainlog).getAddress("USDS_OFT_SOLANA"), l1OldUsds,  "legacy key -> old lockbox");
        assertEq(FakeChainlog(chainlog).getAddress("SUSDS_OFT"),       l1NewSusds, "SUSDS_OFT repointed");
        // old sUSDS route untouched.
        assertEq(OFTAdapterLike(l1OldSusds).peers(AVAX_EID), oldSusdsPeerBefore, "old susds route intact");
        // gov send DVN set installed + relay whitelist swapped.
        address sendLib = EndpointLike(OAppLike(govSender).endpoint()).getSendLibrary(govSender, AVAX_EID);
        assertEq(keccak256(abi.encode(UlnLike(sendLib).getAppUlnConfig(govSender, AVAX_EID))),
                 keccak256(abi.encode(m.sendUlnCfg)), "gov send uln installed");
        // gov send DVN set: 8 optional / threshold 8, CCIP adapter present at its recorded index.
        {
        UlnConfig memory installedSend = UlnLike(sendLib).getAppUlnConfig(govSender, AVAX_EID);
        assertEq(installedSend.optionalDVNCount,     8, "gov send optional count 8");
        assertEq(installedSend.optionalDVNThreshold, 8, "gov send threshold 8");
        assertEq(installedSend.requiredDVNCount,     NIL_DVN_COUNT, "gov send required NIL");
        assertEq(installedSend.optionalDVNs[m.ccipDvnIndex], ccipAdapter, "ccip adapter in send set");
        }
        // migrated NEW L1 lockboxes carry the 4/4 required OFT DVN set on both send + recv libs.
        _assertOftRequiredDvns(l1NewUsds,  AVAX_EID, ETH_SEND_LIB, ETH_RECV_LIB, _ethOftDvns());
        _assertOftRequiredDvns(l1NewSusds, AVAX_EID, ETH_SEND_LIB, ETH_RECV_LIB, _ethOftDvns());
        assertTrue (GovSenderLike(govSender).canCallTarget(l1Relay, AVAX_EID, bytes32(uint256(uint160(newRelay)))),  "new relay whitelisted");
        assertFalse(GovSenderLike(govSender).canCallTarget(l1Relay, AVAX_EID, bytes32(uint256(uint160(oldRelay)))), "old relay de-whitelisted");

        // ---------- 3: force-deliver the relayed L2 spell ----------
        // Force-delivery makes the receiver forward into the OLD relay, which QUEUES the spell as
        // actionId 0 (delay 0 => immediately Ready). Unlike the real OLD relay used in
        // LZAvaxMigrationClone.t.sol, this mock relay separates queue from execution, so we exec it.
        bridge.relayMessagesToDestination(true, govSender, receiver);
        avalanche.selectFork();
        L2GovernanceRelay(oldRelay).exec(0);

        // ---------- 4b: assert the Avalanche half ----------
        // new adapters activated: per-eid rate limits set.
        assertEq(_inLimit(avaxNewUsds,   ETH_EID), avaxUsdsAct.rateLimits.inboundLimit,   "avax new usds inbound");
        assertEq(_inWindow(avaxNewUsds,  ETH_EID), avaxUsdsAct.rateLimits.inboundWindow,  "avax new usds inbound window");
        assertEq(_outLimit(avaxNewUsds,  ETH_EID), avaxUsdsAct.rateLimits.outboundLimit,  "avax new usds outbound");
        assertEq(_outWindow(avaxNewUsds, ETH_EID), avaxUsdsAct.rateLimits.outboundWindow, "avax new usds outbound window");
        assertEq(_inLimit(avaxNewSusds,  ETH_EID), avaxSusdsAct.rateLimits.inboundLimit,  "avax new susds inbound");
        assertEq(_outLimit(avaxNewSusds, ETH_EID), avaxSusdsAct.rateLimits.outboundLimit, "avax new susds outbound");
        // receiver holds the new 8-of-15 recv config, with all 4 ccip + 4 msig replicas present.
        {
        UlnConfig memory installedRecv = _readRecvUln(receiver, ETH_EID);
        assertEq(keccak256(abi.encode(installedRecv)), keccak256(abi.encode(newRecvUln)), "recv uln installed");
        assertEq(installedRecv.optionalDVNCount,     15, "recv optional count 15");
        assertEq(installedRecv.optionalDVNThreshold, 8,  "recv threshold 8");
        assertEq(installedRecv.requiredDVNCount,     NIL_DVN_COUNT, "recv required NIL");
        for (uint256 i; i < ccipReplicas.length; ++i) assertTrue(_inSet(installedRecv.optionalDVNs, ccipReplicas[i]), "ccip replica in recv set");
        for (uint256 i; i < msigReplicas.length; ++i) assertTrue(_inSet(installedRecv.optionalDVNs, msigReplicas[i]), "msig replica in recv set");
        }
        // avax new adapters carry the 4/4 required OFT DVN set on both send + recv libs.
        _assertOftRequiredDvns(avaxNewUsds,  ETH_EID, AVAX_SEND_LIB, AVAX_RECV_LIB, _avaxOftDvns());
        _assertOftRequiredDvns(avaxNewSusds, ETH_EID, AVAX_SEND_LIB, AVAX_RECV_LIB, _avaxOftDvns());

        // ---------- 4c: exercise the MULTISIG wing of the DVN broadcaster ----------
        // The msig broadcaster's verifier (OWNER) drives its 4 replicas, each of which attests the
        // delivered gov packet on the receiver's recv lib (ReceiveUln302.verify, msg.sender == replica).
        // The replicas are members of the installed recv set, so this is the real DVN attestation path.
        vm.prank(OWNER);
        DVNBroadcaster(msigBroadcaster).verify(govHeader, govPayloadHash, CONFIRMATIONS);
        bytes32 headerHash = keccak256(govHeader);
        for (uint256 i; i < msigReplicas.length; ++i) {
            (bool submitted, uint64 conf) = ReceiveUlnLike(AVAX_RECV_LIB).hashLookup(headerHash, govPayloadHash, msigReplicas[i]);
            assertTrue(submitted, "msig replica attestation registered on recv lib");
            assertEq(conf, CONFIRMATIONS, "msig replica attestation confirmations");
        }
        // token wards moved: new adapters + new relay relied; old adapters + old relay denied.
        assertEq(WardsLike(avaxUsds).wards(avaxNewUsds),   1, "avax usds ward new adapter");
        assertEq(WardsLike(avaxSusds).wards(avaxNewSusds), 1, "avax susds ward new adapter");
        assertEq(WardsLike(avaxUsds).wards(avaxOldUsds),   0, "avax usds deny old adapter");
        assertEq(WardsLike(avaxSusds).wards(avaxOldSusds), 0, "avax susds deny old adapter");
        assertEq(WardsLike(avaxUsds).wards(newRelay),      1, "avax usds ward new relay");
        assertEq(WardsLike(avaxSusds).wards(newRelay),     1, "avax susds ward new relay");
        assertEq(WardsLike(avaxUsds).wards(oldRelay),      0, "avax usds deny old relay");
        assertEq(WardsLike(avaxSusds).wards(oldRelay),     0, "avax susds deny old relay");
        // receiver + new adapters owned + delegated by the NEW relay.
        assertEq(OwnableLike(receiver).owner(),               newRelay, "receiver owner=new relay");
        assertEq(EndpointLike(ENDPOINT).delegates(receiver),  newRelay, "receiver delegate=new relay");
        assertEq(OFTAdapterLike(avaxNewUsds).owner(),               newRelay, "avax new usds owner=new relay");
        assertEq(EndpointLike(ENDPOINT).delegates(avaxNewUsds),     newRelay, "avax new usds delegate=new relay");
        assertEq(OFTAdapterLike(avaxNewSusds).owner(),              newRelay, "avax new susds owner=new relay");
        assertEq(EndpointLike(ENDPOINT).delegates(avaxNewSusds),    newRelay, "avax new susds delegate=new relay");

        // ---------- 5: bridge tokens through the migrated NEW adapters ----------
        mainnet.selectFork();
        address user   = makeAddr("bridgeUser");
        uint256 amount = 1000e18;
        vm.prank(OWNER);
        TestERC20(ethUsds).mint(user, amount);
        vm.deal(user, 10 ether);

        SendParam memory sp = _sendParam(AVAX_EID, user, amount);
        vm.startPrank(user);
        TestERC20(ethUsds).approve(l1NewUsds, amount);
        MessagingFee memory fee = SkyOFTAdapter(l1NewUsds).quoteSend(sp, false);
        SkyOFTAdapter(l1NewUsds).send{value: fee.nativeFee}(sp, fee, user);
        vm.stopPrank();

        // forward: locked on the new L1 lockbox (on top of the migrated backing).
        assertEq(TestERC20(ethUsds).balanceOf(user),      0, "user usds spent on L1");
        assertEq(TestERC20(ethUsds).balanceOf(l1NewUsds), AVAX_USDS_BACKING + amount, "new lockbox locked backing+amount");

        bridge.relayMessagesToDestination(true, l1NewUsds, avaxNewUsds);
        avalanche.selectFork();
        assertEq(TestMintBurnERC20(avaxUsds).balanceOf(user), amount, "user minted on avax");

        // return: burn on Avalanche -> unlock on L1.
        vm.deal(user, 10 ether);
        SendParam memory back = _sendParam(ETH_EID, user, amount);
        vm.startPrank(user);
        TestMintBurnERC20(avaxUsds).approve(avaxNewUsds, amount);
        MessagingFee memory backFee = SkyOFTAdapter(avaxNewUsds).quoteSend(back, false);
        SkyOFTAdapter(avaxNewUsds).send{value: backFee.nativeFee}(back, backFee, user);
        vm.stopPrank();
        assertEq(TestMintBurnERC20(avaxUsds).balanceOf(user), 0, "user burned on avax");

        bridge.relayMessagesToSource(true, avaxNewUsds, l1NewUsds);
        assertEq(TestERC20(ethUsds).balanceOf(user),      amount,            "user unlocked on L1");
        assertEq(TestERC20(ethUsds).balanceOf(l1NewUsds), AVAX_USDS_BACKING, "new lockbox back to backing");
    }
}
