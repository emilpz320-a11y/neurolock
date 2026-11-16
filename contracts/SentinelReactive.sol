// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractReactive } from "./lib/reactive-lib/src/base/AbstractReactive.sol";
import { ISystemContract } from "./lib/reactive-lib/src/interfaces/ISystemContract.sol";
import { SentinelMLP } from "./SentinelMLP.sol";

/// @title SentinelReactive
/// @notice Lives on Reactive Network. Watches `WithdrawalRequested` on registered vaults, builds a
/// 4-feature behavioural profile per vault, scores it with an on-chain MLP and requests a `freeze`
/// callback when the score is positive.
contract SentinelReactive is AbstractReactive {
    uint256 public constant WITHDRAWAL_REQUESTED_TOPIC =
        uint256(keccak256("WithdrawalRequested(uint256,address,uint256,uint256,uint256)"));
    uint64 public constant CALLBACK_GAS_LIMIT = 200_000;
    int256 internal constant ONE = 10_000;
    uint256 internal constant WINDOW = 1 hours;
    uint8 internal constant HISTORY = 10;

    struct Profile {
        uint64 lastSeen;
        uint8 head;
        uint64[10] recent; // ring buffer of request timestamps
    }

    event Scored(
        uint256 indexed chainId,
        address indexed vault,
        uint256 indexed requestId,
        int256[4] features,
        int256 score,
        bool frozen
    );
    event Watching(uint256 indexed chainId, address indexed vault);

    error NotOwner();

    address public immutable owner;
    mapping(bytes32 => Profile) internal profiles;
    mapping(bytes32 => bool) public knownRecipient;

    constructor() payable {
        owner = msg.sender;
    }

    function watch(uint256 chainId, address vault) external {
        if (msg.sender != owner) revert NotOwner();
        SYSTEM.subscribe(chainId, vault, WITHDRAWAL_REQUESTED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit Watching(chainId, vault);
    }

    /// @notice Lets the owner pre-approve a recipient (e.g. their own cold wallet).
    function trustRecipient(uint256 chainId, address vault, address recipient) external {
        if (msg.sender != owner) revert NotOwner();
        knownRecipient[_recipientKey(chainId, vault, recipient)] = true;
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 != WITHDRAWAL_REQUESTED_TOPIC || log_.opCode != 3) return;

        uint256 requestId = log_.topic1;
        address to = address(uint160(log_.topic2));
        (uint256 amount, uint256 balanceBefore,) = abi.decode(log_.data, (uint256, uint256, uint256));

        bytes32 vaultKey = keccak256(abi.encode(log_.chainId, log_.contractAddress));
        bytes32 recipientKey = _recipientKey(log_.chainId, log_.contractAddress, to);
        Profile storage p = profiles[vaultKey];

        int256[4] memory x = features(p, amount, balanceBefore, !knownRecipient[recipientKey], block.timestamp);
        int256 s = SentinelMLP.score(x);
        bool freeze = s > 0;

        // Update the behavioural profile after scoring.
        p.recent[p.head] = uint64(block.timestamp);
        p.head = uint8((p.head + 1) % HISTORY);
        p.lastSeen = uint64(block.timestamp);
        if (!freeze) knownRecipient[recipientKey] = true;

        emit Scored(log_.chainId, log_.contractAddress, requestId, x, s, freeze);

        if (freeze) {
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: log_.chainId,
                    recipient: log_.contractAddress,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: abi.encodeWithSignature("freeze(address,uint256,int256)", address(0), requestId, s)
                })
            );
        }
    }

    /// @notice Feature extraction, exposed for transparency and testing. All features are in [0, 1e4].
    function features(Profile storage p, uint256 amount, uint256 balanceBefore, bool isNew, uint256 nowTs)
        internal
        view
        returns (int256[4] memory x)
    {
        x[0] = balanceBefore == 0 ? ONE : int256(_min(amount * uint256(ONE) / balanceBefore, uint256(ONE)));
        x[1] = isNew ? ONE : int256(0);
        if (p.lastSeen == 0) {
            x[2] = 0;
        } else {
            uint256 since = nowTs - p.lastSeen;
            x[2] = ONE - int256(_min(since * uint256(ONE) / WINDOW, uint256(ONE)));
        }
        uint256 count;
        for (uint256 i = 0; i < HISTORY; i++) {
            uint64 t = p.recent[i];
            if (t != 0 && nowTs - t <= WINDOW) count++;
        }
        x[3] = int256(_min(count * uint256(ONE) / HISTORY, uint256(ONE)));
    }

    function _recipientKey(uint256 chainId, address vault, address recipient) internal pure returns (bytes32) {
        return keccak256(abi.encode(chainId, vault, recipient));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
