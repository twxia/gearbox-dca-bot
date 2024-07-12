// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {BalanceDelta} from "@gearbox-protocol/core-v3/contracts/libraries/BalancesLogic.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {IGearboxDCAStruct} from "contracts/interfaces/IGearboxDCAStruct.sol";
import {IGearboxDCA} from "contracts/interfaces/IGearboxDCA.sol";
import {LibFormatter} from "contracts/libs/LibFormatter.sol";

import "contracts/interfaces/IGearboxDCAException.sol";

contract GearboxDCA is EIP712, IGearboxDCA, IGearboxDCAStruct {
    using LibFormatter for uint256;
    using SafeCast for uint256;

    uint256 constant MAX_PARTITION = 1_000_000;

    ICreditFacadeV3 private _creditFacade;
    ICreditManagerV3 private _creditManager;
    IPriceOracleV3 private _priceOracle;

    mapping(bytes32 => OrderStatus) internal _orderStatuses;

    string public constant ORDER_TYPE =
        "Order(address creditAccount,address collateral,address tokenIn,address tokenOut,uint256 salt,uint256 amountIn,uint256 parts,uint256 period,uint256 slippage)";
    bytes32 public constant ORDER_TYPEHASH =
        keccak256(abi.encodePacked(ORDER_TYPE));

    constructor(
        string memory name,
        string memory version,
        address creditFacadeAddress,
        address priceOracle
    ) EIP712(name, version) {
        _creditFacade = ICreditFacadeV3(creditFacadeAddress);
        _creditManager = ICreditManagerV3(_creditFacade.creditManager());
        _priceOracle = IPriceOracleV3(priceOracle);
    }

    //
    // MODIFIER
    //

    //
    // PUBLIC VIEW
    //

    function getCreditFacade() public view returns (ICreditFacadeV3) {
        return _creditFacade;
    }

    function executeOrder(
        Order calldata order,
        bytes calldata signature,
        address adapter,
        bytes calldata adapterCallData
    ) public override {
        _onlyIncompleteAndUnexecutedOrder(order);

        address borrower = _creditManager.getBorrowerOrRevert(
            order.creditAccount
        );

        _verifySigner(borrower, order, signature);

        _execute(order, adapter, adapterCallData);
    }

    function getOrderHash(
        Order calldata order
    ) public view override returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ORDER_TYPEHASH, order)));
    }

    //
    // INTERNAL VIEW
    //
    function _verifySigner(
        address borrower,
        Order calldata order,
        bytes memory signature
    ) internal view {
        bytes32 orderHash = getOrderHash(order);
        address signer = ECDSA.recover(orderHash, signature);

        if (signer != borrower) {
            revert InvalidSingerException();
        }
    }

    function _onlyIncompleteAndUnexecutedOrder(
        Order calldata order
    ) internal view {
        bytes32 orderHash = getOrderHash(order);
        OrderStatus memory status = _orderStatuses[orderHash];

        if (status.cancelledTime > 0) {
            revert OrderAlreadyCancelledException();
        }

        if (status.executedTimes >= order.parts) {
            revert OrderAlreadyCompletedException();
        }

        if (status.executedTime > 0) {
            uint256 nextExecutionTime = status.executedTime + order.period;
            if (block.timestamp < nextExecutionTime) {
                revert OrderAlreadyExecutedException();
            }
        }
    }

    function _calcTokenOutMinAmount(
        Order calldata order
    ) internal returns (uint256) {
        uint8 tokenInDecimals = IERC20Metadata(order.tokenIn).decimals();
        uint8 tokenOutDecimals = IERC20Metadata(order.tokenOut).decimals();
        uint256 tokenInPrice = _priceOracle.getPrice(order.tokenIn);
        uint256 tokenOutPrice = _priceOracle.getPrice(order.tokenOut);
        uint256 price = (tokenInPrice * 1e8) / tokenOutPrice;
        uint256 tokenInAmountWithSlippage = (order.amountIn *
            (PERCENTAGE_FACTOR - order.slippage)) / PERCENTAGE_FACTOR;
        uint256 tokenOutMinAmountWithTokenInDecimals = (tokenInAmountWithSlippage *
                price) / 1e8;
        uint256 tokenOutMinAmount = tokenOutMinAmountWithTokenInDecimals
            .formatDecimals(tokenInDecimals, tokenOutDecimals);
        return tokenOutMinAmount;
    }

    function _execute(
        Order calldata order,
        address adapter,
        bytes calldata adapterCallData
    ) internal {
        ICreditManagerV3 creditManager = ICreditManagerV3(
            _creditFacade.creditManager()
        );
        address borrower = creditManager.getBorrowerOrRevert(
            order.creditAccount
        );
        uint collateralAmount = order.amountIn / order.parts;

        SafeERC20.safeTransferFrom(
            IERC20(order.collateral),
            borrower,
            address(this),
            collateralAmount
        );

        IERC20(order.collateral).approve(
            address(creditManager),
            collateralAmount
        );

        MultiCall[] memory calls = new MultiCall[](7);

        BalanceDelta[] memory deltas = new BalanceDelta[](2);

        deltas[0] = BalanceDelta({
            token: order.tokenIn,
            amount: collateralAmount.toInt256()
        });

        uint256 tokenOutMinAmount = _calcTokenOutMinAmount(order);

        deltas[1] = BalanceDelta({
            token: order.tokenOut,
            amount: tokenOutMinAmount.toInt256()
        });

        calls[0] = MultiCall({
            target: address(_creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.storeExpectedBalances,
                (deltas)
            )
        });

        calls[1] = MultiCall({
            target: address(_creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral,
                (order.collateral, collateralAmount)
            )
        });

        calls[2] = MultiCall({
            target: address(_creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.increaseDebt,
                (order.amountIn)
            )
        });

        calls[3] = MultiCall({
            target: address(_creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.enableToken,
                (order.tokenOut)
            )
        });

        // TODO: enhance quota to this formula:
        // https://github.com/Gearbox-protocol/sdk/blob/d7dda524d049a3c68e31e44a8eed3fecc288b52d/src/core/creditAccount.ts#L564
        calls[4] = MultiCall({
            target: address(_creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.updateQuota,
                (
                    order.tokenOut,
                    int96(uint96(order.amountIn)),
                    uint96(order.amountIn) // TODO: should be total usdt amount in eth
                )
            )
        });

        calls[5] = MultiCall({target: adapter, callData: adapterCallData});

        calls[6] = MultiCall({
            target: address(_creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.compareBalances,
                ()
            )
        });

        _creditFacade.botMulticall(order.creditAccount, calls);

        bytes32 orderHash = getOrderHash(order);

        OrderStatus memory status = _orderStatuses[orderHash];

        status.executedTimes += 1;
    }
}
