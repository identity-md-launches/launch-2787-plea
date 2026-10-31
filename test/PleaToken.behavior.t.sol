// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PleaToken} from "src/PleaToken.sol";

/// @dev Exercises a real contract deployer, including CREATE2, without launch infrastructure.
contract PleaDeploymentProbe {
    function deploy(bytes32 salt) external returns (PleaToken) {
        return new PleaToken{salt: salt}();
    }

    function forward(PleaToken token, address recipient, uint256 amount) external returns (bool) {
        return token.transfer(recipient, amount);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract PleaTokenBehaviorTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    PleaToken internal token;
    address internal deployer = makeAddr("plea deployer");
    address internal alice = makeAddr("plea alice");
    address internal bob = makeAddr("plea bob");
    address internal spender = makeAddr("plea spender");

    function setUp() public {
        vm.prank(deployer);
        token = new PleaToken();
    }

    function test_constructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        vm.prank(alice);
        PleaToken fresh = new PleaToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.balanceOf(deployer), 0);
        assertEq(fresh.balanceOf(address(fresh)), 0);
    }

    function test_contractDeploymentMintsToDirectCallerNotOrigin() public {
        PleaDeploymentProbe factory = new PleaDeploymentProbe();
        vm.prank(alice, bob);
        PleaToken fresh = factory.deploy(keccak256("plea constructor test"));

        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(address(factory)), SUPPLY);
        assertEq(fresh.balanceOf(alice), 0);
        assertEq(fresh.balanceOf(bob), 0);
        assertEq(fresh.balanceOf(address(this)), 0);
        assertEq(fresh.balanceOf(address(fresh)), 0);

        // A contract holding the constructor allocation can forward it without any fee.
        assertTrue(factory.forward(fresh, alice, SUPPLY));
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.balanceOf(address(factory)), 0);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_initialBalancesAndAllowancesAreEmpty() public view {
        address[6] memory accounts = [deployer, alice, bob, spender, address(token), address(0)];
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(token.balanceOf(accounts[i]), i == 0 ? SUPPLY : 0);
            for (uint256 j; j < accounts.length; ++j) {
                assertEq(token.allowance(accounts[i], accounts[j]), 0);
            }
        }
    }

    function test_zeroTransferFromEmptyAccountEmitsEvent() public {
        _expectTransfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function test_transferOneBaseUnitArrivesExactly() public {
        _expectTransfer(deployer, alice, 1);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1));
        _assertBalances(SUPPLY - 1, 1, 0, 0);
    }

    function test_entireSupplyCanMoveAndReturn() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        _assertBalances(0, SUPPLY, 0, 0);
        vm.prank(alice);
        assertTrue(token.transfer(deployer, SUPPLY));
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function test_fullBalanceSelfTransferEmitsEventWithoutChangingBalanceOrAllowance() public {
        _approve(deployer, spender, 17);
        _expectTransfer(deployer, deployer, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        _assertBalances(SUPPLY, 0, 0, 0);
        assertEq(token.allowance(deployer, spender), 17);
    }

    function test_RevertWhen_emptyAccountTransfersOneBaseUnit() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function test_RevertWhen_transferMaximumUint256() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        vm.prank(deployer);
        token.transfer(alice, type(uint256).max);
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function test_RevertWhen_zeroTransferTargetsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 0);
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function test_approvalWithoutBalanceCanBeOverwrittenRepeatedAndRevoked() public {
        uint256[4] memory amounts = [type(uint256).max, uint256(17), uint256(0), uint256(0)];
        for (uint256 i; i < amounts.length; ++i) {
            vm.expectEmit(true, true, false, true, address(token));
            emit IERC20.Approval(alice, spender, amounts[i]);
            _approve(alice, spender, amounts[i]);
            assertEq(token.allowance(alice, spender), amounts[i]);
            _assertBalances(SUPPLY, 0, 0, 0);
        }
    }

    function test_allowancesAreIsolatedByOwnerAndSpender() public {
        _approve(deployer, spender, 11);
        _approve(deployer, bob, 22);
        _approve(alice, spender, 33);
        _approve(spender, deployer, 44);
        _approve(deployer, spender, 7);
        assertEq(token.allowance(deployer, spender), 7);
        assertEq(token.allowance(deployer, bob), 22);
        assertEq(token.allowance(alice, spender), 33);
        assertEq(token.allowance(spender, deployer), 44);
        assertEq(token.allowance(alice, bob), 0);
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function test_spendingExactAllowanceThenRepeatingReverts() public {
        _approve(deployer, spender, 7);
        _expectTransfer(deployer, alice, 7);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 7));
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY - 7, 7, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
        _assertBalances(SUPPLY - 7, 7, 0, 0);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_revocationBlocksPreviouslyAuthorizedSpender() public {
        _approve(deployer, spender, SUPPLY);
        _approve(deployer, spender, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, spender, 1);
        _assertBalances(SUPPLY, 0, 0, 0);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_directTransferDoesNotConsumeAllowance() public {
        _approve(deployer, spender, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.allowance(deployer, spender), SUPPLY);
        _assertBalances(0, SUPPLY, 0, 0);
    }

    function test_zeroTransferFromWithoutApprovalOrBalanceEmitsEvent() public {
        _expectTransfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function test_transferFromCanSpendTheEntireSupply() public {
        _approve(deployer, spender, SUPPLY);
        _expectTransfer(deployer, bob, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, SUPPLY));
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(0, 0, SUPPLY, 0);
    }

    function test_selfTransferFromConsumesFiniteAllowanceButKeepsBalance() public {
        _approve(deployer, spender, SUPPLY);
        _expectTransfer(deployer, deployer, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, SUPPLY));
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function test_transferFromCanCreditTheSpender() public {
        _approve(deployer, spender, 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, spender, 1));
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY - 1, 0, 0, 1);
    }

    function test_RevertWhen_ownerUsesTransferFromWithoutSelfApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(deployer, alice, 1);
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function test_transferFromWithOwnerSpenderAndRecipientAllEqual() public {
        _approve(deployer, deployer, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transferFrom(deployer, deployer, SUPPLY));
        assertEq(token.allowance(deployer, deployer), 0);
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function test_infiniteApprovalSurvivesRepeatedSpendsAndCanBeRevoked() public {
        _approve(deployer, spender, type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertTrue(token.transferFrom(deployer, bob, SUPPLY - 1));
        vm.stopPrank();
        _assertBalances(0, 1, SUPPLY - 1, 0);
        assertEq(token.allowance(deployer, spender), type(uint256).max);

        vm.prank(bob);
        assertTrue(token.transfer(deployer, 1));
        _approve(deployer, spender, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, alice, 1);
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(1, 1, SUPPLY - 2, 0);
    }

    function test_maximumFiniteAllowanceIsDecremented() public {
        _approve(deployer, spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, spender), type(uint256).max - 2);
        _assertBalances(SUPPLY - 1, 1, 0, 0);
    }

    function test_RevertWhen_transferFromExceedsBalancePreservesFiniteAndInfiniteApproval() public {
        _fundAlice(10);
        uint256[2] memory approvals = [uint256(20), type(uint256).max];
        for (uint256 i; i < approvals.length; ++i) {
            _approve(alice, spender, approvals[i]);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10, 11));
            vm.prank(spender);
            token.transferFrom(alice, bob, 11);
            assertEq(token.allowance(alice, spender), approvals[i]);
            _assertBalances(SUPPLY - 10, 10, 0, 0);
        }
    }

    function test_RevertWhen_transferFromZeroReceiverPreservesApprovalIncludingZeroAmount() public {
        _approve(deployer, spender, 2);
        for (uint256 amount; amount <= 1; ++amount) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(spender);
            token.transferFrom(deployer, address(0), amount);
            assertEq(token.allowance(deployer, spender), 2);
            _assertBalances(SUPPLY, 0, 0, 0);
        }
    }

    function test_RevertWhen_transferFromZeroAddressCannotMint() public {
        // Rejection is required; allowance validation may precede sender validation.
        for (uint256 amount; amount <= 1; ++amount) {
            vm.expectRevert();
            vm.prank(spender);
            token.transferFrom(address(0), alice, amount);
            assertEq(token.allowance(address(0), spender), 0);
            _assertBalances(SUPPLY, 0, 0, 0);
        }
    }

    function test_deployerCannotSpendAnotherHoldersTokensWithoutPermission() public {
        _fundAlice(100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1);
        _assertBalances(SUPPLY - 100, 100, 0, 0);
    }

    function test_approvingTheHolderDoesNotAuthorizeSpendingTheirTokens() public {
        _approve(spender, deployer, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, spender, 1);
        assertEq(token.allowance(spender, deployer), type(uint256).max);
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function test_noMintBurnOrAdministrativeEntryPointsForDeployerOrStranger() public {
        _fundAlice(100);
        bytes[14] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", spender, 1),
            abi.encodeWithSignature("mint(uint256)", 1),
            abi.encodeWithSignature("mint()"),
            abi.encodeWithSignature("burn(uint256)", 1),
            abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1),
            abi.encodeWithSignature("initialize(address)", spender),
            abi.encodeWithSignature("transferOwnership(address)", spender),
            abi.encodeWithSignature("setMinter(address)", spender),
            abi.encodeWithSignature("upgradeTo(address)", spender),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("blacklist(address)", alice),
            abi.encodeWithSignature("freeze(address)", alice),
            abi.encodeWithSignature("seize(address)", alice),
            abi.encodeWithSignature("setTransfersEnabled(bool)", false)
        ];
        address[2] memory callers = [deployer, spender];
        for (uint256 i; i < callers.length; ++i) {
            for (uint256 j; j < calls.length; ++j) {
                vm.prank(callers[i]);
                (bool success,) = address(token).call(calls[j]);
                assertFalse(success, "unexpected privileged entry point");
                _assertBalances(SUPPLY - 100, 100, 0, 0);
            }
        }
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100));
        _assertBalances(SUPPLY - 100, 0, 100, 0);
    }

    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        _assertBalances(SUPPLY - amount, amount, 0, 0);
        vm.prank(alice);
        assertTrue(token.transfer(deployer, amount));
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function testFuzz_splitTransfersEqualOneTransfer(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        vm.prank(deployer);
        PleaToken single = new PleaToken();
        vm.startPrank(deployer);
        assertTrue(single.transfer(alice, total));
        assertTrue(token.transfer(alice, first));
        assertTrue(token.transfer(alice, total - first));
        vm.stopPrank();
        assertEq(token.balanceOf(deployer), single.balanceOf(deployer));
        assertEq(token.balanceOf(alice), single.balanceOf(alice));
        _assertBalances(SUPPLY - total, total, 0, 0);
    }

    function testFuzz_selfTransferPreservesAnyFundedBalance(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, 0, balance);
        _fundAlice(balance);
        vm.prank(alice);
        assertTrue(token.transfer(alice, amount));
        _assertBalances(SUPPLY - balance, balance, 0, 0);
    }

    function testFuzz_finiteAllowanceIsACumulativeBudget(uint256 approval, uint256 first, uint256 second) public {
        approval = bound(approval, 0, SUPPLY);
        first = bound(first, 0, approval);
        second = bound(second, 0, approval - first);
        _approve(deployer, spender, approval);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(deployer, alice, first));
        assertTrue(token.transferFrom(deployer, bob, second));
        vm.stopPrank();
        uint256 remaining = approval - first - second;
        assertEq(token.allowance(deployer, spender), remaining);
        _assertBalances(SUPPLY - first - second, first, second, 0);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, remaining, remaining + 1)
        );
        vm.prank(spender);
        token.transferFrom(deployer, spender, remaining + 1);
        assertEq(token.allowance(deployer, spender), remaining);
        _assertBalances(SUPPLY - first - second, first, second, 0);
    }

    function testFuzz_approvalReplacesRatherThanAddsAndIsIdempotent(uint256 previous, uint256 replacement) public {
        _approve(deployer, spender, previous);
        _approve(deployer, spender, replacement);
        assertEq(token.allowance(deployer, spender), replacement);
        _approve(deployer, spender, replacement);
        assertEq(token.allowance(deployer, spender), replacement);
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function testFuzz_transferAboveBalanceIsAtomic(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, balance + 1, type(uint256).max);
        _fundAlice(balance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount));
        vm.prank(alice);
        token.transfer(bob, amount);
        _assertBalances(SUPPLY - balance, balance, 0, 0);
    }

    function testFuzz_transferFromAboveBalanceIsAtomic(uint256 balance, uint256 amount, bool infinite) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, balance + 1, type(uint256).max - 1);
        _fundAlice(balance);
        uint256 approval = infinite ? type(uint256).max : amount;
        _approve(alice, spender, approval);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), approval);
        _assertBalances(SUPPLY - balance, balance, 0, 0);
    }

    function testFuzz_transferFromAboveAllowanceIsAtomic(uint256 approval, uint256 amount) public {
        approval = bound(approval, 0, SUPPLY - 1);
        amount = bound(amount, approval + 1, SUPPLY);
        _approve(deployer, spender, approval);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approval, amount)
        );
        vm.prank(spender);
        token.transferFrom(deployer, alice, amount);
        assertEq(token.allowance(deployer, spender), approval);
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function testFuzz_zeroReceiverCannotBurnOrConsumeApproval(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        _approve(deployer, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(deployer, address(0), amount);
        assertEq(token.allowance(deployer, spender), amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), amount);
        _assertBalances(SUPPLY, 0, 0, 0);
    }

    function _fundAlice(uint256 amount) internal {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
    }

    function _approve(address owner, address delegate, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(delegate, amount));
    }

    function _expectTransfer(address from, address to, uint256 amount) internal {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(from, to, amount);
    }

    function _assertBalances(uint256 deployerBalance, uint256 aliceBalance, uint256 bobBalance, uint256 spenderBalance)
        internal
        view
    {
        assertEq(token.balanceOf(deployer), deployerBalance);
        assertEq(token.balanceOf(alice), aliceBalance);
        assertEq(token.balanceOf(bob), bobBalance);
        assertEq(token.balanceOf(spender), spenderBalance);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
