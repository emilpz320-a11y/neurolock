// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { SentinelMLP } from "../SentinelMLP.sol";
import { SentinelVault } from "../SentinelVault.sol";
import { SentinelReactive } from "../SentinelReactive.sol";
import { IReactive } from "../lib/reactive-lib/src/interfaces/IReactive.sol";
import { IPayable } from "../lib/reactive-lib/src/interfaces/IPayable.sol";
import { ISystemContract } from "../lib/reactive-lib/src/interfaces/ISystemContract.sol";

/// Minimal stand-in for the Reactive system contract (0x8888...8888) and the destination callback proxy.
contract MockSystem {
    uint256 public subscriptions;
    ISystemContract.CallbackConfiguration_V_1_0 internal lastCallback;
    uint256 public callbacks;

    receive() external payable {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscriptions++;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        lastCallback = config_;
        callbacks++;
    }

    function last() external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return lastCallback;
    }
}

contract SentinelTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant CHAIN = 84532; // Base Sepolia
    address constant PROXY = address(0xCA11BAC);
    address constant FRIEND = address(0xF00D);
    address constant ATTACKER = address(0xBAD);

    MockSystem sys;
    SentinelReactive sentinel;
    SentinelVault vault;

    function setUp() public {
        MockSystem impl = new MockSystem();
        vm.etch(SYSTEM, address(impl).code);
        sys = MockSystem(payable(SYSTEM));

        sentinel = new SentinelReactive();
        vault = new SentinelVault{ value: 10 ether }(IPayable(payable(PROXY)), address(sentinel), 30);
        sentinel.watch(CHAIN, address(vault));
        vm.warp(1_800_000_000);
    }

    // ---- MLP golden vectors (match train/train.py output signs) ----
    function test_mlp_routinePaymentIsBenign() public pure {
        assertLt(SentinelMLP.score([int256(500), 0, 1000, 1000]), 0);
    }

    function test_mlp_drainToNewAddressIsAnomalous() public pure {
        assertGt(SentinelMLP.score([int256(9500), 10000, 2000, 1000]), 0);
    }

    function test_mlp_rapidBurstIsAnomalous() public pure {
        assertGt(SentinelMLP.score([int256(3000), 0, 9800, 8000]), 0);
    }

    function test_mlp_bigButKnownIsBenign() public pure {
        assertLt(SentinelMLP.score([int256(4500), 0, 500, 0]), 0);
    }

    // ---- helpers ----
    function _request(address to, uint96 amount) internal returns (uint256 id, IReactive.LogRecord memory log_) {
        uint256 before = vault.available();
        id = vault.requestWithdrawal(to, amount);
        (,, uint64 executeAfter,,,) = vault.requests(id);
        log_ = IReactive.LogRecord({
            chainId: CHAIN,
            contractAddress: address(vault),
            topic0: sentinel.WITHDRAWAL_REQUESTED_TOPIC(),
            topic1: id,
            topic2: uint256(uint160(to)),
            topic3: 0,
            data: abi.encode(uint256(amount), before, uint256(executeAfter)),
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _deliverLastCallback() internal {
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = sys.last();
        assertEq(cb.chainId, CHAIN);
        assertEq(cb.recipient, address(vault));
        // The Reactive Network overwrites the first 160 bits of arg 0 with the reactive contract address.
        bytes memory payload = cb.payload;
        bytes32 sender = bytes32(uint256(uint160(address(sentinel))));
        assembly {
            mstore(add(payload, 36), sender)
        }
        vm.prank(PROXY);
        (bool ok,) = address(vault).call(payload);
        assertTrue(ok);
    }

    // ---- full loop ----
    function test_subscribesOnWatch() public view {
        assertEq(sys.subscriptions(), 1);
    }

    function test_smallPaymentPassesAndExecutes() public {
        (uint256 id, IReactive.LogRecord memory log_) = _request(FRIEND, 0.3 ether);
        vm.prank(SYSTEM);
        sentinel.react(log_);
        assertEq(sys.callbacks(), 0);

        vm.warp(block.timestamp + 31);
        vault.execute(id);
        assertEq(FRIEND.balance, 0.3 ether);
    }

    function test_drainToNewAddressIsFrozenBeforeExecution() public {
        (uint256 id, IReactive.LogRecord memory log_) = _request(ATTACKER, 9.5 ether);
        vm.prank(SYSTEM);
        sentinel.react(log_);
        assertEq(sys.callbacks(), 1);

        vm.warp(block.timestamp + 1); // ~1s Omni block later the callback lands
        _deliverLastCallback();

        vm.warp(block.timestamp + 60);
        vm.expectRevert(SentinelVault.NotPending.selector);
        vault.execute(id);
        assertEq(ATTACKER.balance, 0);

        // Owner reviews and releases the reservation.
        vault.cancel(id);
        assertEq(vault.available(), 10 ether);
    }

    function test_onlySentinelCanFreeze() public {
        (uint256 id,) = _request(ATTACKER, 9 ether);
        vm.prank(PROXY);
        vm.expectRevert();
        vault.freeze(address(0x1234), id, 1);

        vm.prank(ATTACKER);
        vm.expectRevert();
        vault.freeze(address(sentinel), id, 1);
    }

    function test_onlySystemCanReact() public {
        (, IReactive.LogRecord memory log_) = _request(FRIEND, 1 ether);
        vm.expectRevert();
        sentinel.react(log_);
    }

    function test_burstOfWithdrawalsTripsVelocity() public {
        // A trusted recipient, but rapid repeated withdrawals that drain the vault look like a compromised key.
        sentinel.trustRecipient(CHAIN, address(vault), FRIEND);
        uint256 frozenAt = type(uint256).max;
        for (uint256 i = 0; i < 6; i++) {
            (, IReactive.LogRecord memory log_) = _request(FRIEND, 1.5 ether);
            vm.prank(SYSTEM);
            sentinel.react(log_);
            if (sys.callbacks() > 0 && frozenAt == type(uint256).max) frozenAt = i;
            vm.warp(block.timestamp + 5);
        }
        assertLt(frozenAt, 6, "velocity never triggered");
        assertGt(frozenAt, 0, "first withdrawal should pass");
    }
}
