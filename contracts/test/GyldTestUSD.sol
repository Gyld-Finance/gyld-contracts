// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @dev Dev-chain cash-leg token with CONFIGURABLE decimals (GLD-713) — "Gyld Test USD"
///      (gUSD), deployed by DeployMockStablecoin.s.sol. Exists because BNB-chain
///      stablecoins are 18dp, so a public-testnet stack on BSC testnet (97) must exercise
///      the swap's non-6dp cash path; {MockUSDC} is hard-wired to 6. Carries EIP-2612 so
///      the `permitIn` settlement path is testable. Also the unit-test fixture for the 6-or-18dp probe.
///
///      The name deliberately says "Test" and never "USD Coin" / "USDT": it lives on a
///      PUBLIC chain, where a plausible-looking stablecoin name is the confusion GYL-1135
///      closed. For the same reason minting is gated to `minter` (the deployer) instead
///      of being permissionless like {MockUSDC}.
contract GyldTestUSD is ERC20, ERC20Permit {
    uint8 private immutable _decimals;
    address public immutable minter;

    error NotMinter(address caller);

    constructor(uint8 decimals_, address minter_) ERC20("Gyld Test USD", "gUSD") ERC20Permit("Gyld Test USD") {
        _decimals = decimals_;
        minter = minter_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter(msg.sender);
        _mint(to, amount);
    }
}
