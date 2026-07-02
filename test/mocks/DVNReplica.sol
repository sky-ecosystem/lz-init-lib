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

interface IReceiveUln {
    function verify(
        bytes calldata _packetHeader,
        bytes32 _payloadHash,
        uint64 _confirmations
    ) external;
}

contract DVNReplica {
    address public immutable verifier;

    constructor(address _verifier) {
        verifier = _verifier;
    }

    function verify(
        address receiveLib,
        bytes calldata packetHeader,
        bytes32 payloadHash,
        uint64 confirmations
    ) external {
        require(msg.sender == verifier, "DVNReplica/only-verifier");
        IReceiveUln(receiveLib).verify(packetHeader, payloadHash, confirmations);
    }
}
