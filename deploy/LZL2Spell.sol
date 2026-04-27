// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import { LZInit, ExecutorConfig, UlnConfig, OftConfig } from "./LZInit.sol";

/**
 * @title  LZL2Spell
 * @notice L2 spell for LZ configuration on remote chains.
 *         Deployed once per L2, delegatecalled by L2GovernanceRelay.
 */
contract LZL2Spell {

    function wireOftPeer(
        address        endpoint,
        address        oft,
        uint32         dstEid,
        address        peer,
        address        sendLib,
        address        recvLib,
        ExecutorConfig memory execCfg,
        UlnConfig      memory sendUlnCfg,
        UlnConfig      memory recvUlnCfg,
        uint48         inboundWindow,
        uint256        inboundLimit,
        uint48         outboundWindow,
        uint256        outboundLimit,
        uint128        optionsGas
    ) external {
        LZInit.wireOftPeer(
            endpoint, oft, dstEid, peer,
            sendLib, recvLib, execCfg, sendUlnCfg, recvUlnCfg,
            inboundWindow, inboundLimit, outboundWindow, outboundLimit, optionsGas
        );
    }

    function activateOft(
        address oft,
        address endpoint,
        uint32  dstEid,
        OftConfig memory expected,
        uint48  inboundWindow,
        uint256 inboundLimit,
        uint48  outboundWindow,
        uint256 outboundLimit
    ) external {
        LZInit.activateOft(
            oft, endpoint, dstEid, expected,
            inboundWindow, inboundLimit, outboundWindow, outboundLimit
        );
    }

    function updateRateLimits(
        address oft,
        uint32  dstEid,
        uint48  inboundWindow,
        uint256 inboundLimit,
        uint48  outboundWindow,
        uint256 outboundLimit
    ) external {
        LZInit.updateRateLimits(
            oft, dstEid,
            inboundWindow, inboundLimit, outboundWindow, outboundLimit
        );
    }

}
