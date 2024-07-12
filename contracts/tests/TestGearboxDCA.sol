// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../GearboxDCA.sol";

contract TestGearboxDCA is GearboxDCA {
    constructor(string memory name, string memory version, address priceOracle, address contractsRegister)
        GearboxDCA(name, version, priceOracle, contractsRegister)
    {}

    function verifySigner(Order calldata order, bytes calldata signature) external view {
        _verifySigner(order, signature);
    }

    function calcTokenOutMinAmount(Order calldata order) external view returns (uint256) {
        return _calcTokenOutMinAmount(order);
    }
}
