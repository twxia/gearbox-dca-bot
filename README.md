## Gearbox DCA Bot Example

This is a Solidity example of a DCA (Dollar-Cost Averaging) Bot service using the Gearbox protocol. You can use your WBTC as collateral and borrow USDT to DCA buying in the WETH/USDT market.

It does not include backend and frontend services. However, you can easily build a server with two endpoints: one to store signatures in a database, and another to provide available signatures to keeper bots. For frontend, you need to calculate the health risk related stuff and form the `Order` structure. (Please check `_prepareCreditAccountAndSetBotPermissions()`, and `_prepareXXXCollateralForDCABot` in the `GearboxDCA.t.sol` or the below flow chart to know more about it.)

## Flow Chart

![sequence_diagram](./diagram/sequence.png)

### User End

1.  Approve `creditManager` to spend `N` amount of collateral (EIP-2612-compatible token can skip this step)
    - `N > order.collateralAmount * order.parts` (order is the struct in 4.) Otherwise, the order will not be be executed.
2.  Send `creditFacade.openCreditAccount(user, [addCollateral(WETH,10 ether)], 0)`
3.  Send `creditFacade.setBotPermissions(dcaBot, EXTERNAL_CALLS_PERMISSION)`
4.  Submit a DCA order to server

### Keeper End

1. By static calling `executeOrder()` or `getOrderStatus()` to check an order executability
2. Send `executeOrder()` to execute an order.

## Design Note

### How should we handle the `openCreditAccount`?

<details open>
<summary>Capital efficiency version</summary>

- User on-chain actions:
  1.  Approve `dcaBot` to spend 10 WETH (EIP-2612-compatible token can skip this step)
  2.  `creditFacade.openCreditAccount(user, [], 0)`
  3.  `creditFacade.setBotPermissions(dcaBot, PERMISSIONS)`
- Pros:
  1.  Capital efficiency: User can move their money easily. Funds will be moved when the order gets executed
- Cons: 1. Extra security risk: User needs to approve first to let dcaBot to spend their money
</details>

<details>
 <summary>(Skip) Capital inefficiency version</summary>

- User on-chain actions:
  1.  Approve `creditManager` to spend 10 WETH (EIP-2612-compatible token can skip this step)
  2.  `creditFacade.openCreditAccount(user, [addCollateral(WETH,10 ether)], 0)`
  3.  `creditFacade.setBotPermissions(dcaBot, EXTERNAL_CALLS_PERMISSION)`
- Pros:
  1.  Simple design: dcaBot only needs to care about the creditFacade's external calls
- Cons:
  1.  Capital inefficiency: collateral stores in the credit account first
  </details>

## Usage

### .env

```
mv .env.example .env # please update .env
```

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```
