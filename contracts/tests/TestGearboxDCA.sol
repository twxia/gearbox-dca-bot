// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../GearboxDCA.sol";

contract TestGearboxDCA is GearboxDCA {
    constructor(
        string memory name,
        string memory version,
        address creditFacadeAddress,
        address priceOracle
    ) GearboxDCA(name, version, creditFacadeAddress, priceOracle) {}

    function verifySigner(
        address borrower,
        Order calldata order,
        bytes calldata signature
    ) external view {
        _verifySigner(borrower, order, signature);
    }
}
