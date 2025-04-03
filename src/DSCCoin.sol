// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Decentralized Stable Coin
 * @author Ahmed Abusalama
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 * @notice This is the contract meant to be goverened by DSCEngine,
 * this contract is just the ERC20 implementation of our stablecoin system.
 *
 */
contract DSC is ERC20Burnable, Ownable {
    error DSC__MustBeMoreThanZero();
    error DSC__BurnAmountExeedsBalance();
    error DSC__NotZeroAddress();

    constructor() ERC20("DSC", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DSC__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DSC__BurnAmountExeedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DSC__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DSC__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
