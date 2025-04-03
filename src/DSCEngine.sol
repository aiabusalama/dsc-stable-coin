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

import {DSC} from "./DSCCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "src/libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Ahmed Abusalama
 * This system is designed to be as minimal as possiblem and must have the token maintain a 1 token == 1$ peg.
 * This stablecoin has the properties:
 *  - Exogenous Collateral (ETH & BTC)
 *  - Dollar Pegged
 *  - Algorithmically Stable
 * It is similar to DAI if AI had no governance, no fees, and was only backed by WETH & WBTC.
 * @notice Our DSC system shoudl always be "overcollateralized", At no point, should the value of all collateral <= the $ backed value of all the DSC.
 * @notice This contract is the core of the DSC System, it handles all the lgoic for mining and redeeming DSC, as well as depositing & withdrawal collaterals.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    // -------------------------------------
    // Errors
    // -------------------------------------
    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();


    // -------------------------------------
    // Type
    // -------------------------------------
    using OracleLib for AggregatorV3Interface;

    // -------------------------------------
    // State Variables
    // -------------------------------------

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% over collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // 1 is the minimum health factor
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_userCollaterals;
    mapping(address user => uint256 amountDscMinted) private s_userDscMinted;
    address[] private s_collateralTokens;

    DSC private immutable i_dsc;

    // -------------------------------------
    // Events
    // -------------------------------------
    event CollateralDeposited(address indexed user, address indexed tokenCollateral, uint256 amountCollateral);
    event CollateralRedeemed(
        address indexed from, address indexed to, address indexed tokenCollateral, uint256 amountCollateral
    );
    // -------------------------------------
    // Modifiers
    // -------------------------------------

    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _tokenAddress) {
        if (s_priceFeeds[_tokenAddress] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    // -------------------------------------
    // Functions
    // -------------------------------------
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // for example ETH / USD, BTC / USD, MKR / USD, etc.
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DSC(dscAddress);
    }

    // -------------------------------------
    // External Functions
    // -------------------------------------

    /**
     * Deposit collateral and mint DSC
     * @param tokenCollateralAddress represents the address of the token to deposit as collateral (ETH or WBTC)
     * @param amountCollateral represents the amount of the token to deposit as collateral
     * @param amountDscToMint represents the amount of DSC to mint
     *
     * @notice this function is a convenience function that allows the user to deposit collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Follows CEI pattern
     * @param tokenCollateralAddress The address of the token to deposit as collateral (ETH or WBTC)
     * @param amountCollateral The amount of the token to deposit as collateral
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        // Increase the user's collateral balance
        s_userCollaterals[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // in order to redeem collaterals:
    // 1. They must have more than the minimum health factor AFTER collateral is redeemed
    //
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * Redeem collateral and burn DSC
     * @param tokenCollateral the address of the token to redeem
     * @param amountCollateral the amount of the token to redeem
     * @param amountDscToBurn the amount of DSC to burn
     * @notice This function allows the user to redeem collateral and burn DSC in one transaction
     */
    function redeemCollateralsForDsc(address tokenCollateral, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateral, amountCollateral);
        // redeem collateral already checks helth factor
    }

    /**
     *
     * @param amountDscToMint The amount of DSC to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_userDscMinted[msg.sender] += amountDscToMint;
        // if they minted too much (150$ DSC, but they have 100$ ETH)
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) {
        // burn the DSC
        // redeem the collaterals!
        _burnDsc(msg.sender, msg.sender, amountDscToBurn);
        _revertIfHealthFactorIsBroken(msg.sender); // probably not needed, burning your debt should increase your health factor
    }

    // $75 backing 50 DSC
    // liquidator take $75 backing, and burns off the $50 DSC
    // If someone is almost under collateralized, we'll pay you to liquidate them!

    /**
     * Liquidate a user (pay off their debt and take their collateral)
     * @param collateral The address of the ERC20 collateral token to liquidate from the user
     * @param user The user who has broken the health factor, their health factor should be below minimum health factor
     * @param debtToCover The amount of DSC we want to burn to improve the users heath factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the user funds
     * @notice This function working assumes the protocol will be roughly 200% overcolleralized in order for this to work!
     * @notice A known bug is if the protocol is undercollateralized (100% or less), then we won't be able to incentivize liquidators
     * For example, if the price of the collateral plummeted before anyone could be liquidated
     */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) {
        // Check if the user is liquidatable!
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // We want to burn their DSC debt and take their collateral
        // 140$ ETH and 100$ DSC
        // debtToCover = 100$
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus!
        // So we're giving the liquidator a 110$ worth of ETH for 100 DSC (10% bonus)
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amount into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToTake = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToTake);
        // we need to burn the DSC
        _burnDsc(user, msg.sender, debtToCover);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender); // If the caller healthfactor is broken, revert!
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    // -------------------------------------
    // Private / Internal View Functions
    // -------------------------------------

    /**
     * Burn DSC (Internal)
     * @dev low level internal function, do not call unless the function calling it is checking for health factors being broken!
     * @param amountDscToBurn The amount of DSC to burn
     * @param onBehalfOf The user who is burning the DSC
     * @param dscFrom The address of the DSC token
     */
    function _burnDsc(address onBehalfOf, address dscFrom, uint256 amountDscToBurn) private {
        // burn the DSC
        // redeem the collaterals!
        s_userDscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        internal
    {
        s_userCollaterals[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_userDscMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If the user goes below 1, then they can get liquidated
     * @param user The address of the user
     */
    function _healthFactor(address user) private view returns (uint256) {
        // 1. Total DSC minted
        // 2. Total Collateral value
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);

        // Return max uint256 if no DSC minted (infinite health factor)
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }

        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    // 1. Check health factor (do they have enough collaterals?)
    // 2. Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    // -------------------------------------
    // Public & External View Functions
    // -------------------------------------
    function getTokenAmountFromUsd(address token, uint256 amountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((amountInWei * PRECISION)) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // Loop through each collateral token they have, get the amount they've deposited, and map it
        // to the price feed to get the USD value of that token4
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_userCollaterals[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        // get the price of the token
        // multiply the amount by the price
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1ETH = $1000
        // The returned value from CL will be 1000 * 10e8 (ETH has 8 decimals)
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user) external view returns (uint256, uint256) {
        return _getAccountInformation(user);
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_userCollaterals[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getDsc() external view returns (DSC) {
        return i_dsc;
    }
}
