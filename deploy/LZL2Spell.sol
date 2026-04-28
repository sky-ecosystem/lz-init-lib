// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import { LZInit, OftConfig, RateLimits } from "./LZInit.sol";

/**
 * @title  LZL2Spell
 * @notice L2 spell for LZ configuration on remote chains.
 *         Deployed once per L2, delegatecalled by L2GovernanceRelay.
 */
contract LZL2Spell {

    function wireOftPeer(
        address    oft,
        uint32     dstEid,
        OftConfig  memory cfg,
        RateLimits memory rateLimits
    ) external {
        LZInit.wireOftPeer(oft, dstEid, cfg, rateLimits);
    }

    function activateOft(
        address           oft,
        uint32            dstEid,
        OftConfig  memory cfg,
        RateLimits memory rateLimits,
        uint8             rlAccountingType,
        address           token,
        address           owner
    ) external {
        LZInit.activateOft(oft, dstEid, cfg, rateLimits, rlAccountingType, token, owner);
    }

    function updateRateLimits(address oft, uint32 dstEid, RateLimits memory rateLimits) external {
        LZInit.updateRateLimits(oft, dstEid, rateLimits);
    }

    function unpauseOft(address oft) external {
        LZInit.unpauseOft(oft);
    }

}
