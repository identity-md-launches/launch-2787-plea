// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title plea (PLEA)
/// @notice Fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the deployer.
/// @dev No owner, no further minting, no pause, no blacklist, no transfer fee.
contract PleaToken is ERC20 {
    /// @notice 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("plea", "PLEA") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
