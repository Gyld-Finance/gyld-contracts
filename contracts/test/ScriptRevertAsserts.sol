// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @title ScriptRevertAsserts
/// @notice Shared base for suites that assert a deploy script's `run()` refuses to deploy.
/// @dev    Extracted from {DeployScriptsTest} so a second script suite does not need a
///         second copy. The point of {_expectRunRevert} is that it matches the REASON, not
///         merely the fact of a revert: a chain-guard test that passes because some
///         unrelated env var happened to be missing is not testing the chain guard.
abstract contract ScriptRevertAsserts is Test {
    /// Asserts `run()` reverts AND that the reason names the specific guard, so a scenario
    /// cannot pass because some unrelated failure happened to revert first.
    function _expectRunRevert(address script, string memory needle) internal {
        (bool ok, bytes memory ret) = script.call(abi.encodeWithSignature("run()"));
        assertFalse(ok, string.concat("expected run() to revert with: ", needle));
        string memory reason = _revertReason(ret);
        assertTrue(
            _contains(reason, needle),
            string.concat("wrong revert reason\n   expected substring: ", needle, "\n   actual: ", reason)
        );
    }

    function _revertReason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "<no Error(string) payload>";
        bytes memory payload = new bytes(ret.length - 4);
        for (uint256 i = 4; i < ret.length; i++) {
            payload[i - 4] = ret[i];
        }
        return abi.decode(payload, (string));
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
