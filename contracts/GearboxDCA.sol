// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {IGearboxDCAStruct} from "contracts/interfaces/IGearboxDCAStruct.sol";
import {IGearboxDCA} from "contracts/interfaces/IGearboxDCA.sol";

import "contracts/interfaces/IGearboxDCAException.sol";

contract GearboxDCA is EIP712, IGearboxDCA, IGearboxDCAStruct {
    ICreditFacadeV3 private _creditFacade;
    IPriceOracleV3 private _priceOracle;

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
        _priceOracle = IPriceOracleV3(priceOracle);
    }

    //
    // PUBLIC VIEW
    //

    function getCreditFacade() public view returns (ICreditFacadeV3) {
        return _creditFacade;
    }

    function test(
        Order calldata order,
        address adapter,
        bytes calldata adapterCallData
    ) public {
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

        MultiCall[] memory calls = new MultiCall[](5);

        calls[0] = MultiCall({
            target: address(_creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral,
                (order.collateral, collateralAmount)
            )
        });

        calls[1] = MultiCall({
            target: address(_creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.increaseDebt,
                (order.amountIn)
            )
        });

        calls[2] = MultiCall({
            target: address(_creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.enableToken,
                (order.tokenOut)
            )
        });

        // TODO: enhance quota to this formula:
        // https://github.com/Gearbox-protocol/sdk/blob/d7dda524d049a3c68e31e44a8eed3fecc288b52d/src/core/creditAccount.ts#L564
        calls[3] = MultiCall({
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

        calls[4] = MultiCall({target: adapter, callData: adapterCallData});

        _creditFacade.botMulticall(order.creditAccount, calls);
    }

    function executeOrder(
        Order calldata order,
        bytes calldata signature,
        address adapter,
        bytes calldata adapterCallData
    ) public view override {
        revert("Not implemented");
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
}
