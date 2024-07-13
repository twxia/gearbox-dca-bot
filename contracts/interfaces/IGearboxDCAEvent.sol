// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IGearboxDCAEvent {
    /// @notice Emitted when the order is executed
    /// @param creditAccount The address of the credit account
    /// @param orderHash The hash of the executed order
    /// @param keeper The address of the keeper
    /// @param parts The number of parts to split the swap
    /// @param executedTimes The number of times the order has been executed
    event OrderExectued(
        address indexed creditAccount, bytes32 indexed orderHash, address keeper, uint256 parts, uint256 executedTimes
    );

    /// @notice Emitted when the order is cancelled
    /// @param creditAccount The address of the credit account
    /// @param orderHash The hash of the cancelled order
    event OrderCancelled(address indexed creditAccount, bytes32 indexed orderHash);
}
