// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import {
    LZInit,
    OftConfig,
    RateLimits,
    UlnConfig,
    EnforcedOptionParam,
    EndpointLike,
    UlnLike,
    OFTAdapterLike,
    GovOAppSenderLike
} from "./LZInit.sol";

interface TokenLike {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
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
    function getAddress(bytes32) external view returns (address);
    function setAddress(bytes32, address) external;
}

interface CCIPDVNAdapterLike {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function allowlistSize() external view returns (uint64);
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
    OftActivation usds;               // L1 USDS OFT and its initial config
    RateLimits    usdsGlobalLimits;   // L1 USDS OFT global cap
    OftActivation susds;              // L1 sUSDS OFT and its initial config
    RateLimits    susdsGlobalLimits;  // L1 sUSDS OFT global cap
    UlnConfig     recvUlnCfg;         // gov receiver: new receive DVN set
    OftActivation avaxUsds;           // Avalanche USDS remote OFT and its initial config
    OftActivation avaxSusds;          // Avalanche sUSDS remote OFT and its initial config
    address       l2Spell;            // LZAvaxMigrationL2Spell on Avalanche
    uint128       gas;                // relay gas
    uint256       maxFee;             // relay max fee
}

interface LZAvaxMigrationL2SpellLike {
    function migrateAvaxRemote(
        UlnConfig     memory recvUlnCfg,
        address              newRelay,
        OftActivation memory avaxUsds,
        OftActivation memory avaxSusds
    ) external;
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
    ///         by the old relay until the handover) and that Avalanche is the FIRST remote on the
    ///         CCIP DVN adapter and the first to use OFT V2.
    function migrateAvax(AvaxMigration memory m) internal {
        address govSender = chainlog.getAddress("LZ_GOV_SENDER");
        address sendLib   = EndpointLike(OAppLike(govSender).endpoint()).getSendLibrary(govSender, AVAX_EID);
        // Read rather than use address(this) so the migration can be pranked in tests (in prod
        // the spell IS the pause proxy).
        address pProxy    = chainlog.getAddress("MCD_PAUSE_PROXY");

        // ============================ Sanity checks ============================

        _checkDvnOverlap(govSender, sendLib, m.sendUlnCfg);

        // Sanity check the CCIP DVN adapter setup. Indexing the adapter out of the DVN set also enforces
        // it's a member.
        {
            CCIPDVNAdapterLike ccip = CCIPDVNAdapterLike(m.sendUlnCfg.optionalDVNs[m.ccipDvnIndex]);
            require(ccip.hasRole(MESSAGE_LIB_ROLE,   sendLib),   "LZAvaxMigrationInit/ccip-sendlib-missing-role");
            require(ccip.hasRole(ALLOWLIST,          govSender), "LZAvaxMigrationInit/ccip-gov-sender-not-allowlisted");
            require(ccip.allowlistSize()             == 1,       "LZAvaxMigrationInit/ccip-allowlist-not-singleton");
            require(ccip.hasRole(DEFAULT_ADMIN_ROLE, pProxy),    "LZAvaxMigrationInit/ccip-admin-not-handed-off");
        }

        // ============================ Relay L2 spell ============================
        // Relay through the OLD relay, under the still-old send config so the old Avalanche
        // receive config can verify it. Must precede the L1 send-DVN update + whitelist swap below.

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

        address usds       = chainlog.getAddress("USDS");
        address oldUsdsOft = chainlog.getAddress("USDS_OFT");  // current lockbox, kept for Solana

        LZInit.activateOft(m.usds.oft, AVAX_EID, m.usds.cfg, m.usds.rateLimits, m.usds.rlAccountingType, usds, pProxy);
        // Sets the lockbox global cap unconditionally, overwriting any prior value (deployer- or spell-set).
        LZInit.updateGlobalRateLimits(m.usds.oft, m.usdsGlobalLimits);

        uint256 before = TokenLike(usds).balanceOf(pProxy);
        LockboxOftLike(oldUsdsOft).migrateLockedTokens(pProxy);
        uint256 migrated = TokenLike(usds).balanceOf(pProxy) - before;
        TokenLike(usds).transfer(m.usds.oft, AVAX_USDS_BACKING);
        TokenLike(usds).transfer(oldUsdsOft, migrated - AVAX_USDS_BACKING);

        // Sever the old Avalanche route: clearing the peer disables it. Then tidy up (old stays
        // live for Solana) — zero the stale inbound limit and neutralize enforced options. The
        // options can't be reset to empty (the setter rejects non-type-3 bytes), so write the
        // bare type-3 header.
        OFTAdapterLike(oldUsdsOft).setPeer(AVAX_EID, bytes32(0));
        LZInit.updateRateLimits(oldUsdsOft, AVAX_EID, RateLimits(0, 0, 0, 0));
        EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](2);
        opts[0] = EnforcedOptionParam(AVAX_EID, LZInit.MSG_TYPE_SEND,          hex"0003");
        opts[1] = EnforcedOptionParam(AVAX_EID, LZInit.MSG_TYPE_SEND_AND_CALL, hex"0003");
        OFTAdapterLike(oldUsdsOft).setEnforcedOptions(opts);

        chainlog.setAddress("USDS_OFT",        m.usds.oft);
        chainlog.setAddress("USDS_OFT_SOLANA", oldUsdsOft);
        }

        // ============================ sUSDS OFT V2 swap ===========================
        // Activate new + repoint SUSDS_OFT. Old adapter (Avalanche-only) is retired — no funding,
        // teardown or Solana key, just denied on Avalanche.

        LZInit.activateOft(m.susds.oft, AVAX_EID, m.susds.cfg, m.susds.rateLimits, m.susds.rlAccountingType, chainlog.getAddress("SUSDS"), pProxy);
        // Sets the lockbox global cap unconditionally, overwriting any prior value (deployer- or spell-set).
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
