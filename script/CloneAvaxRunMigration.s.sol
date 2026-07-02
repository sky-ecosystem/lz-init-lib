// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Script.sol";

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
    OFTAdapterLike,
    MessagingFee
} from "deploy/LZInit.sol";
import {
    AvaxMigration,
    OftActivation
} from "deploy/LZAvaxMigrationInit.sol";
import { LZAvaxMigrationCloneInit, CloneEnv } from "deploy/LZAvaxMigrationCloneInit.sol";

// --- Local views/structs for the round-trip / reclaim / exec entry points ---
// SkyOFT send parameters (matches SkyOFTAdaptersFlat.SendParam / the OFT standard).
struct SendParam {
    uint32  dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes   extraOptions;
    bytes   composeMsg;
    bytes   oftCmd;
}
// Return structs for OFT send (must match SkyOFTAdaptersFlat exactly, else forge reverts with an
// empty error while ABI-decoding the return value even though the on-chain send succeeded — the
// bug the earlier `(bytes,bytes)` return type caused on the real run).
struct MessagingReceipt {
    bytes32      guid;
    uint64       nonce;
    MessagingFee fee;
}
struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}
interface OftSendLike {
    function quoteSend(SendParam calldata sp, bool payInLzToken) external view returns (MessagingFee memory);
    function send(SendParam calldata sp, MessagingFee calldata fee, address refundAddress) external payable returns (MessagingReceipt memory, OFTReceipt memory);
}
interface MintableLike {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}
interface L2RelayExecLike   { function exec(uint256 actionId) external; }
interface L1RelayReclaimLike { function reclaim(address receiver, uint256 amount) external; }

// ============================================================================================
//  Clone L2 spell (extracted verbatim from test/CloneAvaxMigration.t.sol): delegatecalled by the
//  OLD L2GovernanceRelay, threads the CloneEnv via immutables, and calls migrateAvaxRemote.
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

/// @notice Broadcast driver for the AVAX-migration clone experiment on real mainnet + Avalanche.
///
///   Step A (AVALANCHE):  --sig "deployL2Spell()"
///       Deploys LZAvaxMigrationCloneL2Spell(env) using the clone addresses from clone.avax.json
///       (+ clone.eth.json for oldL1UsdsOft), writes its address into clone.avax.json under "l2Spell".
///
///   Step B (MAINNET):    --sig "run()"
///       Funds the clone L1 gov relay with a little ETH for the LZ fee, builds the AvaxMigration
///       struct (mirrors test/CloneAvaxMigration.t.sol::_buildMigration), and calls
///       LZAvaxMigrationCloneInit.migrateAvax(m, e) AS the EOA (== clone pause proxy == chainlog
///       MCD_PAUSE_PROXY). All migration logic runs inline; the relayed L2 spell is delivered by
///       REAL LayerZero and executed on Avalanche separately.
contract CloneAvaxRunMigration is Script {

    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    /// @dev Owner / pause-proxy stand-in. Read from the DEPLOYER env var; MUST equal the broadcasting
    ///      key's address (== FakeChainlog MCD_PAUSE_PROXY seeded by CloneAvaxBridge.deploy()).
    function _owner() internal view returns (address o) {
        o = vm.envAddress("DEPLOYER");
        require(o != address(0), "DEPLOYER env var not set");
    }

    uint32  constant ETH_EID  = 30101;
    uint32  constant AVAX_EID = 30106;

    address constant ETH_SEND_LIB  = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    address constant ETH_RECV_LIB  = 0xc02Ab410f0734EFa3F14628780e6e695156024C2;
    address constant AVAX_SEND_LIB = 0x197D1333DEA5Fe0D6600E9b396c7f1B1cFCc558a;
    address constant AVAX_RECV_LIB = 0xbf3521d309642FA9B1c91A08609505BA09752c61;

    uint64  constant CONFIRMATIONS   = 15;
    uint8   constant NIL_DVN_COUNT   = type(uint8).max;
    uint128 constant OFT_OPTIONS_GAS = 130_000;

    // Avalanche-side OFT executor for the ETH route, read once off the Avalanche endpoint
    // (getConfig(newAvaxOft, AVAX_SEND_LIB, ETH_EID, 1) => maxMessageSize 10000, this executor).
    // run() executes on mainnet and cannot read the Avalanche endpoint, so the avax adapters'
    // cfg.execCfg (verified by activateOft ON AVALANCHE inside the relayed spell) is pinned here.
    uint32  constant AVAX_EXEC_MAX_MSG = 10000;
    address constant AVAX_OFT_EXECUTOR = 0x90E595783E43eb89fF07f63d27B8430e6B44bD9c;

    // OFT DVNs (production 4-of-4 required, ascending) — must match the wired routes.
    address constant ETH_DVN_HORIZEN     = 0x380275805876Ff19055EA900CDb2B46a94ecF20D;
    address constant ETH_DVN_LZ_LABS     = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
    address constant ETH_DVN_CANARY      = 0xa4fE5A5B9A846458a70Cd0748228aED3bF65c2cd;
    address constant ETH_DVN_NETHERMIND  = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
    address constant AVAX_DVN_HORIZEN    = 0x07C05EaB7716AcB6f83ebF6268F8EECDA8892Ba1;
    address constant AVAX_DVN_LZ_LABS    = 0x962F502A63F5FBeB44DC9ab932122648E8352959;
    address constant AVAX_DVN_NETHERMIND = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;
    address constant AVAX_DVN_CANARY     = 0xcC49E6fca014c77E1Eb604351cc1E08C84511760;

    uint256 constant AVAX_USDS_BACKING = 10_000e18;

    // ETH to send to the clone L1 relay to cover the LZ relay fee (well above the maxFee below).
    uint256 constant RELAY_FUNDING = 0.05 ether;

    string constant ETH_PATH  = "script/clone.eth.json";
    string constant AVAX_PATH = "script/clone.avax.json";

    // ============================================================================
    //  Step A: deploy the L2 clone spell on Avalanche
    // ============================================================================

    function deployL2Spell() external {
        require(block.chainid == 43114, "deployL2Spell(): run on Avalanche");
        require(msg.sender == _owner(), "deployL2Spell(): sender != DEPLOYER");

        CloneEnv memory e = _env();

        vm.startBroadcast();
        LZAvaxMigrationCloneL2Spell spell = new LZAvaxMigrationCloneL2Spell(e);
        vm.stopBroadcast();

        console.log("Deployed LZAvaxMigrationCloneL2Spell:", address(spell));
        _writeAvaxSpell(address(spell));
    }

    // ============================================================================
    //  Step B: run the migration on mainnet
    // ============================================================================

    function run() external {
        require(block.chainid == 1, "run(): run on Ethereum");
        require(msg.sender == _owner(), "run(): sender != DEPLOYER");

        CloneEnv memory e = _env();
        AvaxMigration memory m = _buildMigration();

        address l1Relay = _readAddr(ETH_PATH, ".l1Relay");
        require(l1Relay != address(0), "missing l1Relay");

        vm.startBroadcast();
        // Fund the clone L1 relay for the LZ fee (migrateAvax requires l1Relay.balance >= fee).
        if (l1Relay.balance < RELAY_FUNDING) {
            (bool ok,) = l1Relay.call{value: RELAY_FUNDING - l1Relay.balance}("");
            require(ok, "relay funding failed");
        }
        LZAvaxMigrationCloneInit.migrateAvax(m, e);
        vm.stopBroadcast();

        console.log("migrateAvax broadcast complete. L1 relay balance:", l1Relay.balance);
    }

    // ============================================================================
    //  Step C: exec the queued L2 migration spell (AVALANCHE)
    //
    //  After the relayed migration message is delivered to the gov receiver, the mock OLD
    //  L2GovernanceRelay QUEUES it as actionId 0 (delay 0 => immediately Ready) rather than
    //  executing inline. This runs the queued action. Idempotent-ish: re-running after exec
    //  reverts in the relay ("action not queued"); the Makefile treats a revert here as "already
    //  executed". Verify the outcome with `make verify` regardless.
    // ============================================================================

    function execQueued() external {
        require(block.chainid == 43114, "execQueued(): run on Avalanche");
        address oldRelay = _readAddr(AVAX_PATH, ".oldRelay");
        require(oldRelay != address(0), "missing oldRelay");

        vm.startBroadcast();
        L2RelayExecLike(oldRelay).exec(0);
        vm.stopBroadcast();

        console.log("Executed queued L2 migration action 0 on OLD relay:", oldRelay);
    }

    // ============================================================================
    //  Token round-trip entry points (fold the ad-hoc cast steps from the real run)
    //
    //    sendUsdsToAvax() : MAINNET. Mint clone USDS to DEPLOYER, approve the NEW L1 USDS lockbox,
    //                       quoteSend + send `ROUNDTRIP_AMOUNT` to Avalanche (locks on L1). The
    //                       resulting PacketSent must be delivered with `deliver.sh` (Eth->Avax);
    //                       tokens then mint on the NEW Avax USDS adapter to DEPLOYER.
    //    sendUsdsBack()   : AVALANCHE. Approve the NEW Avax USDS adapter, quoteSend + send the same
    //                       amount back to Ethereum (burns on Avax). Deliver with `deliver.sh`
    //                       (Avax->Eth); tokens unlock on L1 to DEPLOYER.
    // ============================================================================

    uint256 constant ROUNDTRIP_AMOUNT = 1000e18;

    function sendUsdsToAvax() external {
        require(block.chainid == 1, "sendUsdsToAvax(): run on Ethereum");
        address deployer = _owner();
        require(msg.sender == deployer, "sendUsdsToAvax(): sender != DEPLOYER");

        address usds      = _readAddr(ETH_PATH, ".usds");
        address newL1Usds = _readAddr(ETH_PATH, ".newUsdsOft");
        require(usds != address(0) && newL1Usds != address(0), "run deploy/migrate first");

        SendParam memory sp = SendParam({
            dstEid: AVAX_EID, to: bytes32(uint256(uint160(deployer))),
            amountLD: ROUNDTRIP_AMOUNT, minAmountLD: ROUNDTRIP_AMOUNT,
            extraOptions: "", composeMsg: "", oftCmd: ""
        });

        vm.startBroadcast();
        // clone USDS is an open-mint TestERC20; mint the send amount to the deployer.
        MintableLike(usds).mint(deployer, ROUNDTRIP_AMOUNT);
        MintableLike(usds).approve(newL1Usds, ROUNDTRIP_AMOUNT);
        MessagingFee memory fee = OftSendLike(newL1Usds).quoteSend(sp, false);
        OftSendLike(newL1Usds).send{value: fee.nativeFee}(sp, fee, deployer);
        vm.stopBroadcast();

        console.log("Sent USDS Eth->Avax. amount:", ROUNDTRIP_AMOUNT);
        console.log("  L1 lockbox:", newL1Usds, " fee(wei):", fee.nativeFee);
        console.log("  DELIVER with: ./script/deliver.sh <thisTxHash> eth avax");
    }

    function sendUsdsBack() external {
        require(block.chainid == 43114, "sendUsdsBack(): run on Avalanche");
        address deployer = _owner();
        require(msg.sender == deployer, "sendUsdsBack(): sender != DEPLOYER");

        address newAvaxUsds = _readAddr(AVAX_PATH, ".newUsdsOft");
        address avaxUsds    = _readAddr(AVAX_PATH, ".usds");
        require(newAvaxUsds != address(0) && avaxUsds != address(0), "run deploy/migrate first");

        SendParam memory sp = SendParam({
            dstEid: ETH_EID, to: bytes32(uint256(uint160(deployer))),
            amountLD: ROUNDTRIP_AMOUNT, minAmountLD: ROUNDTRIP_AMOUNT,
            extraOptions: "", composeMsg: "", oftCmd: ""
        });

        vm.startBroadcast();
        MintableLike(avaxUsds).approve(newAvaxUsds, ROUNDTRIP_AMOUNT);
        MessagingFee memory fee = OftSendLike(newAvaxUsds).quoteSend(sp, false);
        OftSendLike(newAvaxUsds).send{value: fee.nativeFee}(sp, fee, deployer);
        vm.stopBroadcast();

        console.log("Sent USDS Avax->Eth. amount:", ROUNDTRIP_AMOUNT);
        console.log("  Avax adapter:", newAvaxUsds, " fee(wei):", fee.nativeFee);
        console.log("  DELIVER with: ./script/deliver.sh <thisTxHash> avax eth");
    }

    // --- sUSDS round-trip (mirror of the USDS one, through the NEW sUSDS lockbox/adapter) ---
    function sendSusdsToAvax() external {
        require(block.chainid == 1, "sendSusdsToAvax(): run on Ethereum");
        address deployer = _owner();
        require(msg.sender == deployer, "sendSusdsToAvax(): sender != DEPLOYER");

        address susds      = _readAddr(ETH_PATH, ".susds");
        address newL1Susds = _readAddr(ETH_PATH, ".newSusdsOft");
        require(susds != address(0) && newL1Susds != address(0), "run deploy/migrate first");

        SendParam memory sp = SendParam({
            dstEid: AVAX_EID, to: bytes32(uint256(uint160(deployer))),
            amountLD: ROUNDTRIP_AMOUNT, minAmountLD: ROUNDTRIP_AMOUNT,
            extraOptions: "", composeMsg: "", oftCmd: ""
        });

        vm.startBroadcast();
        MintableLike(susds).mint(deployer, ROUNDTRIP_AMOUNT);
        MintableLike(susds).approve(newL1Susds, ROUNDTRIP_AMOUNT);
        MessagingFee memory fee = OftSendLike(newL1Susds).quoteSend(sp, false);
        OftSendLike(newL1Susds).send{value: fee.nativeFee}(sp, fee, deployer);
        vm.stopBroadcast();

        console.log("Sent sUSDS Eth->Avax. amount:", ROUNDTRIP_AMOUNT);
        console.log("  L1 lockbox:", newL1Susds, " fee(wei):", fee.nativeFee);
        console.log("  DELIVER with: ./script/deliver.sh <thisTxHash> eth avax");
    }

    function sendSusdsBack() external {
        require(block.chainid == 43114, "sendSusdsBack(): run on Avalanche");
        address deployer = _owner();
        require(msg.sender == deployer, "sendSusdsBack(): sender != DEPLOYER");

        address newAvaxSusds = _readAddr(AVAX_PATH, ".newSusdsOft");
        address avaxSusds    = _readAddr(AVAX_PATH, ".susds");
        require(newAvaxSusds != address(0) && avaxSusds != address(0), "run deploy/migrate first");

        SendParam memory sp = SendParam({
            dstEid: ETH_EID, to: bytes32(uint256(uint160(deployer))),
            amountLD: ROUNDTRIP_AMOUNT, minAmountLD: ROUNDTRIP_AMOUNT,
            extraOptions: "", composeMsg: "", oftCmd: ""
        });

        vm.startBroadcast();
        MintableLike(avaxSusds).approve(newAvaxSusds, ROUNDTRIP_AMOUNT);
        MessagingFee memory fee = OftSendLike(newAvaxSusds).quoteSend(sp, false);
        OftSendLike(newAvaxSusds).send{value: fee.nativeFee}(sp, fee, deployer);
        vm.stopBroadcast();

        console.log("Sent sUSDS Avax->Eth. amount:", ROUNDTRIP_AMOUNT);
        console.log("  Avax adapter:", newAvaxSusds, " fee(wei):", fee.nativeFee);
        console.log("  DELIVER with: ./script/deliver.sh <thisTxHash> avax eth");
    }

    // ============================================================================
    //  Reclaim leftover LZ-fee funding from the clone L1 gov relay (MAINNET).
    //  The deployer is a ward of the relay (deployed it), so reclaim(deployer, balance) is authed.
    // ============================================================================

    function reclaim() external {
        require(block.chainid == 1, "reclaim(): run on Ethereum");
        address deployer = _owner();
        require(msg.sender == deployer, "reclaim(): sender != DEPLOYER");

        address l1Relay = _readAddr(ETH_PATH, ".l1Relay");
        require(l1Relay != address(0), "missing l1Relay");
        uint256 bal = l1Relay.balance;

        if (bal == 0) { console.log("L1 relay balance is 0, nothing to reclaim"); return; }

        vm.startBroadcast();
        L1RelayReclaimLike(l1Relay).reclaim(deployer, bal);
        vm.stopBroadcast();

        console.log("Reclaimed from L1 relay to deployer (wei):", bal);
    }

    // ============================================================================
    //  CloneEnv (reads all clone addresses from the JSON files)
    // ============================================================================

    function _env() internal returns (CloneEnv memory) {
        return CloneEnv({
            chainlog:        _readAddr(ETH_PATH,  ".chainlog"),
            oldAvaxGovRelay: _readAddr(AVAX_PATH, ".oldRelay"),
            avaxGovReceiver: _readAddr(AVAX_PATH, ".receiver"),
            avaxUsds:        _readAddr(AVAX_PATH, ".usds"),
            avaxSusds:       _readAddr(AVAX_PATH, ".susds"),
            oldAvaxUsdsOft:  _readAddr(AVAX_PATH, ".oldUsdsOft"),
            oldAvaxSusdsOft: _readAddr(AVAX_PATH, ".oldSusdsOft"),
            oldL1UsdsOft:    _readAddr(ETH_PATH,  ".oldUsdsOft"),
            avaxUsdsBacking: AVAX_USDS_BACKING
        });
    }

    // ============================================================================
    //  Migration builder (mirrors test/CloneAvaxMigration.t.sol::_buildMigration + setUp)
    //  Must run on the mainnet fork/chain: reads the clone gov sender send config + ccip adapter.
    // ============================================================================

    function _buildMigration() internal returns (AvaxMigration memory m) {
        address govSender   = _readAddr(ETH_PATH, ".sender");
        address ccipAdapter = _readAddr(ETH_PATH, ".ccipAdapter");
        address l1NewUsds   = _readAddr(ETH_PATH, ".newUsdsOft");
        address l1NewSusds  = _readAddr(ETH_PATH, ".newSusdsOft");
        address avaxNewUsds  = _readAddr(AVAX_PATH, ".newUsdsOft");
        address avaxNewSusds = _readAddr(AVAX_PATH, ".newSusdsOft");
        address l2Spell     = _readAddr(AVAX_PATH, ".l2Spell");
        require(govSender != address(0) && ccipAdapter != address(0) && l2Spell != address(0), "missing addrs");

        // ---- gov send DVN set: current 7 optionalDVNs + CCIP adapter inserted (sorted) => 8, threshold 8 ----
        address sendLib = EndpointLike(OAppLike(govSender).endpoint()).getSendLibrary(govSender, AVAX_EID);
        UlnConfig memory cfg = UlnLike(sendLib).getAppUlnConfig(govSender, AVAX_EID);
        (cfg.optionalDVNs, m.ccipDvnIndex) = _insertSorted(cfg.optionalDVNs, ccipAdapter);
        cfg.optionalDVNCount     = uint8(cfg.optionalDVNs.length);
        cfg.optionalDVNThreshold = 8;
        m.sendUlnCfg = cfg;

        m.newL2GovRelay     = _readAddr(AVAX_PATH, ".newRelay");
        m.ccipAllowlistSize = 1;

        // ---- L1 USDS new lockbox activation ----
        m.usds = OftActivation({
            oft:              l1NewUsds,
            cfg:              _oftConfig(l1NewUsds, AVAX_EID, avaxNewUsds, _ethOftDvns(), ETH_SEND_LIB, ETH_RECV_LIB),
            rlAccountingType: 0,
            rateLimits:       RateLimits({inboundWindow: 1 days, inboundLimit: 5_000_000e18, outboundWindow: 1 days, outboundLimit: 4_000_000e18})
        });
        m.usdsGlobalLimits = RateLimits({inboundWindow: 1 days, inboundLimit: 9_000_000e18, outboundWindow: 1 days, outboundLimit: 8_000_000e18});
        m.legacyCLKey      = "USDS_OFT_SOLANA";

        // ---- L1 sUSDS new lockbox activation (0 limits) ----
        m.susds = OftActivation({
            oft:              l1NewSusds,
            cfg:              _oftConfig(l1NewSusds, AVAX_EID, avaxNewSusds, _ethOftDvns(), ETH_SEND_LIB, ETH_RECV_LIB),
            rateLimits:       RateLimits(0, 0, 0, 0),
            rlAccountingType: 0
        });
        m.susdsGlobalLimits = RateLimits(0, 0, 0, 0);

        // ---- gov receiver: new recv DVN set = sort(7 AVAX gov LZ DVNs ++ ccipReplicas(4) ++ msigReplicas(4))
        // = 15, threshold 8. The receiver lives on Avalanche; its replica addresses are read from
        // clone.avax.json (persisted by CloneAvaxDvnBroadcaster). setUlnConfig on Avalanche OVERWRITES the
        // receiver's recv config to this value (no verification against the prior config).
        {
        address[] memory ccipReplicas = _readAddrArr(AVAX_PATH, ".ccipReplicas");
        address[] memory msigReplicas = _readAddrArr(AVAX_PATH, ".msigReplicas");
        require(ccipReplicas.length == 4 && msigReplicas.length == 4, "run chunk 3 (CloneAvaxDvnBroadcaster) first");
        address[] memory recvDvns = _sort(_concat(_concat(_avaxGovRecvDvns(), ccipReplicas), msigReplicas));
        require(recvDvns.length == 15, "recv dvn set must be 15");
        m.recvUlnCfg = UlnConfig({
            confirmations:        CONFIRMATIONS,
            requiredDVNCount:     NIL_DVN_COUNT,
            optionalDVNCount:     15,
            optionalDVNThreshold: 8,
            requiredDVNs:         new address[](0),
            optionalDVNs:         recvDvns
        });
        }

        // ---- Avalanche new adapter activations (execCfg pinned to the avax executor; see constant) ----
        m.avaxUsds = OftActivation({
            oft:              avaxNewUsds,
            cfg:              _avaxOftConfig(l1NewUsds, _avaxOftDvns()),
            rateLimits:       RateLimits({inboundWindow: 1 hours, inboundLimit: 5_000_000e18, outboundWindow: 2 hours, outboundLimit: 4_000_000e18}),
            rlAccountingType: 0
        });
        m.avaxSusds = OftActivation({
            oft:              avaxNewSusds,
            cfg:              _avaxOftConfig(l1NewSusds, _avaxOftDvns()),
            rateLimits:       RateLimits({inboundWindow: 3 hours, inboundLimit: 3_000_000e18, outboundWindow: 4 hours, outboundLimit: 2_000_000e18}),
            rlAccountingType: 0
        });

        m.l2Spell = l2Spell;
        m.gas     = 800_000;
        m.maxFee  = 1 ether;
    }

    // ---- OftConfig for an L1 lockbox (execCfg read from the mainnet endpoint, where run() executes) ----
    function _oftConfig(address oft, uint32 remoteEid, address peer, address[] memory dvns, address sendLib, address recvLib)
        internal view returns (OftConfig memory cfg)
    {
        ExecutorConfig memory exec = abi.decode(EndpointLike(ENDPOINT).getConfig(oft, sendLib, remoteEid, 1), (ExecutorConfig));
        cfg = OftConfig({
            peer: peer, sendLib: sendLib, execCfg: exec, sendUlnCfg: _uln(dvns),
            recvLib: recvLib, recvUlnCfg: _uln(dvns), optionsGas: OFT_OPTIONS_GAS
        });
    }

    // ---- OftConfig for an Avalanche adapter (verified by activateOft ON AVALANCHE). execCfg is pinned
    //      to the avax executor read off the Avalanche endpoint, since run() cannot read it from mainnet.
    function _avaxOftConfig(address peer, address[] memory dvns) internal pure returns (OftConfig memory cfg) {
        cfg = OftConfig({
            peer:       peer,
            sendLib:    AVAX_SEND_LIB,
            execCfg:    ExecutorConfig({maxMessageSize: AVAX_EXEC_MAX_MSG, executor: AVAX_OFT_EXECUTOR}),
            sendUlnCfg: _uln(dvns),
            recvLib:    AVAX_RECV_LIB,
            recvUlnCfg: _uln(dvns),
            optionsGas: OFT_OPTIONS_GAS
        });
    }

    function _uln(address[] memory dvns) internal pure returns (UlnConfig memory) {
        return UlnConfig({
            confirmations:        CONFIRMATIONS,
            requiredDVNCount:     uint8(dvns.length),
            optionalDVNCount:     NIL_DVN_COUNT,
            optionalDVNThreshold: 0,
            requiredDVNs:         dvns,
            optionalDVNs:         new address[](0)
        });
    }

    // ============================================================================
    //  helpers
    // ============================================================================

    function _insertSorted(address[] memory arr, address x) internal pure returns (address[] memory out, uint256 idx) {
        out = new address[](arr.length + 1);
        idx = arr.length;
        for (uint256 i; i < arr.length; ++i) { if (x < arr[i]) { idx = i; break; } }
        for (uint256 i; i < idx; ++i)              out[i]     = arr[i];
        out[idx] = x;
        for (uint256 i = idx; i < arr.length; ++i) out[i + 1] = arr[i];
    }

    function _ethOftDvns() internal pure returns (address[] memory d) { d = new address[](4); (d[0], d[1], d[2], d[3]) = (ETH_DVN_HORIZEN, ETH_DVN_LZ_LABS, ETH_DVN_CANARY, ETH_DVN_NETHERMIND); }
    function _avaxOftDvns() internal pure returns (address[] memory d) { d = new address[](4); (d[0], d[1], d[2], d[3]) = (AVAX_DVN_HORIZEN, AVAX_DVN_LZ_LABS, AVAX_DVN_NETHERMIND, AVAX_DVN_CANARY); }

    // The 7 AVAX gov LZ DVNs (sorted ascending) the bridge wire installed on the receiver.
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

    function _concat(address[] memory a, address[] memory b) internal pure returns (address[] memory out) {
        out = new address[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) out[i] = a[i];
        for (uint256 i; i < b.length; ++i) out[a.length + i] = b[i];
    }

    // Insertion sort ascending (ULN302 requires strictly ascending optionalDVNs, no dupes).
    function _sort(address[] memory arr) internal pure returns (address[] memory) {
        for (uint256 i = 1; i < arr.length; ++i) {
            address key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) { arr[j] = arr[j - 1]; --j; }
            arr[j] = key;
        }
        return arr;
    }

    function _readAddrArr(string memory path, string memory key) internal returns (address[] memory) {
        try vm.readFile(path) returns (string memory raw) {
            try vm.parseJsonAddressArray(raw, key) returns (address[] memory a) { return a; }
            catch { return new address[](0); }
        } catch { return new address[](0); }
    }

    function _writeAvaxSpell(address spell) internal {
        string memory json = "avaxspell";
        vm.serializeAddress(json, "usds",        _readAddr(AVAX_PATH, ".usds"));
        vm.serializeAddress(json, "susds",       _readAddr(AVAX_PATH, ".susds"));
        vm.serializeAddress(json, "receiver",    _readAddr(AVAX_PATH, ".receiver"));
        vm.serializeAddress(json, "oldRelay",    _readAddr(AVAX_PATH, ".oldRelay"));
        vm.serializeAddress(json, "newRelay",    _readAddr(AVAX_PATH, ".newRelay"));
        vm.serializeAddress(json, "oldUsdsOft",  _readAddr(AVAX_PATH, ".oldUsdsOft"));
        vm.serializeAddress(json, "oldSusdsOft", _readAddr(AVAX_PATH, ".oldSusdsOft"));
        vm.serializeAddress(json, "newUsdsOft",  _readAddr(AVAX_PATH, ".newUsdsOft"));
        vm.serializeAddress(json, "newSusdsOft", _readAddr(AVAX_PATH, ".newSusdsOft"));
        // Preserve the DVN-broadcaster keys (CloneAvaxDvnBroadcaster runs before this step): a bare
        // re-serialize would drop avaxCcipAdapter / ccip+msig broadcasters / the 8 replica arrays,
        // and _buildMigration() then reverts "run chunk 3 first". Keep them.
        vm.serializeAddress(json, "avaxCcipAdapter", _readAddr(AVAX_PATH, ".avaxCcipAdapter"));
        vm.serializeAddress(json, "ccipBroadcaster", _readAddr(AVAX_PATH, ".ccipBroadcaster"));
        vm.serializeAddress(json, "msigBroadcaster", _readAddr(AVAX_PATH, ".msigBroadcaster"));
        vm.serializeAddress(json, "ccipReplicas",    _readAddrArr(AVAX_PATH, ".ccipReplicas"));
        vm.serializeAddress(json, "msigReplicas",    _readAddrArr(AVAX_PATH, ".msigReplicas"));
        string memory out = vm.serializeAddress(json, "l2Spell", spell);
        vm.writeJson(out, AVAX_PATH);
    }

    function _readAddr(string memory path, string memory key) internal returns (address) {
        try vm.readFile(path) returns (string memory raw) {
            try vm.parseJsonAddress(raw, key) returns (address a) { return a; }
            catch { return address(0); }
        } catch { return address(0); }
    }
}
