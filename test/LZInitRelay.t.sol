// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { LZInit, UlnConfig, ExecutorConfig, GovOAppSenderLike } from "deploy/LZInit.sol";

import { Bridge }                from "xchain-helpers/testing/Bridge.sol";
import { Domain, DomainHelpers } from "xchain-helpers/testing/Domain.sol";
import { LZBridgeTesting }      from "xchain-helpers/testing/bridges/LZBridgeTesting.sol";
import { LZGovBridgeForwarder, MessagingFee } from "xchain-helpers/forwarders/LZGovBridgeForwarder.sol";

import { OptionsBuilder } from "layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import { GovernanceOAppReceiverMock } from "lib/xchain-helpers/test/mocks/lz/GovernanceOAppReceiverMock.sol";
import { LZGovBridgeReceiver }       from "xchain-helpers/receivers/LZGovBridgeReceiver.sol";

/*** Test target contract on remote — receives governance calls ***/

contract TestTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }
}

/*** Relay test contract ***/

contract LZInitRelayTest is Test {

    using DomainHelpers   for *;
    using LZBridgeTesting for *;
    using OptionsBuilder  for bytes;

    // --- Ethereum mainnet addresses ---
    address constant ENDPOINT    = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant GOV_SENDER  = 0x27FC1DD771817b53bE48Dc28789533BEa53C9CCA;
    address constant L1_GOV_RELAY = 0x2beBFe397D497b66cB14461cB6ee467b4C3B7D61;
    address constant GOV_OWNER   = 0xBE8E3e3618f7474F8cB1d074A26afFef007E98FB;
    address constant SEND_LIB    = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    address constant RECV_LIB    = 0xc02Ab410f0734EFa3F14628780e6e695156024C2;
    address constant EXECUTOR    = 0x173272739Bd7Aa6e4e214714048a9fE699453059;

    // DVN addresses (Ethereum)
    address constant DVN_LZ_LABS    = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
    address constant DVN_NETHERMIND = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;

    // Base chain
    uint32  constant DST_EID      = 30184;
    address constant ENDPOINT_BASE = 0x1a44076050125825900e736c501f859c50fE728c;

    // Domains and bridge
    Domain  mainnet;
    Domain  remote;
    Bridge  bridge;

    // Remote contracts
    GovernanceOAppReceiverMock govOAppReceiver;
    TestTarget                testTarget;

    function setUp() public {
        mainnet = getChain("mainnet").createSelectFork();
        remote  = getChain("base").createFork();
        bridge  = LZBridgeTesting.createLZBridge(mainnet, remote);

        // --- Deploy remote-side contracts on Base fork ---
        remote.selectFork();

        govOAppReceiver = new GovernanceOAppReceiverMock(
            LZGovBridgeForwarder.ENDPOINT_ID_ETHEREUM,
            bytes32(uint256(uint160(GOV_SENDER))),
            ENDPOINT_BASE,
            address(this)
        );
        testTarget = new TestTarget();

        // --- Configure Ethereum side using init library ---
        mainnet.selectFork();

        address[] memory requiredDVNs = new address[](2);
        requiredDVNs[0] = DVN_LZ_LABS;
        requiredDVNs[1] = DVN_NETHERMIND;

        vm.startPrank(GOV_OWNER);
        LZInit.initGovSender(
            ENDPOINT,
            GOV_SENDER,
            DST_EID,
            address(govOAppReceiver),
            L1_GOV_RELAY,
            address(testTarget), // l2GovRelay = testTarget for simplicity (direct target)
            SEND_LIB,
            RECV_LIB,
            ExecutorConfig({ maxMessageSize: 10000, executor: EXECUTOR }),
            UlnConfig({
                confirmations:        15,
                requiredDVNCount:     2,
                optionalDVNCount:     0,
                optionalDVNThreshold: 0,
                requiredDVNs:         requiredDVNs,
                optionalDVNs:         new address[](0)
            }),
            UlnConfig({
                confirmations:        12,
                requiredDVNCount:     2,
                optionalDVNCount:     0,
                optionalDVNThreshold: 0,
                requiredDVNs:         requiredDVNs,
                optionalDVNs:         new address[](0)
            })
        );
        vm.stopPrank();
    }

    function test_govRelayEndToEnd() public {
        // --- Send governance message from Ethereum ---
        mainnet.selectFork();

        bytes memory message = abi.encodeCall(TestTarget.setValue, (42));
        bytes memory extraOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        address dstTarget = address(testTarget);

        // Quote the fee
        MessagingFee memory fee = LZGovBridgeForwarder.quote(
            GOV_SENDER,
            DST_EID,
            dstTarget,
            message,
            extraOptions,
            false
        );

        // Send from L1GovernanceRelay (which is whitelisted by initGovSender)
        vm.deal(L1_GOV_RELAY, fee.nativeFee);
        vm.prank(L1_GOV_RELAY);
        LZGovBridgeForwarder.sendMessage(
            GOV_SENDER,
            DST_EID,
            dstTarget,
            message,
            extraOptions,
            L1_GOV_RELAY,
            fee,
            address(0)
        );

        // --- Relay message to Base ---
        bridge.relayMessagesToDestination(true, GOV_SENDER, address(govOAppReceiver));

        // --- Verify execution on Base ---
        assertEq(testTarget.value(), 42, "Governance message should have set value to 42");
    }
}
