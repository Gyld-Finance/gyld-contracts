// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ISwapReentryTarget {
    struct SwapMessage {
        uint256 quoteId;
        address taker;
        address tokenIn;
        uint256 maxAmountIn;
        address tokenOut;
        uint256 price;
        uint64 expiry;
        uint64 epoch;
    }

    struct PermitData {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function executeSwap(
        SwapMessage calldata m,
        bytes calldata signature,
        PermitData calldata permitIn,
        uint256 requestedAmountIn
    ) external;
}

/// @dev Malicious ERC-20 used to probe the swap's nonReentrant guard. On every
///      transfer/transferFrom it attempts to re-enter the swap's executeSwap. The
///      re-entrant call MUST revert (ReentrancyGuardReentrantCall), which — because
///      the attack is wired inside the token's transfer hook — bubbles up and reverts
///      the whole tx. Reports 18 decimals so it can pose as a bond series.
contract MockReentrantToken is ERC20 {
    enum Mode {
        Off,
        ReenterExecuteSwap
    }

    Mode public mode;
    address public swapTarget;
    bool private _entered; // prevents infinite recursion in our OWN hook

    // Captured args for the re-entrant executeSwap attempt.
    ISwapReentryTarget.SwapMessage private _msg;
    bytes private _sig;
    uint256 private _requestedAmountIn;

    constructor() ERC20("Malicious Bond", "EVIL") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function armExecuteSwap(
        address swap_,
        ISwapReentryTarget.SwapMessage calldata m,
        bytes calldata sig_,
        uint256 requestedAmountIn_
    ) external {
        mode = Mode.ReenterExecuteSwap;
        swapTarget = swap_;
        _msg = m;
        _sig = sig_;
        _requestedAmountIn = requestedAmountIn_;
    }

    /// The hook fires inside the swap's safeTransfer (executeSwap leg 2). The re-entrant
    /// call hits a contract that is already mid-executeSwap, so the nonReentrant guard
    /// reverts — which propagates out of this transfer and reverts the enclosing tx.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (_entered) return;
        _entered = true;
        if (mode == Mode.ReenterExecuteSwap) {
            ISwapReentryTarget(swapTarget).executeSwap(_msg, _sig, _emptyPermit(), _requestedAmountIn);
        }
        _entered = false;
    }

    function _emptyPermit() private pure returns (ISwapReentryTarget.PermitData memory) {
        return ISwapReentryTarget.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }
}
