// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IGearboxDCAStruct {
    /// @param creditAccount The address of the credit account
    /// @param collateral The address of the collateral token
    /// @param tokenIn The address of the token to swap from
    /// @param tokenOut The address of the token to swap to
    /// @param salt The salt of the order for preventing same hash from same order parameters
    /// @param amountIn The amount of tokenIn to swap
    /// @param parts The number of parts to split the swap
    /// @param period The period in seconds between each swap
    /// @param slippage The slippage tolerance in percentage, (1e4 = 100%)

    struct Order {
        address creditAccount;
        address collateral;
        address tokenIn;
        address tokenOut;
        uint256 salt;
        uint256 collateralAmount;
        uint256 amountIn;
        uint256 parts;
        uint256 period;
        uint256 slippage;
    }

    struct OrderStatus {
        uint32 executedTimes;
        uint32 executedTime;
        uint32 cancelledTime;
    }
}
