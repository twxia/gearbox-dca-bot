## Gearbox DCA Bot Example

This is a Solidity example of a DCA (Dollar-Cost Averaging) Bot using the Gearbox protocol.

It does not include backend and frontend services. However, you can easily build a server with two endpoints: one to store signatures in a database, and another to provide available signatures to keeper bots. For frontend, you need to calculate the health risk related stuff and form the `Order` structure.

## Flow Chart

![sequence_diagram](./diagram/sequence.png)

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
