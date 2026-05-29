// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

// Contract types imported strictly to `new` them in the constructor (interfaces can't be instantiated).
import { CCIPDVNAdapter }  from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapter.sol";
import { DVNBroadcaster }  from "lz-gov-dvns/DVNBroadcaster.sol";

import { ICCIPDVNAdapter } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/interfaces/adapters/ICCIPDVNAdapter.sol";

interface AdapterLike {
    function setDstConfig(ICCIPDVNAdapter.DstConfigParam[] calldata) external;
    function grantRole (bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
}

interface BroadcasterLike {
    function getReplicas() external view returns (address[] memory);
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

/// @notice Single auditable deployer for the remote (recv-side) CCIP DVN adapter
///         + both DVN broadcasters. Admin handoff happens in the same call.
contract RecvSideDeployer {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");

    address   public immutable adapter;
    address   public immutable ccipBroadcaster;
    address   public immutable msigBroadcaster;
    address[] public           ccipReplicas;
    address[] public           msigReplicas;

    /// @dev `chain.finalAdmin == address(0)` leaves no admin on the adapter
    ///      (provably can't send — no one can grant MESSAGE_LIB_ROLE).
    /// @dev Self-revoke uses `revokeRole` (not `renounceRole`, which Worker disables).
    /// @dev Everything happens in the constructor because `new CCIPDVNAdapter`
    ///      (~21KB) embeds its bytecode in the deployer; in a function that
    ///      would blow the EIP-170 24KB runtime limit. In the constructor it
    ///      lives in initcode (EIP-3860 49KB limit).
    constructor(RecvSideChain memory chain) {
        address[] memory admins = new address[](1);
        admins[0] = address(this);

        adapter = address(new CCIPDVNAdapter(admins, chain.ccipRouter));
        AdapterLike a = AdapterLike(adapter);

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
        ccipBroadcaster = address(new DVNBroadcaster(chain.receiveUln302, adapter,        chain.nCcip));
        msigBroadcaster = address(new DVNBroadcaster(chain.receiveUln302, chain.multisig, chain.nMsig));
        ccipReplicas    = BroadcasterLike(ccipBroadcaster).getReplicas();
        msigReplicas    = BroadcasterLike(msigBroadcaster).getReplicas();

        if (chain.finalAdmin != address(0)) {
            a.grantRole(DEFAULT_ADMIN_ROLE, chain.finalAdmin);
            a.grantRole(ADMIN_ROLE,         chain.finalAdmin);
        }
        a.revokeRole(ADMIN_ROLE,         address(this));
        a.revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    function getCcipReplicas() external view returns (address[] memory) { return ccipReplicas; }
    function getMsigReplicas() external view returns (address[] memory) { return msigReplicas; }
}
