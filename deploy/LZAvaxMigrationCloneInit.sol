// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

// ============================================================================================
//  CLONE / TEST-ONLY variant of LZAvaxMigrationInit.
//
//  LZAvaxMigrationInit hardcodes production addresses (OLD_AVAX_GOV_RELAY, AVAX_GOV_RECEIVER,
//  AVAX_USDS/SUSDS, the old OFTs, OLD_L1_USDS_OFT) as constants and reads the rest from the real
//  chainlog. To exercise the migration end-to-end against an independent CLONE of the Sky setup on
//  real mainnet + Avalanche (mirroring the Eth<->Base test-clone methodology), this variant lifts
//  exactly those hardcoded/chainlog-resolved addresses into a CloneEnv struct + a fake chainlog.
//
//  IMPORTANT: the migration LOGIC below is a byte-faithful transcription of LZAvaxMigrationInit's
//  migrateAvax / migrateAvaxRemote / _checkDvnOverlap. ONLY the address SOURCES differ (constants
//  and `chainlog` -> CloneEnv fields / e.chainlog). Chain-independent values are left as-is: the
//  LZ EIDs (the clone still bridges the real Eth<->Avax mainnets), MIN_DVN_OVERLAP, and the CCIP
//  AccessControl role ids. Do NOT "fix" anything here — this must reproduce the real lib's behavior
//  (including any latent bug) so the experiment surfaces real problems.
// ============================================================================================

import {
    LZInit,
    OftConfig,
    RateLimits,
    UlnConfig,
    EndpointLike,
    UlnLike,
    OFTAdapterLike,
    GovOAppSenderLike,
    L1GovernanceRelayLike,
    L2GovernanceRelayLike,
    TxParams,
    MessagingFee
} from "./LZInit.sol";
import {
    OftActivation,
    AvaxMigration,
    TokenLike,
    OAppLike,
    LockboxOftLike,
    ChainlogLike,
    CCIPDVNAdapterLike,
    LZAvaxMigrationL2SpellLike
} from "./LZAvaxMigrationInit.sol";

// The production constants of LZAvaxMigrationInit, lifted to params for the clone run.
struct CloneEnv {
    address chainlog;          // fake chainlog: LZ_GOV_SENDER, LZ_GOV_RELAY, MCD_PAUSE_PROXY, USDS, SUSDS, USDS_OFT, SUSDS_OFT
    address oldAvaxGovRelay;   // OLD_AVAX_GOV_RELAY
    address avaxGovReceiver;   // AVAX_GOV_RECEIVER
    address avaxUsds;          // AVAX_USDS
    address avaxSusds;         // AVAX_SUSDS
    address oldAvaxUsdsOft;    // OLD_AVAX_USDS_OFT
    address oldAvaxSusdsOft;   // OLD_AVAX_SUSDS_OFT
    address oldL1UsdsOft;      // OLD_L1_USDS_OFT
    uint256 avaxUsdsBacking;   // AVAX_USDS_BACKING (clone's frozen backing)
}

library LZAvaxMigrationCloneInit {

    // Chain-independent: identical to LZAvaxMigrationInit (real Eth<->Avax mainnets in the clone too).
    uint32 internal constant AVAX_EID        = 30106;
    uint32 internal constant ETH_EID         = 30101;
    uint8  internal constant MIN_DVN_OVERLAP = 4;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ALLOWLIST          = keccak256("ALLOWLIST");
    bytes32 internal constant MESSAGE_LIB_ROLE   = keccak256("MESSAGE_LIB_ROLE");

    // ---- transcription of migrateAvax (address sources parameterized) ----
    function migrateAvax(AvaxMigration memory m, CloneEnv memory e) internal {
        ChainlogLike chainlog = ChainlogLike(e.chainlog);

        address govSender = chainlog.getAddress("LZ_GOV_SENDER");
        address govRelay  = chainlog.getAddress("LZ_GOV_RELAY");
        address sendLib   = EndpointLike(OAppLike(govSender).endpoint()).getSendLibrary(govSender, AVAX_EID);
        address pProxy    = chainlog.getAddress("MCD_PAUSE_PROXY");

        // ============================ Sanity checks ============================
        _checkDvnOverlap(govSender, sendLib, m.sendUlnCfg);

        {
        CCIPDVNAdapterLike ccip = CCIPDVNAdapterLike(m.sendUlnCfg.optionalDVNs[m.ccipDvnIndex]);
        require(ccip.hasRole(MESSAGE_LIB_ROLE,   sendLib),               "LZAvaxMigrationInit/ccip-sendlib-missing-role");
        require(ccip.hasRole(ALLOWLIST,          govSender),             "LZAvaxMigrationInit/ccip-gov-sender-not-allowlisted");
        require(ccip.allowlistSize()             == m.ccipAllowlistSize, "LZAvaxMigrationInit/ccip-allowlist-size-mismatch");
        require(ccip.hasRole(DEFAULT_ADMIN_ROLE, pProxy),                "LZAvaxMigrationInit/ccip-admin-not-handed-off");
        }

        // ============================ Relay L2 spell ============================
        // CLONE DEVIATION (only): the real migrateAvax uses LZInit.relayToL2, which resolves the gov
        // sender + L1 relay from the hardcoded production chainlog. For a clone we must relay through
        // the CLONE gov bridge, so we call a parameterized relay with the clone sender/relay (read from
        // the fake chainlog). Mirrors the Eth<->Base relayToL2 overload. Migration semantics unchanged.
        _relayToL2(
            govSender, govRelay, AVAX_EID, e.oldAvaxGovRelay, m.l2Spell,
            abi.encodeCall(
                LZAvaxMigrationL2SpellLike.migrateAvaxRemote,
                (m.recvUlnCfg, m.newL2GovRelay, m.avaxUsds, m.avaxSusds)
            ),
            m.gas, m.maxFee
        );

        {
        // ============================ USDS OFT V2 swap ============================
        address usds = chainlog.getAddress("USDS");

        LZInit.activateOft(m.usds.oft, AVAX_EID, m.usds.cfg, m.usds.rateLimits, m.usds.rlAccountingType, usds, pProxy);
        LZInit.updateGlobalRateLimits(m.usds.oft, m.usdsGlobalLimits);

        uint256 before = TokenLike(usds).balanceOf(pProxy);
        LockboxOftLike(e.oldL1UsdsOft).migrateLockedTokens(pProxy);
        uint256 migrated = TokenLike(usds).balanceOf(pProxy) - before;
        TokenLike(usds).transfer(m.usds.oft, e.avaxUsdsBacking);
        TokenLike(usds).transfer(e.oldL1UsdsOft, migrated - e.avaxUsdsBacking);

        OFTAdapterLike(e.oldL1UsdsOft).setPeer(AVAX_EID, bytes32(0));
        LZInit.updateRateLimits(e.oldL1UsdsOft, AVAX_EID, RateLimits(0, 0, 0, 0));

        chainlog.setAddress("USDS_OFT",    m.usds.oft);
        chainlog.setAddress(m.legacyCLKey, e.oldL1UsdsOft);
        }

        // ============================ sUSDS OFT V2 swap ===========================
        LZInit.activateOft(m.susds.oft, AVAX_EID, m.susds.cfg, m.susds.rateLimits, m.susds.rlAccountingType, chainlog.getAddress("SUSDS"), pProxy);
        LZInit.updateGlobalRateLimits(m.susds.oft, m.susdsGlobalLimits);

        chainlog.setAddress("SUSDS_OFT", m.susds.oft);

        // ==========================================================================
        // Gov bridge: update the L1 send DVN set, then swap the gov-relay whitelist.
        LZInit.setUlnConfig(govSender, AVAX_EID, sendLib, m.sendUlnCfg);

        GovOAppSenderLike(govSender).setCanCallTarget(govRelay, AVAX_EID, bytes32(uint256(uint160(m.newL2GovRelay))), true);
        GovOAppSenderLike(govSender).setCanCallTarget(govRelay, AVAX_EID, bytes32(uint256(uint160(e.oldAvaxGovRelay))), false);
    }

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

    // Parameterized transcription of LZInit.relayToL2 (which hardcodes the production chainlog gov
    // bridge) so the clone relays through the CLONE gov sender + L1 relay. Byte-identical logic.
    // Split into _quoteRelayToL2 + _doRelayEVM to avoid stack-too-deep without via-ir (same split the
    // Eth<->Base relayToL2 overload used).
    function _relayToL2(
        address       govSender,
        address       l1Relay,
        uint32        remoteEid,
        address       l2GovRelay,
        address       l2Spell,
        bytes  memory targetData,
        uint128       gas,
        uint256       maxFee
    ) private {
        (bytes memory extraOptions, MessagingFee memory fee) =
            _quoteRelayToL2(govSender, remoteEid, l2GovRelay, l2Spell, targetData, gas);
        require(fee.lzTokenFee == 0,              "LZInit/lz-token-fee-nonzero");
        require(fee.nativeFee <= maxFee,          "LZInit/fee-exceeds-max");
        require(l1Relay.balance >= fee.nativeFee, "LZInit/insufficient-relay-balance");
        _doRelayEVM(l1Relay, remoteEid, l2GovRelay, l2Spell, targetData, extraOptions, fee);
    }

    function _quoteRelayToL2(
        address       govSender,
        uint32        remoteEid,
        address       l2GovRelay,
        address       l2Spell,
        bytes  memory targetData,
        uint128       gas
    ) private view returns (bytes memory extraOptions, MessagingFee memory fee) {
        extraOptions = _encodeOpts(gas);
        fee = GovOAppSenderLike(govSender).quoteTx(
            TxParams({
                dstEid:       remoteEid,
                dstTarget:    bytes32(uint256(uint160(l2GovRelay))),
                dstCallData:  abi.encodeCall(L2GovernanceRelayLike.relay, (l2Spell, targetData)),
                extraOptions: extraOptions
            }),
            false
        );
    }

    function _doRelayEVM(
        address             l1Relay,
        uint32              remoteEid,
        address             l2GovRelay,
        address             l2Spell,
        bytes  memory       targetData,
        bytes  memory       extraOptions,
        MessagingFee memory fee
    ) private {
        L1GovernanceRelayLike(l1Relay).relayEVM({
            dstEid:            remoteEid,
            l2GovernanceRelay: l2GovRelay,
            target:            l2Spell,
            targetData:        targetData,
            extraOptions:      extraOptions,
            fee:               fee,
            refundAddress:     l1Relay
        });
    }

    // Identical bytes to LZInit._encodeLzReceiveOptions(gas) (type-3 lzReceive option).
    function _encodeOpts(uint128 gas) private pure returns (bytes memory) {
        return abi.encodePacked(hex"0003", uint8(1), uint16(17), uint8(1), gas);
    }

    // ---- transcription of migrateAvaxRemote (address sources parameterized) ----
    function migrateAvaxRemote(
        UlnConfig     memory recvUlnCfg,
        address              newRelay,
        OftActivation memory avaxUsds,
        OftActivation memory avaxSusds,
        CloneEnv      memory e
    ) internal {
        // OFT token authority: rely the new adapters, deny the old ones.
        TokenLike(e.avaxUsds).rely(avaxUsds.oft);   TokenLike(e.avaxUsds).deny(e.oldAvaxUsdsOft);
        TokenLike(e.avaxSusds).rely(avaxSusds.oft); TokenLike(e.avaxSusds).deny(e.oldAvaxSusdsOft);

        // Activate the new remote OFTs for the Ethereum route.
        LZInit.activateOft(avaxUsds.oft,  ETH_EID, avaxUsds.cfg,  avaxUsds.rateLimits,  avaxUsds.rlAccountingType,  e.avaxUsds,  address(this));
        LZInit.activateOft(avaxSusds.oft, ETH_EID, avaxSusds.cfg, avaxSusds.rateLimits, avaxSusds.rlAccountingType, e.avaxSusds, address(this));

        // Gov receiver: new receive DVN set (lib read from the endpoint).
        (address recvLib,) = EndpointLike(OAppLike(e.avaxGovReceiver).endpoint()).getReceiveLibrary(e.avaxGovReceiver, ETH_EID);
        LZInit.setUlnConfig(e.avaxGovReceiver, ETH_EID, recvLib, recvUlnCfg);

        // Grant token authority to the new relay.
        TokenLike(e.avaxUsds).rely(newRelay);
        TokenLike(e.avaxSusds).rely(newRelay);

        // Hand delegate + ownership to the new relay: gov receiver + both new adapters.
        address[3] memory oapps = [e.avaxGovReceiver, avaxUsds.oft, avaxSusds.oft];
        for (uint256 i; i < oapps.length; ++i) {
            OAppLike(oapps[i]).setDelegate(newRelay);
            OAppLike(oapps[i]).transferOwnership(newRelay);
        }

        // Old relay denies itself on the tokens.
        TokenLike(e.avaxUsds).deny(address(this));
        TokenLike(e.avaxSusds).deny(address(this));
    }
}
