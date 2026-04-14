// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import { LZInit, ExecutorConfig, UlnConfig } from "./LZInit.sol";

/**
 * @title  L2InitOFTAdapterSpell
 * @notice L2 spell for wiring an OFT adapter to a new remote chain.
 *         Deployed once per L2, delegatecalled by L2GovernanceRelay via relayInitOFTAdapter.
 */
contract L2InitOFTAdapterSpell {

    function execute(
        address        endpoint,
        address        oftAdapter,
        uint32         dstEid,
        address        remoteMintBurn,
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
        LZInit.initOFTAdapter(
            endpoint, oftAdapter, dstEid, remoteMintBurn,
            sendLib, recvLib, execCfg, sendUlnCfg, recvUlnCfg,
            inboundWindow, inboundLimit, outboundWindow, outboundLimit, optionsGas
        );
    }
}
