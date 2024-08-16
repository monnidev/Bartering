# Disclaimer

This code is part of a small personal project and is not intended for use in production environments. It has not been thoroughly tested, nor has it undergone any form of security audit. Use this code at your own risk, and be aware that it may contain bugs, vulnerabilities, or other issues that could lead to unexpected behavior.

# Bartering

## Overview
Bartering is a decentralized smart contract platform that enables users to exchange ERC20 and ERC721 tokens. The platform allows users to create barter requests, specifying the tokens they want to offer and the tokens they seek in return. Other users can then browse and accept these barter requests.

### Key Functionalities
- **Create Barter Requests:** Users can propose trades by specifying which tokens they are willing to offer and which tokens they want in return.
- **Accept Barter Requests:** Users can accept existing barter proposals that match the tokens they are willing to exchange.
- **Cancel Barter Requests:** Users who have created barter requests can cancel them if they decide not to proceed with the trade.
- **Withdraw Tokens:** After a barter request is completed or canceled, users can withdraw their tokens from the contract.

## Getting Started

### Requirements

- [git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git)
  - You'll know you did it right if you can run `git --version` and you see a response like `git version x.x.x`
- [foundry](https://getfoundry.sh/)
  - You'll know you did it right if you can run `forge --version` and you see a response like `forge 0.2.0 (816e00b 2023-03-16T00:05:26.396218Z)`

### Installation

Clone the repository and compile contracts
```bash 
git clone https://github.com/monnidev/Bartering
code Bartering
```

### Build

```
forge build
```

### Test

```
forge test
```

## Licensing
- The `Bartering.sol` contract is released under the GPL 3 license.
