// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

struct RateLimitConfig {
    uint32  eid;
    uint48  window;
    uint256 limit;
}

interface OFTAdapterLike {
    function setRateLimits(RateLimitConfig[] calldata inbound, RateLimitConfig[] calldata outbound) external;
    function peers(uint32 eid) external view returns (bytes32);
}

/**
 * @title  L2UpdateOFTRateLimitsSpell
 * @notice L2 spell for updating the rate limits of an OFT adapter.
 *         Deployed once per L2, and it will be delegate called by L2GovernanceRelay when bridged from core spell.
 */
contract L2UpdateOFTRateLimitsSpell {

    function execute(
        uint32  dstEid,
        address oftAdapter,
        uint48  inboundWindow,
        uint256 inboundLimit,
        uint48  outboundWindow,
        uint256 outboundLimit
    ) external {
        OFTAdapterLike oft = OFTAdapterLike(oftAdapter);

        // Sanity check
        require(oft.peers(dstEid) != bytes32(0), "LZUpdateRateLimits/no-peer-set-for-dstEid");

        RateLimitConfig[] memory inboundCfg  = new RateLimitConfig[](1);
        RateLimitConfig[] memory outboundCfg = new RateLimitConfig[](1);

        inboundCfg[0]  = RateLimitConfig(dstEid, inboundWindow,  inboundLimit);
        outboundCfg[0] = RateLimitConfig(dstEid, outboundWindow, outboundLimit);
        oft.setRateLimits(inboundCfg, outboundCfg);
    }
}
