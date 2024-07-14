// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IGearboxDCAStruct {
    /// @param owner The address of the order owner
    /// @param creditManager The address of the credit manager
    /// @param creditAccount The address of the credit account
    /// @param collateral The address of the collateral token
    /// @param tokenIn The address of the token to swap from (shuold be the underlying token of the credit account)
    /// @param tokenOut The address of the token to swap to
    /// @param parts The number of parts to split the swap
    /// @param period The period in seconds between each swap
    /// @param slippage The slippage tolerance in percentage, (1e4 = 100%)
    /// @param salt The salt of the order for preventing same hash from same order parameters
    /// @param collateralAmount The amount of collateral to deposit to the credit account
    /// @param amountIn The amount of tokenIn to swap
    struct Order {
        address owner;
        address creditManager;
        address creditAccount;
        address collateral;
        address tokenIn;
        address tokenOut;
        uint32 parts;
        uint32 period;
        uint16 slippage;
        uint256 salt;
        uint256 collateralAmount;
        uint256 amountIn;
    }

    /// @param executedTimes The number of times the order has been executed
    /// @param executedTime The timestamp of the last execution
    /// @param cancelledTime The timestamp of the order cancellation
    struct OrderStatus {
        uint32 executedTimes;
        uint32 executedTime;
        uint32 cancelledTime;
    }
}
