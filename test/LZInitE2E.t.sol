// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import "forge-std/Test.sol";

import { LZInit, UlnConfig, ExecutorConfig, MessagingFee } from "deploy/LZInit.sol";

import { Bridge }                from "xchain-helpers/testing/Bridge.sol";
import { Domain, DomainHelpers } from "xchain-helpers/testing/Domain.sol";
import { LZBridgeTesting }       from "xchain-helpers/testing/bridges/LZBridgeTesting.sol";
import { OptionsBuilder }        from "layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import { GovernanceOAppReceiverMock } from "test/mocks/GovernanceOAppReceiverMock.sol";
import { L2GovernanceRelayMock }      from "test/mocks/L2GovernanceRelayMock.sol";

interface ChainlogReadLike {
    function getAddress(bytes32) external view returns (address);
}

contract TestTarget {
    uint256 public value;
    function setValue(uint256 _value) external { value = _value; }
}

contract TestSpell {
    function execute(address target, uint256 _value) external {
        TestTarget(target).setValue(_value);
    }
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

contract LZInitE2ETest is Test {

    using DomainHelpers   for *;
    using LZBridgeTesting for *;
    using OptionsBuilder  for bytes;

    ChainlogReadLike constant chainlog = ChainlogReadLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    // LZ infra (not in chainlog)
    address constant ETH_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant SEND_LIB     = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    address constant EXECUTOR     = 0x173272739Bd7Aa6e4e214714048a9fE699453059;

    address PAUSE_PROXY;
    address GOV_SENDER;
    address L1_GOV_RELAY;

    address constant DVN_P2P              = 0x06559EE34D85a88317Bf0bfE307444116c631b67;
    address constant DVN_DEUTSCHE_TELEKOM = 0x373a6E5c0C4E89E24819f00AA37ea370917AAfF4;
    address constant DVN_HORIZEN          = 0x380275805876Ff19055EA900CDb2B46a94ecF20D;
    address constant DVN_LUGANODES        = 0x58249a2Ec05c1978bF21DF1f5eC1847e42455CF4;
    address constant DVN_LZ_LABS          = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b;
    address constant DVN_CANARY           = 0xa4fE5A5B9A846458a70Cd0748228aED3bF65c2cd;
    address constant DVN_NETHERMIND       = 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5;

    uint32 constant SRC_EID  = 30101;
    uint32 constant BASE_EID = 30184;

    Domain mainnet;
    Bridge bridge;

    function test_govRelayEndToEnd() public {
        mainnet      = getChain("mainnet").createSelectFork();
        PAUSE_PROXY  = chainlog.getAddress("MCD_PAUSE_PROXY");
        GOV_SENDER   = chainlog.getAddress("LZ_GOV_SENDER");
        L1_GOV_RELAY = chainlog.getAddress("LZ_GOV_RELAY");
        Domain memory base = getChain("base").createFork();
        bridge = LZBridgeTesting.createLZBridge(mainnet, base);

        // Deploy mocks on Base
        base.selectFork();
        GovernanceOAppReceiverMock peer = new GovernanceOAppReceiverMock(
            SRC_EID, bytes32(uint256(uint160(GOV_SENDER))), ETH_ENDPOINT, address(this)
        );
        L2GovernanceRelayMock l2GovRelay = new L2GovernanceRelayMock(
            SRC_EID, address(peer), L1_GOV_RELAY
        );
        TestTarget testTarget = new TestTarget();
        TestSpell  testSpell  = new TestSpell();

        // Wire GOV_SENDER for Base
        mainnet.selectFork();

        address[] memory govOptionalDVNs = new address[](7);
        govOptionalDVNs[0] = DVN_P2P;
        govOptionalDVNs[1] = DVN_DEUTSCHE_TELEKOM;
        govOptionalDVNs[2] = DVN_HORIZEN;
        govOptionalDVNs[3] = DVN_LUGANODES;
        govOptionalDVNs[4] = DVN_LZ_LABS;
        govOptionalDVNs[5] = DVN_CANARY;
        govOptionalDVNs[6] = DVN_NETHERMIND;

        vm.startPrank(PAUSE_PROXY);
        LZInit.addGovRoute(
            ETH_ENDPOINT, BASE_EID,
            address(peer), address(l2GovRelay),
            SEND_LIB,
            ExecutorConfig({ maxMessageSize: 10000, executor: EXECUTOR }),
            UlnConfig({
                confirmations:        15,
                requiredDVNCount:     255,
                optionalDVNCount:     7,
                optionalDVNThreshold: 4,
                requiredDVNs:         new address[](0),
                optionalDVNs:         govOptionalDVNs
            })
        );
        vm.stopPrank();

        // Send governance message
        bytes memory spellData = abi.encodeCall(TestSpell.execute, (address(testTarget), 42));
        bytes memory extraOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);

        TxParams memory txParams = TxParams({
            dstEid:       BASE_EID,
            dstTarget:    bytes32(uint256(uint160(address(l2GovRelay)))),
            dstCallData:  abi.encodeCall(L2GovernanceRelayMock.relay, (address(testSpell), spellData)),
            extraOptions: extraOptions
        });

        MessagingFee memory fee = IGovOAppSender(GOV_SENDER).quoteTx(txParams, false);
        vm.deal(L1_GOV_RELAY, fee.nativeFee);
        vm.prank(L1_GOV_RELAY);
        IGovOAppSender(GOV_SENDER).sendTx{value: fee.nativeFee}(txParams, fee, L1_GOV_RELAY);

        bridge.relayMessagesToDestination(true, GOV_SENDER, address(peer));
        assertEq(testTarget.value(), 42);
    }

}
