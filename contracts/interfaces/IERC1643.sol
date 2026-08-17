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
    struct Document {
        string uri;
        bytes32 documentHash;
        uint256 lastModified;
    }

    /// @dev Emitted when a document is added or replaced.
    event DocumentUpdated(bytes32 indexed name, string uri, bytes32 documentHash);
    /// @dev Emitted when an existing document is removed.
    event DocumentRemoved(bytes32 indexed name);

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