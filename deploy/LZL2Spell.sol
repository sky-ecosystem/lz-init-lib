// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { LZInit, OftConfig, RateLimits, UlnConfig } from "./LZInit.sol";

/// @notice L2 spell for LZ configuration on remote chains. Deployed once
///         per L2, delegatecalled by L2GovernanceRelay.
contract LZL2Spell {

    address public immutable SELF = address(this);

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
        address           owner,
        address           endpoint
    ) external {
        LZInit.activateOft(oft, remoteEid, cfg, rateLimits, rlAccountingType, token, owner, endpoint);
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

    /// @dev Based on https://github.com/sky-ecosystem/lockstake/blob/e389dc18fa21b5ae460714522a9f484d0b1b9f30/src/Multicall.sol#L9,
    ///      using `SELF` instead of `address(this)` because this contract
    ///      runs in the relay's context.
    function multicall(bytes[] calldata calls) external {
        for (uint256 i; i < calls.length; ++i) {
            (bool success, bytes memory result) = SELF.delegatecall(calls[i]);
            if (!success) {
                if (result.length == 0) revert("LZL2Spell/multicall-failed");
                assembly ("memory-safe") {
                    revert(add(32, result), mload(result))
                }
            }
        }
    }

}
