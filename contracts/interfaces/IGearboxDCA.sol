// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IGearboxDCAStruct} from "./IGearboxDCAStruct.sol";

interface IGearboxDCA {
    function executeOrder(
        IGearboxDCAStruct.Order calldata order,
        bytes calldata signature,
        address adapter,
        bytes calldata adapterCallData
    ) external;

    function getOrderHash(IGearboxDCAStruct.Order calldata order) external view returns (bytes32);
}
