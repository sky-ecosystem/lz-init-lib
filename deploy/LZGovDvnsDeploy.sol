// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import { CCIPDVNAdapter }       from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapter.sol";
import { CCIPDVNAdapterFeeLib } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapterFeeLib.sol";
import { ICCIPDVNAdapter }      from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/interfaces/adapters/ICCIPDVNAdapter.sol";

import { DVNBroadcaster } from "lz-gov-dvns/DVNBroadcaster.sol";

import { LZInit, CCIPDVNRemote } from "./LZInit.sol";

interface OwnableLike {
    function transferOwnership(address newOwner) external;
}

interface InitializableFeeLibLike {
    function initialize() external;
}

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

struct RecvSideChain {
    uint32  sourceEid;
    address ccipRouter;
    uint64  sourceChainSelector;
    address sourceCcipAdapter;
    address receiveUln302;
    address multisig;
    uint256 nCcip;
    uint256 nMsig;
    address finalAdmin;
}

struct DvnDeploy {
    address   ccipBroadcaster;
    address   msigBroadcaster;
    address[] ccipReplicas;
    address[] msigReplicas;
}

/// @notice Deploy + configure library for the CCIP and Multisig DVN wings of the
///         Sky LZ governance bridge. OApp-agnostic.
///
/// Expected invocation order (deployer EOA, one tx per step):
///   1. deploySendSide    (Ethereum)
///   2. deployRecvSide    (remote)  — adapter + both broadcasters + admin handoff
///   3. configureSendSide (Ethereum)
///   4. <smoke test through a whitelisted test OApp>
///   5. handOffSendSide   (Ethereum)
library LZGovDvnsDeploy {

    ChainlogLike internal constant chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    // Worker declares these `internal`, so we recompute them.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");
    bytes32 internal constant ALLOWLIST          = keccak256("ALLOWLIST");

    /// @dev WARNING: `deployer` ends up with DEFAULT_ADMIN_ROLE + ADMIN_ROLE on
    ///      the adapter and as Ownable.owner of the FeeLib. Must be handed off
    ///      via `handOffSendSide` before the bridge goes live.
    /// @dev `deployer` must equal the broadcast address in the caller's script.
    function deploySendSide(
        address deployer,
        address ccipRouter
    ) internal returns (address adapter, address feeLib) {
        address[] memory admins = new address[](1);
        admins[0] = deployer;

        adapter = address(new CCIPDVNAdapter(admins, ccipRouter));
        feeLib  = address(new CCIPDVNAdapterFeeLib());

        // Upstream FeeLib is built for hardhat-deploy proxies. Calling
        // initialize() once on a freshly deployed instance seals the `proxied`
        // admin slot and runs __Ownable_init() with msg.sender as owner.
        InitializableFeeLibLike(feeLib).initialize();

        CCIPDVNAdapter(payable(adapter)).setWorkerFeeLib(feeLib);
    }

    /// @notice Deploys the recv-side adapter, both DVN broadcasters, and hands
    ///         adapter admin off in the same tx.
    /// @dev    `chain.finalAdmin == address(0)` leaves no admin on the adapter
    ///         (provably can't send — no one can grant MESSAGE_LIB_ROLE).
    /// @dev    Self-revoke uses `revokeRole` (not `renounceRole`, which Worker
    ///         disables).
    function deployRecvSide(
        address              deployer,
        RecvSideChain memory chain
    ) internal returns (address adapter, DvnDeploy memory dvn) {
        address[] memory admins = new address[](1);
        admins[0] = deployer;

        CCIPDVNAdapter a = new CCIPDVNAdapter(admins, chain.ccipRouter);
        adapter = address(a);

        ICCIPDVNAdapter.DstConfigParam[] memory params = new ICCIPDVNAdapter.DstConfigParam[](1);
        params[0] = ICCIPDVNAdapter.DstConfigParam({
            eid:           chain.sourceEid,
            multiplierBps: 0,
            chainSelector: chain.sourceChainSelector,
            gas:           0,
            peer:          abi.encode(chain.sourceCcipAdapter)
        });
        a.setDstConfig(params);

        // Broadcaster ctors take no roles; safe to deploy before admin handoff.
        DVNBroadcaster ccipB = new DVNBroadcaster(chain.receiveUln302, adapter,        chain.nCcip);
        DVNBroadcaster msigB = new DVNBroadcaster(chain.receiveUln302, chain.multisig, chain.nMsig);
        dvn.ccipBroadcaster = address(ccipB);
        dvn.msigBroadcaster = address(msigB);
        dvn.ccipReplicas    = ccipB.getReplicas();
        dvn.msigReplicas    = msigB.getReplicas();

        if (chain.finalAdmin != address(0)) {
            a.grantRole(DEFAULT_ADMIN_ROLE, chain.finalAdmin);
            a.grantRole(ADMIN_ROLE,         chain.finalAdmin);
        }
        a.revokeRole(ADMIN_ROLE,         deployer);
        a.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    }

    /// @notice Bring-up wiring for the send side. Thin wrapper over
    ///         `LZInit.wireCCIPDVN`; same body is reused by future spells when
    ///         adding a new remote post-handoff.
    function configureSendSide(
        address               adapter,
        address               feeLib,
        CCIPDVNRemote memory  remote,
        address[]     memory  allowedOApps
    ) internal {
        LZInit.wireCCIPDVN(adapter, feeLib, remote, allowedOApps);
    }

    /// @notice Final bring-up step. Revokes the bring-up test OApp(s) from the
    ///         allowlist, transfers FeeLib ownership and adapter admin to
    ///         PAUSE_PROXY (read from chainlog), then self-revokes the deployer.
    /// @dev    Same `revokeRole`-not-`renounceRole` mechanism as `deployRecvSide`.
        function handOffSendSide(
        address          deployer,
        address          adapter,
        address          feeLib,
        address[] memory revokeOApps
    ) internal {
        address pauseProxy = chainlog.getAddress("MCD_PAUSE_PROXY");

        CCIPDVNAdapter a = CCIPDVNAdapter(payable(adapter));

        for (uint256 i = 0; i < revokeOApps.length; ++i) {
            a.revokeRole(ALLOWLIST, revokeOApps[i]);
        }

        OwnableLike(feeLib).transferOwnership(pauseProxy);

        a.grantRole(DEFAULT_ADMIN_ROLE, pauseProxy);
        a.grantRole(ADMIN_ROLE,         pauseProxy);

        a.revokeRole(ADMIN_ROLE,         deployer);
        a.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    }
}
