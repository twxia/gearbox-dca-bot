// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditManagerV3, CollateralDebtData, CollateralCalcTask} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IBotListV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IBotListV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {GearboxDCA} from "contracts/GearboxDCA.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGearboxDCAStruct} from "contracts/interfaces/IGearboxDCAStruct.sol";
import {IUniswapV3Adapter, ISwapRouter} from "@gearbox-protocol/integrations-v3/contracts/interfaces/uniswap/IUniswapV3Adapter.sol";
import {UniswapV3_Multicaller, UniswapV3_Calls} from "@gearbox-protocol/integrations-v3/contracts/test/multicall/uniswap/UniswapV3_Calls.sol";

uint192 constant BOT_PERMISSIONS = EXTERNAL_CALLS_PERMISSION |
    ADD_COLLATERAL_PERMISSION |
    ENABLE_TOKEN_PERMISSION |
    UPDATE_QUOTA_PERMISSION |
    INCREASE_DEBT_PERMISSION;

contract GearboxDCATest is Test {
    uint256 internal constant FORK_BLOCK = 20_262_950;
    address internal constant PRICE_ORACLE =
        0x599f585D1042A14aAb194AC8031b2048dEFdFB85;
    address internal constant WETH_TIER_1_CREDIT_FACADE =
        0x65352F69E4aA18dEBCf0763455e5277dAD9374C5;
    address internal constant WETH_ADDRESS =
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDT_ADDRESS =
        0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER =
        0x33fcf8E7ad67E0eBcc8C79fE5d254AC56B7AfEA1;

    ICreditFacadeV3 public creditFacade;
    IWETH public weth;
    GearboxDCA public dcaBot;

    address public bob = makeAddr("Bob");

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
        creditFacade = ICreditFacadeV3(WETH_TIER_1_CREDIT_FACADE);

        dcaBot = new GearboxDCA(
            "GearboxDCA",
            "1.0.0",
            address(creditFacade),
            PRICE_ORACLE
        );

        vm.deal(bob, 20 ether);

        weth = IWETH(WETH_ADDRESS);

        vm.label(WETH_ADDRESS, "WETH");

        vm.prank(bob);
        weth.deposit{value: 10 ether}();
    }

    function test_prepareCreditAccountAndAuthorizeGearboxDCABot() public {
        vm.prank(0xF977814e90dA44bFA03b6295A0616a897441aceC);
        SafeERC20.safeTransfer(IERC20(USDT_ADDRESS), bob, 50000e6);

        vm.startPrank(bob);

        // 1. Approve dcaBot to spend 10 WETH
        IERC20(address(weth)).approve(address(dcaBot), 10 ether);

        // 2. openCreditAccount with 0 collateral
        address creditAccount = creditFacade.openCreditAccount(
            bob,
            new MultiCall[](0),
            0
        );
        vm.label(creditAccount, "Bob's creditAccount");

        // 3. Set bot permissions (allow dcaBot to control creditAccount)
        creditFacade.setBotPermissions(
            creditAccount,
            address(dcaBot),
            BOT_PERMISSIONS
        );

        dcaBot.test(
            IGearboxDCAStruct.Order({
                creditAccount: creditAccount,
                collateral: address(weth),
                tokenIn: WETH_ADDRESS,
                tokenOut: USDT_ADDRESS,
                amountIn: 10e18,
                parts: 2,
                period: 100,
                slippage: 0
            }),
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(
                ISwapRouter.exactInputSingle.selector,
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: WETH_ADDRESS,
                    tokenOut: USDT_ADDRESS,
                    fee: 3000,
                    amountIn: 10e18,
                    recipient: address(creditAccount),
                    deadline: block.timestamp + 100,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        );

        ICreditManagerV3 creditManager = ICreditManagerV3(
            creditFacade.creditManager()
        );
        CollateralDebtData memory data = creditManager.calcDebtAndCollateral(
            creditAccount,
            CollateralCalcTask.DEBT_COLLATERAL
        );
        console.log("Bob's debt: %s", data.debt);
        console.log("Bob's totalDebtUSD: %s", data.totalDebtUSD);
        console.log("Bob's totalValueUSD: %s", data.totalValueUSD);
        console.log("Bob's twvUSD: %s", data.twvUSD);

        console.log(
            "IERC20(address(WETH_ADDRESS)).balanceOf(bob)",
            IERC20(WETH_ADDRESS).balanceOf(bob)
        );
        console.log(
            "IERC20(address(WETH_ADDRESS)).balanceOf(creditAccount)",
            IERC20(WETH_ADDRESS).balanceOf(creditAccount)
        );
        console.log(
            "IERC20(address(USDT_ADDRESS)).balanceOf(creditAccount)",
            IERC20(USDT_ADDRESS).balanceOf(creditAccount)
        );

        vm.stopPrank();
    }
}
