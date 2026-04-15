// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import { MessageOrigin } from "./GovernanceOAppReceiverMock.sol";

interface GovernanceOAppReceiverLike {
    function messageOrigin() external view returns (MessageOrigin memory);
}

contract L2GovernanceRelayMock {

    GovernanceOAppReceiverLike public l2Oapp;
    address                 public l1GovernanceRelay;
    uint32 immutable        public l1Eid;

    constructor(uint32 _l1Eid, address _l2Oapp, address _l1GovernanceRelay) {
        l1Eid              = _l1Eid;
        l2Oapp             = GovernanceOAppReceiverLike(_l2Oapp);
        l1GovernanceRelay  = _l1GovernanceRelay;
    }

    function relay(address target, bytes calldata targetData) external {
        MessageOrigin memory mo = l2Oapp.messageOrigin();
        require(
            msg.sender                                         == address(l2Oapp) &&
            mo.srcEid                                          == l1Eid &&
            address(uint160(uint256(mo.srcSender)))            == l1GovernanceRelay,
            "L2GovernanceRelayMock/bad-message-auth"
        );
        (bool success, bytes memory result) = target.delegatecall(targetData);
        if (!success) {
            if (result.length == 0) revert("L2GovernanceRelayMock/delegatecall-error");
            assembly ("memory-safe") {
                revert(add(32, result), mload(result))
            }
        }
    }
}
