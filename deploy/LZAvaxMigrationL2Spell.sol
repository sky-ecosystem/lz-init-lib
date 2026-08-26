// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { LZAvaxMigrationInit, OftActivation, UlnConfig } from "./LZAvaxMigrationInit.sol";

/// @notice One-off L2 spell for the Avalanche half of the migration, delegatecalled by the (old)
///         L2GovernanceRelay.
contract LZAvaxMigrationL2Spell {
    function migrateAvaxRemote(
        UlnConfig     memory recvUlnCfg,
        address              newRelay,
        OftActivation memory avaxUsds,
        OftActivation memory avaxSusds
    ) external {
        LZAvaxMigrationInit.migrateAvaxRemote(recvUlnCfg, newRelay, avaxUsds, avaxSusds);
    }
}
