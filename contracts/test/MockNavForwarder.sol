// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Settable NAVFeedForwarder stand-in for tests only. The real forwarder
///      delegates to KaleidoscopeNAVFeed, which enforces a 1-hour min update
///      interval and a 10% deviation band — too rigid for unit tests that need
///      arbitrary (including non-positive) answers. Reports 8 decimals so it
///      passes GyldSettlementVault.registerSeries's probe.
contract MockNavForwarder {
    int256 private _answer;

    constructor(int256 initialAnswer) {
        _answer = initialAnswer;
    }

    function setAnswer(int256 newAnswer) external {
        _answer = newAnswer;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}
