// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

// The real production gov-bridge CCIP deployers, adapted for the CLONE experiment.
//
//  - RecvSideDeployer  : VERBATIM copy of lz-gov-dvns-deploy@dev RecvSideDeployer.sol. It reads NO
//                        chainlog, so it is used unchanged. It deploys the Avalanche CCIP DVN adapter
//                        with the REAL mainnet CCIP adapter already set as its source peer, then spawns
//                        the ccip + msig DVN broadcasters, then self-revokes admin. Because the source
//                        peer is set in the constructor, this MUST run AFTER the mainnet adapter exists
//                        (that is exactly what avoids the set-once `0xdead` placeholder bug).
//
//  - CloneSendSideDeployer : copy of lz-gov-dvns-deploy@dev SendSideDeployer.sol with ONE change for
//                        the clone: handOff() takes an explicit `pauseProxy` instead of reading the
//                        hardcoded production chainlog's MCD_PAUSE_PROXY (same parameterization pattern
//                        as LZAvaxMigrationCloneInit). Also tolerates the feeLib.initialize() revert
//                        that only happens on a real broadcast (proxied-slot already sealed).
//
// Both reuse the real CCIPDVNAdapter / CCIPDVNAdapterFeeLib / LZDVNInit / CCIPDVNCfg types flattened
// in SendSideDeployerFlat.sol, and the DVNBroadcaster mock.

import {
    CCIPDVNAdapter,
    CCIPDVNAdapterFeeLib,
    ICCIPDVNAdapter,
    LZDVNInit,
    CCIPDVNCfg
} from "test/mocks/SendSideDeployerFlat.sol";
import { DVNBroadcaster } from "test/mocks/DVNBroadcaster.sol";

contract RecvSideDeployer {
    uint32  internal constant L1_EID            = 30101;               // https://docs.layerzero.network/v2/deployments/deployed-contracts
    uint64  internal constant L1_CHAIN_SELECTOR = 5009297550715157269; // https://docs.chain.link/ccip/directory/mainnet/chain/mainnet

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");

    CCIPDVNAdapter public immutable adapter;
    DVNBroadcaster public immutable ccipBroadcaster;
    DVNBroadcaster public immutable msigBroadcaster;

    constructor(
        address ccipRouter,
        address endpoint,
        address sourceCcipAdapter,
        address multisig,
        uint256 nCcip,
        uint256 nMsig
    ) {
        address[] memory admins = new address[](1);
        admins[0] = address(this);
        adapter = new CCIPDVNAdapter(admins, ccipRouter);

        ICCIPDVNAdapter.DstConfigParam[] memory dstCfg = new ICCIPDVNAdapter.DstConfigParam[](1);
        dstCfg[0] = ICCIPDVNAdapter.DstConfigParam({
            eid:           L1_EID,
            multiplierBps: 0,
            chainSelector: L1_CHAIN_SELECTOR,
            gas:           0,
            peer:          abi.encode(sourceCcipAdapter)
        });
        adapter.setDstConfig(dstCfg);

        ccipBroadcaster = new DVNBroadcaster(endpoint, address(adapter), nCcip);
        msigBroadcaster = new DVNBroadcaster(endpoint, multisig,         nMsig);

        adapter.revokeRole(ADMIN_ROLE,         address(this));
        adapter.revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }
}

contract CloneSendSideDeployer {
    address internal constant CCIP_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;

    // Worker declares these `internal`, so we recompute them.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");
    bytes32 internal constant ALLOWLIST          = keccak256("ALLOWLIST");
    bytes32 internal constant MESSAGE_LIB_ROLE   = keccak256("MESSAGE_LIB_ROLE");

    // Break-even fee premium (1e4 = no markup over the raw CCIP fee)
    uint16 internal constant DEFAULT_MULTIPLIER_BPS = 10_000;

    address              public immutable deployer;
    address              public immutable sendLib;
    CCIPDVNAdapter       public immutable adapter;
    CCIPDVNAdapterFeeLib public immutable feeLib;

    modifier onlyDeployer() {
        require(msg.sender == deployer, "CloneSendSideDeployer/not-deployer");
        _;
    }

    constructor(address _sendLib, address[] memory allowedOApps) {
        deployer = msg.sender;
        sendLib  = _sendLib;

        // CLONE deviation: on a real broadcast the freshly-`new`ed flattened feeLib already reports its
        // hardhat-deploy `proxied` admin slot as sealed and _initialized == 1, so initialize() reverts.
        // The adapter never checks feelib ownership (only calls it for fee math), so tolerate it.
        feeLib = new CCIPDVNAdapterFeeLib();
        try feeLib.initialize() {
            try feeLib.renounceOwnership() {} catch {}
        } catch {}

        address[] memory admins = new address[](1);
        admins[0] = address(this);
        adapter = new CCIPDVNAdapter(admins, CCIP_ROUTER);
        adapter.setWorkerFeeLib(address(feeLib));
        adapter.setDefaultMultiplierBps(DEFAULT_MULTIPLIER_BPS);

        // MESSAGE_LIB_ROLE on the SendLib enables admin-triggered fee sweeps via Worker.withdrawFee.
        adapter.grantRole(MESSAGE_LIB_ROLE, _sendLib);

        // First grantRole(ALLOWLIST, _) flips allowlistSize > 0 and makes the ACL strict (deny-by-default).
        for (uint256 i = 0; i < allowedOApps.length; ++i) {
            adapter.grantRole(ALLOWLIST, allowedOApps[i]);
        }
    }

    function configure(CCIPDVNCfg calldata cfg) external onlyDeployer {
        require(cfg.sendLib == sendLib, "CloneSendSideDeployer/wrong-sendlib");
        LZDVNInit.wireCCIPDVN(address(adapter), cfg);
    }

    // CLONE deviation: pauseProxy is an explicit argument (the real handOff reads MCD_PAUSE_PROXY off
    // the hardcoded production chainlog). Grants admin to the clone's pause-proxy stand-in (deployer EOA)
    // and revokes it from this deployer contract, matching the migration's `ccip.hasRole(DEFAULT_ADMIN_ROLE, pProxy)` check.
    function handOff(address pauseProxy, address[] calldata revokeOApps) external onlyDeployer {
        for (uint256 i = 0; i < revokeOApps.length; ++i) {
            adapter.revokeRole(ALLOWLIST, revokeOApps[i]);
        }

        adapter.grantRole(DEFAULT_ADMIN_ROLE, pauseProxy);
        adapter.grantRole(ADMIN_ROLE,         pauseProxy);

        adapter.revokeRole(ADMIN_ROLE,         address(this));
        adapter.revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }
}
