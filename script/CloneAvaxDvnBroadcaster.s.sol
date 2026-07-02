// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import { DVNBroadcaster }   from "test/mocks/DVNBroadcaster.sol";
import { RecvSideDeployer } from "test/mocks/GovCcipSideDeployers.sol";

/// @notice Chunk 3 of the Eth<->Avalanche migration CLONE experiment: deploys the RECV-side of the
///         real production DVN-Broadcaster machinery on AVALANCHE (the 8-of-15 gov recv topology's
///         non-LZ wing). Two independent broadcasters, each spawning 4 DVNReplica verifier slots:
///           - ccipBroadcaster : verifier == the Avax CCIP DVN adapter (attestations arriving over
///             Chainlink CCIP from the mainnet CCIP adapter drive its 4 replicas).
///           - msigBroadcaster : verifier == the multisig (here the DEPLOYER stand-in) that can
///             directly drive its 4 replicas.
///         The 4 ccip replicas + 4 msig replicas + 7 AVAX gov LZ DVNs == the 15-DVN recv set the
///         migration installs on the gov receiver at optionalDVNThreshold 8.
///
///         Persists into script/clone.avax.json: avaxCcipAdapter, ccipBroadcaster, msigBroadcaster,
///         ccipReplicas[4], msigReplicas[4].
///
///         Usage (real run later; requires chunk 1+2 deployed, and clone.eth.json.ccipAdapter set):
///           forge script script/CloneAvaxDvnBroadcaster.s.sol --sig "deploy()" \
///               --rpc-url $AVALANCHE_RPC_URL --broadcast --private-key $PRIVATE_KEY
contract CloneAvaxDvnBroadcaster is Script {

    // Canonical LZ endpoint (same address on Eth + Avax).
    address constant AVAX_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    uint32 constant ETH_EID  = 30101;
    uint32 constant AVAX_EID = 30106;

    // CCIP chain selectors.
    uint64 constant ETH_CCIP_SELECTOR = 5009297550715157269;

    // Avalanche C-Chain Chainlink CCIP Router (mainnet).
    address constant AVAX_CCIP_ROUTER = 0xF4c7E640EdA248ef95972845a62bdC74237805dB;

    // CCIP attestation exec gas on the destination (Ethereum) chain for the reverse route.
    uint256 constant CCIP_GAS       = 600_000;
    uint16  constant CCIP_MULTIPLIER_BPS = 10_000;
    uint256 constant N_REPLICAS     = 4;

    // CCIP adapter AccessControl role ids (declared internal on the mock; recompute).
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @dev Deployer / admin stand-in. Read from the DEPLOYER env var; == broadcasting key.
    ///      Also the multisig broadcaster's verifier in the clone.
    function _owner() internal view returns (address o) {
        o = vm.envAddress("DEPLOYER");
        require(o != address(0), "DEPLOYER env var not set");
    }

    string constant ETH_PATH  = "script/clone.eth.json";
    string constant AVAX_PATH = "script/clone.avax.json";

    function deploy() external {
        require(block.chainid == 43114, "deploy(): run on Avalanche");
        address deployer = _owner();
        require(msg.sender == deployer, "deploy(): sender != DEPLOYER");

        address mainnetCcipAdapter = _readAddr(ETH_PATH, ".ccipAdapter");
        // The mainnet CCIP adapter must ALREADY exist (deployed BARE by chunk 2 deployOft() on Eth).
        // RecvSideDeployer bakes it as the Avax adapter's set-once source peer, so a placeholder here
        // would permanently break the CCIP recv path (the original 0xdead bug). No placeholder allowed.
        require(mainnetCcipAdapter != address(0), "run chunk 2 deployOft() on Eth FIRST (real ccipAdapter, no placeholder)");

        // Idempotency: skip if already deployed.
        if (_readAddr(AVAX_PATH, ".ccipBroadcaster") != address(0)) {
            console.log("DVN broadcaster machinery already deployed, skipping");
            return;
        }

        vm.startBroadcast();

        // Deploy the entire Avalanche recv side via the REAL production RecvSideDeployer (verbatim; it
        // reads no chainlog). Its constructor: deploys the Avax CCIP DVN adapter, sets its source peer =
        // the REAL mainnet adapter (ETH selector), spawns the ccip broadcaster (verifier = the adapter)
        // and the msig broadcaster (verifier = the multisig, here the deployer EOA), then self-revokes
        // its admin roles. nCcip = nMsig = 4 replicas each.
        RecvSideDeployer r = new RecvSideDeployer(
            AVAX_CCIP_ROUTER,
            AVAX_ENDPOINT,
            mainnetCcipAdapter,
            deployer,           // multisig wing verifier == the clone's msig stand-in (deployer EOA)
            N_REPLICAS,
            N_REPLICAS
        );

        address          avaxCcipAdapter = address(r.adapter());
        DVNBroadcaster   ccipBroadcaster = r.ccipBroadcaster();
        DVNBroadcaster   msigBroadcaster = r.msigBroadcaster();
        address[] memory ccipReplicas    = ccipBroadcaster.getReplicas();
        address[] memory msigReplicas    = msigBroadcaster.getReplicas();

        vm.stopBroadcast();

        require(ccipReplicas.length == N_REPLICAS && msigReplicas.length == N_REPLICAS, "replica count mismatch");

        console.log("Avax CCIP DVN adapter:", avaxCcipAdapter);
        console.log("CCIP broadcaster:",      address(ccipBroadcaster));
        console.log("Msig broadcaster:",      address(msigBroadcaster));

        _write(avaxCcipAdapter, address(ccipBroadcaster), address(msigBroadcaster), ccipReplicas, msigReplicas);
    }

    // ============================================================================
    //  JSON helpers (merge new keys into clone.avax.json)
    // ============================================================================

    function _write(
        address          avaxCcipAdapter,
        address          ccipBroadcaster,
        address          msigBroadcaster,
        address[] memory ccipReplicas,
        address[] memory msigReplicas
    ) internal {
        string memory json = "avaxdvn";
        // preserve existing keys
        vm.serializeAddress(json, "usds",        _readAddr(AVAX_PATH, ".usds"));
        vm.serializeAddress(json, "susds",       _readAddr(AVAX_PATH, ".susds"));
        vm.serializeAddress(json, "receiver",    _readAddr(AVAX_PATH, ".receiver"));
        vm.serializeAddress(json, "oldRelay",    _readAddr(AVAX_PATH, ".oldRelay"));
        vm.serializeAddress(json, "newRelay",    _readAddr(AVAX_PATH, ".newRelay"));
        vm.serializeAddress(json, "oldUsdsOft",  _readAddr(AVAX_PATH, ".oldUsdsOft"));
        vm.serializeAddress(json, "oldSusdsOft", _readAddr(AVAX_PATH, ".oldSusdsOft"));
        vm.serializeAddress(json, "newUsdsOft",  _readAddr(AVAX_PATH, ".newUsdsOft"));
        vm.serializeAddress(json, "newSusdsOft", _readAddr(AVAX_PATH, ".newSusdsOft"));
        vm.serializeAddress(json, "l2Spell",     _readAddr(AVAX_PATH, ".l2Spell"));
        // new keys
        vm.serializeAddress(json, "avaxCcipAdapter", avaxCcipAdapter);
        vm.serializeAddress(json, "ccipBroadcaster", ccipBroadcaster);
        vm.serializeAddress(json, "msigBroadcaster", msigBroadcaster);
        vm.serializeAddress(json, "ccipReplicas",    ccipReplicas);
        string memory out = vm.serializeAddress(json, "msigReplicas", msigReplicas);
        vm.writeJson(out, AVAX_PATH);
    }

    function _readAddr(string memory path, string memory key) internal returns (address) {
        try vm.readFile(path) returns (string memory raw) {
            try vm.parseJsonAddress(raw, key) returns (address a) { return a; }
            catch { return address(0); }
        } catch { return address(0); }
    }
}
