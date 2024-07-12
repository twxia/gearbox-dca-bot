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

    IPriceOracleV3 private _priceOracle;

    mapping(bytes32 => OrderStatus) internal _orderStatuses;

    string public constant ORDER_TYPE =
        "Order(address creditAccount,address collateral,address tokenIn,address tokenOut,uint256 salt,uint256 amountIn,uint256 parts,uint256 period,uint256 slippage)";
    bytes32 public constant ORDER_TYPEHASH =
        keccak256(abi.encodePacked(ORDER_TYPE));

    constructor(
        string memory name,
        string memory version,
        address priceOracle
    ) EIP712(name, version) {
        _priceOracle = IPriceOracleV3(priceOracle);
    }

    //
    // MODIFIER
    //

    modifier onlyIncompleteAndUnexecutedOrder(Order calldata order) {
        _onlyIncompleteAndUnexecutedOrder(order);
        _;
    }

    modifier onlyOrderOwner(Order calldata order) {
        if (order.owner != msg.sender) {
            revert InvalidOrderOwnerException();
        }
        _;
    }

    //
    // EXTERNAL
    //

    function executeOrder(
        Order calldata order,
        bytes calldata signature,
        address adapter,
        bytes calldata adapterCallData
    ) external override onlyIncompleteAndUnexecutedOrder(order) {
        _verifySigner(order, signature);

        _execute(order, adapter, adapterCallData);
    }

    function cancelOrder(Order calldata order) external onlyOrderOwner(order) {
        bytes32 orderHash = _getOrderHash(order);
        OrderStatus storage status = _orderStatuses[orderHash];

        if (status.cancelledTime > 0) {
            revert OrderAlreadyCancelledException();
        }

        status.cancelledTime = uint32(block.timestamp);
    }

    //
    // EXTERNAL VIEW

    function getOrderHash(
        Order calldata order
    ) external view override returns (bytes32) {
        return _getOrderHash(order);
    }

    function getOrderStatus(
        bytes32 orderHash
    ) external view returns (OrderStatus memory) {
        return _orderStatuses[orderHash];
    }

    //
    // INTERNAL VIEW
    //
    function _getOrderHash(
        Order calldata order
    ) internal view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ORDER_TYPEHASH, order)));
    }

    function _verifySigner(
        Order calldata order,
        bytes memory signature
    ) internal view {
        bytes32 orderHash = _getOrderHash(order);
        address signer = ECDSA.recover(orderHash, signature);

        if (signer != order.owner) {
            revert InvalidSingerException();
        }
    }

    function _onlyIncompleteAndUnexecutedOrder(
        Order calldata order
    ) internal view {
        bytes32 orderHash = _getOrderHash(order);
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
    ) internal view returns (uint256) {
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
        address creditFacadeAddress = order.creditFacade;
        ICreditFacadeV3 creditFacade = ICreditFacadeV3(creditFacadeAddress);
        address creditManager = creditFacade.creditManager();

        SafeERC20.safeTransferFrom(
            IERC20Metadata(order.collateral),
            order.owner,
            address(this),
            order.collateralAmount
        );

        SafeERC20.forceApprove(
            IERC20Metadata(order.collateral),
            creditManager,
            order.collateralAmount
        );

        MultiCall[] memory calls = new MultiCall[](7);

        BalanceDelta[] memory deltas = new BalanceDelta[](2);

        deltas[0] = BalanceDelta({
            token: order.tokenIn,
            amount: order.collateralAmount.toInt256()
        });

        uint256 tokenOutMinAmount = _calcTokenOutMinAmount(order);

        deltas[1] = BalanceDelta({
            token: order.tokenOut,
            amount: tokenOutMinAmount.toInt256()
        });

        calls[0] = MultiCall({
            target: creditFacadeAddress,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.storeExpectedBalances,
                (deltas)
            )
        });

        calls[1] = MultiCall({
            target: creditFacadeAddress,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral,
                (order.collateral, order.collateralAmount)
            )
        });

        calls[2] = MultiCall({
            target: creditFacadeAddress,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.increaseDebt,
                (order.amountIn)
            )
        });

        calls[3] = MultiCall({
            target: creditFacadeAddress,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.enableToken,
                (order.tokenOut)
            )
        });

        // TODO: enhance quota to this formula:
        // https://github.com/Gearbox-protocol/sdk/blob/d7dda524d049a3c68e31e44a8eed3fecc288b52d/src/core/creditAccount.ts#L564
        calls[4] = MultiCall({
            target: creditFacadeAddress,
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
            target: creditFacadeAddress,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.compareBalances,
                ()
            )
        });

        creditFacade.botMulticall(order.creditAccount, calls);

        bytes32 orderHash = _getOrderHash(order);

        OrderStatus storage status = _orderStatuses[orderHash];

        status.executedTimes += 1;
        status.executedTime = uint32(block.timestamp);
    }
}
