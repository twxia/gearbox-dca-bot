// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {GearboxDCA} from "../contracts/GearboxDCA.sol";
import {Script, console} from "forge-std/Script.sol";

contract Deploy is Script {
    GearboxDCA public gearboxDCA;

    // mainnet oracle
    address internal constant PRICE_ORACLE = 0x599f585D1042A14aAb194AC8031b2048dEFdFB85;
    address internal constant CONTRACTS_REGISTER = 0xA50d4E7D8946a7c90652339CDBd262c375d54D99;
    address internal constant ROUTER = 0xA6FCd1fE716aD3801C71F2DE4E7A15f3a6994835;
    address[] internal CONNECTORS = [
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // WETH
        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
        0xdAC17F958D2ee523a2206206994597C13D831ec7 // USDT
    ];

    function run() external {
        vm.startBroadcast();

        gearboxDCA = new GearboxDCA("GearboxDCA", "1.0.0", PRICE_ORACLE, CONTRACTS_REGISTER, ROUTER, CONNECTORS);

        vm.stopBroadcast();
    }
}
