// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Script.sol";

import {
    SetConfigParam,
    UlnConfig,
    ExecutorConfig,
    EnforcedOptionParam,
    EndpointLike,
    OAppLike
} from "deploy/LZInit.sol";

import {
    GovernanceOAppSender,
    GovernanceOAppReceiver,
    L1GovernanceRelay
} from "test/mocks/GovBridgeFlat.sol";
import { L2GovernanceRelay } from "test/mocks/L2GovernanceRelay.sol";

import { FakeChainlog, TestERC20, TestMintBurnERC20 } from "script/CloneHelpers.sol";

/// @notice Deploys + wires a real-mainnet <-> real-Avalanche CLONE of the Sky LZ
///         gov-bridge (GovernanceOAppSender/Receiver + L1/L2GovernanceRelay clones)
///         plus fake tokens and a fake chainlog, for the Eth(30101) <-> Avax(30106) pair.
///
///         This is the standalone gov-bridge scaffold that a later step runs the AVAX
///         migration against. It reproduces the production topology:
///           MAINNET: sender + L1 relay (+ fake USDS/sUSDS lockbox tokens + fake chainlog)
///           AVAX:    receiver + OLD L2 relay (owns receiver) + NEW L2 relay
///                    (+ fake mint/burn USDS/sUSDS)
///
///         Owner / pause-proxy stand-in (deployer EOA): read from the DEPLOYER env var, which MUST
///         equal the broadcasting key's address (--private-key / keystore). Every deploy sets this
///         address as owner/delegate and seeds it as FakeChainlog MCD_PAUSE_PROXY.
///
///         FLOW (run per chain; --sig steps are idempotent and skip if already done):
///           1. deploy()  on Mainnet   -> writes script/clone.eth.json
///           2. deploy()  on Avalanche -> reads clone.eth.json (sender), writes clone.avax.json
///           3. wire()    on Mainnet   -> wires SEND side (needs avax receiver from clone.avax.json)
///           4. wire()    on Avalanche -> wires RECV side + hands receiver to OLD L2 relay
///
///         Usage (real run later):
///           forge script script/CloneAvaxBridge.s.sol --sig "deploy()" \
///               --rpc-url $MAINNET_RPC_URL   --broadcast --private-key $PRIVATE_KEY
///           forge script script/CloneAvaxBridge.s.sol --sig "deploy()" \
///               --rpc-url $AVALANCHE_RPC_URL --broadcast --private-key $PRIVATE_KEY
///           forge script script/CloneAvaxBridge.s.sol --sig "wire()" \
///               --rpc-url $MAINNET_RPC_URL   --broadcast --private-key $PRIVATE_KEY
///           forge script script/CloneAvaxBridge.s.sol --sig "wire()" \
///               --rpc-url $AVALANCHE_RPC_URL --broadcast --private-key $PRIVATE_KEY
contract CloneAvaxBridge is Script {

    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c; // canonical on both chains

    /// @dev Owner / pause-proxy stand-in. Read from the DEPLOYER env var; MUST equal the broadcasting
    ///      key's address so the require() in each entry point passes. Replaces the old hardcoded EOA.
    function _owner() internal view returns (address o) {
        o = vm.envAddress("DEPLOYER");
        require(o != address(0), "DEPLOYER env var not set");
    }

    uint32  constant ETH_EID  = 30101;
    uint32  constant AVAX_EID = 30106;

    // --- SEND side (mainnet) LZ infra ---
    address constant ETH_SEND_LIB = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    address constant ETH_EXECUTOR = 0x173272739Bd7Aa6e4e214714048a9fE699453059;

    // --- RECV side (avalanche) LZ infra ---
    address constant AVAX_RECV_LIB = 0xbf3521d309642FA9B1c91A08609505BA09752c61;

    uint64  constant CONFIRMATIONS     = 15;
    uint8   constant NIL_DVN_COUNT     = type(uint8).max; // 255: NIL sentinel -> zero required DVNs
    uint32  constant EXECUTOR_CFG_TYPE = 1;
    uint32  constant ULN_CFG_TYPE      = 2;
    uint128 constant LZRECEIVE_GAS     = 130_000;
    uint16  constant MSG_TYPE_SEND     = 1;

    // OLD L2 relay is the pre-timelock instance in production; the clone uses the same
    // (timelock-capable) contract with delay 0. NEW relay carries the migration timelock.
    uint256 constant OLD_DELAY        = 0;
    uint256 constant OLD_GRACE_PERIOD = 7 days;

    string constant ETH_PATH  = "script/clone.eth.json";
    string constant AVAX_PATH = "script/clone.avax.json";

    // ============================================================================
    //  Step 1 & 2: deploy
    // ============================================================================

    function deploy() external {
        if      (block.chainid == 1)     _deployEth();
        else if (block.chainid == 43114) _deployAvax();
        else revert("CloneAvaxBridge: unsupported chain (use Ethereum or Avalanche)");
    }

    function _deployEth() internal {
        address OWNER = _owner();
        require(msg.sender == OWNER, "deploy(): sender != DEPLOYER");

        address chainlog  = _readAddr(ETH_PATH, ".chainlog");
        address usds      = _readAddr(ETH_PATH, ".usds");
        address susds     = _readAddr(ETH_PATH, ".susds");
        address sender    = _readAddr(ETH_PATH, ".sender");
        address l1Relay   = _readAddr(ETH_PATH, ".l1Relay");

        vm.startBroadcast();

        if (chainlog == address(0)) {
            chainlog = address(new FakeChainlog());
            console.log("Deployed FakeChainlog:", chainlog);
        }
        if (usds == address(0)) {
            usds = address(new TestERC20("Fake USDS", "fUSDS"));
            console.log("Deployed FakeUSDS (plain ERC20):", usds);
        }
        if (susds == address(0)) {
            susds = address(new TestERC20("Fake sUSDS", "fsUSDS"));
            console.log("Deployed FakeSUSDS (plain ERC20):", susds);
        }
        if (sender == address(0)) {
            sender = address(new GovernanceOAppSender(ENDPOINT, OWNER));
            console.log("Deployed GovernanceOAppSender:", sender);
        }
        if (l1Relay == address(0)) {
            L1GovernanceRelay relay = new L1GovernanceRelay();
            relay.file("l1Oapp", sender);
            l1Relay = address(relay);
            console.log("Deployed L1GovernanceRelay:", l1Relay);
        }

        // Seed the fake chainlog with the keys the migration lib reads on L1.
        FakeChainlog(chainlog).setAddress("MCD_PAUSE_PROXY", OWNER);
        FakeChainlog(chainlog).setAddress("LZ_GOV_SENDER",   sender);
        FakeChainlog(chainlog).setAddress("LZ_GOV_RELAY",    l1Relay);
        FakeChainlog(chainlog).setAddress("USDS",            usds);
        FakeChainlog(chainlog).setAddress("SUSDS",           susds);

        vm.stopBroadcast();

        string memory json = "eth";
        vm.serializeAddress(json, "chainlog", chainlog);
        vm.serializeAddress(json, "usds",     usds);
        vm.serializeAddress(json, "susds",    susds);
        vm.serializeAddress(json, "sender",   sender);
        string memory out = vm.serializeAddress(json, "l1Relay", l1Relay);
        vm.writeJson(out, ETH_PATH);
    }

    function _deployAvax() internal {
        address OWNER = _owner();
        require(msg.sender == OWNER, "deploy(): sender != DEPLOYER");

        address sender = _readAddr(ETH_PATH, ".sender");
        require(sender != address(0), "deploy Eth side first");

        address usds     = _readAddr(AVAX_PATH, ".usds");
        address susds    = _readAddr(AVAX_PATH, ".susds");
        address receiver = _readAddr(AVAX_PATH, ".receiver");
        address oldRelay = _readAddr(AVAX_PATH, ".oldRelay");
        address newRelay = _readAddr(AVAX_PATH, ".newRelay");

        vm.startBroadcast();

        if (usds == address(0)) {
            usds = address(new TestMintBurnERC20("Fake USDS", "fUSDS"));
            console.log("Deployed FakeUSDS (mint/burn):", usds);
        }
        if (susds == address(0)) {
            susds = address(new TestMintBurnERC20("Fake sUSDS", "fsUSDS"));
            console.log("Deployed FakeSUSDS (mint/burn):", susds);
        }
        if (receiver == address(0)) {
            receiver = address(new GovernanceOAppReceiver(
                ETH_EID,
                bytes32(uint256(uint160(sender))),
                ENDPOINT,
                OWNER
            ));
            console.log("Deployed GovernanceOAppReceiver:", receiver);
        }
        // Both relays must trust the mainnet L1 gov relay as srcSender (L2GovernanceRelay.messageAuth
        // requires _origin.sender == l1GovernanceRelay). Deploying the OLD relay with address(0) here
        // caused the relayed migration spell to revert `L2GovernanceRelay/bad-message-auth` — the real
        // OLD_AVAX_GOV_RELAY has l1GovernanceRelay == 0x2beB…7D61.
        address l1Relay = _readAddr(ETH_PATH, ".l1Relay");
        if (oldRelay == address(0)) {
            oldRelay = address(new L2GovernanceRelay(
                ETH_EID, receiver, l1Relay, OLD_DELAY, OLD_GRACE_PERIOD, new address[](0)
            ));
            console.log("Deployed OLD L2GovernanceRelay:", oldRelay);
        }
        if (newRelay == address(0)) {
            newRelay = address(new L2GovernanceRelay(
                ETH_EID, receiver, l1Relay, 1 days, 7 days, new address[](0)
            ));
            console.log("Deployed NEW L2GovernanceRelay:", newRelay);
        }

        vm.stopBroadcast();

        string memory json = "avax";
        vm.serializeAddress(json, "usds",     usds);
        vm.serializeAddress(json, "susds",    susds);
        vm.serializeAddress(json, "receiver", receiver);
        vm.serializeAddress(json, "oldRelay", oldRelay);
        string memory out = vm.serializeAddress(json, "newRelay", newRelay);
        vm.writeJson(out, AVAX_PATH);
    }

    // ============================================================================
    //  Step 3 & 4: wire
    // ============================================================================

    function wire() external {
        if      (block.chainid == 1)     _wireEth();
        else if (block.chainid == 43114) _wireAvax();
        else revert("CloneAvaxBridge: unsupported chain (use Ethereum or Avalanche)");
    }

    /// @dev SEND side on mainnet. The on-branch LZInit.wireGovPeer reads addresses from the
    ///      real hardcoded chainlog, so for a fresh clone we replicate its _wireSend body with
    ///      raw endpoint/OApp calls against our own sender.
    function _wireEth() internal {
        require(msg.sender == _owner(), "wire(): sender != DEPLOYER");

        address sender   = _readAddr(ETH_PATH, ".sender");
        address l1Relay  = _readAddr(ETH_PATH, ".l1Relay");
        require(sender != address(0) && l1Relay != address(0), "deploy Eth side first");

        address receiver = _readAddr(AVAX_PATH, ".receiver");
        address newRelay = _readAddr(AVAX_PATH, ".newRelay");
        address oldRelay = _readAddr(AVAX_PATH, ".oldRelay");
        require(receiver != address(0) && newRelay != address(0) && oldRelay != address(0), "deploy Avax side first");

        bytes32 peer = bytes32(uint256(uint160(receiver)));
        if (OAppLike(sender).peers(AVAX_EID) == peer) {
            console.log("Send side already wired, skipping");
            return;
        }

        vm.startBroadcast();

        // setPeer + setSendLibrary + send ULN/executor config
        OAppLike(sender).setPeer(AVAX_EID, peer);
        EndpointLike(ENDPOINT).setSendLibrary(sender, AVAX_EID, ETH_SEND_LIB);

        SetConfigParam[] memory sendParams = new SetConfigParam[](2);
        sendParams[0] = SetConfigParam(
            AVAX_EID, EXECUTOR_CFG_TYPE,
            abi.encode(ExecutorConfig({maxMessageSize: 10000, executor: ETH_EXECUTOR}))
        );
        sendParams[1] = SetConfigParam(AVAX_EID, ULN_CFG_TYPE, abi.encode(_ethSendUlnCfg()));
        EndpointLike(ENDPOINT).setConfig(sender, ETH_SEND_LIB, sendParams);

        // enforced lzReceive gas for the gov message type
        _setEnforcedGovOption(sender, AVAX_EID);

        // whitelist L1 relay -> OLD L2 relay target on the sender. The migration relays its own L2
        // spell THROUGH the old relay (before flipping the whitelist to the new one), so the
        // pre-migration state must allow the OLD target — mirrors production (OLD==true/NEW==false
        // before migrateAvax). Whitelisting NEW here reverted the migration's relay with CannotCallTarget().
        GovSenderClone(sender).setCanCallTarget(l1Relay, AVAX_EID, bytes32(uint256(uint160(oldRelay))), true);

        vm.stopBroadcast();

        console.log("Wired SEND side: sender", sender, "-> avax receiver", receiver);
    }

    /// @dev RECV side on avalanche + hand receiver ownership/delegate to the OLD L2 relay.
    function _wireAvax() internal {
        require(msg.sender == _owner(), "wire(): sender != DEPLOYER");

        address receiver = _readAddr(AVAX_PATH, ".receiver");
        address oldRelay = _readAddr(AVAX_PATH, ".oldRelay");
        require(receiver != address(0) && oldRelay != address(0), "deploy Avax side first");

        if (GovReceiverClone(receiver).owner() == oldRelay) {
            console.log("Recv side already wired, skipping");
            return;
        }

        vm.startBroadcast();

        EndpointLike(ENDPOINT).setReceiveLibrary(receiver, ETH_EID, AVAX_RECV_LIB, 0);
        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam(ETH_EID, ULN_CFG_TYPE, abi.encode(_avaxRecvUlnCfg()));
        EndpointLike(ENDPOINT).setConfig(receiver, AVAX_RECV_LIB, recvParams);

        // hand LZ delegate + ownership to the OLD L2 relay (mirrors production)
        GovReceiverClone(receiver).setDelegate(oldRelay);
        GovReceiverClone(receiver).transferOwnership(oldRelay);

        vm.stopBroadcast();

        console.log("Wired RECV side + handed receiver to OLD L2 relay:", oldRelay);
    }

    // ============================================================================
    //  ULN configs: NIL required + 4-of-7 OPTIONAL real LZ DVNs, conf 15 (mirrors
    //  production + the Eth<->Base gov clone). The migration's _checkDvnOverlap
    //  requires the current gov send config to carry >=4 optional DVNs.
    //  optionalDVNs MUST be strictly ascending by address (ULN302 rejects otherwise).
    // ============================================================================

    function _ethSendUlnCfg() internal pure returns (UlnConfig memory) {
        address[] memory dvns = new address[](7);
        dvns[0] = 0x06559EE34D85a88317Bf0bfE307444116c631b67; // P2P
        dvns[1] = 0x373a6E5c0C4E89E24819f00AA37ea370917AAfF4; // Deutsche Telekom
        dvns[2] = 0x380275805876Ff19055EA900CDb2B46a94ecF20D; // Horizen
        dvns[3] = 0x58249a2Ec05c1978bF21DF1f5eC1847e42455CF4; // Luganodes
        dvns[4] = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b; // LayerZero Labs
        dvns[5] = 0xa4fE5A5B9A846458a70Cd0748228aED3bF65c2cd; // Canary
        dvns[6] = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5; // Nethermind
        return UlnConfig({
            confirmations:        CONFIRMATIONS,
            requiredDVNCount:     NIL_DVN_COUNT,
            optionalDVNCount:     7,
            optionalDVNThreshold: 4,
            requiredDVNs:         new address[](0),
            optionalDVNs:         dvns
        });
    }

    function _avaxRecvUlnCfg() internal pure returns (UlnConfig memory) {
        address[] memory dvns = new address[](7);
        dvns[0] = 0x07C05EaB7716AcB6f83ebF6268F8EECDA8892Ba1; // Horizen
        dvns[1] = 0x962F502A63F5FBeB44DC9ab932122648E8352959; // LayerZero Labs
        dvns[2] = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5; // Nethermind
        dvns[3] = 0xbe57e9E7d9eB16B92C6383792aBe28D64a18c0F1; // Luganodes
        dvns[4] = 0xcC49E6fca014c77E1Eb604351cc1E08C84511760; // Canary
        dvns[5] = 0xE4193136B92bA91402313e95347c8e9FAD8d27d0; // P2P
        dvns[6] = 0xE94aE34DfCC87A61836938641444080B98402c75; // Deutsche Telekom
        return UlnConfig({
            confirmations:        CONFIRMATIONS,
            requiredDVNCount:     NIL_DVN_COUNT,
            optionalDVNCount:     7,
            optionalDVNThreshold: 4,
            requiredDVNs:         new address[](0),
            optionalDVNs:         dvns
        });
    }

    function _setEnforcedGovOption(address sender, uint32 eid) internal {
        EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](1);
        opts[0] = EnforcedOptionParam(eid, MSG_TYPE_SEND, _encodeLzReceiveOptions(LZRECEIVE_GAS));
        OAppOptionsClone(sender).setEnforcedOptions(opts);
    }

    function _encodeLzReceiveOptions(uint128 gas) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"0003", uint8(1), uint16(17), uint8(1), gas);
    }

    // ============================================================================
    //  JSON helpers
    // ============================================================================

    function _readAddr(string memory path, string memory key) internal returns (address) {
        try vm.readFile(path) returns (string memory raw) {
            try vm.parseJsonAddress(raw, key) returns (address a) { return a; }
            catch { return address(0); }
        } catch { return address(0); }
    }
}

// --- Minimal local views (the gov clones expose these beyond the shared OAppLike) ---
interface GovSenderClone {
    function setCanCallTarget(address srcSender, uint32 dstEid, bytes32 dstTarget, bool canCall) external;
}
interface OAppOptionsClone {
    function setEnforcedOptions(EnforcedOptionParam[] calldata opts) external;
}
interface GovReceiverClone {
    function owner() external view returns (address);
    function setDelegate(address delegate) external;
    function transferOwnership(address newOwner) external;
}
