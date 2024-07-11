// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IGearboxDCAStruct {
    struct Order {
        address creditAccount;
        address collateral;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 parts;
        uint256 period;
        uint256 slippage;
    }
}
