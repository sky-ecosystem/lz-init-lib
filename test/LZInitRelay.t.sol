// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { LZInit, UlnConfig, ExecutorConfig, MessagingFee } from "deploy/LZInit.sol";
import { L2InitOFTAdapterSpell } from "deploy/L2InitOFTAdapterSpell.sol";

import { Bridge }                from "xchain-helpers/testing/Bridge.sol";
import { Domain, DomainHelpers } from "xchain-helpers/testing/Domain.sol";
import { LZBridgeTesting }      from "xchain-helpers/testing/bridges/LZBridgeTesting.sol";
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

interface IGovOAppSender {
    function sendTx(TxParams calldata params, MessagingFee calldata fee, address refundAddress) external payable;
    function quoteTx(TxParams calldata params, bool payInLzToken) external view returns (MessagingFee memory);
}

interface IL2GovernanceRelay {
    function relay(address target, bytes calldata targetData) external;
}

interface EndpointReadLike {
    function getSendLibrary(address oapp, uint32 eid) external view returns (address);
    function getReceiveLibrary(address oapp, uint32 eid) external view returns (address lib, bool isDefault);
}

interface OFTReadLike {
    function peers(uint32 eid) external view returns (bytes32);
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
    function outboundRateLimits(uint32 eid) external view returns (uint128, uint48, uint256, uint256);
    function inboundRateLimits(uint32 eid) external view returns (uint128, uint48, uint256, uint256);
}

/*** Relay tests ***/

contract LZInitRelayTest is Test {

    using DomainHelpers   for *;
    using LZBridgeTesting for *;
    using OptionsBuilder  for bytes;

    ChainlogReadLike constant chainlog = ChainlogReadLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    address GOV_SENDER;
    address L1_GOV_RELAY;

    // --- Avalanche (existing deployment) ---
    address constant AVAX_ENDPOINT          = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant AVAX_GOV_OAPP_RECEIVER = 0x6fdd46947ca6903c8c159d1dF2012Bc7fC5cEeec;
    address constant AVAX_L2_GOV_RELAY      = 0xe928885BCe799Ed933651715608155F01abA23cA;
    address constant AVAX_USDS_OFT          = 0x4fec40719fD9a8AE3F8E20531669DEC5962D2619;
    address constant AVAX_SEND_LIB          = 0x197D1333DEA5Fe0D6600E9b396c7f1B1cFCc558a;
    address constant AVAX_RECV_LIB          = 0xbf3521d309642FA9B1c91A08609505BA09752c61;
    address constant AVAX_EXECUTOR          = 0x90E595783E43eb89fF07f63d27B8430e6B44bD9c;
    address constant AVAX_DVN_LZ_LABS       = 0x962F502A63F5FBeB44DC9ab932122648E8352959;
    address constant AVAX_DVN_NETHERMIND    = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;

    uint32 constant BASE_EID = 30184;
    uint32 constant AVAX_EID = 30106;

    Domain mainnet;
    Bridge bridge;

    function test_relayInitOFTAdapter() public {
        mainnet = getChain("mainnet").createSelectFork();
        GOV_SENDER   = chainlog.getAddress("LZ_GOV_SENDER");
        L1_GOV_RELAY = chainlog.getAddress("LZ_GOV_RELAY");

        Domain memory avalanche = getChain("avalanche").createFork();
        bridge = LZBridgeTesting.createLZBridge(mainnet, avalanche);

        // GOV_SENDER is already wired for Avalanche from the live deployment.
        // Deploy only the L2 spell on the Avalanche fork.
        avalanche.selectFork();
        L2InitOFTAdapterSpell l2Spell = new L2InitOFTAdapterSpell();

        // Configure Avalanche USDS OFT to talk to Base (new route)
        address[] memory avaxDVNs = new address[](2);
        avaxDVNs[0] = AVAX_DVN_LZ_LABS;
        avaxDVNs[1] = AVAX_DVN_NETHERMIND;

        uint32  newDstEid      = BASE_EID;
        address remoteMintBurn = makeAddr("remoteMintBurn");
        uint48  inboundWindow  = 1 days;
        uint256 inboundLimit   = 5_000_000e18;
        uint48  outboundWindow = 1 days;
        uint256 outboundLimit  = 5_000_000e18;
        uint128 optionsGas     = 130_000;

        mainnet.selectFork();

        bytes memory spellCallData = abi.encodeCall(
            L2InitOFTAdapterSpell.execute,
            (
                AVAX_ENDPOINT, AVAX_USDS_OFT, newDstEid, remoteMintBurn,
                AVAX_SEND_LIB, AVAX_RECV_LIB,
                ExecutorConfig({ maxMessageSize: 10000, executor: AVAX_EXECUTOR }),
                UlnConfig({ confirmations: 12, requiredDVNCount: 2, optionalDVNCount: 0, optionalDVNThreshold: 0, requiredDVNs: avaxDVNs, optionalDVNs: new address[](0) }),
                UlnConfig({ confirmations: 15, requiredDVNCount: 2, optionalDVNCount: 0, optionalDVNThreshold: 0, requiredDVNs: avaxDVNs, optionalDVNs: new address[](0) }),
                inboundWindow, inboundLimit, outboundWindow, outboundLimit, optionsGas
            )
        );

        bytes memory extraOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(500_000, 0);

        TxParams memory txParams = TxParams({
            dstEid:       AVAX_EID,
            dstTarget:    bytes32(uint256(uint160(AVAX_L2_GOV_RELAY))),
            dstCallData:  abi.encodeCall(IL2GovernanceRelay.relay, (address(l2Spell), spellCallData)),
            extraOptions: extraOptions
        });

        MessagingFee memory fee = IGovOAppSender(GOV_SENDER).quoteTx(txParams, false);
        vm.deal(L1_GOV_RELAY, fee.nativeFee);
        vm.prank(L1_GOV_RELAY);
        IGovOAppSender(GOV_SENDER).sendTx{value: fee.nativeFee}(txParams, fee, L1_GOV_RELAY);

        bridge.relayMessagesToDestination(true, GOV_SENDER, AVAX_GOV_OAPP_RECEIVER);

        // Verify USDS OFT on Avalanche is configured for Base
        assertEq(OFTReadLike(AVAX_USDS_OFT).peers(newDstEid), bytes32(uint256(uint160(remoteMintBurn))), "peer");
        assertEq(EndpointReadLike(AVAX_ENDPOINT).getSendLibrary(AVAX_USDS_OFT, newDstEid), AVAX_SEND_LIB, "send lib");
        (address rl,) = EndpointReadLike(AVAX_ENDPOINT).getReceiveLibrary(AVAX_USDS_OFT, newDstEid);
        assertEq(rl, AVAX_RECV_LIB, "recv lib");

        (,,, uint256 ibLimit) = OFTReadLike(AVAX_USDS_OFT).inboundRateLimits(newDstEid);
        assertEq(ibLimit, inboundLimit, "inbound limit");
        (,,, uint256 obLimit) = OFTReadLike(AVAX_USDS_OFT).outboundRateLimits(newDstEid);
        assertEq(obLimit, outboundLimit, "outbound limit");

        bytes memory expectedOpts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(optionsGas, 0);
        assertEq(OFTReadLike(AVAX_USDS_OFT).enforcedOptions(newDstEid, 1), expectedOpts, "enforced options SEND");
        assertEq(OFTReadLike(AVAX_USDS_OFT).enforcedOptions(newDstEid, 2), expectedOpts, "enforced options SEND_AND_CALL");
    }

}
