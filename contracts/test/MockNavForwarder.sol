// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Settable NAVFeedForwarder stand-in for tests only. The real forwarder
///      delegates to KaleidoscopeNAVFeed, which enforces a 1-hour min update
///      interval and a 10% deviation band — too rigid for unit tests that need
///      arbitrary (including non-positive) answers. Reports 8 decimals so it
///      passes GyldAtomicSwap.registerSeries's probe.
///
///      `updatedAt` is settable so the swap's max-feed-age (StaleNav) check is
///      testable; it defaults to block.timestamp at construction (fresh feed).
contract MockNavForwarder {
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(int256 initialAnswer) {
        _answer = initialAnswer;
        _updatedAt = block.timestamp;
    }

    function setAnswer(int256 newAnswer) external {
        _answer = newAnswer;
    }

    function setUpdatedAt(uint256 ts) external {
        _updatedAt = ts;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}
