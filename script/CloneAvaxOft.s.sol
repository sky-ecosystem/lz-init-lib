// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Script.sol";

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
} from "test/mocks/SkyOFTAdaptersFlat.sol";
import {
    CCIPDVNCfg,
    CCIPDVNAdapter,
    CCIPDVNAdapterFeeLib,
    LZDVNInit
} from "test/mocks/SendSideDeployerFlat.sol";
import { CloneSendSideDeployer } from "test/mocks/GovCcipSideDeployers.sol";

import { FakeChainlog, TestERC20, TestMintBurnERC20 } from "script/CloneHelpers.sol";

// Role + config setters on the CCIP adapter (AccessControl + Worker + DVNAdapterBase surface).
interface CCIPAdapterAdminLike {
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function setWorkerFeeLib(address workerFeeLib) external;
    function setDefaultMultiplierBps(uint16 multiplierBps) external;
    function allowlistSize() external view returns (uint64);
    function dstConfig(uint32 eid) external view returns (uint64 chainSelector, uint16 multiplierBps, bytes memory peer, uint256 gas);
}
interface FeeLibLike {
    function initialize() external;
    function renounceOwnership() external;
}

/// @notice Chunk 2 of the Eth<->Avalanche migration CLONE experiment: adds the OFT adapters
///         (OLD V1 + NEW V2, all real audited SkyOFTAdapter/SkyOFTAdapterMintBurn behind UUPS
///         proxies) plus the CCIP send-side DVN adapter, on top of chunk 1's gov-bridge + fake
///         tokens + fake chainlog (script/CloneAvaxBridge.s.sol, addresses in clone.*.json).
///
///         Reproduces the production AVAX topology *and* the migration's activateOft
///         preconditions:
///           MAINNET:
///             - OLD L1 USDS lockbox   = SkyOFTAdapter(FakeUSDS_L1), owner=EOA, wired to OLD AVAX
///                                       USDS m/b, 2-of-2 required DVN, NOT paused, holds backing,
///                                       outbound[AVAX]=0 (frozen) / inbound[AVAX]=big.
///             - OLD L1 sUSDS lockbox  = SkyOFTAdapter(FakeSUSDS_L1), PAUSED, rate limits 0, no backing.
///             - NEW L1 USDS/sUSDS lockboxes (pre-activation: rate limits 0, NOT paused, owner==delegate==EOA).
///             - CCIP DVN adapter (deployed directly; admin handed to the clone pause-proxy EOA —
///               see _deployCcip: we deliberately do NOT use SendSideDeployer.handOff, which reads
///               the real hardcoded chainlog and would hand admin to the real pause proxy).
///             - FakeChainlog: USDS_OFT -> OLD L1 USDS lockbox, SUSDS_OFT -> OLD L1 sUSDS lockbox.
///           AVALANCHE:
///             - OLD AVAX USDS/sUSDS m/b (SkyOFTAdapterMintBurn), wired to OLD L1 lockboxes,
///               relied on their tokens (+ OLD L2 relay relied), PAUSED, owner+delegate = OLD L2 relay.
///             - NEW AVAX USDS/sUSDS m/b (pre-activation: rate limits 0, NOT paused, owner+delegate =
///               OLD L2 relay). Tokens NOT yet relied on the new adapters (the migration does that).
///
///         Owner / pause-proxy stand-in (deployer EOA): read from the DEPLOYER env var (== the
///         broadcasting key's address).
///
///         FLOW (adapters on both chains mutually reference each other, so deploy on BOTH before
///         wiring — same split as chunk 1):
///           1. deployOft() on Mainnet   -> writes L1 OLD/NEW lockboxes + CCIP into clone.eth.json
///           2. deployOft() on Avalanche -> writes AVAX OLD/NEW m/b into clone.avax.json
///           3. wireOft()   on Mainnet   -> wires L1 lockboxes (needs avax adapters), seeds backing/chainlog, hands off CCIP
///           4. wireOft()   on Avalanche -> wires AVAX adapters (needs L1 lockboxes), relies tokens, pauses old, hands to OLD relay
///
///         Usage (real run later; requires chunk 1 already deployed):
///           forge script script/CloneAvaxOft.s.sol --sig "deployOft()" --rpc-url $MAINNET_RPC_URL   --broadcast --private-key $PRIVATE_KEY
///           forge script script/CloneAvaxOft.s.sol --sig "deployOft()" --rpc-url $AVALANCHE_RPC_URL --broadcast --private-key $PRIVATE_KEY
///           forge script script/CloneAvaxOft.s.sol --sig "wireOft()"   --rpc-url $MAINNET_RPC_URL   --broadcast --private-key $PRIVATE_KEY
///           forge script script/CloneAvaxOft.s.sol --sig "wireOft()"   --rpc-url $AVALANCHE_RPC_URL --broadcast --private-key $PRIVATE_KEY
contract CloneAvaxOft is Script {

    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    /// @dev Owner / pause-proxy stand-in. Read from the DEPLOYER env var; MUST equal the broadcasting
    ///      key's address. Fresh OFT proxies are initialized with this as owner+delegate, adapters are
    ///      handed to the OLD relay, and the CCIP admin is this address (see _deployCcip).
    function _owner() internal view returns (address o) {
        o = vm.envAddress("DEPLOYER");
        require(o != address(0), "DEPLOYER env var not set");
    }

    uint32  constant ETH_EID  = 30101;
    uint32  constant AVAX_EID = 30106;

    // --- mainnet LZ infra (OFT route) ---
    address constant ETH_SEND_LIB = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    address constant ETH_RECV_LIB = 0xc02Ab410f0734EFa3F14628780e6e695156024C2;
    address constant ETH_EXECUTOR = 0x173272739Bd7Aa6e4e214714048a9fE699453059;

    // --- avalanche LZ infra (OFT route) — send lib resolved from the endpoint for the OLD avax
    //     adapter route (getSendLibrary(oldAvaxOapp, ETH_EID)); recv lib matches chunk 1. ---
    address constant AVAX_SEND_LIB = 0x197D1333DEA5Fe0D6600E9b396c7f1B1cFCc558a;
    address constant AVAX_RECV_LIB = 0xbf3521d309642FA9B1c91A08609505BA09752c61;

    // OFT enforced-option gas + required-DVN configs (4-of-4, ascending, conf 15).
    uint128 constant OPTIONS_GAS   = 130_000;
    uint64  constant CONFIRMATIONS = 15;
    uint8   constant NIL_DVN_COUNT = type(uint8).max;

    // ETH-side OFT DVNs (production 4/4 required, ascending): Horizen < LZ Labs < Canary < Nethermind
    address constant ETH_DVN_HORIZEN    = 0x380275805876Ff19055EA900CDb2B46a94ecF20D;
    address constant ETH_DVN_LZ_LABS    = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
    address constant ETH_DVN_CANARY     = 0xa4fE5A5B9A846458a70Cd0748228aED3bF65c2cd;
    address constant ETH_DVN_NETHERMIND = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
    // AVAX-side OFT DVNs (production 4/4 required, ascending): Horizen < LZ Labs < Nethermind < Canary
    address constant AVAX_DVN_HORIZEN    = 0x07C05EaB7716AcB6f83ebF6268F8EECDA8892Ba1;
    address constant AVAX_DVN_LZ_LABS    = 0x962F502A63F5FBeB44DC9ab932122648E8352959;
    address constant AVAX_DVN_NETHERMIND = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
    address constant AVAX_DVN_CANARY     = 0xcC49E6fca014c77E1Eb604351cc1E08C84511760;

    // CCIP: Avalanche C-chain selector (matches the migration + the migration-clone test).
    uint64  constant AVAX_CCIP_SELECTOR = 6433500567565415381;
    // Real mainnet CCIP router (same constant SendSideDeployer uses).
    address constant CCIP_ROUTER        = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    uint16  constant CCIP_MULTIPLIER_BPS = 10_000; // break-even (matches SendSideDeployer's default)
    // Dest-chain (Avalanche) ccipReceive exec-gas budget for the CCIP attestation message. Must cover
    // the broadcaster fanning out to its 4 DVN replicas (each -> ReceiveUln.verify). The prior hand-rolled
    // run used only 200k; the production reference (01_DeployGovBridge) uses 600k. Matches that.
    uint256 constant CCIP_RECV_GAS = 600_000;

    // CCIP adapter AccessControl role ids (recomputed; the mock declares them internal).
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");
    bytes32 constant ALLOWLIST          = keccak256("ALLOWLIST");
    bytes32 constant MESSAGE_LIB_ROLE   = keccak256("MESSAGE_LIB_ROLE");

    // Live production OLD Avalanche USDS OFT — used only as a reference to read the executor for the
    // Avax->Eth route off the endpoint at wire time (mirrors the migration test's refOft pattern),
    // rather than hardcoding a guessed executor address.
    address constant REF_AVAX_OFT = 0x4fec40719fD9a8AE3F8E20531669DEC5962D2619;

    // Clone economic parameters (fork experiment values).
    // AVAX_USDS_BACKING: the "frozen" Avalanche USDS supply minted on Avax; becomes the baked
    // AVAX_USDS_BACKING constant in the migration. L1_USDS_BACKING: the L1 lockbox seed; MUST be
    // > AVAX_USDS_BACKING (migrateLockedTokens moves it all, then only backing goes to the new box).
    uint256 constant AVAX_USDS_BACKING = 10_000e18;
    uint256 constant L1_USDS_BACKING   = 100_000e18;
    address constant AVAX_HOLDER       = 0x000000000000000000000000000000000000dEaD;

    string constant ETH_PATH  = "script/clone.eth.json";
    string constant AVAX_PATH = "script/clone.avax.json";

    // ============================================================================
    //  Step 1 & 2: deployOft
    // ============================================================================

    function deployOft() external {
        if      (block.chainid == 1)     _deployEth();
        else if (block.chainid == 43114) _deployAvax();
        else revert("CloneAvaxOft: unsupported chain (use Ethereum or Avalanche)");
    }

    function _deployEth() internal {
        require(msg.sender == _owner(), "deployOft(): sender != DEPLOYER");

        address usds  = _readAddr(ETH_PATH, ".usds");
        address susds = _readAddr(ETH_PATH, ".susds");
        require(usds != address(0) && susds != address(0), "run chunk 1 deploy() on Eth first");

        address oldUsdsOft  = _readAddr(ETH_PATH, ".oldUsdsOft");
        address oldSusdsOft = _readAddr(ETH_PATH, ".oldSusdsOft");
        address newUsdsOft  = _readAddr(ETH_PATH, ".newUsdsOft");
        address newSusdsOft = _readAddr(ETH_PATH, ".newSusdsOft");
        address ccipAdapter      = _readAddr(ETH_PATH, ".ccipAdapter");
        address ccipSendDeployer = _readAddr(ETH_PATH, ".ccipSendDeployer");

        vm.startBroadcast();

        if (oldUsdsOft == address(0))  { oldUsdsOft  = _deployLockbox(usds);  console.log("OLD L1 USDS lockbox:",  oldUsdsOft); }
        if (oldSusdsOft == address(0)) { oldSusdsOft = _deployLockbox(susds); console.log("OLD L1 sUSDS lockbox:", oldSusdsOft); }
        if (newUsdsOft == address(0))  { newUsdsOft  = _deployLockbox(usds);  console.log("NEW L1 USDS lockbox:",  newUsdsOft); }
        if (newSusdsOft == address(0)) { newSusdsOft = _deployLockbox(susds); console.log("NEW L1 sUSDS lockbox:", newSusdsOft); }

        if (ccipAdapter == address(0)) {
            address govSender = _readAddr(ETH_PATH, ".sender");
            require(govSender != address(0), "run chunk 1 deploy() on Eth first (sender)");
            (ccipAdapter, ccipSendDeployer) = _deployCcip(govSender);
            console.log("CCIP DVN adapter (bare, peer wired in wireOft):", ccipAdapter);
            console.log("CCIP send deployer:", ccipSendDeployer);
        }

        vm.stopBroadcast();

        _writeEth(oldUsdsOft, oldSusdsOft, newUsdsOft, newSusdsOft, ccipAdapter, ccipSendDeployer);
    }

    function _deployAvax() internal {
        require(msg.sender == _owner(), "deployOft(): sender != DEPLOYER");

        address usds  = _readAddr(AVAX_PATH, ".usds");
        address susds = _readAddr(AVAX_PATH, ".susds");
        require(usds != address(0) && susds != address(0), "run chunk 1 deploy() on Avax first");

        address oldUsdsOft  = _readAddr(AVAX_PATH, ".oldUsdsOft");
        address oldSusdsOft = _readAddr(AVAX_PATH, ".oldSusdsOft");
        address newUsdsOft  = _readAddr(AVAX_PATH, ".newUsdsOft");
        address newSusdsOft = _readAddr(AVAX_PATH, ".newSusdsOft");

        vm.startBroadcast();

        if (oldUsdsOft == address(0))  { oldUsdsOft  = _deployMintBurn(usds);  console.log("OLD AVAX USDS m/b:",  oldUsdsOft); }
        if (oldSusdsOft == address(0)) { oldSusdsOft = _deployMintBurn(susds); console.log("OLD AVAX sUSDS m/b:", oldSusdsOft); }
        if (newUsdsOft == address(0))  { newUsdsOft  = _deployMintBurn(usds);  console.log("NEW AVAX USDS m/b:",  newUsdsOft); }
        if (newSusdsOft == address(0)) { newSusdsOft = _deployMintBurn(susds); console.log("NEW AVAX sUSDS m/b:", newSusdsOft); }

        vm.stopBroadcast();

        _writeAvax(oldUsdsOft, oldSusdsOft, newUsdsOft, newSusdsOft);
    }

    // ============================================================================
    //  Step 3 & 4: wireOft
    // ============================================================================

    function wireOft() external {
        if      (block.chainid == 1)     _wireEth();
        else if (block.chainid == 43114) _wireAvax();
        else revert("CloneAvaxOft: unsupported chain (use Ethereum or Avalanche)");
    }

    function _wireEth() internal {
        require(msg.sender == _owner(), "wireOft(): sender != DEPLOYER");

        address chainlog = _readAddr(ETH_PATH, ".chainlog");
        address usds     = _readAddr(ETH_PATH, ".usds");
        address oldUsds  = _readAddr(ETH_PATH, ".oldUsdsOft");
        address oldSusds = _readAddr(ETH_PATH, ".oldSusdsOft");
        address newUsds  = _readAddr(ETH_PATH, ".newUsdsOft");
        address newSusds = _readAddr(ETH_PATH, ".newSusdsOft");
        require(oldUsds != address(0) && newSusds != address(0), "run deployOft() on Eth first");

        // avax peers
        address avaxOldUsds  = _readAddr(AVAX_PATH, ".oldUsdsOft");
        address avaxOldSusds = _readAddr(AVAX_PATH, ".oldSusdsOft");
        address avaxNewUsds  = _readAddr(AVAX_PATH, ".newUsdsOft");
        address avaxNewSusds = _readAddr(AVAX_PATH, ".newSusdsOft");
        require(avaxOldUsds != address(0) && avaxNewSusds != address(0), "run deployOft() on Avax first");

        // NOTE: the early-skip guard (oldUsds.peers != 0) was removed for the real run. A prior --slow
        // broadcast timed out AFTER landing oldUsds.setPeer but BEFORE the rate-limits/backing-mint and
        // the other three lockboxes, which would make the guard short-circuit a resume and leave the L1
        // side half-wired. All the endpoint/OApp/token setters below are idempotent (setting the same
        // peer/config/limit again is a no-op-in-effect), and the backing mint is guarded separately, so
        // it is safe to re-run the full body. Broadcast without --slow so all txs go out in one batch.

        vm.startBroadcast();

        // OLD L1 USDS lockbox: wire, big inbound / 0 outbound (frozen), NOT paused, holds backing, owner=EOA.
        _wireL1(oldUsds, avaxOldUsds);
        _setRateLimits(oldUsds, AVAX_EID, 5_000_000e18, 0);           // inbound big, outbound frozen
        // Guard the backing mint so a re-run (see note above) does not double-mint backing.
        if (TestERC20(usds).balanceOf(oldUsds) < L1_USDS_BACKING) {
            TestERC20(usds).mint(oldUsds, L1_USDS_BACKING - TestERC20(usds).balanceOf(oldUsds));
        }

        // OLD L1 sUSDS lockbox: wire, rate limits 0, PAUSED, 0 backing, owner=EOA.
        _wireL1(oldSusds, avaxOldSusds);
        _pauseSelf(oldSusds);

        // NEW L1 USDS/sUSDS lockboxes: wire to NEW avax peers, rate limits 0 (pre-activation),
        // NOT paused, owner==delegate==EOA, fee=0, msgInspector=0 (fresh proxy defaults).
        _wireL1(newUsds,  avaxNewUsds);
        _wireL1(newSusds, avaxNewSusds);

        // Seed FakeChainlog with the OLD L1 lockboxes under the live OFT keys.
        FakeChainlog(chainlog).setAddress("USDS_OFT",  oldUsds);
        FakeChainlog(chainlog).setAddress("SUSDS_OFT", oldSusds);

        // CCIP send-side peer wiring + admin handoff, DEFERRED here from deployOft (see _deployCcip).
        // Runs after the Avalanche recv side (chunk 3) exists, so the mainnet adapter's set-once
        // dstConfig peer is the REAL avax adapter and the whole CCIP wing is peered correctly on BOTH
        // sides. Idempotent: configure guarded on dstConfig unset, handOff guarded on deployer-still-admin.
        _configureCcip();

        vm.stopBroadcast();

        console.log("Wired L1 OFT side. OLD USDS lockbox backing:", TestERC20(usds).balanceOf(oldUsds));
    }

    /// @dev setDstConfig + setReceiveLibs (via CloneSendSideDeployer.configure) then handOff admin to the
    ///      clone pause-proxy (EOA). Called inside _wireEth's broadcast. Requires chunk 3 deployed.
    function _configureCcip() internal {
        address ccipAdapter      = _readAddr(ETH_PATH, ".ccipAdapter");
        address ccipSendDeployer = _readAddr(ETH_PATH, ".ccipSendDeployer");
        if (ccipSendDeployer == address(0)) return;   // no CCIP adapter deployed (skip)

        address avaxAdapter     = _readAddr(AVAX_PATH, ".avaxCcipAdapter");
        address avaxBroadcaster = _readAddr(AVAX_PATH, ".ccipBroadcaster");
        require(avaxAdapter != address(0) && avaxBroadcaster != address(0),
            "run CloneAvaxDvnBroadcaster (chunk 3) on Avalanche BEFORE wireOft() on Eth");

        // configure() once (setDstConfig is set-once; guard on dstConfig[AVAX_EID % 30000].chainSelector).
        (uint64 sel,,,) = CCIPAdapterAdminLike(ccipAdapter).dstConfig(AVAX_EID % 30000);
        if (sel == 0) {
            CloneSendSideDeployer(ccipSendDeployer).configure(CCIPDVNCfg({
                remoteEid:               AVAX_EID,
                remoteCcipChainSelector: AVAX_CCIP_SELECTOR,
                remoteCcipAdapter:       avaxAdapter,
                remoteCcipBroadcaster:   avaxBroadcaster,
                sendLib:                 ETH_SEND_LIB,
                multiplierBps:           0,
                gas:                     CCIP_RECV_GAS
            }));
            console.log("CCIP send adapter configured -> avax adapter/broadcaster, gas:", CCIP_RECV_GAS);
        }

        // handOff() admin to the clone pause proxy (EOA) once (guard: deployer contract still admin).
        if (CCIPAdapterAdminLike(ccipAdapter).hasRole(DEFAULT_ADMIN_ROLE, ccipSendDeployer)) {
            address[] memory none = new address[](0);
            CloneSendSideDeployer(ccipSendDeployer).handOff(_owner(), none);
            console.log("CCIP send adapter admin handed off to clone pause proxy (EOA):", _owner());
        }
    }

    function _wireAvax() internal {
        require(msg.sender == _owner(), "wireOft(): sender != DEPLOYER");

        address usds     = _readAddr(AVAX_PATH, ".usds");
        address susds    = _readAddr(AVAX_PATH, ".susds");
        address oldRelay = _readAddr(AVAX_PATH, ".oldRelay");
        address oldUsds  = _readAddr(AVAX_PATH, ".oldUsdsOft");
        address oldSusds = _readAddr(AVAX_PATH, ".oldSusdsOft");
        address newUsds  = _readAddr(AVAX_PATH, ".newUsdsOft");
        address newSusds = _readAddr(AVAX_PATH, ".newSusdsOft");
        require(oldRelay != address(0), "run chunk 1 deploy() on Avax first (oldRelay)");
        require(oldUsds != address(0) && newSusds != address(0), "run deployOft() on Avax first");

        // l1 peers
        address l1OldUsds  = _readAddr(ETH_PATH, ".oldUsdsOft");
        address l1OldSusds = _readAddr(ETH_PATH, ".oldSusdsOft");
        address l1NewUsds  = _readAddr(ETH_PATH, ".newUsdsOft");
        address l1NewSusds = _readAddr(ETH_PATH, ".newSusdsOft");
        require(l1OldUsds != address(0) && l1NewSusds != address(0), "run deployOft() on Eth first");

        if (OFTAdapterLike(oldUsds).peers(ETH_EID) != bytes32(0)) { console.log("AVAX OFT already wired, skipping"); return; }

        vm.startBroadcast();

        // OLD AVAX USDS/sUSDS m/b: wire to OLD L1 lockboxes, rely on tokens (mint/burn ward),
        // rely OLD relay too (old relay is a token ward in production), PAUSED, owner+delegate = OLD relay.
        _wireAvaxOft(oldUsds,  l1OldUsds);
        _wireAvaxOft(oldSusds, l1OldSusds);
        TestMintBurnERC20(usds).rely(oldUsds);
        TestMintBurnERC20(susds).rely(oldSusds);
        TestMintBurnERC20(usds).rely(oldRelay);
        TestMintBurnERC20(susds).rely(oldRelay);
        _pauseSelf(oldUsds);
        _pauseSelf(oldSusds);
        _handToRelay(oldUsds,  oldRelay);
        _handToRelay(oldSusds, oldRelay);

        // Mint the "frozen avax USDS supply" (becomes AVAX_USDS_BACKING) to a holder; sUSDS supply 0.
        TestMintBurnERC20(usds).mint(AVAX_HOLDER, AVAX_USDS_BACKING);

        // NEW AVAX USDS/sUSDS m/b: wire to NEW L1 lockboxes, rate limits 0 (pre-activation),
        // NOT paused, owner+delegate = OLD relay (the migration's activateOft on the L2 side requires
        // owner==delegate==msg.sender==OLD relay; migrateAvaxRemote then hands to the new relay).
        // Do NOT rely the new adapters on the tokens yet (the migration does that).
        _wireAvaxOft(newUsds,  l1NewUsds);
        _wireAvaxOft(newSusds, l1NewSusds);
        _handToRelay(newUsds,  oldRelay);
        _handToRelay(newSusds, oldRelay);

        vm.stopBroadcast();

        console.log("Wired AVAX OFT side. Frozen avax USDS supply minted:", AVAX_USDS_BACKING);
    }

    // ============================================================================
    //  Deploy helpers
    // ============================================================================

    function _deployLockbox(address token_) internal returns (address) {
        address impl = address(new SkyOFTAdapter(token_, ENDPOINT));
        return address(new ERC1967Proxy(impl, abi.encodeWithSignature("initialize(address)", _owner())));
    }

    function _deployMintBurn(address token_) internal returns (address) {
        address impl = address(new SkyOFTAdapterMintBurn(token_, ENDPOINT));
        return address(new ERC1967Proxy(impl, abi.encodeWithSignature("initialize(address)", _owner())));
    }

    /// @dev Deploy the mainnet CCIP DVN adapter via the REAL CloneSendSideDeployer constructor (a
    ///      faithful copy of production SendSideDeployer, differing only in a parameterized handOff — see
    ///      test/mocks/GovCcipSideDeployers.sol). The CONSTRUCTOR only DEPLOYS the adapter: fresh feeLib
    ///      (initialize tolerated), CCIP_ROUTER, MESSAGE_LIB_ROLE(sendLib), ALLOWLIST(govSender),
    ///      DEFAULT_ADMIN/ADMIN held by the deployer contract. It does NOT set the remote peer.
    ///
    ///      Peer wiring (setDstConfig + setReceiveLibs) is deferred to wireOft() via
    ///      CloneSendSideDeployer.configure(), which runs AFTER the Avalanche recv side (chunk 3) exists.
    ///      This is the FIX for the recv-side set-once `0xdead` placeholder bug: the mainnet adapter's
    ///      dstConfig peer is only ever written with the REAL avax adapter, and — critically — the AVAX
    ///      adapter's srcConfig peer is written by RecvSideDeployer with the REAL mainnet adapter (which
    ///      exists by then). Neither side ever bakes a placeholder.
    ///
    ///      Returns (adapter, sendDeployer). The sendDeployer is persisted so wireOft() can call
    ///      configure()/handOff() on it (both onlyDeployer == this broadcasting EOA).
    function _deployCcip(address govSender) internal returns (address, address) {
        address[] memory allowed = new address[](1);
        allowed[0] = govSender;
        CloneSendSideDeployer d = new CloneSendSideDeployer(ETH_SEND_LIB, allowed);
        return (address(d.adapter()), address(d));
    }

    // ============================================================================
    //  Wiring helpers (raw endpoint/OApp calls, msg.sender == OWNER == owner+delegate of a fresh proxy)
    // ============================================================================

    // L1 lockbox route (Avalanche side): 4-of-4 required ETH DVNs.
    function _wireL1(address oft, address peer) internal {
        _wireRoute(oft, AVAX_EID, ETH_SEND_LIB, ETH_RECV_LIB, ETH_EXECUTOR, _ethOftDvns(), peer);
    }

    // AVAX remote route (Ethereum side): 4-of-4 required AVAX DVNs; executor read at wire time off
    // the live production OLD avax OFT route via the send lib (refOft pattern).
    function _wireAvaxOft(address oft, address peer) internal {
        address exec = abi.decode(
            EndpointLike(ENDPOINT).getConfig(REF_AVAX_OFT, AVAX_SEND_LIB, ETH_EID, 1),
            (ExecutorConfig)
        ).executor;
        _wireRoute(oft, ETH_EID, AVAX_SEND_LIB, AVAX_RECV_LIB, exec, _avaxOftDvns(), peer);
    }

    function _wireRoute(
        address oft,
        uint32  remoteEid,
        address sendLib,
        address recvLib,
        address executor,
        address[] memory dvns,
        address peer
    ) internal {
        // Per-OFT idempotency guard: the LZ endpoint's setSendLibrary reverts (custom error 0xd0ecb66b)
        // if the send lib is already set to the same value. A prior --slow run timed out mid-wire with
        // one lockbox's route already fully set (incl. setPeer), so skip any OFT already peered to its
        // target — its route calls are done. Remaining per-lockbox state (rate limits, pause, backing)
        // lives in _wireEth/_wireAvax and is applied idempotently there.
        if (OFTAdapterLike(oft).peers(remoteEid) == bytes32(uint256(uint160(peer)))) return;

        UlnConfig memory uln = UlnConfig({
            confirmations:        CONFIRMATIONS,
            requiredDVNCount:     uint8(dvns.length),
            optionalDVNCount:     NIL_DVN_COUNT,
            optionalDVNThreshold: 0,
            requiredDVNs:         dvns,
            optionalDVNs:         new address[](0)
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

    function _setRateLimits(address oft, uint32 eid, uint256 inLimit, uint256 outLimit) internal {
        RateLimitConfig[] memory inb = new RateLimitConfig[](1);
        RateLimitConfig[] memory out = new RateLimitConfig[](1);
        inb[0] = RateLimitConfig({eid: eid, window: 1 days, limit: inLimit});
        out[0] = RateLimitConfig({eid: eid, window: 1 days, limit: outLimit});
        OFTAdapterLike(oft).setRateLimits(inb, out);
    }

    // Make OWNER a pauser then pause the adapter (must run while OWNER still owns it).
    // Guarded for re-run safety: setPauser reverts (PauserIdempotent) if the flag is already set, and
    // pause() reverts if already paused. A prior timed-out run may have paused some adapters already.
    function _pauseSelf(address oft) internal {
        address OWNER = _owner();
        if (!SkyOFTCore(oft).pausers(OWNER)) SkyOFTCore(oft).setPauser(OWNER, true);
        if (!SkyOFTCore(oft).paused())       SkyOFTCore(oft).pause();
    }

    function _handToRelay(address oft, address relay) internal {
        SkyOFTCore(oft).setDelegate(relay);
        SkyOFTCore(oft).transferOwnership(relay);
    }

    function _ethOftDvns() internal pure returns (address[] memory d) {
        d = new address[](4);
        (d[0], d[1], d[2], d[3]) = (ETH_DVN_HORIZEN, ETH_DVN_LZ_LABS, ETH_DVN_CANARY, ETH_DVN_NETHERMIND);   // ascending
    }
    function _avaxOftDvns() internal pure returns (address[] memory d) {
        d = new address[](4);
        (d[0], d[1], d[2], d[3]) = (AVAX_DVN_HORIZEN, AVAX_DVN_LZ_LABS, AVAX_DVN_NETHERMIND, AVAX_DVN_CANARY); // ascending
    }

    function _encodeOpts(uint128 gas) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"0003", uint8(1), uint16(17), uint8(1), gas);
    }

    // ============================================================================
    //  JSON helpers (merge new keys into the existing clone.*.json from chunk 1)
    // ============================================================================

    function _writeEth(address oldUsds, address oldSusds, address newUsds, address newSusds, address ccip, address ccipDeployer) internal {
        string memory json = "ethoft";
        vm.serializeAddress(json, "chainlog", _readAddr(ETH_PATH, ".chainlog"));
        vm.serializeAddress(json, "usds",     _readAddr(ETH_PATH, ".usds"));
        vm.serializeAddress(json, "susds",    _readAddr(ETH_PATH, ".susds"));
        vm.serializeAddress(json, "sender",   _readAddr(ETH_PATH, ".sender"));
        vm.serializeAddress(json, "l1Relay",  _readAddr(ETH_PATH, ".l1Relay"));
        vm.serializeAddress(json, "oldUsdsOft",  oldUsds);
        vm.serializeAddress(json, "oldSusdsOft", oldSusds);
        vm.serializeAddress(json, "newUsdsOft",  newUsds);
        vm.serializeAddress(json, "newSusdsOft", newSusds);
        vm.serializeAddress(json, "ccipAdapter", ccip);
        string memory out = vm.serializeAddress(json, "ccipSendDeployer", ccipDeployer);
        vm.writeJson(out, ETH_PATH);
    }

    function _writeAvax(address oldUsds, address oldSusds, address newUsds, address newSusds) internal {
        string memory json = "avaxoft";
        vm.serializeAddress(json, "usds",     _readAddr(AVAX_PATH, ".usds"));
        vm.serializeAddress(json, "susds",    _readAddr(AVAX_PATH, ".susds"));
        vm.serializeAddress(json, "receiver", _readAddr(AVAX_PATH, ".receiver"));
        vm.serializeAddress(json, "oldRelay", _readAddr(AVAX_PATH, ".oldRelay"));
        vm.serializeAddress(json, "newRelay", _readAddr(AVAX_PATH, ".newRelay"));
        vm.serializeAddress(json, "oldUsdsOft",  oldUsds);
        vm.serializeAddress(json, "oldSusdsOft", oldSusds);
        vm.serializeAddress(json, "newUsdsOft",  newUsds);
        string memory out = vm.serializeAddress(json, "newSusdsOft", newSusds);
        vm.writeJson(out, AVAX_PATH);
    }

    function _readAddr(string memory path, string memory key) internal returns (address) {
        try vm.readFile(path) returns (string memory raw) {
            try vm.parseJsonAddress(raw, key) returns (address a) { return a; }
            catch { return address(0); }
        } catch { return address(0); }
    }
}
