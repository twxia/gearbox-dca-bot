// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IContractsRegister} from "@gearbox-protocol/core-v2/contracts/interfaces/IContractsRegister.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {
    CollateralCalcTask,
    CollateralDebtData,
    ICreditManagerV3
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {BalanceDelta} from "@gearbox-protocol/core-v3/contracts/libraries/BalancesLogic.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";

import {IGearboxDCA} from "contracts/interfaces/IGearboxDCA.sol";

import {IGearboxDCAEvent} from "contracts/interfaces/IGearboxDCAEvent.sol";
import {IGearboxDCAStruct} from "contracts/interfaces/IGearboxDCAStruct.sol";
import {LibFormatter} from "contracts/libs/LibFormatter.sol";

import "contracts/interfaces/IGearboxDCAException.sol";

contract GearboxDCA is EIP712, IGearboxDCA, IGearboxDCAStruct, IGearboxDCAEvent {
    using LibFormatter for uint256;
    using SafeCast for uint256;

    uint32 public constant MAX_PARTITION = 1_000_000;

    string public constant ORDER_TYPE =
        "Order(address creditAccount,address collateral,address tokenIn,address tokenOut,uint256 salt,uint256 amountIn,uint256 parts,uint256 period,uint256 slippage)";
    bytes32 public constant ORDER_TYPEHASH = keccak256(abi.encodePacked(ORDER_TYPE));

    IPriceOracleV3 private _priceOracle;

    IContractsRegister private _contractsRegister;

    mapping(bytes32 => OrderStatus) internal _orderStatuses;

    constructor(
        string memory name,
        string memory version,
        address priceOracle,
        address contractsRegister
    )
        EIP712(name, version)
    {
        _priceOracle = IPriceOracleV3(priceOracle);
        _contractsRegister = IContractsRegister(contractsRegister);
    }

    //
    // MODIFIER
    //
    modifier onlyIncompleteAndUnexecutedOrder(Order calldata order) {
        _onlyIncompleteAndUnexecutedOrder(order);
        _;
    }

    modifier onlyOrderOwner(address owner) {
        if (owner != msg.sender) {
            revert InvalidOrderOwnerException();
        }
        _;
    }

    modifier onlyValidCreditManager(address creditManager) {
        if (!_contractsRegister.isCreditManager(creditManager)) {
            revert InvalidCreditManagerException();
        }
        _;
    }

    modifier onlyValidPartition(uint256 parts) {
        if (parts > MAX_PARTITION) {
            revert InvalidPartitionException();
        }
        _;
    }

    //
    // EXTERNAL
    //

    /// @notice Execute the order
    /// @param order The order to execute
    /// @param signature The signature of the order
    /// @param adapter The address of the adapter to use
    /// @param adapterCallData The call data of the adapter
    function executeOrder(
        Order calldata order,
        bytes calldata signature,
        address adapter,
        bytes calldata adapterCallData
    )
        external
        override
        onlyIncompleteAndUnexecutedOrder(order)
        onlyValidCreditManager(order.creditManager)
        onlyValidPartition(order.parts)
    {
        _verifySigner(order, signature);

        _execute(order, adapter, adapterCallData);
    }

    /// @notice Cancel the order
    /// @param order The order to cancel
    function cancelOrder(Order calldata order) external override onlyOrderOwner(order.owner) {
        bytes32 orderHash = _getOrderHash(order);
        OrderStatus storage status = _orderStatuses[orderHash];

        if (status.cancelledTime > 0) {
            revert OrderAlreadyCancelledException();
        }

        status.cancelledTime = uint32(block.timestamp);

        emit OrderCancelled(order.creditAccount, orderHash);
    }

    //
    // EXTERNAL VIEW

    /// @notice Get the order hash
    /// @param order The order to get the hash
    function getOrderHash(Order calldata order) external view override returns (bytes32) {
        return _getOrderHash(order);
    }

    /// @notice Get the order status
    /// @param orderHash The order hash to get the status
    function getOrderStatus(bytes32 orderHash) external view returns (OrderStatus memory) {
        return _orderStatuses[orderHash];
    }

    //
    // INTERNAL VIEW
    //
    function _getOrderHash(Order calldata order) internal view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ORDER_TYPEHASH, order)));
    }

    /// @notice Verify the signer of the order
    /// @param order The order to verify
    /// @param signature The signature of the order
    function _verifySigner(Order calldata order, bytes memory signature) internal view {
        bytes32 orderHash = _getOrderHash(order);
        address signer = ECDSA.recover(orderHash, signature);

        if (signer != order.owner) {
            revert InvalidSingerException();
        }
    }

    function _onlyIncompleteAndUnexecutedOrder(Order calldata order) internal view {
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

    function _price(address tokenA, address tokenB) internal view returns (uint256) {
        return _priceOracle.getPrice(tokenA) * 1e8 / _priceOracle.getPrice(tokenB);
    }

    function _calcTokenOutMinAmount(Order calldata order) internal view returns (uint256) {
        uint8 tokenInDecimals = IERC20Metadata(order.tokenIn).decimals();
        uint8 tokenOutDecimals = IERC20Metadata(order.tokenOut).decimals();
        uint256 price = _price(order.tokenIn, order.tokenOut);
        uint256 tokenInAmountWithSlippage = (order.amountIn * (PERCENTAGE_FACTOR - order.slippage)) / PERCENTAGE_FACTOR;
        uint256 tokenOutMinAmountWithTokenInDecimals = (tokenInAmountWithSlippage * price) / 1e8;
        uint256 tokenOutMinAmount =
            tokenOutMinAmountWithTokenInDecimals.formatDecimals(tokenInDecimals, tokenOutDecimals);

        return tokenOutMinAmount;
    }

    function _calcQuotaForQuotedToken(
        address quotedToken,
        address underlyingToken,
        uint256 quotedTokenAmount
    )
        internal
        view
        returns (int96)
    {
        uint8 quotedTokenDecimals = IERC20Metadata(quotedToken).decimals();
        uint8 underlyingTokenDecimals = IERC20Metadata(underlyingToken).decimals();
        uint256 price = _price(quotedToken, underlyingToken).formatDecimals(8, underlyingTokenDecimals);
        uint256 quota = (price * quotedTokenAmount) / (10 ** quotedTokenDecimals);

        return int96(uint96(quota));
    }

    function _genBalanceDelta(Order calldata order) internal view returns (BalanceDelta[] memory) {
        BalanceDelta[] memory deltas;
        uint256 tokenOutMinAmount = _calcTokenOutMinAmount(order);

        if (order.collateral != order.tokenIn) {
            if (order.collateral == order.tokenOut) {
                deltas = new BalanceDelta[](2);
                tokenOutMinAmount = tokenOutMinAmount + order.collateralAmount;
                deltas[0] = BalanceDelta({token: order.tokenIn, amount: 0});
                deltas[1] = BalanceDelta({token: order.tokenOut, amount: tokenOutMinAmount.toInt256()});
                return deltas;
            }
            deltas = new BalanceDelta[](3);
            deltas[0] = BalanceDelta({token: order.tokenIn, amount: 0});
            deltas[1] = BalanceDelta({token: order.tokenOut, amount: tokenOutMinAmount.toInt256()});
            deltas[2] = BalanceDelta({token: order.collateral, amount: order.collateralAmount.toInt256()});
            return deltas;
        }
        deltas = new BalanceDelta[](2);
        deltas[0] = BalanceDelta({token: order.tokenIn, amount: order.collateralAmount.toInt256()});
        deltas[1] = BalanceDelta({token: order.tokenOut, amount: tokenOutMinAmount.toInt256()});
        return deltas;
    }

    function _genCalls(
        Order calldata order,
        address adapter,
        bytes calldata adapterCallData
    )
        internal
        view
        returns (MultiCall[] memory)
    {
        ICreditManagerV3 creditManager = ICreditManagerV3(order.creditManager);
        address creditFacadeAddress = creditManager.creditFacade();

        MultiCall[] memory calls;

        bool isNonTokenInOrOutCollateral = order.collateral != order.tokenIn && order.collateral != order.tokenOut;

        if (isNonTokenInOrOutCollateral) {
            calls = new MultiCall[](7);
        } else {
            calls = new MultiCall[](6);
        }

        calls[0] = MultiCall({
            target: creditFacadeAddress,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.storeExpectedBalances, (_genBalanceDelta(order)))
        });

        calls[1] = MultiCall({
            target: creditFacadeAddress,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (order.collateral, order.collateralAmount))
        });

        calls[2] = MultiCall({
            target: creditFacadeAddress,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (order.amountIn))
        });

        calls[3] = MultiCall({target: adapter, callData: adapterCallData});

        if (isNonTokenInOrOutCollateral) {
            uint256 tokenOutMinAmount = _calcTokenOutMinAmount(order);
            int96 quotaForCollateral = _calcQuotaForQuotedToken(order.collateral, order.tokenIn, order.collateralAmount);
            int96 quotaForTokenOut = _calcQuotaForQuotedToken(order.tokenOut, order.tokenIn, tokenOutMinAmount);

            /// @dev can be enhanced to this formula (muliplied by LT):
            /// https://github.com/Gearbox-protocol/sdk/blob/d7dda524d049a3c68e31e44a8eed3fecc288b52d/src/core/creditAccount.ts#L564
            calls[4] = MultiCall({
                target: creditFacadeAddress,
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (order.tokenOut, quotaForTokenOut, uint96(quotaForTokenOut))
                    )
            });

            calls[5] = MultiCall({
                target: creditFacadeAddress,
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (order.collateral, quotaForCollateral, uint96(quotaForCollateral))
                    )
            });
        } else {
            int96 quota = int96(uint96(order.amountIn));
            if (order.collateral != order.tokenIn && order.collateral == order.tokenOut) {
                quota += _calcQuotaForQuotedToken(order.collateral, order.tokenIn, order.collateralAmount);
            }

            /// @dev can be enhanced to this formula (muliplied by LT):
            /// https://github.com/Gearbox-protocol/sdk/blob/d7dda524d049a3c68e31e44a8eed3fecc288b52d/src/core/creditAccount.ts#L564
            calls[4] = MultiCall({
                target: creditFacadeAddress,
                callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (order.tokenOut, quota, uint96(quota)))
            });
        }

        /// @dev isNonTokenInOrOutCollateral has an additional call data
        calls[isNonTokenInOrOutCollateral ? 6 : 5] = MultiCall({
            target: creditFacadeAddress,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.compareBalances, ())
        });

        return calls;
    }

    function _execute(Order calldata order, address adapter, bytes calldata adapterCallData) internal {
        ICreditManagerV3 creditManager = ICreditManagerV3(order.creditManager);
        address creditFacadeAddress = creditManager.creditFacade();

        SafeERC20.safeTransferFrom(IERC20Metadata(order.collateral), order.owner, address(this), order.collateralAmount);

        SafeERC20.forceApprove(IERC20Metadata(order.collateral), address(creditManager), order.collateralAmount);

        MultiCall[] memory calls = _genCalls(order, adapter, adapterCallData);
        ICreditFacadeV3(creditFacadeAddress).botMulticall(order.creditAccount, calls);

        bytes32 orderHash = _getOrderHash(order);

        OrderStatus storage status = _orderStatuses[orderHash];

        status.executedTimes += 1;
        status.executedTime = uint32(block.timestamp);

        emit OrderExectued(order.creditAccount, orderHash, msg.sender, order.parts, status.executedTimes);
    }
}
