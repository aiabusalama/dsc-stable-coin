// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DSC} from "src/DSCCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {console} from "forge-std/console.sol";
import {Handler} from "test/fuzz/Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSC dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        Handler handler = new Handler(engine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // get value of all collateral in the protocl
        // compare it to all the debt (dsc)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = ERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = ERC20(wbtc).balanceOf(address(engine));
        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);
        console.log("Total Supply: ", totalSupply);
        console.log("Total Value: ", wethValue + wbtcValue);

        assert(wethValue + wbtcValue >= totalSupply);
    }
    // function invariant_gettersCantRevert() public view {
    //     engine.getAdditionalFeedPrecision();
    //     engine.getCollateralTokens();
    //     engine.getLiquidationBonus();
    //     engine.getLiquidationThreshold();
    //     engine.getMinHealthFactor();
    //     engine.getPrecision();
    //     engine.getDsc();
    //     // engine.getTokenAmountFromUsd();
    //     // engine.getCollateralTokenPriceFeed();
    //     // engine.getCollateralBalanceOfUser();
    //     // getAccountCollateralValue();
    // }
}
// What are our invarionts?
// 1. Total supply of DSC (our debt) should be less than the total value of collaterals
// 2. Getter view functions should never revert <- evergreen invariant!
