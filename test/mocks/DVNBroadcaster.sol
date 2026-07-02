// SPDX-FileCopyrightText: © 2026 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.24;

import { DVNReplica } from "./DVNReplica.sol";

interface IEndpoint {
    function getReceiveLibrary(address receiver, uint32 srcEid) external view returns (address lib, bool isDefault);
}

contract DVNBroadcaster {
    event Spawned(address indexed verifier, address[] replicas);

    address public immutable endpoint;
    address public immutable verifier;
    DVNReplica[] public replicas;

    constructor(address _endpoint, address _verifier, uint256 n) {
        require(n > 0, "DVNBroadcaster/zero-replica");
        endpoint = _endpoint;
        verifier = _verifier;

        address[] memory addrs = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            DVNReplica r = new DVNReplica(address(this));
            replicas.push(r);
            addrs[i] = address(r);
        }
        emit Spawned(_verifier, addrs);
    }

    function verify(bytes calldata packetHeader, bytes32 payloadHash, uint64 confirmations) external {
        require(msg.sender == verifier, "DVNBroadcaster/only-verifier");

        require(uint8(packetHeader[0]) == 1, "DVNBroadcaster/bad-header-version");
        uint32  srcEid   = uint32(bytes4(packetHeader[9:13]));
        address receiver = address(bytes20(packetHeader[61:81]));

        (address rcvLib,) = IEndpoint(endpoint).getReceiveLibrary(receiver, srcEid);

        uint256 len = replicas.length;
        for (uint256 i = 0; i < len; ++i) {
            replicas[i].verify(rcvLib, packetHeader, payloadHash, confirmations);
        }
    }

    function getReplicas() external view returns (address[] memory out) {
        uint256 n = replicas.length;
        out = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = address(replicas[i]);
        }
    }

    function getReplicasCount() external view returns (uint256) {
        return replicas.length;
    }
}
