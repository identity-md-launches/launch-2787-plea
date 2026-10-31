// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PleaToken} from "src/PleaToken.sol";

/// @dev The actor set is closed: every successful transfer starts and ends within it.
/// Expected balances and spending budgets come from the initial allocation and requested
/// operations, never from copying the token's resulting state. Failed calls do not update them.
contract PleaTokenHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant ACTOR_COUNT = 5;
    PleaToken public immutable token;
    address[5] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    uint256 public successfulTransfers;
    uint256 public positiveTransfers;
    uint256 public approvals;
    uint256 public rejectedCalls;

    constructor(PleaToken token_, address[5] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            expectedBalance[actors_[i]] = SUPPLY / ACTOR_COUNT;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        _transfer(from, to, _edgeAmount(amountSeed, expectedBalance[from]));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        uint256 mode = amountSeed % 5;
        uint256 amount;
        if (mode == 1) amount = type(uint256).max;
        else if (mode == 2) amount = type(uint256).max - 1;
        else if (mode > 2) amount = bound(amountSeed, 0, SUPPLY);
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), 0);
    }

    /// @dev Uses approvals left by earlier actions, so revocation, reuse and exhaustion interact.
    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 limit = _min(expectedBalance[owner], expectedAllowance[owner][spender]);
        _transferFrom(owner, spender, _actor(toSeed), _edgeAmount(amountSeed, limit));
    }

    /// @dev Retains the entire uint256 amount domain, alongside the successful bounded actions.
    /// Expected failures are checked, rather than silently discarded by the invariant runner.
    function transferFromUnbounded(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];

        if (amount > allowance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount)
            );
        } else if (amount > balance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
            );
        } else {
            _transferFrom(owner, spender, to, amount);
            return;
        }
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ++rejectedCalls;
    }

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 balance = expectedBalance[from];
        uint256 amount = bound(amountSeed, balance + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(_actor(toSeed), amount);
        ++rejectedCalls;
    }

    function invalidRecipient(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool delegated) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 limit = expectedBalance[owner];
        if (delegated) limit = _min(limit, expectedAllowance[owner][spender]);
        uint256 amount = _edgeAmount(amountSeed, limit);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        if (delegated) {
            vm.prank(spender);
            token.transferFrom(owner, address(0), amount);
        } else {
            vm.prank(owner);
            token.transfer(address(0), amount);
        }
        ++rejectedCalls;
    }

    function invalidSpender(uint256 ownerSeed, uint256 amount) external {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(_actor(ownerSeed));
        token.approve(address(0), amount);
        ++rejectedCalls;
    }

    function roundTrip(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 amount = _edgeAmount(amountSeed, expectedBalance[from]);
        _transfer(from, to, amount);
        _transfer(to, from, amount);
        assertEq(token.balanceOf(from), fromBefore, "round trip changed sender balance");
        assertEq(token.balanceOf(to), toBefore, "round trip changed recipient balance");
    }

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "valid transfer returned false");
        _recordTransfer(from, to, amount);
    }

    function _transferFrom(address owner, address spender, address to, uint256 amount) internal {
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "valid delegated transfer returned false");
        if (expectedAllowance[owner][spender] != type(uint256).max) {
            expectedAllowance[owner][spender] -= amount;
        }
        _recordTransfer(owner, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "valid approval returned false");
        expectedAllowance[owner][spender] = amount;
        ++approvals;
    }

    function _recordTransfer(address from, address to, uint256 amount) internal {
        if (from != to) {
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
        }
        ++successfulTransfers;
        if (amount > 0 && from != to) ++positiveTransfers;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    /// @dev Force zero, one base unit, the whole balance, and one below it into sequences.
    function _edgeAmount(uint256 seed, uint256 maximum) internal pure returns (uint256) {
        uint256 mode = seed % 5;
        if (mode == 0) return 0;
        if (mode == 1) return maximum == 0 ? 0 : 1;
        if (mode == 2) return maximum;
        if (mode == 3) return maximum == 0 ? 0 : maximum - 1;
        return bound(seed, 0, maximum);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
