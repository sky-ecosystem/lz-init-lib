// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

/// @notice Helper contracts for the Eth<->Avalanche gov-bridge clone experiment.
///         All are intentionally permissionless / mintable so the clone can be driven
///         freely on a fork. NONE of these are production contracts.

// --------------------------------------------------------------------------------------------
//  FakeChainlog: a trivial mapping-backed chainlog with an open setAddress (no auth), matching
//  the MockChainlog used by the clone tests. Lets the later migration step read/write keys
//  (LZ_GOV_SENDER, LZ_GOV_RELAY, USDS_OFT, ...) against the clone rather than the real chainlog.
// --------------------------------------------------------------------------------------------
contract FakeChainlog {
    mapping(bytes32 => address) public addrs;

    function getAddress(bytes32 key) external view returns (address) {
        return addrs[key];
    }

    function setAddress(bytes32 key, address addr) external {
        addrs[key] = addr;
    }
}

// --------------------------------------------------------------------------------------------
//  Plain ERC20 with an open mint. Used for the L1 lockbox tokens (FakeUSDS / FakeSUSDS on
//  mainnet): the L1 SkyOFTAdapter locks/unlocks a plain ERC20, so no wards are required.
// --------------------------------------------------------------------------------------------
contract TestERC20 {
    string public name;
    string public symbol;
    uint8  public constant decimals = 18;

    uint256                                         public totalSupply;
    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_) {
        name   = name_;
        symbol = symbol_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        _move(from, to, amount);
        return true;
    }
    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
    function mint(address to, uint256 amount) external virtual {
        totalSupply   += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
}

// --------------------------------------------------------------------------------------------
//  Maker-style mint/burn ERC20 with wards. Used for the Avalanche tokens (FakeUSDS / FakeSUSDS
//  on Avax): the Avax SkyOFTAdapterMintBurn mints/burns its token, so it (and the relay) must
//  be relied on the token.
// --------------------------------------------------------------------------------------------
contract TestMintBurnERC20 is TestERC20 {
    mapping(address => uint256) public wards;

    event Rely(address indexed usr);
    event Deny(address indexed usr);

    constructor(string memory name_, string memory symbol_) TestERC20(name_, symbol_) {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    modifier auth() { require(wards[msg.sender] == 1, "TestMintBurn/not-authed"); _; }

    function rely(address u) external auth { wards[u] = 1; emit Rely(u); }
    function deny(address u) external auth { wards[u] = 0; emit Deny(u); }

    function mint(address to, uint256 amount) external override auth {
        totalSupply   += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    function burn(address from, uint256 amount) external auth {
        balanceOf[from] -= amount;
        totalSupply     -= amount;
        emit Transfer(from, address(0), amount);
    }
}
