// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IContractsRegister} from "@gearbox-protocol/core-v2/contracts/interfaces/IContractsRegister.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {BalanceDelta} from "@gearbox-protocol/core-v3/contracts/libraries/BalancesLogic.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";

import {IGearboxDCA} from "contracts/interfaces/IGearboxDCA.sol";
import {IGearboxDCAStruct} from "contracts/interfaces/IGearboxDCAStruct.sol";
import {LibFormatter} from "contracts/libs/LibFormatter.sol";

import "contracts/interfaces/IGearboxDCAException.sol";

contract GearboxDCA is EIP712, IGearboxDCA, IGearboxDCAStruct {
    using LibFormatter for uint256;
    using SafeCast for uint256;

    uint256 constant MAX_PARTITION = 1_000_000;

    IPriceOracleV3 private _priceOracle;

    IContractsRegister private _contractsRegister;

    mapping(bytes32 => OrderStatus) internal _orderStatuses;

    string public constant ORDER_TYPE =
        "Order(address creditAccount,address collateral,address tokenIn,address tokenOut,uint256 salt,uint256 amountIn,uint256 parts,uint256 period,uint256 slippage)";
    bytes32 public constant ORDER_TYPEHASH = keccak256(abi.encodePacked(ORDER_TYPE));

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

    function _calcTokenOutMinAmount(Order calldata order) internal view returns (uint256) {
        uint8 tokenInDecimals = IERC20Metadata(order.tokenIn).decimals();
        uint8 tokenOutDecimals = IERC20Metadata(order.tokenOut).decimals();
        uint256 tokenInPrice = _priceOracle.getPrice(order.tokenIn);
        uint256 tokenOutPrice = _priceOracle.getPrice(order.tokenOut);
        uint256 price = (tokenInPrice * 1e8) / tokenOutPrice;
        uint256 tokenInAmountWithSlippage = (order.amountIn * (PERCENTAGE_FACTOR - order.slippage)) / PERCENTAGE_FACTOR;
        uint256 tokenOutMinAmountWithTokenInDecimals = (tokenInAmountWithSlippage * price) / 1e8;
        uint256 tokenOutMinAmount =
            tokenOutMinAmountWithTokenInDecimals.formatDecimals(tokenInDecimals, tokenOutDecimals);
        return tokenOutMinAmount;
    }

    function _execute(Order calldata order, address adapter, bytes calldata adapterCallData) internal {
        address creditManager = order.creditManager;
        address creditFacade = ICreditManagerV3(creditManager).creditFacade();

        SafeERC20.safeTransferFrom(IERC20Metadata(order.collateral), order.owner, address(this), order.collateralAmount);

        SafeERC20.forceApprove(IERC20Metadata(order.collateral), creditManager, order.collateralAmount);

        MultiCall[] memory calls = new MultiCall[](7);

        BalanceDelta[] memory deltas = new BalanceDelta[](2);

        deltas[0] = BalanceDelta({token: order.tokenIn, amount: order.collateralAmount.toInt256()});

        uint256 tokenOutMinAmount = _calcTokenOutMinAmount(order);

        deltas[1] = BalanceDelta({token: order.tokenOut, amount: tokenOutMinAmount.toInt256()});

        calls[0] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.storeExpectedBalances, (deltas))
        });

        calls[1] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (order.collateral, order.collateralAmount))
        });

        calls[2] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (order.amountIn))
        });

        calls[3] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.enableToken, (order.tokenOut))
        });

        // TODO: enhance quota to this formula:
        // https://github.com/Gearbox-protocol/sdk/blob/d7dda524d049a3c68e31e44a8eed3fecc288b52d/src/core/creditAccount.ts#L564
        calls[4] = MultiCall({
            target: creditFacade,
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

        calls[6] =
            MultiCall({target: creditFacade, callData: abi.encodeCall(ICreditFacadeV3Multicall.compareBalances, ())});

        ICreditFacadeV3(creditFacade).botMulticall(order.creditAccount, calls);

        bytes32 orderHash = _getOrderHash(order);

        OrderStatus storage status = _orderStatuses[orderHash];

        status.executedTimes += 1;
        status.executedTime = uint32(block.timestamp);
    }
}
