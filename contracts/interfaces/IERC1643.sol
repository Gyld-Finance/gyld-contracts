// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

/// @title IERC1643 — Document Management Standard
/// @notice ERC-1643 (https://eips.ethereum.org/EIPS/eip-1643) defines a standard for
///         managing documents associated with a security token. Each document is
///         identified by a `bytes32` name and stores a content-addressed URI together
///         with the hash of the hosted file, so a holder can verify the file they see
///         is exactly the original uploaded for this bond series.
///
///         Vendored here (rather than imported from a package) because OpenZeppelin
///         v5.x ships no ERC-1643 interface. The signatures and events follow the EIP
///         reference implementation.
interface IERC1643 {
    /// @dev On-chain metadata for a single document.
    ///
    ///      ⚠ THESE THREE MEMBERS ARE LIVE STORAGE LAYOUT — APPEND ONLY, NEVER REORDER.
    ///      This struct is the value type of `GyldBondTokenStorage.documents`, so member
    ///      order is the physical layout of every document on every deployed proxy.
    ///      Reordering them does not move any data — it re-points the labels, so
    ///      getDocument() would return a block timestamp as `documentHash` and every
    ///      holder verifying a prospectus would see a mismatch that reads as tampering.
    ///
    ///      ci/check_storage_layout.py CANNOT catch this: `documents` is reached through
    ///      a mapping, and solc's type label for a mapping is byte-identical however the
    ///      value struct's members are ordered — so the guard prints OK on a reorder.
    ///      The only thing that catches it is
    ///      GyldBondToken.t.sol::test_storageLayout_documentFieldsAppendedAtOffsets3and4,
    ///      which pins each member's slot against a real proxy. Do not delete those pins;
    ///      extend them if this struct gains a field.
    struct Document {
        string uri;
        bytes32 documentHash;
        uint256 lastModified;
    }

    /// @dev Emitted when a document is added or replaced.
    event DocumentUpdated(bytes32 indexed name, string uri, bytes32 documentHash);
    /// @dev Emitted when an existing document is removed. Carries the removed `uri` and
    ///      `documentHash` so the log alone is a complete audit trail of what was deleted —
    ///      and so the topic0 matches the ERC-1643 reference and CMTAT, which is what any
    ///      standard-aware indexer filters on.
    event DocumentRemoved(bytes32 indexed name, string uri, bytes32 documentHash);

    /// @notice Set (add or replace) the document named `name`.
    /// @param name         bytes32 identifier of the document.
    /// @param uri          Content-addressed URI (e.g. an Arweave / S3 pointer).
    /// @param documentHash Hash of the hosted file, so a holder can verify originality.
    function setDocument(bytes32 name, string calldata uri, bytes32 documentHash) external;

    /// @notice Remove the document named `name`.
    function removeDocument(bytes32 name) external;

    /// @notice Return the `(uri, documentHash, lastModified)` for the document named `name`.
    function getDocument(bytes32 name) external view returns (string memory, bytes32, uint256);

    /// @notice Return the names of all documents associated with this token.
    function getAllDocuments() external view returns (bytes32[] memory);
}