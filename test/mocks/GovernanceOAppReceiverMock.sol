// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

import { Ownable }                        from "@openzeppelin/contracts/access/Ownable.sol";
import { OAppReceiver, Origin, OAppCore } from "layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

struct MessageOrigin {
    uint32  srcEid;
    bytes32 srcSender;
}

contract GovernanceOAppReceiverMock is OAppReceiver {

    MessageOrigin private _messageOrigin;

    constructor(uint32 _srcEid, bytes32 _peer, address _endpoint, address _owner)
        OAppCore(_endpoint, _owner) Ownable(_owner)
    {
        _setPeer(_srcEid, _peer);
    }

    function messageOrigin() external view returns (MessageOrigin memory) {
        return _messageOrigin;
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32,
        bytes calldata _payload,
        address,
        bytes calldata
    ) internal override {
        bytes32 srcSender  = bytes32(_payload[0:32]);
        address dstTarget  = address(uint160(bytes20(_payload[44:64])));
        bytes memory dstCallData = _payload[64:];

        _messageOrigin = MessageOrigin({ srcEid: _origin.srcEid, srcSender: srcSender });

        (bool success, bytes memory result) = dstTarget.call{ value: msg.value }(dstCallData);
        if (!success) {
            if (result.length == 0) revert("GovernanceOAppReceiverMock/call-failed");
            assembly ("memory-safe") {
                revert(add(32, result), mload(result))
            }
        }

        _messageOrigin = MessageOrigin({ srcEid: 0, srcSender: bytes32(0) });
    }
}
