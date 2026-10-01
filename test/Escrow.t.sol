// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Escrow} from "../src/Escrow.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract EscrowTest is Test {
    Escrow public escrow;
    MockERC20 public token;

    address public arbiter = address(0x1);
    address public buyer = address(0x2);
    address public seller = address(0x3);
    address public other = address(0x4);

    uint256 public constant ARBITER_FEE_BPS = 250; // 2.5%
    uint256 public constant AMOUNT = 1000 * 10**18;
    uint256 public constant SELLER_TIMEOUT = 1 days;
    uint256 public constant BUYER_TIMEOUT = 3 days;

    function setUp() public {
        vm.prank(arbiter);
        escrow = new Escrow(arbiter, ARBITER_FEE_BPS);

        token = new MockERC20("Tether USD", "USDT", 18);

        // Mint tokens to buyer
        token.mint(buyer, AMOUNT * 10);

        // Approve escrow contract
        vm.prank(buyer);
        token.approve(address(escrow), type(uint256).max);
    }

    function test_CreateEscrow() public {
        vm.prank(buyer);
        uint256 id = escrow.createEscrow(seller, address(token), AMOUNT, SELLER_TIMEOUT, BUYER_TIMEOUT);

        assertEq(id, 1);

        // Retrieve transaction using struct
        (
            , // id
            address eBuyer,
            address eSeller,
            address eToken,
            uint256 eAmount,
            , // sellerTimeout
            , // buyerTimeout
            , // createdAt
            , // inProgressAt
            Escrow.EscrowState eState,
            , // buyerAgreed
             // sellerAgreed
        ) = escrow.escrows(id);

        assertEq(eBuyer, buyer);
        assertEq(eSeller, seller);
        assertEq(eToken, address(token));
        assertEq(eAmount, AMOUNT);
        assertEq(uint(eState), uint(Escrow.EscrowState.CREATED));

        assertEq(token.balanceOf(address(escrow)), AMOUNT);
        assertEq(token.balanceOf(buyer), (AMOUNT * 10) - AMOUNT);
    }

    function test_HappyPath_ProcessAndConfirm() public {
        vm.prank(buyer);
        uint256 id = escrow.createEscrow(seller, address(token), AMOUNT, SELLER_TIMEOUT, BUYER_TIMEOUT);

        vm.prank(seller);
        escrow.processOrder(id);

        (,,,,,,,,, Escrow.EscrowState eState,,) = escrow.escrows(id);
        assertEq(uint(eState), uint(Escrow.EscrowState.IN_PROGRESS));

        vm.prank(buyer);
        escrow.confirmReceipt(id);

        (,,,,,,,,, Escrow.EscrowState finalState,,) = escrow.escrows(id);
        assertEq(uint(finalState), uint(Escrow.EscrowState.COMPLETED));

        assertEq(token.balanceOf(seller), AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_SellerTimeoutRefund() public {
        vm.prank(buyer);
        uint256 id = escrow.createEscrow(seller, address(token), AMOUNT, SELLER_TIMEOUT, BUYER_TIMEOUT);

        vm.warp(block.timestamp + SELLER_TIMEOUT + 1);

        vm.prank(buyer);
        escrow.claimTimeout(id);

        (,,,,,,,,, Escrow.EscrowState finalState,,) = escrow.escrows(id);
        assertEq(uint(finalState), uint(Escrow.EscrowState.CANCELLED));

        assertEq(token.balanceOf(buyer), AMOUNT * 10);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_BuyerTimeoutPayout() public {
        vm.prank(buyer);
        uint256 id = escrow.createEscrow(seller, address(token), AMOUNT, SELLER_TIMEOUT, BUYER_TIMEOUT);

        vm.prank(seller);
        escrow.processOrder(id);

        vm.warp(block.timestamp + BUYER_TIMEOUT + 1);

        vm.prank(seller);
        escrow.claimTimeout(id);

        (,,,,,,,,, Escrow.EscrowState finalState,,) = escrow.escrows(id);
        assertEq(uint(finalState), uint(Escrow.EscrowState.COMPLETED));

        assertEq(token.balanceOf(seller), AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_MutualCancellation() public {
        vm.prank(buyer);
        uint256 id = escrow.createEscrow(seller, address(token), AMOUNT, SELLER_TIMEOUT, BUYER_TIMEOUT);

        vm.prank(buyer);
        escrow.requestCancel(id);

        (,,,,,,,,,, bool bAgreed, bool sAgreed) = escrow.escrows(id);
        assertTrue(bAgreed);
        assertFalse(sAgreed);

        vm.prank(seller);
        escrow.requestCancel(id);

        (,,,,,,,,, Escrow.EscrowState finalState,,) = escrow.escrows(id);
        assertEq(uint(finalState), uint(Escrow.EscrowState.CANCELLED));

        assertEq(token.balanceOf(buyer), AMOUNT * 10);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_DisputeAndResolve_BuyerWins() public {
        vm.prank(buyer);
        uint256 id = escrow.createEscrow(seller, address(token), AMOUNT, SELLER_TIMEOUT, BUYER_TIMEOUT);

        vm.prank(seller);
        escrow.processOrder(id);

        vm.prank(buyer);
        escrow.initiateDispute(id);

        (,,,,,,,,, Escrow.EscrowState dState,,) = escrow.escrows(id);
        assertEq(uint(dState), uint(Escrow.EscrowState.DISPUTED));

        vm.prank(arbiter);
        escrow.resolveDispute(id, buyer);

        (,,,,,,,,, Escrow.EscrowState finalState,,) = escrow.escrows(id);
        assertEq(uint(finalState), uint(Escrow.EscrowState.RESOLVED));

        uint256 fee = (AMOUNT * ARBITER_FEE_BPS) / 10000;
        uint256 payout = AMOUNT - fee;

        assertEq(token.balanceOf(arbiter), fee);
        assertEq(token.balanceOf(buyer), (AMOUNT * 9) + payout);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_DisputeAndResolve_SellerWins() public {
        vm.prank(buyer);
        uint256 id = escrow.createEscrow(seller, address(token), AMOUNT, SELLER_TIMEOUT, BUYER_TIMEOUT);

        vm.prank(seller);
        escrow.processOrder(id);

        vm.prank(seller);
        escrow.initiateDispute(id);

        vm.prank(arbiter);
        escrow.resolveDispute(id, seller);

        uint256 fee = (AMOUNT * ARBITER_FEE_BPS) / 10000;
        uint256 payout = AMOUNT - fee;

        assertEq(token.balanceOf(arbiter), fee);
        assertEq(token.balanceOf(seller), payout);
        assertEq(token.balanceOf(address(escrow)), 0);
    }
}

import {FeeOnTransferToken} from "./FeeOnTransferToken.sol";

contract EscrowFeeOnTransferTest is Test {
    Escrow public escrow;
    FeeOnTransferToken public token;

    address public arbiter = address(0x1);
    address public buyer = address(0x2);
    address public seller = address(0x3);

    uint256 public constant AMOUNT = 1000 * 10**18;

    function setUp() public {
        escrow = new Escrow(arbiter, 250);
        token = new FeeOnTransferToken();

        token.mint(buyer, AMOUNT * 10);

        vm.prank(buyer);
        token.approve(address(escrow), type(uint256).max);
    }

    function test_FeeOnTransfer() public {
        vm.prank(buyer);
        uint256 id = escrow.createEscrow(seller, address(token), AMOUNT, 1 days, 3 days);

        (,,,,uint256 eAmount,,,,,,,) = escrow.escrows(id);

        // Fee is 5%, so 1000 * 0.95 = 950
        uint256 expectedAmount = (AMOUNT * 95) / 100;
        assertEq(eAmount, expectedAmount);
        assertEq(token.balanceOf(address(escrow)), expectedAmount);

        vm.prank(seller);
        escrow.processOrder(id);

        vm.prank(buyer);
        escrow.confirmReceipt(id);

        // When paying out, there will be another 5% fee on the transfer to the seller.
        // So expectedAmount * 0.95 = 950 * 0.95 = 902.5
        uint256 expectedPayout = (expectedAmount * 95) / 100;
        assertEq(token.balanceOf(seller), expectedPayout);
        assertEq(token.balanceOf(address(escrow)), 0);
    }
}
