// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import { LZInit, OftConfig, RateLimits, UlnConfig } from "./LZInit.sol";

/// @notice L2 spell for LZ configuration on remote chains. Deployed once
///         per L2, delegatecalled by L2GovernanceRelay.
contract LZL2Spell {

    function wireOftPeer(
        address           oft,
        uint32            remoteEid,
        OftConfig  memory cfg,
        RateLimits memory rateLimits
    ) external {
        LZInit.wireOftPeer(oft, remoteEid, cfg, rateLimits);
    }

    function activateOft(
        address           oft,
        uint32            remoteEid,
        OftConfig  memory cfg,
        RateLimits memory rateLimits,
        uint8             rlAccountingType,
        address           token,
        address           owner
    ) external {
        LZInit.activateOft(oft, remoteEid, cfg, rateLimits, rlAccountingType, token, owner);
    }

    function updateRateLimits(address oft, uint32 remoteEid, RateLimits memory rateLimits) external {
        LZInit.updateRateLimits(oft, remoteEid, rateLimits);
    }

    function setUlnConfig(
        address          oapp,
        uint32           remoteEid,
        address          lib,
        UlnConfig memory ulnCfg
    ) external {
        LZInit.setUlnConfig(oapp, remoteEid, lib, ulnCfg);
    }

    function unpauseOft(address oft) external {
        LZInit.unpauseOft(oft);
    }

}
