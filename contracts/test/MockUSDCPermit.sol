// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @dev Permit-bearing USDC stand-in for tests only. MockUSDC has no permit();
///      this variant adds EIP-2612 so the GyldAtomicSwap USDC-leg permit path can
///      be exercised in-test (real USDC permit is non-standard version "2", but
///      the swap applies permits via try/catch so the standard shape suffices).
contract MockUSDCPermit is ERC20, ERC20Permit {
    constructor() ERC20("USD Coin", "USDC") ERC20Permit("USD Coin") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
