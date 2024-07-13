// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";

import {IGearboxDCAEvent} from "../contracts/interfaces/IGearboxDCAEvent.sol";
import "../contracts/interfaces/IGearboxDCAException.sol";
import {IGearboxDCAStruct} from "../contracts/interfaces/IGearboxDCAStruct.sol";
import {TestGearboxDCA} from "../contracts/tests/TestGearboxDCA.sol";
import {IWETH} from "@gearbox-protocol/core-v2/contracts/interfaces/external/IWETH.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {IBotListV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IBotListV3.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {
    CollateralCalcTask,
    CollateralDebtData,
    ICreditManagerV3
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {BalanceLessThanExpectedException} from "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    ISwapRouter,
    IUniswapV3Adapter
} from "@gearbox-protocol/integrations-v3/contracts/interfaces/uniswap/IUniswapV3Adapter.sol";
import {
    UniswapV3_Calls,
    UniswapV3_Multicaller
} from "@gearbox-protocol/integrations-v3/contracts/test/multicall/uniswap/UniswapV3_Calls.sol";
import {LibFormatter} from "contracts/libs/LibFormatter.sol";

uint192 constant BOT_PERMISSIONS =
    EXTERNAL_CALLS_PERMISSION | ADD_COLLATERAL_PERMISSION | UPDATE_QUOTA_PERMISSION | INCREASE_DEBT_PERMISSION;

contract GearboxDCATest is Test {
    using LibFormatter for uint256;

    uint256 internal constant FORK_BLOCK = 20_262_950;
    address internal constant CONTRACTS_REGISTER = 0xA50d4E7D8946a7c90652339CDBd262c375d54D99;
    address internal constant PRICE_ORACLE = 0x599f585D1042A14aAb194AC8031b2048dEFdFB85;
    address internal constant WETH_TIER_1_CREDIT_MANAGER = 0xa30099925B14b00b76Ae2EfE2639CD01598fE68a;
    address internal constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDT_ADDRESS = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant WBTC_ADDRESS = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER = 0x33fcf8E7ad67E0eBcc8C79fE5d254AC56B7AfEA1;

    uint256 internal constant BOB_INIT_WETH = 10 ether;
    uint256 internal constant BOB_INIT_USDT = 30_000e6;
    uint256 internal constant BOB_INIT_WBTC = 0.5e8;

    IWETH public weth;
    IERC20Metadata public usdt;
    IERC20Metadata public wbtc;
    ICreditManagerV3 public creditManager;
    ICreditFacadeV3 public creditFacade;
    TestGearboxDCA public dcaBot;
    IPriceOracleV3 public priceOracle;

    address public bob;
    address public bobCreditAccount;
    uint256 public bobPrivateKey;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
        creditManager = ICreditManagerV3(WETH_TIER_1_CREDIT_MANAGER);
        creditFacade = ICreditFacadeV3(creditManager.creditFacade());
        priceOracle = IPriceOracleV3(PRICE_ORACLE);
        dcaBot = new TestGearboxDCA("GearboxDCA", "1.0.0", PRICE_ORACLE, CONTRACTS_REGISTER);

        (bob, bobPrivateKey) = makeAddrAndKey("Bob");

        vm.deal(bob, 20 ether);

        usdt = IERC20Metadata(USDT_ADDRESS);
        wbtc = IERC20Metadata(WBTC_ADDRESS);
        weth = IWETH(WETH_ADDRESS);

        vm.label(USDT_ADDRESS, "USDT");
        vm.label(WBTC_ADDRESS, "WBTC");
        vm.label(WETH_ADDRESS, "WETH");

        vm.prank(bob);
        weth.deposit{value: BOB_INIT_WETH}();

        _prepareCreditAccountAndSetBotPermissions();

        // for (uint256 i = 0; i < creditManager.collateralTokensCount(); i++) {
        //     (address collateralToken, uint16 lt) = creditManager.collateralTokenByMask(2 ** i);
        //     console.log("Collateral token: %s", collateralToken);
        //     console.log("Collateral token lt: %s", lt);
        // }
    }

    function _prepareWethCollateralForDCABot() private {
        vm.startPrank(bob);

        // 1. Approve dcaBot to spend 10 WETH
        IERC20Metadata(address(weth)).approve(address(dcaBot), 10 ether);

        vm.stopPrank();
    }

    function _prepareUsdtCollateralForDCABot() private {
        vm.prank(0x28C6c06298d514Db089934071355E5743bf21d60); // binance hot wallet
        SafeERC20.safeTransfer(usdt, bob, BOB_INIT_USDT);

        vm.startPrank(bob);

        // 1. Approve dcaBot to spend 30K USDT
        SafeERC20.forceApprove(usdt, address(dcaBot), BOB_INIT_USDT);

        vm.stopPrank();
    }

    function _prepareWbtcCollateralForDCABot() private {
        vm.prank(0x28C6c06298d514Db089934071355E5743bf21d60); // binance hot wallet
        SafeERC20.safeTransfer(wbtc, bob, BOB_INIT_WBTC);

        vm.startPrank(bob);

        // 1. Approve dcaBot to spend 0.5 WBTC
        SafeERC20.forceApprove(wbtc, address(dcaBot), BOB_INIT_WBTC);

        vm.stopPrank();
    }

    function _prepareCreditAccountAndSetBotPermissions() private {
        vm.startPrank(bob);

        // 2. openCreditAccount with 0 collateral
        bobCreditAccount = creditFacade.openCreditAccount(bob, new MultiCall[](0), 0);
        vm.label(bobCreditAccount, "Bob's creditAccount");

        // 3. Set bot permissions (allow dcaBot to control creditAccount)
        creditFacade.setBotPermissions(bobCreditAccount, address(dcaBot), BOT_PERMISSIONS);

        vm.stopPrank();
    }

    function test_getOrderHash() public {
        IGearboxDCAStruct.Order memory order1 = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(weth),
            collateralAmount: 3 ether,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: 10e18,
            parts: 5,
            period: 100,
            slippage: 0
        });

        IGearboxDCAStruct.Order memory order2 = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 2, // diff
            collateral: address(weth),
            collateralAmount: 3 ether,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: 10e18,
            parts: 5,
            period: 100,
            slippage: 0
        });

        bytes32 orderHash1 = dcaBot.getOrderHash(order1);
        bytes32 orderHash2 = dcaBot.getOrderHash(order2);

        assertNotEq(orderHash1, orderHash2);
    }

    function test_verifySigner() public {
        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(weth),
            collateralAmount: 3 ether,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: 10e18,
            parts: 5,
            period: 100,
            slippage: 0
        });

        bytes32 orderHash = dcaBot.getOrderHash(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, orderHash);

        dcaBot.verifySigner(order, abi.encodePacked(r, s, v));

        (v, r, s) = vm.sign(1, orderHash); // vm.addr(1) != bob

        vm.expectRevert(InvalidSingerException.selector);
        dcaBot.verifySigner(order, abi.encodePacked(r, s, v));
    }

    function test_executeOrder() public {
        _prepareWethCollateralForDCABot();

        uint256 parts = 2;
        uint256 amountIn = 10 ether;
        uint256 slippage = 5; // 0.5%
        uint256 period = 100;
        uint256 collateralAmount = 3 ether;

        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(weth),
            collateralAmount: collateralAmount,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: amountIn,
            parts: parts,
            period: period,
            slippage: slippage
        });
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            fee: 500,
            amountIn: amountIn,
            recipient: bobCreditAccount,
            deadline: block.timestamp + 100,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes32 orderHash = dcaBot.getOrderHash(order);
        bytes memory sig = _genSignature(bobPrivateKey, orderHash);

        _expectOrderExecutedEvent(bobCreditAccount, orderHash, parts, 1);

        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );

        uint256 rate = _calcRate(WETH_ADDRESS, USDT_ADDRESS);
        uint256 expectedAmountOut = ((rate * order.amountIn) / 1e18).formatDecimals(8, 6);
        uint256 maxSlippageAmount = (expectedAmountOut * slippage) / PERCENTAGE_FACTOR;

        IGearboxDCAStruct.OrderStatus memory status = dcaBot.getOrderStatus(orderHash);

        assertEq(IERC20Metadata(WETH_ADDRESS).balanceOf(bob), BOB_INIT_WETH - collateralAmount);
        assertEq(IERC20Metadata(WETH_ADDRESS).balanceOf(bobCreditAccount), collateralAmount);
        assertApproxEqAbs(usdt.balanceOf(bobCreditAccount), expectedAmountOut, maxSlippageAmount);
        assertEq(status.executedTimes, 1);
        assertEq(status.executedTime, block.timestamp);
        assertEq(status.cancelledTime, 0);

        vm.warp(block.timestamp + period);
        vm.roll(block.number + 1);

        _expectOrderExecutedEvent(bobCreditAccount, orderHash, parts, 2);

        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );

        status = dcaBot.getOrderStatus(orderHash);

        assertEq(IERC20Metadata(WETH_ADDRESS).balanceOf(bob), BOB_INIT_WETH - collateralAmount * 2);
        assertEq(IERC20Metadata(WETH_ADDRESS).balanceOf(bobCreditAccount), collateralAmount * 2);
        assertApproxEqAbs(usdt.balanceOf(bobCreditAccount), expectedAmountOut * 2, maxSlippageAmount * 2);
        assertEq(status.executedTimes, 2);
        assertEq(status.executedTime, block.timestamp);
        assertEq(status.cancelledTime, 0);

        // CollateralDebtData memory data =
        //     creditManager.calcDebtAndCollateral(order.creditAccount, CollateralCalcTask.GENERIC_PARAMS);
        // console.log("Collateral: %s", data.debt);
    }

    function test_executeOrder_with_usdt_collateral() public {
        _prepareUsdtCollateralForDCABot();

        uint256 parts = 2;
        uint256 amountIn = 10 ether;
        uint256 slippage = 5; // 0.5%
        uint256 period = 100;
        uint256 collateralAmount = 10000e6;

        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(usdt),
            collateralAmount: collateralAmount,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: amountIn,
            parts: parts,
            period: period,
            slippage: slippage
        });
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            fee: 500,
            amountIn: amountIn,
            recipient: bobCreditAccount,
            deadline: block.timestamp + 100,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes32 orderHash = dcaBot.getOrderHash(order);
        bytes memory sig = _genSignature(bobPrivateKey, orderHash);

        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );

        uint256 rate = _calcRate(WETH_ADDRESS, USDT_ADDRESS);
        uint256 expectedAmountOut = ((rate * order.amountIn) / 1e18).formatDecimals(8, 6);
        uint256 maxSlippageAmount = (expectedAmountOut * slippage) / PERCENTAGE_FACTOR;

        IGearboxDCAStruct.OrderStatus memory status = dcaBot.getOrderStatus(orderHash);

        assertEq(IERC20Metadata(USDT_ADDRESS).balanceOf(bob), BOB_INIT_USDT - collateralAmount);
        assertApproxEqAbs(usdt.balanceOf(bobCreditAccount), collateralAmount + expectedAmountOut, maxSlippageAmount);
        assertEq(status.executedTimes, 1);
        assertEq(status.executedTime, block.timestamp);
        assertEq(status.cancelledTime, 0);

        vm.warp(block.timestamp + period);
        vm.roll(block.number + 1);

        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );

        status = dcaBot.getOrderStatus(orderHash);

        assertEq(IERC20Metadata(USDT_ADDRESS).balanceOf(bob), BOB_INIT_USDT - collateralAmount * 2);
        assertApproxEqAbs(
            usdt.balanceOf(bobCreditAccount), collateralAmount * 2 + expectedAmountOut * 2, maxSlippageAmount * 2
        );
        assertEq(status.executedTimes, 2);
        assertEq(status.executedTime, block.timestamp);
        assertEq(status.cancelledTime, 0);
    }

    function test_executeOrder_with_wbtc_collateral() public {
        _prepareWbtcCollateralForDCABot();

        uint256 parts = 2;
        uint256 amountIn = 10 ether;
        uint256 slippage = 5; // 0.5%
        uint256 period = 100;
        uint256 collateralAmount = 0.2e8; // 0.2 WBTC

        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(wbtc),
            collateralAmount: collateralAmount,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: amountIn,
            parts: parts,
            period: period,
            slippage: slippage
        });
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            fee: 500,
            amountIn: amountIn,
            recipient: bobCreditAccount,
            deadline: block.timestamp + 100,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes32 orderHash = dcaBot.getOrderHash(order);
        bytes memory sig = _genSignature(bobPrivateKey, orderHash);

        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );

        uint256 rate = _calcRate(WETH_ADDRESS, USDT_ADDRESS);
        uint256 expectedAmountOut = ((rate * order.amountIn) / 1e18).formatDecimals(8, 6);
        uint256 maxSlippageAmount = (expectedAmountOut * slippage) / PERCENTAGE_FACTOR;

        IGearboxDCAStruct.OrderStatus memory status = dcaBot.getOrderStatus(orderHash);

        assertEq(wbtc.balanceOf(bob), BOB_INIT_WBTC - collateralAmount);
        assertEq(wbtc.balanceOf(bobCreditAccount), collateralAmount);
        assertApproxEqAbs(usdt.balanceOf(bobCreditAccount), expectedAmountOut, maxSlippageAmount);
        assertEq(status.executedTimes, 1);
        assertEq(status.executedTime, block.timestamp);
        assertEq(status.cancelledTime, 0);

        vm.warp(block.timestamp + period);
        vm.roll(block.number + 1);

        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );

        status = dcaBot.getOrderStatus(orderHash);

        assertEq(wbtc.balanceOf(bob), BOB_INIT_WBTC - collateralAmount * 2);
        assertEq(wbtc.balanceOf(bobCreditAccount), collateralAmount * 2);
        assertApproxEqAbs(usdt.balanceOf(bobCreditAccount), expectedAmountOut * 2, maxSlippageAmount * 2);
        assertEq(status.executedTimes, 2);
        assertEq(status.executedTime, block.timestamp);
        assertEq(status.cancelledTime, 0);
    }

    function test_executeOrder_revert_InvalidPartitionException() public {
        _prepareWethCollateralForDCABot();

        uint256 parts = dcaBot.MAX_PARTITION() + 1;
        uint256 amountIn = 10 ether;
        uint256 slippage = 5; // 0.5%
        uint256 period = 100;

        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(weth),
            collateralAmount: 3 ether,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: amountIn,
            parts: parts,
            period: period,
            slippage: slippage
        });
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            fee: 500,
            amountIn: amountIn,
            recipient: bobCreditAccount,
            deadline: block.timestamp + 100,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes memory sig = _genSignature(bobPrivateKey, dcaBot.getOrderHash(order));

        vm.expectRevert(InvalidPartitionException.selector);
        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );

        order.parts = dcaBot.MAX_PARTITION();
        sig = _genSignature(bobPrivateKey, dcaBot.getOrderHash(order));
        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );
    }

    function test_executeOrder_revert_InvalidCreditManagerException() public {
        _prepareWethCollateralForDCABot();

        uint256 parts = 2;
        uint256 amountIn = 10 ether;
        uint256 slippage = 5; // 0.5%
        uint256 period = 100;

        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: makeAddr("fake credit manager"),
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(weth),
            collateralAmount: 3 ether,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: amountIn,
            parts: parts,
            period: period,
            slippage: slippage
        });
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            fee: 500,
            amountIn: amountIn,
            recipient: bobCreditAccount,
            deadline: block.timestamp + 100,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes memory sig = _genSignature(bobPrivateKey, dcaBot.getOrderHash(order));

        vm.expectRevert(InvalidCreditManagerException.selector);
        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );
    }

    function test_executeOrder_revert_InvalidSignerException() public {
        _prepareWethCollateralForDCABot();

        uint256 parts = 2;
        uint256 amountIn = 10 ether;
        uint256 slippage = 5; // 0.5%
        uint256 period = 100;

        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(weth),
            collateralAmount: 3 ether,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: amountIn,
            parts: parts,
            period: period,
            slippage: slippage
        });
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            fee: 500,
            amountIn: amountIn,
            recipient: bobCreditAccount,
            deadline: block.timestamp + 100,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes memory sig = _genSignature(1, dcaBot.getOrderHash(order));

        vm.expectRevert(InvalidSingerException.selector);
        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );
    }

    function test_executeOrder_revert_OrderAlreadyExecutedException() public {
        _prepareWethCollateralForDCABot();

        uint256 parts = 2;
        uint256 amountIn = 10 ether;
        uint256 slippage = 5; // 0.5%
        uint256 period = 100;

        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(weth),
            collateralAmount: 3 ether,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: amountIn,
            parts: parts,
            period: period,
            slippage: slippage
        });
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            fee: 500,
            amountIn: amountIn,
            recipient: bobCreditAccount,
            deadline: block.timestamp + 100,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes memory sig = _genSignature(bobPrivateKey, dcaBot.getOrderHash(order));

        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );

        vm.expectRevert(OrderAlreadyExecutedException.selector);
        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );
    }

    function test_executeOrder_revert_OrderAlreadyCompletedException() public {
        _prepareWethCollateralForDCABot();

        uint256 parts = 2;
        uint256 amountIn = 10 ether;
        uint256 slippage = 5; // 0.5%
        uint256 period = 100;

        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(weth),
            collateralAmount: 3 ether,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: amountIn,
            parts: parts,
            period: period,
            slippage: slippage
        });
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            fee: 500,
            amountIn: amountIn,
            recipient: bobCreditAccount,
            deadline: block.timestamp + 100,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes memory sig = _genSignature(bobPrivateKey, dcaBot.getOrderHash(order));

        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );

        vm.warp(block.timestamp + period);
        vm.roll(block.number + 1);

        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );

        vm.warp(block.timestamp + period);
        vm.roll(block.number + 1);

        vm.expectRevert(OrderAlreadyCompletedException.selector);
        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );
    }

    function test_executeOrder_slippage_protection() public {
        _prepareWethCollateralForDCABot();

        uint256 parts = 2;
        uint256 amountIn = 40 ether;
        uint256 slippage = 1; // 0.1%
        uint256 period = 100;

        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(weth),
            collateralAmount: 5 ether,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: amountIn,
            parts: parts,
            period: period,
            slippage: slippage
        });
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            fee: 500,
            amountIn: amountIn,
            recipient: bobCreditAccount,
            deadline: block.timestamp + 100,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes32 orderHash = dcaBot.getOrderHash(order);
        bytes memory sig = _genSignature(bobPrivateKey, orderHash);

        vm.expectRevert(BalanceLessThanExpectedException.selector);
        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );
    }

    function test_executeOrder_revert_OrderAlreadyCancelledException() public {
        _prepareWethCollateralForDCABot();

        uint256 parts = 2;
        uint256 amountIn = 10 ether;
        uint256 slippage = 5; // 0.5%
        uint256 period = 100;

        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(weth),
            collateralAmount: 3 ether,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: amountIn,
            parts: parts,
            period: period,
            slippage: slippage
        });
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            fee: 500,
            amountIn: amountIn,
            recipient: bobCreditAccount,
            deadline: block.timestamp + 100,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        bytes memory sig = _genSignature(bobPrivateKey, dcaBot.getOrderHash(order));

        vm.prank(bob);
        dcaBot.cancelOrder(order);

        vm.expectRevert(OrderAlreadyCancelledException.selector);
        dcaBot.executeOrder(
            order,
            sig,
            WETH_TIER_1_ADAPTER_UNISWAP_V3_ROUTER,
            abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams)
        );
    }

    function test_getOrderStatus_initial_values() public {
        bytes32 anyOrderHash = keccak256(abi.encodePacked("0"));

        IGearboxDCAStruct.OrderStatus memory status = dcaBot.getOrderStatus(anyOrderHash);

        assertEq(status.executedTimes, 0);
        assertEq(status.executedTime, 0);
        assertEq(status.cancelledTime, 0);
    }

    function test_cancelOrder() public {
        _prepareWethCollateralForDCABot();

        uint256 parts = 2;
        uint256 amountIn = 10 ether;
        uint256 slippage = 5; // 0.5%
        uint256 period = 100;

        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(weth),
            collateralAmount: 3 ether,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: amountIn,
            parts: parts,
            period: period,
            slippage: slippage
        });

        vm.warp(168);
        vm.startPrank(bob);
        dcaBot.cancelOrder(order);

        IGearboxDCAStruct.OrderStatus memory status = dcaBot.getOrderStatus(dcaBot.getOrderHash(order));

        assertEq(status.executedTimes, 0);
        assertEq(status.executedTime, 0);
        assertEq(status.cancelledTime, 168);
    }

    function test_cancelOrder_revert_OrderAlreadyCancelledException() public {
        _prepareWethCollateralForDCABot();

        uint256 parts = 2;
        uint256 amountIn = 10 ether;
        uint256 slippage = 5; // 0.5%
        uint256 period = 100;

        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(weth),
            collateralAmount: 3 ether,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: amountIn,
            parts: parts,
            period: period,
            slippage: slippage
        });

        vm.startPrank(bob);
        dcaBot.cancelOrder(order);

        vm.expectRevert(OrderAlreadyCancelledException.selector);
        dcaBot.cancelOrder(order);
        vm.stopPrank();
    }

    function test_cancelOrder_revert_InvalidOrderOwnerException() public {
        _prepareWethCollateralForDCABot();

        uint256 parts = 2;
        uint256 amountIn = 10 ether;
        uint256 slippage = 5; // 0.5%
        uint256 period = 100;

        IGearboxDCAStruct.Order memory order = IGearboxDCAStruct.Order({
            owner: bob,
            creditManager: WETH_TIER_1_CREDIT_MANAGER,
            creditAccount: bobCreditAccount,
            salt: 1,
            collateral: address(weth),
            collateralAmount: 3 ether,
            tokenIn: WETH_ADDRESS,
            tokenOut: USDT_ADDRESS,
            amountIn: amountIn,
            parts: parts,
            period: period,
            slippage: slippage
        });

        vm.expectRevert(InvalidOrderOwnerException.selector);
        dcaBot.cancelOrder(order);
    }

    function _calcRate(address tokenIn, address tokenOut) internal view returns (uint256) {
        uint256 inPrice = priceOracle.getPrice(tokenIn);
        uint256 outPrice = priceOracle.getPrice(tokenOut);

        return (inPrice * 1e8) / outPrice;
    }

    function _genSignature(uint256 privateKey, bytes32 orderHash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, orderHash);
        return abi.encodePacked(r, s, v);
    }

    function _expectOrderExecutedEvent(
        address creditAccount,
        bytes32 orderHash,
        uint256 parts,
        uint256 executedTimes
    )
        internal
    {
        vm.expectEmit(true, true, true, true, address(dcaBot));
        emit IGearboxDCAEvent.OrderExectued(creditAccount, orderHash, address(this), parts, executedTimes);
    }
}
