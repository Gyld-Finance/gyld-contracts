// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Stablecoin stand-in with configurable decimals (GLD-713) — e.g. an 18dp cash
///      token on BSC testnet, or out-of-range fixtures for the initialize probe. Test only.
contract MockStablecoin is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20("Mock Stablecoin", "mUSD") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
