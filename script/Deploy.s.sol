// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {GearboxDCA} from "../contracts/GearboxDCA.sol";

contract Deploy is Script {
    GearboxDCA public gearboxDCA;

    // mainnet oracle
    address internal constant PRICE_ORACLE = 0x599f585D1042A14aAb194AC8031b2048dEFdFB85;
    address internal constant CONTRACTS_REGISTER = 0xA50d4E7D8946a7c90652339CDBd262c375d54D99;

    function run() external {
        vm.startBroadcast();

        gearboxDCA = new GearboxDCA("GearboxDCA", "1.0.0", PRICE_ORACLE, CONTRACTS_REGISTER);

        vm.stopBroadcast();
    }
}
