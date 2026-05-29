// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

// Contract types imported strictly to `new` them in the constructor (interfaces can't be instantiated).
import { CCIPDVNAdapter }       from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapter.sol";
import { CCIPDVNAdapterFeeLib } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapterFeeLib.sol";
import { LZInit, CCIPDVNRemote } from "./LZInit.sol";

interface AdapterLike {
    function setWorkerFeeLib(address) external;
    function grantRole (bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
}

interface OwnableLike {
    function transferOwnership(address newOwner) external;
}

interface InitializableFeeLibLike {
    function initialize() external;
}

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

/// @notice Single auditable deployer for the L1 (send-side) CCIP DVN adapter + FeeLib.
///         Holds the adapter/feeLib admin roles for the lifetime of the bring-up;
///         the owner EOA drives the flow via gated functions.
///
///         Expected flow:
///           1. new SendSideDeployer(ccipRouter)                  on L1
///           2. new RecvSideDeployer(chain)                       on each remote chain
///           3. configure(remote, allowedOApps)                   on L1, once per remote
///                  (remote.remoteCcipAdapter + remoteCcipBroadcaster come from step 2)
///           4. (smoke test through an allowed OApp)
///           5. handOff(revokeOApps)                              on L1; moves roles to PAUSE_PROXY
contract SendSideDeployer {
    ChainlogLike internal constant chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    // Worker declares these `internal`, so we recompute them.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");
    bytes32 internal constant ALLOWLIST          = keccak256("ALLOWLIST");

    address public immutable deployer;
    address public immutable adapter;
    address public immutable feeLib;

    modifier onlyDeployer() {
        require(msg.sender == deployer, "SendSideDeployer/not-deployer");
        _;
    }

    /// @dev `new CCIPDVNAdapter` lives in the constructor (not a function) so
    ///      the bytecode lands in initcode (EIP-3860, 49KB) instead of runtime
    ///      (EIP-170, 24KB) — the adapter alone is ~21KB.
    constructor(address ccipRouter) {
        deployer = msg.sender;

        address[] memory admins = new address[](1);
        admins[0] = address(this);

        adapter = address(new CCIPDVNAdapter(admins, ccipRouter));
        feeLib  = address(new CCIPDVNAdapterFeeLib());

        // Upstream FeeLib is built for hardhat-deploy proxies. Calling
        // initialize() once on a freshly deployed instance seals the `proxied`
        // admin slot and runs __Ownable_init() with msg.sender as owner.
        InitializableFeeLibLike(feeLib).initialize();

        AdapterLike(adapter).setWorkerFeeLib(feeLib);
    }

    function configure(CCIPDVNRemote calldata remote, address[] calldata allowedOApps) external onlyDeployer {
        LZInit.wireCCIPDVN(adapter, feeLib, remote, allowedOApps);
    }

    /// @dev Hands FeeLib ownership and adapter admin to PAUSE_PROXY (read from
    ///      chainlog), then self-revokes. Uses `revokeRole` since Worker
    ///      disables `renounceRole`.
    function handOff(address[] calldata revokeOApps) external onlyDeployer {
        address pauseProxy = chainlog.getAddress("MCD_PAUSE_PROXY");
        AdapterLike a = AdapterLike(adapter);

        for (uint256 i = 0; i < revokeOApps.length; ++i) {
            a.revokeRole(ALLOWLIST, revokeOApps[i]);
        }

        OwnableLike(feeLib).transferOwnership(pauseProxy);

        a.grantRole(DEFAULT_ADMIN_ROLE, pauseProxy);
        a.grantRole(ADMIN_ROLE,         pauseProxy);

        a.revokeRole(ADMIN_ROLE,         address(this));
        a.revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }
}
