// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DSC} from "src/DSCCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DSC dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    address wbtc;
    address public USER = makeAddr("USER");
    uint256 private constant PRECISION = 1e18;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% over collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators

    event CollateralDeposited(address indexed user, address indexed tokenCollateral, uint256 amountCollateral);
    event CollateralRedeemed(
        address indexed from, address indexed to, address indexed tokenCollateral, uint256 amountCollateral
    );

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    function testDSCOwnerIsEngine() public view {
        assertEq(dsc.owner(), address(engine));
    }
    // -------------------------------------
    // Constructor Tests
    // -------------------------------------

    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }
    // -------------------------------------
    // Price Tests
    // -------------------------------------

    function testGetEthUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000$ = 30000e18 (15ETH * 2000$ = 30,000$)
        uint256 expectedUsdValue = 30000e18;
        uint256 actualUsdValue = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsdValue, actualUsdValue);
    }

    function testGetBtcUsdValue() public view {
        uint256 btcAmount = 15e18;
        // 15e18 * 1000$ = 15000e18 (15BTC * 1000$ = 15,000$)
        uint256 expectedUsdValue = 15000e18;
        uint256 actualUsdValue = engine.getUsdValue(wbtc, btcAmount);
        assertEq(expectedUsdValue, actualUsdValue);
    }

    function testGetTokenAmountFromUsdReturnsCorrectAmount() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeiAmount = 0.05 ether;
        uint256 actualWeiAmount = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeiAmount, actualWeiAmount);
    }

    function testGetTokenAmountFromUsdRevertsOnZeroPrice() public {
        // Arrange - mock price feed returning 0
        vm.mockCall(
            ethUsdPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, 0, 0, 0, 0) // $0 price
        );
        // Act/Assert
        vm.expectRevert(); // Division by zero
        engine.getTokenAmountFromUsd(weth, 100e18);
    }

    function testGetTokenAmountFromUsdRevertsOnNegativePrice() public {
        // Arrange - mock negative price
        vm.mockCall(
            ethUsdPriceFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, -2000e8, 0, 0, 0) // -$2000
        );
        // Act/Assert
        vm.expectRevert(); // Underflow when converting to uint256
        engine.getTokenAmountFromUsd(weth, 100e18);
    }

    // -------------------------------------
    // Deposit Collateral Tests
    // -------------------------------------

    function testDepositCollateralRevertsWithZeroAmount() public {
        vm.prank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testDepositCollateralRevertsWithUnapprovedToken() public {
        ERC20Mock aToken = new ERC20Mock();
        aToken.mint(address(this), AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(aToken), AMOUNT_COLLATERAL);
    }

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testDepositCollateralSucceedsWithApprovedToken() public depositCollateral {
        (uint256 totalDscMinted, uint256 totalCollateralInUsd) = engine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, totalCollateralInUsd);

        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
        assertEq(expectedTotalDscMinted, totalDscMinted);
    }

    function testDepositCollateralUpdatesAccountInformation() public {
        // Setup
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        // Get initial state
        (uint256 initialDscMinted, uint256 initialCollateralValue) = engine.getAccountInformation(USER);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        // Verify state changes
        (uint256 finalDscMinted, uint256 finalCollateralValue) = engine.getAccountInformation(USER);

        assertEq(finalDscMinted, initialDscMinted); // Should remain 0 (as we didn't mint any DSC yet)
        assertEq(finalCollateralValue, initialCollateralValue + engine.getUsdValue(weth, AMOUNT_COLLATERAL));

        // Additional token transfer verification
        assertEq(ERC20Mock(weth).balanceOf(USER), STARTING_ERC20_BALANCE - AMOUNT_COLLATERAL);
        assertEq(ERC20Mock(weth).balanceOf(address(engine)), AMOUNT_COLLATERAL);
    }

    // // 13: Test deposit emits event (unchanged)
    function testDepositCollateralEmitsEventCorrectly() public {
        // Setup
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        // Start recording logs
        vm.recordLogs();

        // Perform deposit
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        // Get recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify exactly one event was emitted
        assertEq(logs.length, 2, "Should emit exactly one event");

        // Verify event signature
        bytes32 expectedEventSig = keccak256("CollateralDeposited(address,address,uint256)");
        assertEq(logs[0].topics[0], expectedEventSig, "Event signature mismatch");

        // Verify indexed parameters (USER and weth)
        assertEq(address(uint160(uint256(logs[0].topics[1]))), USER, "User address mismatch");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), weth, "Token address mismatch");

        // Verify non-indexed parameter (amountCollateral)
        assertEq(abi.decode(logs[0].data, (uint256)), AMOUNT_COLLATERAL, "Amount mismatch");
    }

    function testDepositCollateralAndMintDscWorksEndToEnd() public {
        // Setup
        uint256 dscToMint = 500e18; // $500 DSC (assuming ETH price is $2000)
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        // Pre-action balances
        uint256 initialWethBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 initialDscBalance = dsc.balanceOf(USER);

        // Execute
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, dscToMint);
        vm.stopPrank();

        // Verify
        (uint256 totalDscMinted, uint256 totalCollateralValue) = engine.getAccountInformation(USER);

        // Check token balances
        assertEq(ERC20Mock(weth).balanceOf(USER), initialWethBalance - AMOUNT_COLLATERAL);
        assertEq(ERC20Mock(weth).balanceOf(address(engine)), AMOUNT_COLLATERAL);
        assertEq(dsc.balanceOf(USER), initialDscBalance + dscToMint);

        // Check engine state
        assertEq(totalDscMinted, dscToMint);
        assertEq(totalCollateralValue, engine.getUsdValue(weth, AMOUNT_COLLATERAL));

        // Verify health factor is valid
        uint256 healthFactor = engine.getHealthFactor(USER);
        assertGt(healthFactor, MIN_HEALTH_FACTOR, "Health factor too low");
    }

    // Test getHealthFactor returns max for no debt
    function testGetHealthFactorReturnsMaxForNoDebt() public depositCollateral {
        // Should return type(uint256).max when no DSC minted
        uint256 healthFactor = engine.getHealthFactor(USER);
        console.log(healthFactor);
        console.log(healthFactor);
        console.log(healthFactor);
        assertEq(healthFactor, type(uint256).max);
    }

    // Test getHealthFactor returns low when undercollateralized
    function testGetHealthFactorReturnsLowWhenUndercollateralized() public {
        // Create undercollateralized position
        uint256 collateralAmount = 1 ether; // $2000 worth
        uint256 dscToMint = 2000e18; // $2000 DSC (100% collateralization)
        uint256 expectedHealthFactor = 0.5e18;
        ERC20Mock(weth).mint(USER, collateralAmount);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), collateralAmount);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.depositCollateralAndMintDsc(weth, collateralAmount, dscToMint);
        vm.stopPrank();
    }

    function testMintDscRevertsWithZeroAmount() public depositCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testMintDscRevertsIfHealthFactorBroken() public depositCollateral {
        // Deposit some collateral first (done by depositCollateral modifier)
        // Calculate how much DSC would break health factor
        uint256 collateralValue = engine.getAccountCollateralValue(USER);
        // Calculate DSC amount that would bring health factor below minimum
        uint256 breakingDscAmount = (collateralValue * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION + 1;

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                (collateralValue * LIQUIDATION_THRESHOLD * PRECISION) / (breakingDscAmount * LIQUIDATION_PRECISION)
            )
        );
        engine.mintDsc(breakingDscAmount);
        vm.stopPrank();
    }

    function testMintDscSucceedsWithSufficientCollateral() public depositCollateral {
        // Calculate safe amount to mint (well below collateral limit)
        uint256 collateralValue = engine.getAccountCollateralValue(USER);
        uint256 safeDscToMint = (collateralValue * LIQUIDATION_THRESHOLD) / (LIQUIDATION_PRECISION * 2); // Only use half of available capacity

        vm.startPrank(USER);
        engine.mintDsc(safeDscToMint);
        vm.stopPrank();

        // Verify
        (uint256 totalDscMinted,) = engine.getAccountInformation(USER);
        assertEq(totalDscMinted, safeDscToMint);
        assertGt(engine.getHealthFactor(USER), MIN_HEALTH_FACTOR);
    }

    function testMintDscUpdatesMintedAmountCorrectly() public depositCollateral {
        (uint256 initialMintedAmount,) = engine.getAccountInformation(USER);

        uint256 mintAmount = 100e18; // $100 DSC

        vm.startPrank(USER);
        engine.mintDsc(mintAmount);
        vm.stopPrank();

        // Check the minted amount was updated correctly
        (uint256 newMintedAmount,) = engine.getAccountInformation(USER);
        assertEq(newMintedAmount, initialMintedAmount + mintAmount);

        // Verify the DSC token balance was updated
        assertEq(dsc.balanceOf(USER), mintAmount);
    }

    function testRedeemCollateralRevertsWithZeroAmount() public depositCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRedeemCollateralRevertsIfHealthFactorBroken() public depositCollateral {
        // First mint some DSC against collateral
        uint256 dscToMint = 500e18; // $500 DSC
        vm.startPrank(USER);
        engine.mintDsc(dscToMint);

        // Get current account information
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = engine.getAccountInformation(USER);

        // Calculate expected health factor after redemption
        uint256 remainingCollateralValue = totalCollateralValueInUsd - engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 expectedHealthFactor =
            (remainingCollateralValue * LIQUIDATION_THRESHOLD * PRECISION) / (totalDscMinted * LIQUIDATION_PRECISION);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRedeemCollateralSucceedsWithSufficientCollateral() public depositCollateral {
        uint256 redeemAmount = AMOUNT_COLLATERAL / 2;
        uint256 initialBalance = ERC20Mock(weth).balanceOf(USER);

        vm.startPrank(USER);
        engine.redeemCollateral(weth, redeemAmount);
        vm.stopPrank();

        assertEq(ERC20Mock(weth).balanceOf(USER), initialBalance + redeemAmount);
        assertEq(engine.getAccountCollateralValue(USER), engine.getUsdValue(weth, AMOUNT_COLLATERAL - redeemAmount));
    }

    function testRedeemCollateralUpdatesBalancesCorrectly() public depositCollateral {
        // Get initial balances
        uint256 initialEngineBalance = ERC20Mock(weth).balanceOf(address(engine));
        uint256 initialUserBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 redeemAmount = 1 ether;

        // Get initial collateral value from engine
        (, uint256 initialCollateralValue) = engine.getAccountInformation(USER);

        vm.startPrank(USER);
        engine.redeemCollateral(weth, redeemAmount);
        vm.stopPrank();

        // Check token balances
        assertEq(ERC20Mock(weth).balanceOf(address(engine)), initialEngineBalance - redeemAmount);
        assertEq(ERC20Mock(weth).balanceOf(USER), initialUserBalance + redeemAmount);

        // Check engine's collateral tracking using getAccountInformation
        (, uint256 newCollateralValue) = engine.getAccountInformation(USER);
        uint256 expectedValueReduction = engine.getUsdValue(weth, redeemAmount);
        assertEq(newCollateralValue, initialCollateralValue - expectedValueReduction);
    }

    function testRedeemCollateralEmitsEvent() public depositCollateral {
        vm.startPrank(USER);
        vm.expectEmit(true, true, true, true);
        emit CollateralRedeemed(USER, USER, weth, 1 ether);
        engine.redeemCollateral(weth, 1 ether);
        vm.stopPrank();
    }

    function testRedeemCollateralsForDscWorksEndToEnd() public depositCollateral {
        // First mint some DSC
        uint256 dscToMint = 500e18;
        vm.startPrank(USER);
        engine.mintDsc(dscToMint);

        // Now redeem collateral for DSC
        uint256 collateralToRedeem = 1 ether;
        uint256 dscToBurn = 100e18;

        // Approve the engine to burn DSC on user's behalf
        dsc.approve(address(engine), dscToBurn);

        (, uint256 initialCollateral) = engine.getAccountInformation(USER);
        uint256 initialDscBalance = dsc.balanceOf(USER);

        engine.redeemCollateralsForDsc(weth, collateralToRedeem, dscToBurn);
        (, uint256 finalCollateral) = engine.getAccountInformation(USER);
        vm.stopPrank();

        assertEq(finalCollateral, initialCollateral - engine.getUsdValue(weth, collateralToRedeem));
        assertEq(dsc.balanceOf(USER), initialDscBalance - dscToBurn);
        assertGt(engine.getHealthFactor(USER), MIN_HEALTH_FACTOR);
    }

    function testBurnDscRevertsWithZeroAmount() public depositCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    function testBurnDscSucceedsAndUpdatesBalances() public depositCollateral {
        // First mint some DSC
        uint256 dscToMint = 500e18;
        vm.startPrank(USER);
        engine.mintDsc(dscToMint);

        // Approve engine to burn DSC
        dsc.approve(address(engine), dscToMint);

        uint256 amountToBurn = 100e18;
        uint256 initialDscBalance = dsc.balanceOf(USER);
        (uint256 initialMintedAmount,) = engine.getAccountInformation(USER);

        engine.burnDsc(amountToBurn);

        // Check balances
        assertEq(dsc.balanceOf(USER), initialDscBalance - amountToBurn);
        (uint256 newMintedAmount,) = engine.getAccountInformation(USER);
        assertEq(newMintedAmount, initialMintedAmount - amountToBurn);
        vm.stopPrank();
    }

    function testBurnDscImprovesHealthFactor() public depositCollateral {
        // First mint some DSC to create debt
        uint256 dscToMint = 500e18;
        vm.startPrank(USER);
        engine.mintDsc(dscToMint);

        // Approve engine to burn DSC
        dsc.approve(address(engine), dscToMint);

        uint256 initialHealthFactor = engine.getHealthFactor(USER);
        uint256 amountToBurn = 100e18;

        engine.burnDsc(amountToBurn);

        uint256 newHealthFactor = engine.getHealthFactor(USER);
        assertGt(newHealthFactor, initialHealthFactor);
        vm.stopPrank();
    }

    function testLiquidateRevertsIfHealthFactorOk() public depositCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth, USER, 100e18);
        vm.stopPrank();
    }
    // function testLiquidateSucceedsWhenUndercollateralized() public {
    //     // Setup accounts
    //     address liquidator = makeAddr("liquidator");
    //     ERC20Mock(weth).mint(liquidator, 10e18);

    //     // Liquidator prepares by getting some DSC
    //     vm.startPrank(liquidator);
    //     ERC20Mock(weth).approve(address(engine), 10e18);
    //     engine.depositCollateral(weth, 5e18);
    //     engine.mintDsc(2500e18); // $2500 DSC
    //     vm.stopPrank();

    //     // User creates a healthy position
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(engine), 10e18);
    //     engine.depositCollateral(weth, 1e18); // $2000 worth at $2000/ETH
    //     engine.mintDsc(1000e18); // $1000 DSC (health factor = 2.0)
    //     vm.stopPrank();

    //     // Price feed data for mock
    //     uint80 roundId = 1;
    //     int256 crashedPrice = 1000e8; // $1000/ETH
    //     uint256 timestamp = block.timestamp;
    //     uint80 answeredInRound = 1;

    //     // Mock price feed to return crashed price
    //     vm.mockCall(
    //         ethUsdPriceFeed,
    //         abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
    //         abi.encode(roundId, crashedPrice, 0, timestamp, answeredInRound)
    //     );

    //     // Verify position is now undercollateralized (1 ETH @ $1000 = $1000 collateral vs $1000 debt)
    //     uint256 userHealthFactor = engine.getHealthFactor(USER);
    //     assertLt(userHealthFactor, MIN_HEALTH_FACTOR, "User should be undercollateralized after price drop");

    //     // Liquidator needs to know token amount from USD - mock this call too
    //     vm.mockCall(
    //         ethUsdPriceFeed,
    //         abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
    //         abi.encode(roundId, crashedPrice, 0, timestamp, answeredInRound)
    //     );

    //     // Execute liquidation of $500 debt (0.5 ETH worth at $1000/ETH)
    //     vm.startPrank(liquidator);
    //     dsc.approve(address(engine), 500e18);

    //     // Mock price feed during liquidation
    //     vm.mockCall(
    //         ethUsdPriceFeed,
    //         abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
    //         abi.encode(roundId, crashedPrice, 0, timestamp, answeredInRound)
    //     );

    //     engine.liquidate(weth, USER, 500e18);
    //     vm.stopPrank();

    //     // Mock price feed for final health check
    //     vm.mockCall(
    //         ethUsdPriceFeed,
    //         abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
    //         abi.encode(roundId, crashedPrice, 0, timestamp, answeredInRound)
    //     );

    //     // Verify health factor improved
    //     uint256 newHealthFactor = engine.getHealthFactor(USER);
    //     assertGt(newHealthFactor, userHealthFactor, "Health factor should improve after liquidation");
    //     assertGt(newHealthFactor, MIN_HEALTH_FACTOR, "Health factor should be above minimum");
    // }
    // function testLiquidateCalculatesBonusCorrectly() public {
    //     // Setup
    //     address liquidator = makeAddr("liquidator");
    //     ERC20Mock(weth).mint(liquidator, 1000e18);

    //     vm.startPrank(USER);
    //     engine.depositCollateral(weth, 10e18);
    //     engine.mintDsc(5000e18); // Undercollateralized
    //     vm.stopPrank();

    //     uint256 debtToCover = 1000e18;
    //     uint256 expectedBonus = (debtToCover * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

    //     vm.startPrank(liquidator);
    //     dsc.approve(address(engine), debtToCover);
    //     engine.liquidate(weth, USER, debtToCover);

    //     uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
    //     assertEq(liquidatorWethBalance, expectedBonus);
    //     vm.stopPrank();
    // }
    // function testLiquidateRevertsIfBonusExceedsCollateral() public {
    //     address liquidator = makeAddr("liquidator");
    //     ERC20Mock(weth).mint(liquidator, 1000e18);

    //     vm.startPrank(USER);
    //     engine.depositCollateral(weth, 1e18); // Small collateral
    //     engine.mintDsc(5000e18); // Large debt
    //     vm.stopPrank();

    //     vm.startPrank(liquidator);
    //     dsc.approve(address(engine), 5000e18);
    //     vm.expectRevert(); // Should revert due to insufficient collateral
    //     engine.liquidate(weth, USER, 5000e18);
    //     vm.stopPrank();
    // }
    // function testLiquidateImprovesTargetHealthFactor() public {
    //     address liquidator = makeAddr("liquidator");
    //     ERC20Mock(weth).mint(liquidator, 1000e18);

    //     vm.startPrank(USER);
    //     engine.depositCollateral(weth, 10e18);
    //     engine.mintDsc(5000e18); // Undercollateralized
    //     uint256 initialHealthFactor = engine.getHealthFactor(USER);
    //     vm.stopPrank();

    //     vm.startPrank(liquidator);
    //     dsc.approve(address(engine), 1000e18);
    //     engine.liquidate(weth, USER, 1000e18);

    //     uint256 newHealthFactor = engine.getHealthFactor(USER);
    //     assertGt(newHealthFactor, initialHealthFactor);
    //     vm.stopPrank();
    // }
    // function testLiquidateDoesntWorsenLiquidatorsHealth() public {
    //     address liquidator = makeAddr("liquidator");
    //     ERC20Mock(weth).mint(liquidator, 1000e18);

    //     // Setup liquidator position
    //     vm.startPrank(liquidator);
    //     engine.depositCollateral(weth, 5e18);
    //     engine.mintDsc(2000e18);
    //     uint256 initialLiquidatorHealth = engine.getHealthFactor(liquidator);
    //     vm.stopPrank();

    //     // Setup undercollateralized user
    //     vm.startPrank(USER);
    //     engine.depositCollateral(weth, 10e18);
    //     engine.mintDsc(5000e18);
    //     vm.stopPrank();

    //     vm.startPrank(liquidator);
    //     dsc.approve(address(engine), 1000e18);
    //     engine.liquidate(weth, USER, 1000e18);

    //     uint256 finalLiquidatorHealth = engine.getHealthFactor(liquidator);
    //     assertGe(finalLiquidatorHealth, initialLiquidatorHealth);
    //     vm.stopPrank();
    // }
}
