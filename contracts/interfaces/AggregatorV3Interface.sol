// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

/// @title AggregatorV3Interface — the Chainlink price-feed shape
/// @notice Vendored rather than imported: pulling `@chainlink/contracts` in for five
///         function signatures would add a dependency the rest of the tree never uses.
///
/// @dev    `answeredInRound` is retained because the ABI is fixed and Morpho, Aave and
///         Euler all decode five values — but it is deliberately NOT checked by any
///         consumer here. Chainlink deprecated the field and OCR aggregators return it
///         equal to `roundId`, as does `KaleidoscopeNAVFeed`. See decision D-18.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

/// @title IUpstreamOracle — AggregatorV3 plus the legacy V2 accessor
/// @notice Aave V3 calls `latestAnswer()`, which AggregatorV3Interface does not carry.
///         Both `KaleidoscopeNAVFeed` and `NAVFeedForwarder` implement the full shape,
///         so both declare this rather than the narrower parent.
/// @dev    Extending the parent (rather than restating its five functions) is what
///         keeps the two in step — there is no second copy to drift.
interface IUpstreamOracle is AggregatorV3Interface {
    function latestAnswer() external view returns (int256);
}
