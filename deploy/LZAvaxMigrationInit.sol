// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import {
    LZInit,
    OftConfig,
    RateLimits,
    UlnConfig,
    EndpointLike,
    UlnLike,
    OFTAdapterLike,
    GovOAppSenderLike
} from "./LZInit.sol";

interface TokenLike {
    function balanceOf(address usr) external view returns (uint256);
    function transfer(address to, uint256 amount) external;
    function rely(address usr) external;
    function deny(address usr) external;
}

interface OAppLike {
    function setDelegate(address delegate) external;
    function transferOwnership(address newOwner) external;
    function endpoint() external view returns (address);
}

interface LockboxOftLike {
    function migrateLockedTokens(address to) external;
}

interface ChainlogLike {
    function getAddress(bytes32 key) external view returns (address);
    function setAddress(bytes32 key, address addr) external;
}

interface CCIPDVNAdapterLike {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function allowlistSize() external view returns (uint64);
}

interface LZAvaxMigrationL2SpellLike {
    function migrateAvaxRemote(
        UlnConfig     memory recvUlnCfg,
        address              newRelay,
        OftActivation memory avaxUsds,
        OftActivation memory avaxSusds
    ) external;
}

struct OftActivation {
    address    oft;
    OftConfig  cfg;
    RateLimits rateLimits;
    uint8      rlAccountingType;
}

struct AvaxMigration {
    UlnConfig     sendUlnCfg;         // gov sender: new send DVN set
    address       newL2GovRelay;      // new L2GovernanceRelay
    uint256       ccipDvnIndex;       // CCIP DVN adapter's index in sendUlnCfg.optionalDVNs
    uint64        ccipAllowlistSize;  // expected CCIP DVN adapter allowlist size
    OftActivation usds;               // L1 USDS OFT and its initial config
    RateLimits    usdsGlobalLimits;   // L1 USDS OFT global cap
    bytes32       legacyCLKey;        // chainlog key to record the legacy (old V1) USDS OFT under
    OftActivation susds;              // L1 sUSDS OFT and its initial config
    RateLimits    susdsGlobalLimits;  // L1 sUSDS OFT global cap
    UlnConfig     recvUlnCfg;         // gov receiver: new receive DVN set
    OftActivation avaxUsds;           // Avalanche USDS remote OFT and its initial config
    OftActivation avaxSusds;          // Avalanche sUSDS remote OFT and its initial config
    address       l2Spell;            // LZAvaxMigrationL2Spell on Avalanche
    uint128       gas;                // relay gas
    uint256       maxFee;             // relay max fee
}

/// @notice One-off helpers for the Avalanche gov-bridge + OFT V2 migration, built on the
///         general LZInit primitives. The gov-bridge reconfiguration and the USDS/sUSDS
///         OFT V2 swaps run together in a single L1 spell and a single relayed Avalanche
///         message.
library LZAvaxMigrationInit {

    uint32  internal constant AVAX_EID            = 30106; // Avalanche LayerZero EID
    uint32  internal constant ETH_EID             = 30101; // Ethereum LayerZero EID
    uint8   internal constant MIN_DVN_OVERLAP     = 4;     // min DVNs the new optional set must keep from the current 4/7
    address internal constant OLD_AVAX_GOV_RELAY  = 0xe928885BCe799Ed933651715608155F01abA23cA; // current Avalanche L2GovernanceRelay
    address internal constant AVAX_GOV_RECEIVER   = 0x6fdd46947ca6903c8c159d1dF2012Bc7fC5cEeec; // Avalanche GovernanceOAppReceiver
    address internal constant AVAX_USDS           = 0x86Ff09db814ac346a7C6FE2Cd648F27706D1D470; // USDS on Avalanche
    address internal constant AVAX_SUSDS          = 0xb94D9613C7aAB11E548a327154Cc80eCa911B5c1; // sUSDS on Avalanche
    address internal constant OLD_AVAX_USDS_OFT   = 0x4fec40719fD9a8AE3F8E20531669DEC5962D2619; // current Avalanche USDS OFT
    address internal constant OLD_AVAX_SUSDS_OFT  = 0x7297D4811f088FC26bC5475681405B99b41E1FF9; // current Avalanche sUSDS OFT
    address internal constant OLD_L1_USDS_OFT     = 0x1e1D42781FC170EF9da004Fb735f56F0276d01B8; // V1 L1 USDS lockbox, kept for Solana

    // USDS supply on Avalanche (frozen) = backing moved old->new. sUSDS never bridged.
    uint256 internal constant AVAX_USDS_BACKING   = 10571537000000000000; // 10.571537 USDS

    // CCIP DVN adapter AccessControl roles (it declares these internal, so recompute).
    bytes32 internal constant DEFAULT_ADMIN_ROLE  = 0x00;
    bytes32 internal constant ALLOWLIST           = keccak256("ALLOWLIST");
    bytes32 internal constant MESSAGE_LIB_ROLE    = keccak256("MESSAGE_LIB_ROLE");

    ChainlogLike internal constant chainlog = ChainlogLike(address(LZInit.chainlog));

    /// @notice Migrate the Avalanche gov bridge (new DVN set + new L2GovernanceRelay) and both
    ///         token bridges (new OFT V2 adapters) in one L1 spell, relaying the Avalanche half
    ///         through the OLD relay (still owner + whitelisted).
    /// @dev    Assumes the deployer pre-configured the new adapters (the new Avalanche ones owned
    ///         by the old relay until the handover). Avalanche is expected to be the first L2
    ///         brought up on the V2 OFTs; if it isn't, the earlier L2's spell is assumed to have
    ///         either left the chainlog unchanged or set USDS_OFT/SUSDS_OFT -> new OFTs and
    ///         m.legacyCLKey -> legacy OFT, so this spell still works redundantly (see README).
    ///         m.usds/susdsGlobalLimits must be the system-wide totals across every L2 on the new
    ///         lockbox (excluding Solana, which stays on the old USDS adapter).
    function migrateAvax(AvaxMigration memory m) internal {
        address govSender = chainlog.getAddress("LZ_GOV_SENDER");
        address sendLib   = EndpointLike(OAppLike(govSender).endpoint()).getSendLibrary(govSender, AVAX_EID);
        // Read rather than use address(this) so the migration can be pranked in tests (in prod
        // the spell IS the pause proxy).
        address pProxy    = chainlog.getAddress("MCD_PAUSE_PROXY");

        // ============================ Sanity checks ============================

        _checkDvnOverlap(govSender, sendLib, m.sendUlnCfg);

        // Sanity check the CCIP DVN adapter setup. Indexing the adapter out of the DVN set also enforces
        // it's a member. Assumes the adapter was verified off-chain to have been deployed by the
        // SendSideDeployer contract.
        {
        CCIPDVNAdapterLike ccip = CCIPDVNAdapterLike(m.sendUlnCfg.optionalDVNs[m.ccipDvnIndex]);
        require(ccip.hasRole(MESSAGE_LIB_ROLE,   sendLib),               "LZAvaxMigrationInit/ccip-sendlib-missing-role");
        require(ccip.hasRole(ALLOWLIST,          govSender),             "LZAvaxMigrationInit/ccip-gov-sender-not-allowlisted");
        require(ccip.allowlistSize()             == m.ccipAllowlistSize, "LZAvaxMigrationInit/ccip-allowlist-size-mismatch");
        require(ccip.hasRole(DEFAULT_ADMIN_ROLE, pProxy),                "LZAvaxMigrationInit/ccip-admin-not-handed-off");
        }

        // ============================ Relay L2 spell ============================
        // Relay through the OLD relay (still whitelisted), before the whitelist swap below. The L1
        // send-DVN update lands in the same transaction, but the DVN overlap checked above keeps the
        // relayed message verifiable.

        LZInit.relayToL2(
            AVAX_EID, OLD_AVAX_GOV_RELAY, m.l2Spell,
            abi.encodeCall(
                LZAvaxMigrationL2SpellLike.migrateAvaxRemote,
                (m.recvUlnCfg, m.newL2GovRelay, m.avaxUsds, m.avaxSusds)
            ),
            m.gas, m.maxFee
        );

        {
        // ============================ USDS OFT V2 swap ============================
        // Activate new, move backing old->new, sever the old Avalanche route (old stays live for
        // Solana), repoint the chainlog.

        address usds = chainlog.getAddress("USDS");

        LZInit.activateOft(m.usds.oft, AVAX_EID, m.usds.cfg, m.usds.rateLimits, m.usds.rlAccountingType, usds, pProxy);
        // Set the lockbox global cap unconditionally, overwriting any prior value (deployer- or spell-set).
        LZInit.updateGlobalRateLimits(m.usds.oft, m.usdsGlobalLimits);

        uint256 before = TokenLike(usds).balanceOf(pProxy);
        LockboxOftLike(OLD_L1_USDS_OFT).migrateLockedTokens(pProxy);
        uint256 migrated = TokenLike(usds).balanceOf(pProxy) - before;
        TokenLike(usds).transfer(m.usds.oft, AVAX_USDS_BACKING);
        TokenLike(usds).transfer(OLD_L1_USDS_OFT, migrated - AVAX_USDS_BACKING);

        // Sever the old Avalanche route: clearing the peer disables it, then zero the stale rate
        // limits (old stays live for Solana). The rest of the AVAX_EID route config (send/receive
        // libraries, their DVN/executor configs, enforced options) is left in place: all inert once
        // the peer is cleared.
        OFTAdapterLike(OLD_L1_USDS_OFT).setPeer(AVAX_EID, bytes32(0));
        LZInit.updateRateLimits(OLD_L1_USDS_OFT, AVAX_EID, RateLimits(0, 0, 0, 0));

        chainlog.setAddress("USDS_OFT",    m.usds.oft);
        chainlog.setAddress(m.legacyCLKey, OLD_L1_USDS_OFT);
        }

        // ============================ sUSDS OFT V2 swap ===========================
        // Activate new + repoint SUSDS_OFT. The old L1 sUSDS adapter is fully abandoned (not kept
        // for Solana, unlike USDS), so no need to sever its Avalanche route here: its peer is left
        // set and its rate limits are already 0 on-chain.

        LZInit.activateOft(m.susds.oft, AVAX_EID, m.susds.cfg, m.susds.rateLimits, m.susds.rlAccountingType, chainlog.getAddress("SUSDS"), pProxy);
        // Set the lockbox global cap unconditionally, overwriting any prior value (deployer- or spell-set).
        LZInit.updateGlobalRateLimits(m.susds.oft, m.susdsGlobalLimits);

        chainlog.setAddress("SUSDS_OFT", m.susds.oft);

        // ==========================================================================
        // Gov bridge: update the L1 send DVN set, then swap the gov-relay whitelist.

        LZInit.setUlnConfig(govSender, AVAX_EID, sendLib, m.sendUlnCfg);

        address govRelay = chainlog.getAddress("LZ_GOV_RELAY");
        GovOAppSenderLike(govSender).setCanCallTarget(govRelay, AVAX_EID, bytes32(uint256(uint160(m.newL2GovRelay))), true);
        GovOAppSenderLike(govSender).setCanCallTarget(govRelay, AVAX_EID, bytes32(uint256(uint160(OLD_AVAX_GOV_RELAY))), false);
    }

    /// @dev Require the new optional DVN set to keep >= MIN_DVN_OVERLAP of the current (4/7) set: a
    ///      LZ quirk requires a DVN that has been assigned a verification job to still be present at
    ///      the end of the block. Both sets are sorted ascending (LZ-enforced); the loop below
    ///      relies on that to count the overlap in a single pass.
    function _checkDvnOverlap(address govSender, address sendLib, UlnConfig memory newCfg) private view {
        address[] memory newOpt = newCfg.optionalDVNs;
        address[] memory oldOpt = UlnLike(sendLib).getAppUlnConfig(govSender, AVAX_EID).optionalDVNs;
        uint256 common;
        uint256 i;
        uint256 j;
        while (i < newOpt.length && j < oldOpt.length) {
            if      (newOpt[i] == oldOpt[j]) { ++common; ++i; ++j; }
            else if (newOpt[i] <  oldOpt[j]) ++i;
            else                             ++j;
        }
        require(common >= MIN_DVN_OVERLAP, "LZAvaxMigrationInit/insufficient-dvn-overlap");
    }

    /// @notice The Avalanche half, run as one delegatecall by the OLD relay: bring up the new
    ///         remote OFTs and hand them (and their tokens) + the gov bridge to the new relay.
    function migrateAvaxRemote(
        UlnConfig     memory recvUlnCfg,
        address              newRelay,
        OftActivation memory avaxUsds,
        OftActivation memory avaxSusds
    ) internal {
        // OFT token authority: rely the new adapters, deny the old ones.
        TokenLike(AVAX_USDS).rely(avaxUsds.oft);   TokenLike(AVAX_USDS).deny(OLD_AVAX_USDS_OFT);
        TokenLike(AVAX_SUSDS).rely(avaxSusds.oft); TokenLike(AVAX_SUSDS).deny(OLD_AVAX_SUSDS_OFT);

        // Activate the new remote OFTs for the Ethereum route.
        LZInit.activateOft(avaxUsds.oft,  ETH_EID, avaxUsds.cfg,  avaxUsds.rateLimits,  avaxUsds.rlAccountingType,  AVAX_USDS,  address(this));
        LZInit.activateOft(avaxSusds.oft, ETH_EID, avaxSusds.cfg, avaxSusds.rateLimits, avaxSusds.rlAccountingType, AVAX_SUSDS, address(this));

        // Gov receiver: new receive DVN set (lib read from the endpoint).
        (address recvLib,) = EndpointLike(OAppLike(AVAX_GOV_RECEIVER).endpoint()).getReceiveLibrary(AVAX_GOV_RECEIVER, ETH_EID);
        LZInit.setUlnConfig(AVAX_GOV_RECEIVER, ETH_EID, recvLib, recvUlnCfg);

        // Grant token authority to the new relay.
        TokenLike(AVAX_USDS).rely(newRelay);
        TokenLike(AVAX_SUSDS).rely(newRelay);

        // Hand delegate + ownership to the new relay: gov receiver + both new adapters.
        address[3] memory oapps = [AVAX_GOV_RECEIVER, avaxUsds.oft, avaxSusds.oft];
        for (uint256 i; i < oapps.length; ++i) {
            OAppLike(oapps[i]).setDelegate(newRelay);
            OAppLike(oapps[i]).transferOwnership(newRelay);
        }

        // Old relay denies itself on the tokens.
        TokenLike(AVAX_USDS).deny(address(this));
        TokenLike(AVAX_SUSDS).deny(address(this));
    }
}
