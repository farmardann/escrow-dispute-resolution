// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

// Mock fee-on-transfer token for testing
contract FeeOnTransferToken is IERC20 {
    string public name = "Fee Token";
    string public symbol = "FEE";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public constant FEE_BPS = 500; // 5% fee

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: transfer amount exceeds balance");

        uint256 fee = (amount * FEE_BPS) / 10000;
        uint256 netAmount = amount - fee;

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += netAmount;
        // The fee is just burned for simplicity
        totalSupply -= fee;

        emit Transfer(msg.sender, to, netAmount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(allowance[from][msg.sender] >= amount, "ERC20: transfer amount exceeds allowance");
        require(balanceOf[from] >= amount, "ERC20: transfer amount exceeds balance");

        uint256 fee = (amount * FEE_BPS) / 10000;
        uint256 netAmount = amount - fee;

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += netAmount;
        // The fee is just burned for simplicity
        totalSupply -= fee;

        emit Transfer(from, to, netAmount);
        return true;
    }
}
