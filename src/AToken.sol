// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

contract AToken is ERC20 {
    address public immutable lendingPool;

    modifier onlyLendingPool() {
        require(msg.sender == lendingPool, "ONLY_LENDING_POOL");
        _;
    }

    constructor(string memory name_, string memory symbol_, address lendingPool_) ERC20(name_, symbol_) {
        lendingPool = lendingPool_;
    }

    function mint(address to, uint256 amount) external onlyLendingPool {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyLendingPool {
        _burn(from, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert("NON_TRANSFERABLE");
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("NON_TRANSFERABLE");
    }
}
