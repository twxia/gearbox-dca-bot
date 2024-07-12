// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Thrown on invalid credit manager
error InvalidCreditManagerException();

/// @notice Thrown on invalid signer
error InvalidSingerException();

/// @notice Thrown on order already cancelled
error OrderAlreadyCancelledException();

/// @notice Thrown on order already completed
error OrderAlreadyCompletedException();

/// @notice Thrown on order already executed
error OrderAlreadyExecutedException();

/// @notice Thrown on invalid order owner
error InvalidOrderOwnerException();
