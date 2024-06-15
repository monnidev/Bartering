// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("MockERC20", "M20") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC721 is ERC721 {
    uint256 private _currentTokenId;

    constructor() ERC721("MockERC721", "M721") {}

    function mint(address to) external {
        _currentTokenId++;
        _mint(to, _currentTokenId);
    }
}
