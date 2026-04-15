// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;
import { L2UpdateOFTRateLimitsSpell } from "deploy/L2UpdateOFTRateLimitsSpell.sol";

import { GasProfilerScript, TestParams } from "@layerzerolabs/script-devtools-evm-foundry/scripts/GasProfiling/GasProfiler.s.sol";

contract SkyLinkGasProfiler is GasProfilerScript {

    uint32 constant  ETH_EID           = 30101;
    bytes32 constant ETH_GOV_SENDER    = bytes32(uint256(uint160(0x27FC1DD771817b53bE48Dc28789533BEa53C9CCA)));

    GasProfilerScript public gasProfiler = new GasProfilerScript();

    /// @notice Profile rate limits update spell lzReceive gas
    /// @dev Run with: REMOTE_RPC_URL=<rpc_url> forge script script/SkyLinkGasProfiler.s.sol:SkyLinkGasProfiler --sig "run_rate_limits_update_spell(uint32,address,address,address)" <dstEid> <receiver> <remoteEndpoint> <usdsOftAddress>
    function run_rate_limits_update_spell(uint32 dstEid, address receiver, address remoteEndpoint, address usdsOftAddress) external {
        bytes[] memory payloads = new bytes[](1);

        // payload for calling rate limit spell
        payloads[0] = abi.encodeCall(
            L2UpdateOFTRateLimitsSpell.execute,
            (ETH_EID, usdsOftAddress, 24 hours, 50_000_000, 24 hours, 50_000_000)
        );

        TestParams memory params = TestParams({
            srcEid:    ETH_EID,
            sender:    ETH_GOV_SENDER,
            dstEid:    dstEid,
            receiver:  receiver,
            payloads:  payloads,
            msgValue:  0,
            numOfRuns: 5
        });

        gasProfiler.run_lzReceive(_getRemoteRpcUrl(), remoteEndpoint, params);
    }

    function _getRemoteRpcUrl() private view returns (string memory) {
        return vm.envString("REMOTE_RPC_URL");
    }
}
