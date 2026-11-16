// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractCallback } from "./lib/reactive-lib/src/base/AbstractCallback.sol";
import { IPayable } from "./lib/reactive-lib/src/interfaces/IPayable.sol";

/// @title SentinelVault
/// @notice A time-locked ETH vault on Base/Unichain Sepolia. Every withdrawal waits `delay` seconds.
/// A Reactive Network contract scores each request with an on-chain neural network and, if it looks
/// anomalous, calls back `freeze` within that window — Omni's ~1s blocks make the window short.
contract SentinelVault is AbstractCallback {
    struct Request {
        address to;
        uint96 amount;
        uint64 executeAfter;
        bool executed;
        bool frozen;
        bool cancelled;
    }

    event WithdrawalRequested(
        uint256 indexed id,
        address indexed to,
        uint256 amount,
        uint256 balanceBefore,
        uint256 executeAfter
    );
    event WithdrawalExecuted(uint256 indexed id, address indexed to, uint256 amount);
    event WithdrawalFrozen(uint256 indexed id, int256 score);
    event WithdrawalCancelled(uint256 indexed id);
    event Deposited(address indexed from, uint256 amount);

    error NotOwner();
    error NotReady();
    error NotPending();
    error AmountTooLarge();

    address public immutable owner;
    uint64 public immutable delay;
    uint256 public reserved;
    uint256 public nextId;
    mapping(uint256 => Request) public requests;

    constructor(IPayable callbackProxy_, address sentinel_, uint64 delay_)
        payable
        AbstractCallback(callbackProxy_, sentinel_)
    {
        owner = msg.sender;
        delay = delay_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    receive() external payable override {
        emit Deposited(msg.sender, msg.value);
    }

    function available() public view returns (uint256) {
        return address(this).balance - reserved;
    }

    function requestWithdrawal(address to, uint96 amount) external onlyOwner returns (uint256 id) {
        uint256 free = available();
        if (amount > free) revert AmountTooLarge();
        id = nextId++;
        uint64 executeAfter = uint64(block.timestamp) + delay;
        requests[id] = Request(to, amount, executeAfter, false, false, false);
        reserved += amount;
        emit WithdrawalRequested(id, to, amount, free, executeAfter);
    }

    /// @notice Anyone may execute a matured, unfrozen request (keeps it permissionless and simple).
    function execute(uint256 id) external {
        Request storage r = requests[id];
        if (r.executed || r.frozen || r.cancelled || r.to == address(0)) revert NotPending();
        if (block.timestamp < r.executeAfter) revert NotReady();
        r.executed = true;
        reserved -= r.amount;
        (bool ok,) = r.to.call{ value: r.amount }("");
        require(ok, "transfer failed");
        emit WithdrawalExecuted(id, r.to, r.amount);
    }

    function cancel(uint256 id) external onlyOwner {
        Request storage r = requests[id];
        if (r.executed || r.cancelled || r.to == address(0)) revert NotPending();
        // Frozen requests keep their funds reserved until the owner reviews and cancels them here.
        r.cancelled = true;
        reserved -= r.amount;
        emit WithdrawalCancelled(id);
    }

    /// @notice Reactive callback. The first argument is overwritten by the Reactive Network with the
    /// address of the reactive contract that requested it, which must be our sentinel.
    function freeze(address sentinel_, uint256 id, int256 score)
        external
        onlyServiceProvider
        onlyCallbackSender(sentinel_)
    {
        Request storage r = requests[id];
        if (r.executed || r.frozen || r.cancelled || r.to == address(0)) return; // too late or unknown: no-op
        r.frozen = true;
        emit WithdrawalFrozen(id, score);
    }

    /// @notice Settles callback fees owed to the Reactive callback proxy from the vault's balance.
    function coverDebt() external {
        _coverDebt();
    }
}
