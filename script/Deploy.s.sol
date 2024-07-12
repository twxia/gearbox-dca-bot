// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {GearboxDCA} from "../contracts/GearboxDCA.sol";

contract Deploy is Script {
    GearboxDCA public gearboxDCA;

    // CONSTANTS
    address internal constant PRICE_ORACLE =
        0x599f585D1042A14aAb194AC8031b2048dEFdFB85;

    function run() external {
        vm.startBroadcast();

        gearboxDCA = new GearboxDCA("GearboxDCA", "1.0.0", PRICE_ORACLE);

        vm.stopBroadcast();
    }
}
