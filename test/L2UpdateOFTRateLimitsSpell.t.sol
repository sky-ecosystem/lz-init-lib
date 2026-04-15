// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { L2UpdateOFTRateLimitsSpell } from "deploy/L2UpdateOFTRateLimitsSpell.sol";
import { LZHelpers, ChainlogLike } from "deploy/LZHelpers.sol";

import { Bridge } from "xchain-helpers/testing/Bridge.sol";
import { Domain, DomainHelpers } from "xchain-helpers/testing/Domain.sol";
import { LZBridgeTesting } from "xchain-helpers/testing/bridges/LZBridgeTesting.sol";

interface OAppReadLike {
    function peers(uint32 eid) external view returns (bytes32);
    function owner() external view returns (address);
}

interface OFTReadLike is OAppReadLike {
    function outboundRateLimits(uint32 eid) external view returns (uint128 lastUpdated, uint48 window, uint256 amountInFlight, uint256 limit);
    function inboundRateLimits(uint32 eid) external view returns (uint128 lastUpdated, uint48 window, uint256 amountInFlight, uint256 limit);
}

/*** Test contract ***/
contract LZUpdateRateLimitsTest is Test {

    using DomainHelpers   for *;
    using LZBridgeTesting for *;

    ChainlogLike constant chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    uint48  inboundWindow = 24 hours;
    uint256 inboundLimit = 50_000_000 ether;
    uint48  outboundWindow = 24 hours;
    uint256 outboundLimit = 50_000_000 ether;
    
    address MCD_PAUSE_PROXY;
    address LZ_GOV_SENDER;
    address LZ_GOV_RELAY;
    address USDS_OFT;

    address govOAppReceiver;
    address l2GovRelay;
    address usdsMintBurn;
    L2UpdateOFTRateLimitsSpell l2Spell;

    uint32 constant ETHEREUM_EID  = 30101;
    uint32 constant AVALANCHE_EID = 30106;

    Domain mainnet;
    Domain avalanche;
    Bridge bridge;

    function setUp() public {
        // Set up the bridge (pinned to the block after ethereum <> avalanche wire is done from spell)
        mainnet = getChain("mainnet").createSelectFork(24871364);
        avalanche = getChain("avalanche").createFork(82186129);
        bridge = mainnet.createLZBridge(avalanche);

        mainnet.selectFork();

        MCD_PAUSE_PROXY  = chainlog.getAddress("MCD_PAUSE_PROXY");
        LZ_GOV_SENDER    = chainlog.getAddress("LZ_GOV_SENDER");
        LZ_GOV_RELAY     = chainlog.getAddress("LZ_GOV_RELAY");
        USDS_OFT         = chainlog.getAddress("USDS_OFT");

        // Set up remote addresses
        govOAppReceiver = bytes32ToAddress(OAppReadLike(LZ_GOV_SENDER).peers(AVALANCHE_EID));
        usdsMintBurn    = bytes32ToAddress(OFTReadLike(USDS_OFT).peers(AVALANCHE_EID));
       
        avalanche.selectFork();
        // Deploy the L2 spell
        l2Spell = new L2UpdateOFTRateLimitsSpell();

        // Set up remote addresses from avalanche
        l2GovRelay = OAppReadLike(govOAppReceiver).owner();

        mainnet.selectFork();
    }

    function test_setRateLimits() public {
        // Donate some ETH to pay LZ fee
        vm.deal(address(MCD_PAUSE_PROXY), 0.00003 ether);

        // Check state before relay
        avalanche.selectFork();
        ( , uint48 inWindowBefore, , uint256 inLimitBefore) = OFTReadLike(usdsMintBurn).inboundRateLimits(ETHEREUM_EID);
        ( , uint48 outWindowBefore, , uint256 outLimitBefore) = OFTReadLike(usdsMintBurn).outboundRateLimits(ETHEREUM_EID);
        assertNotEq(inLimitBefore, inboundLimit);
        assertNotEq(outLimitBefore, outboundLimit);
        // Check rateLimits window values are not already set
        assertEq(inWindowBefore, inboundWindow);
        assertEq(outWindowBefore, outboundWindow);

        // Execute core spell and relay messages
        mainnet.selectFork();
        vm.startPrank(MCD_PAUSE_PROXY);
        LZHelpers.relayUpdateOFTRateLimits(
            AVALANCHE_EID,
            l2GovRelay,
            address(l2Spell),
            uint128(100_000),
            usdsMintBurn,
            ETHEREUM_EID,
            inboundWindow,
            inboundLimit,
            outboundWindow,
            outboundLimit
        ); 
        vm.stopPrank();
        bridge.relayMessagesToDestination(true, LZ_GOV_SENDER, address(govOAppReceiver));

        // Check updated rate limits on the OFT adapter
        ( , uint48 inWindow, , uint256 inLimit) = OFTReadLike(usdsMintBurn).inboundRateLimits(ETHEREUM_EID);
        ( , uint48 outWindow, , uint256 outLimit) = OFTReadLike(usdsMintBurn).outboundRateLimits(ETHEREUM_EID);
        assertEq(inWindow, inboundWindow);
        assertEq(inLimit, inboundLimit);
        assertEq(outWindow, outboundWindow);
        assertEq(outLimit, outboundLimit);
    }

    function test_setRateLimits_revertsIfNoPeerSet() public {
        uint32 baseEid = 30184;
        // Switch to Avalanche and test the spell directly
        avalanche.selectFork();

        // Pre-condition: peer is not set
        assertEq(OFTReadLike(usdsMintBurn).peers(baseEid), bytes32(0), "peer must not be set");

        // Expect the spell to revert when peer is not set
        vm.expectRevert("LZUpdateRateLimits/no-peer-set-for-dstEid");
        vm.prank(l2GovRelay);
        l2Spell.execute(baseEid, usdsMintBurn, inboundWindow, inboundLimit, outboundWindow, outboundLimit);
    }

    function bytes32ToAddress(bytes32 b) internal pure returns (address) {
        return address(uint160(uint256(b)));
    }
}
