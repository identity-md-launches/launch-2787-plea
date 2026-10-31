// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PleaToken} from "src/PleaToken.sol";
import {PleaTokenHandler} from "test/handlers/PleaTokenHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract PleaTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    PleaToken internal token;
    PleaTokenHandler internal handler;
    address[5] internal actors;

    function setUp() public {
        actors = [
            makeAddr("sequence deployer"),
            makeAddr("sequence alice"),
            makeAddr("sequence bob"),
            makeAddr("sequence carol"),
            makeAddr("sequence dave")
        ];
        vm.prank(actors[0]);
        token = new PleaToken();
        assertEq(token.balanceOf(actors[0]), SUPPLY);
        vm.startPrank(actors[0]);
        for (uint256 i = 1; i < actors.length; ++i) {
            assertTrue(token.transfer(actors[i], SUPPLY / actors.length));
        }
        vm.stopPrank();
        handler = new PleaTokenHandler(token, actors);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.revoke.selector;
        selectors[3] = handler.transferFrom.selector;
        selectors[4] = handler.transferFromUnbounded.selector;
        selectors[5] = handler.transferTooMuch.selector;
        selectors[6] = handler.invalidRecipient.selector;
        selectors[7] = handler.invalidSpender.selector;
        selectors[8] = handler.roundTrip.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        invariant_supplyIsFixedAndFullyAccountedFor();
        invariant_balancesMatchAuthorizedTransfers();
        invariant_allowancesMatchApprovalsAndSpending();
    }

    function invariant_supplyIsFixedAndFullyAccountedFor() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(token.totalSupply(), SUPPLY, "fixed supply changed");
        assertEq(sum, SUPPLY, "tokens created, destroyed or leaked outside the actor set");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function invariant_balancesMatchAuthorizedTransfers() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.expectedBalance(actors[i]), "unexpected balance change");
        }
    }

    function invariant_allowancesMatchApprovalsAndSpending() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.expectedAllowance(actors[i], actors[j]),
                    "approval replacement, spending or revert rollback was incorrect"
                );
            }
            assertEq(token.allowance(actors[i], address(0)), 0);
            assertEq(token.allowance(address(0), actors[i]), 0);
        }
    }

    function invariant_metadataNeverChanges() public view {
        assertEq(token.name(), "plea");
        assertEq(token.symbol(), "PLEA");
        assertEq(token.decimals(), 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// @dev Every holder can still transfer their entire balance after a random sequence.
    function afterInvariant() public {
        for (uint256 i = 1; i < actors.length; ++i) {
            handler.transfer(i, 0, 2); // The handler's mode 2 selects the full balance.
        }
        assertEq(token.balanceOf(actors[0]), SUPPLY, "holders could not recover the full allocation");
        invariant_supplyIsFixedAndFullyAccountedFor();
        invariant_balancesMatchAuthorizedTransfers();
        invariant_allowancesMatchApprovalsAndSpending();
    }

    /// @dev Pins a meaningful sequence to guard against a vacuous or incorrectly wired handler.
    function test_handlerExercisesPositiveSpendsRevocationAndExpectedFailures() public {
        handler.approve(0, 1, 1); // Infinite approval.
        handler.transferFrom(0, 1, 2, 1); // One base unit.
        assertEq(token.allowance(actors[0], actors[1]), type(uint256).max);
        handler.revoke(0, 1);
        handler.transferFromUnbounded(0, 1, 2, 1); // Revoked approval must reject.
        handler.approve(2, 3, 4); // Finite approval of four units.
        handler.transferFrom(2, 3, 4, 2); // Exhaust that approval.
        assertEq(token.allowance(actors[2], actors[3]), 0);
        handler.transferFromUnbounded(2, 3, 4, 1);
        handler.transferTooMuch(1, 2, type(uint256).max);
        handler.invalidRecipient(0, 1, 1, false);
        handler.approve(0, 1, 4);
        handler.invalidRecipient(0, 1, 1, true); // Reverted spend preserves finite approval.
        handler.invalidSpender(0, type(uint256).max);
        handler.roundTrip(4, 0, 2);
        handler.transfer(0, 0, 2); // Full self-transfer.

        assertGt(handler.positiveTransfers(), 0);
        assertGt(handler.successfulTransfers(), 0);
        assertEq(handler.approvals(), 4);
        assertEq(handler.rejectedCalls(), 6);
        invariant_supplyIsFixedAndFullyAccountedFor();
        invariant_balancesMatchAuthorizedTransfers();
        invariant_allowancesMatchApprovalsAndSpending();
        invariant_metadataNeverChanges();
        afterInvariant();
    }
}
