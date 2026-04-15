// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { LZInit, UlnConfig, ExecutorConfig, MessagingFee, OAppLike, OFTAdapterLike } from "deploy/LZInit.sol";
import { LZL2Spell } from "deploy/LZL2Spell.sol";

import { Bridge }                from "xchain-helpers/testing/Bridge.sol";
import { Domain, DomainHelpers } from "xchain-helpers/testing/Domain.sol";
import { LZBridgeTesting }       from "xchain-helpers/testing/bridges/LZBridgeTesting.sol";
import { OptionsBuilder }        from "layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

interface ChainlogReadLike {
    function getAddress(bytes32) external view returns (address);
}

struct TxParams {
    uint32  dstEid;
    bytes32 dstTarget;
    bytes   dstCallData;
    bytes   extraOptions;
}

interface GovSenderLike {
    function sendTx(TxParams calldata params, MessagingFee calldata fee, address refundAddress) external payable;
    function quoteTx(TxParams calldata params, bool payInLzToken) external view returns (MessagingFee memory);
}

interface L2GovernanceRelayLike {
    function relay(address target, bytes calldata targetData) external;
}

interface EndpointLike {
    function getSendLibrary(address oapp, uint32 eid) external view returns (address);
    function getReceiveLibrary(address oapp, uint32 eid) external view returns (address lib, bool isDefault);
}

interface OAppOptionsLike {
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
}

/*** Relay tests ***/

contract LZInitRelayTest is Test {

    using DomainHelpers   for *;
    using LZBridgeTesting for *;
    using OptionsBuilder  for bytes;

    ChainlogReadLike constant chainlog = ChainlogReadLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    address GOV_SENDER;
    address L1_GOV_RELAY;
    address AVAX_GOV_OAPP_RECEIVER;
    address AVAX_USDS_OFT;

    // --- Avalanche (existing deployment, not resolvable from mainnet) ---
    address constant AVAX_ENDPOINT          = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant AVAX_L2_GOV_RELAY      = 0xe928885BCe799Ed933651715608155F01abA23cA;
    address constant AVAX_SEND_LIB          = 0x197D1333DEA5Fe0D6600E9b396c7f1B1cFCc558a;
    address constant AVAX_RECV_LIB          = 0xbf3521d309642FA9B1c91A08609505BA09752c61;
    address constant AVAX_EXECUTOR          = 0x90E595783E43eb89fF07f63d27B8430e6B44bD9c;
    address constant AVAX_DVN_LZ_LABS       = 0x962F502A63F5FBeB44DC9ab932122648E8352959;
    address constant AVAX_DVN_NETHERMIND    = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;

    uint32 constant ETH_EID  = 30101;
    uint32 constant BASE_EID = 30184;
    uint32 constant AVAX_EID = 30106;

    Domain    mainnet;
    Bridge    bridge;
    LZL2Spell l2Spell;

    function setUp() public {
        // Pinned to the block where SUSDS_OFT was configured for Avalanche, still with 0 rate limits.
        mainnet      = getChain("mainnet").createSelectFork(24871363);
        GOV_SENDER   = chainlog.getAddress("LZ_GOV_SENDER");
        L1_GOV_RELAY = chainlog.getAddress("LZ_GOV_RELAY");

        AVAX_GOV_OAPP_RECEIVER = address(uint160(uint256(OAppLike(GOV_SENDER).peers(AVAX_EID))));
        AVAX_USDS_OFT = address(uint160(uint256(OFTAdapterLike(chainlog.getAddress("USDS_OFT")).peers(AVAX_EID))));

        Domain memory avalanche = getChain("avalanche").createFork();
        bridge = LZBridgeTesting.createLZBridge(mainnet, avalanche);

        bridge.destination.selectFork();
        l2Spell = new LZL2Spell();
    }

    function _relaySpell(bytes memory spellCallData) internal {
        mainnet.selectFork();

        bytes memory extraOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(500_000, 0);

        TxParams memory txParams = TxParams({
            dstEid:       AVAX_EID,
            dstTarget:    bytes32(uint256(uint160(AVAX_L2_GOV_RELAY))),
            dstCallData:  abi.encodeCall(L2GovernanceRelayLike.relay, (address(l2Spell), spellCallData)),
            extraOptions: extraOptions
        });

        MessagingFee memory fee = GovSenderLike(GOV_SENDER).quoteTx(txParams, false);
        vm.deal(L1_GOV_RELAY, fee.nativeFee);
        vm.prank(L1_GOV_RELAY);
        GovSenderLike(GOV_SENDER).sendTx{value: fee.nativeFee}(txParams, fee, L1_GOV_RELAY);

        bridge.relayMessagesToDestination(true, GOV_SENDER, AVAX_GOV_OAPP_RECEIVER);
    }

    function test_relayAddOftRoute() public {
        address[] memory avaxDVNs = new address[](2);
        avaxDVNs[0] = AVAX_DVN_LZ_LABS;
        avaxDVNs[1] = AVAX_DVN_NETHERMIND;

        uint32  newDstEid      = BASE_EID;
        address peer           = makeAddr("peer");
        uint48  inboundWindow  = 1 days;
        uint256 inboundLimit   = 5_000_000e18;
        uint48  outboundWindow = 1 days;
        uint256 outboundLimit  = 5_000_000e18;
        uint128 optionsGas     = 130_000;

        _relaySpell(abi.encodeCall(
            LZL2Spell.addOftRoute,
            (
                AVAX_ENDPOINT, AVAX_USDS_OFT, newDstEid, peer,
                AVAX_SEND_LIB, AVAX_RECV_LIB,
                ExecutorConfig({ maxMessageSize: 10000, executor: AVAX_EXECUTOR }),
                UlnConfig({ confirmations: 12, requiredDVNCount: 2, optionalDVNCount: 0, optionalDVNThreshold: 0, requiredDVNs: avaxDVNs, optionalDVNs: new address[](0) }),
                UlnConfig({ confirmations: 15, requiredDVNCount: 2, optionalDVNCount: 0, optionalDVNThreshold: 0, requiredDVNs: avaxDVNs, optionalDVNs: new address[](0) }),
                inboundWindow, inboundLimit, outboundWindow, outboundLimit, optionsGas
            )
        ));

        assertEq(OFTAdapterLike(AVAX_USDS_OFT).peers(newDstEid), bytes32(uint256(uint160(peer))), "peer");
        assertEq(EndpointLike(AVAX_ENDPOINT).getSendLibrary(AVAX_USDS_OFT, newDstEid), AVAX_SEND_LIB, "send lib");
        (address rl,) = EndpointLike(AVAX_ENDPOINT).getReceiveLibrary(AVAX_USDS_OFT, newDstEid);
        assertEq(rl, AVAX_RECV_LIB, "recv lib");

        (,,, uint256 ibLimit) = OFTAdapterLike(AVAX_USDS_OFT).inboundRateLimits(newDstEid);
        assertEq(ibLimit, inboundLimit, "inbound limit");
        (,,, uint256 obLimit) = OFTAdapterLike(AVAX_USDS_OFT).outboundRateLimits(newDstEid);
        assertEq(obLimit, outboundLimit, "outbound limit");

        bytes memory expectedOpts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(optionsGas, 0);
        assertEq(OAppOptionsLike(AVAX_USDS_OFT).enforcedOptions(newDstEid, 1), expectedOpts, "enforced options SEND");
        assertEq(OAppOptionsLike(AVAX_USDS_OFT).enforcedOptions(newDstEid, 2), expectedOpts, "enforced options SEND_AND_CALL");
    }

    function test_relayActivateOft() public {
        mainnet.selectFork();
        address ethSusdsOft  = chainlog.getAddress("SUSDS_OFT");
        address avaxSusdsOft = address(uint160(uint256(OFTAdapterLike(ethSusdsOft).peers(AVAX_EID))));

        bridge.destination.selectFork();
        address expectedOwner = OFTAdapterLike(avaxSusdsOft).owner();
        address expectedToken = OFTAdapterLike(avaxSusdsOft).token();
        bytes32 expectedPeer  = OFTAdapterLike(avaxSusdsOft).peers(ETH_EID);
        uint8   expectedRlAt  = OFTAdapterLike(avaxSusdsOft).rateLimitAccountingType();

        uint48  inboundWindow  = 1 days;
        uint256 inboundLimit   = 2_000_000e18;
        uint48  outboundWindow = 1 days;
        uint256 outboundLimit  = 2_000_000e18;

        _relaySpell(abi.encodeCall(
            LZL2Spell.activateOft,
            (
                avaxSusdsOft, AVAX_ENDPOINT, ETH_EID, expectedPeer,
                expectedOwner, expectedToken, expectedRlAt,
                inboundWindow, inboundLimit, outboundWindow, outboundLimit
            )
        ));

        (,,, uint256 ibLimit) = OFTAdapterLike(avaxSusdsOft).inboundRateLimits(ETH_EID);
        assertEq(ibLimit, inboundLimit, "inbound limit");
        (,,, uint256 obLimit) = OFTAdapterLike(avaxSusdsOft).outboundRateLimits(ETH_EID);
        assertEq(obLimit, outboundLimit, "outbound limit");
    }

    function test_relayUpdateRateLimits() public {
        uint48  newInboundWindow  = 1 days;
        uint256 newInboundLimit   = 10_000_000e18;
        uint48  newOutboundWindow = 1 days;
        uint256 newOutboundLimit  = 10_000_000e18;

        _relaySpell(abi.encodeCall(
            LZL2Spell.updateRateLimits,
            (AVAX_USDS_OFT, ETH_EID, newInboundWindow, newInboundLimit, newOutboundWindow, newOutboundLimit)
        ));

        (,,, uint256 ibLimit) = OFTAdapterLike(AVAX_USDS_OFT).inboundRateLimits(ETH_EID);
        assertEq(ibLimit, newInboundLimit, "inbound limit");
        (,,, uint256 obLimit) = OFTAdapterLike(AVAX_USDS_OFT).outboundRateLimits(ETH_EID);
        assertEq(obLimit, newOutboundLimit, "outbound limit");
    }

}
