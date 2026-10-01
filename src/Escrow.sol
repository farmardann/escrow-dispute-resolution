// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeERC20} from "./SafeERC20.sol";

contract Escrow {
    using SafeERC20 for IERC20;
    // -------------------------------------------------------------------------
    // Structs & Enums
    // -------------------------------------------------------------------------

    enum EscrowState {
        CREATED,
        IN_PROGRESS,
        COMPLETED,
        CANCELLED,
        DISPUTED,
        RESOLVED
    }

    struct EscrowTransaction {
        uint256 id;
        address buyer;
        address seller;
        address token;
        uint256 amount;
        uint256 sellerTimeout;
        uint256 buyerTimeout;
        uint256 createdAt;
        uint256 inProgressAt;
        EscrowState state;
        bool buyerAgreedCancel;
        bool sellerAgreedCancel;
    }

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    address public arbiter;
    uint256 public arbiterFeeBps; // Fee in basis points (e.g., 250 = 2.5%)

    uint256 public nextEscrowId;
    mapping(uint256 => EscrowTransaction) public escrows;

    uint256 private _status; // Reentrancy guard status

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event EscrowCreated(uint256 indexed id, address indexed buyer, address indexed seller, address token, uint256 amount, uint256 sellerTimeout, uint256 buyerTimeout);
    event OrderProcessed(uint256 indexed id);
    event ReceiptConfirmed(uint256 indexed id);
    event EscrowCancelled(uint256 indexed id);
    event CancelRequested(uint256 indexed id, address indexed party);
    event DisputeInitiated(uint256 indexed id, address indexed party);
    event DisputeResolved(uint256 indexed id, address winner, uint256 payout, uint256 fee);
    event SellerTimeoutClaimed(uint256 indexed id);
    event BuyerTimeoutClaimed(uint256 indexed id);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error Unauthorized();
    error InvalidState(EscrowState expected, EscrowState actual);
    error InvalidAddress();
    error InvalidAmount();
    error InvalidTimeout();
    error TimeoutNotReached();
    error ReentrancyGuardReentrantCall();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier nonReentrant() {
        if (_status == 2) revert ReentrancyGuardReentrantCall();
        _status = 2;
        _;
        _status = 1;
    }

    modifier onlyBuyer(uint256 _id) {
        if (msg.sender != escrows[_id].buyer) revert Unauthorized();
        _;
    }

    modifier onlySeller(uint256 _id) {
        if (msg.sender != escrows[_id].seller) revert Unauthorized();
        _;
    }

    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert Unauthorized();
        _;
    }

    modifier inState(uint256 _id, EscrowState _state) {
        if (escrows[_id].state != _state) revert InvalidState(_state, escrows[_id].state);
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _arbiter, uint256 _arbiterFeeBps) {
        if (_arbiter == address(0)) revert InvalidAddress();
        if (_arbiterFeeBps > 10000) revert InvalidAmount(); // Max 100%
        arbiter = _arbiter;
        arbiterFeeBps = _arbiterFeeBps;
        nextEscrowId = 1;
        _status = 1; // Unlocked
    }

    // -------------------------------------------------------------------------
    // Core Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Create a new escrow transaction. Buyer must have approved this contract.
     * @param _seller The address of the seller.
     * @param _token The address of the ERC20 token to use.
     * @param _amount The amount of tokens to deposit.
     * @param _sellerTimeout Duration (in seconds) seller has to process the order.
     * @param _buyerTimeout Duration (in seconds) buyer has to confirm receipt after seller processes.
     */
    function createEscrow(
        address _seller,
        address _token,
        uint256 _amount,
        uint256 _sellerTimeout,
        uint256 _buyerTimeout
    ) external nonReentrant returns (uint256) {
        if (_seller == address(0) || _seller == msg.sender) revert InvalidAddress();
        if (_amount == 0) revert InvalidAmount();
        if (_sellerTimeout == 0 || _buyerTimeout == 0) revert InvalidTimeout();

        uint256 escrowId = nextEscrowId++;

        escrows[escrowId] = EscrowTransaction({
            id: escrowId,
            buyer: msg.sender,
            seller: _seller,
            token: _token,
            amount: _amount,
            sellerTimeout: _sellerTimeout,
            buyerTimeout: _buyerTimeout,
            createdAt: block.timestamp,
            inProgressAt: 0,
            state: EscrowState.CREATED,
            buyerAgreedCancel: false,
            sellerAgreedCancel: false
        });

        // Emit event before transfer to avoid reentrancy warnings, although nonReentrant is used
        emit EscrowCreated(escrowId, msg.sender, _seller, _token, _amount, _sellerTimeout, _buyerTimeout);

        // Check balance before and after to handle fee-on-transfer tokens
        uint256 balanceBefore = IERC20(_token).balanceOf(address(this));

        // Transfer funds from buyer to this contract
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 balanceAfter = IERC20(_token).balanceOf(address(this));
        uint256 actualReceived = balanceAfter - balanceBefore;

        // Update the amount to the actual received amount
        escrows[escrowId].amount = actualReceived;

        return escrowId;
    }

    /**
     * @notice Seller marks the order as processed/shipped.
     * @param _id The escrow ID.
     */
    function processOrder(uint256 _id) external onlySeller(_id) inState(_id, EscrowState.CREATED) {
        escrows[_id].state = EscrowState.IN_PROGRESS;
        escrows[_id].inProgressAt = block.timestamp;

        emit OrderProcessed(_id);
    }

    /**
     * @notice Buyer confirms receipt of goods/services. Funds are released to the seller.
     * @param _id The escrow ID.
     */
    function confirmReceipt(uint256 _id) external nonReentrant onlyBuyer(_id) inState(_id, EscrowState.IN_PROGRESS) {
        EscrowTransaction storage txn = escrows[_id];
        txn.state = EscrowState.COMPLETED;

        emit ReceiptConfirmed(_id);

        IERC20(txn.token).safeTransfer(txn.seller, txn.amount);
    }

    /**
     * @notice Handles timeouts for both buyer and seller.
     * If seller fails to process in time, buyer can refund.
     * If buyer fails to confirm in time, seller gets paid.
     * @param _id The escrow ID.
     */
    function claimTimeout(uint256 _id) external nonReentrant {
        EscrowTransaction storage txn = escrows[_id];

        if (txn.state == EscrowState.CREATED) {
            // Seller failed to process the order in time, refund buyer
            if (block.timestamp <= txn.createdAt + txn.sellerTimeout) revert TimeoutNotReached();
            if (msg.sender != txn.buyer) revert Unauthorized();

            txn.state = EscrowState.CANCELLED;

            emit SellerTimeoutClaimed(_id);
            emit EscrowCancelled(_id);

            IERC20(txn.token).safeTransfer(txn.buyer, txn.amount);

        } else if (txn.state == EscrowState.IN_PROGRESS) {
            // Buyer failed to confirm receipt in time, pay seller
            if (block.timestamp <= txn.inProgressAt + txn.buyerTimeout) revert TimeoutNotReached();
            if (msg.sender != txn.seller) revert Unauthorized();

            txn.state = EscrowState.COMPLETED;

            emit BuyerTimeoutClaimed(_id);

            IERC20(txn.token).safeTransfer(txn.seller, txn.amount);
        } else {
            revert InvalidState(EscrowState.CREATED, txn.state); // Using CREATED as placeholder for expected state since it could be CREATED or IN_PROGRESS
        }
    }

    // -------------------------------------------------------------------------
    // Cancellation (Mutual Agreement)
    // -------------------------------------------------------------------------

    /**
     * @notice Request or confirm cancellation of the escrow.
     * If both parties agree, the escrow is cancelled and funds are refunded to the buyer.
     * @param _id The escrow ID.
     */
    function requestCancel(uint256 _id) external nonReentrant {
        EscrowTransaction storage txn = escrows[_id];

        // Can only mutually cancel if it hasn't been completed, already cancelled, or resolved
        require(
            txn.state == EscrowState.CREATED || txn.state == EscrowState.IN_PROGRESS || txn.state == EscrowState.DISPUTED,
            "Cannot cancel in current state"
        );

        if (msg.sender == txn.buyer) {
            txn.buyerAgreedCancel = true;
        } else if (msg.sender == txn.seller) {
            txn.sellerAgreedCancel = true;
        } else {
            revert Unauthorized();
        }

        emit CancelRequested(_id, msg.sender);

        if (txn.buyerAgreedCancel && txn.sellerAgreedCancel) {
            txn.state = EscrowState.CANCELLED;

            emit EscrowCancelled(_id);

            IERC20(txn.token).safeTransfer(txn.buyer, txn.amount);
        }
    }

    // -------------------------------------------------------------------------
    // Dispute Resolution
    // -------------------------------------------------------------------------

    /**
     * @notice Initiate a dispute. Either buyer or seller can call this.
     * @param _id The escrow ID.
     */
    function initiateDispute(uint256 _id) external {
        EscrowTransaction storage txn = escrows[_id];
        require(txn.state == EscrowState.IN_PROGRESS, "Can only dispute IN_PROGRESS");
        require(msg.sender == txn.buyer || msg.sender == txn.seller, "Unauthorized");

        txn.state = EscrowState.DISPUTED;
        emit DisputeInitiated(_id, msg.sender);
    }

    /**
     * @notice Resolve a dispute. Only the arbiter can call this.
     * @param _id The escrow ID.
     * @param _winner The address of the winning party (must be buyer or seller).
     */
    function resolveDispute(uint256 _id, address _winner) external nonReentrant onlyArbiter inState(_id, EscrowState.DISPUTED) {
        EscrowTransaction storage txn = escrows[_id];
        require(_winner == txn.buyer || _winner == txn.seller, "Invalid winner address");

        txn.state = EscrowState.RESOLVED;

        uint256 fee = (txn.amount * arbiterFeeBps) / 10000;
        uint256 payout = txn.amount - fee;

        emit DisputeResolved(_id, _winner, payout, fee);

        if (fee > 0) {
            IERC20(txn.token).safeTransfer(arbiter, fee);
        }

        IERC20(txn.token).safeTransfer(_winner, payout);
    }
}
