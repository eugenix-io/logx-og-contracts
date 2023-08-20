// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import '../src/contracts/core/PriceFeed.sol';
import "forge-std/Script.sol";
import '../src/contracts/core/Vault.sol';
import '../src/contracts/core/Router.sol';
import '../src/contracts/core/OrderManager.sol';
import '../src/contracts/core/USDL.sol';
import '../src/contracts/core/LlpManager.sol';
import '../src/contracts/core/RewardRouter.sol';
import '../src/contracts/core/RewardTracker.sol';
import '../src/contracts/core/VaultUtils.sol';
import '../src/contracts/libraries/token/IERC20.sol';
import '../../src/contracts/core/interfaces/IMintable.sol';



contract Deployment is Script {
    uint constant liquidationFeeUsd = 5 * 10 ** 30;
    uint constant fundingRateFactor = 100;
    uint constant maxAllowedDelayPriceFeed = 300;
    uint constant minExecutionFeeMarketOrder = 37 * 10 ** 16;
    uint constant minExecutionFeeLimitOrder = 37 * 10 ** 16;
    uint constant llpCooldownDuration = 1 hours;
    uint constant maxGlobalLongSize = 10**24;
    uint constant maxGlobalShortSize = 10**24;
    uint constant minPurchaseTokenAmountUsd = 0;
    address constant executor = 0x143328D5d7C84515b3c8b3f8891471ff872C0015;

    function run() external{  
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY"); 
        vm.startBroadcast(deployerPrivateKey);
        allContractDeployments();
        vm.stopBroadcast();
    }

    function allContractDeployments() public {
        Vault vault = deployVault();
        PriceFeed priceFeed  = deployAndInitializePriceFeed();
        Router router = deployRouter(vault);
        USDL usdl = deployUSDL(vault);
        RewardRouter rewardRouter = deployRewardRouter();
        LlpManager llpManager = deployLlpManager(vault, usdl, rewardRouter);
        initializeLLP(llpManager);
        VaultUtils vaultUtils = deployVaultUtils(vault);
        initializeVault(vault, router, priceFeed, usdl, vaultUtils);
        RewardTracker rewardTracker = deployRewardTracker();
        initializeRewardRouter(rewardRouter, vm.envAddress("USDC"), vm.envAddress("LLP"), address(llpManager), address(rewardTracker));
        deployOrderManager(vault, router, priceFeed);
    }

    function deployOrderManager(Vault vault, Router router, PriceFeed priceFeed) public returns (OrderManager){
        OrderManager orderManager = new OrderManager(address(vault), address(router), minExecutionFeeMarketOrder, minExecutionFeeLimitOrder);
        console.log("OrderManager deployed at address: ", address(orderManager));
        orderManager.setPositionKeeper(address(priceFeed), true);
        orderManager.setMinExecutionFeeLimitOrder(minExecutionFeeLimitOrder);
        orderManager.setMinExecutionFeeMarketOrder(minExecutionFeeMarketOrder);
        orderManager.setLiquidator(0x143328D5d7C84515b3c8b3f8891471ff872C0015, true);
        orderManager.setOrderKeeper(0x143328D5d7C84515b3c8b3f8891471ff872C0015, true);
        orderManager.setDelayValues(0, 0, 3600);
        return orderManager;
    }

    function initializeRewardRouter(RewardRouter rewardRouter, address usdc, address llp, address llpManager, address rewardTracker) public {
        rewardRouter.initialize(usdc, llp, llpManager, rewardTracker);
        RewardTracker(rewardTracker).setHandler(address(rewardRouter), true);
    }

    function deployRewardTracker() public returns (RewardTracker){
        RewardTracker rewardTracker = new RewardTracker("fee LLP", "fLlp");
        console.log("RewardTracker deployed at address: ", address(rewardTracker));
        return rewardTracker;
    }

    function deployVaultUtils(Vault vault) public returns (VaultUtils){
        VaultUtils vaultUtils = new VaultUtils(vault);
        console.log("VaultUtils deployed at address: ", address(vaultUtils));
        return vaultUtils;
    }

    function deployUSDL(Vault vault) public returns (USDL){
        USDL usdl = new USDL(address(vault));
        console.log("USDL deployed at address: ", address(usdl));
        return usdl;
    }

    function deployRewardRouter() public returns (RewardRouter){
        RewardRouter rewardRouter = new RewardRouter();
        console.log("RewardRouter deployed at address: ", address(rewardRouter));
        //whitelist tokens
        return rewardRouter;
    }

    function initializeLLP(LlpManager llpManager) public {
        IMintable llp = IMintable(vm.envAddress("LLP"));
        llp.setMinter(address(llpManager), true);
    }

    function deployRouter(Vault vault) public returns (Router){
        Router router = new Router(address(vault));
        console.log("Router deployed at address: ", address(router));
        return router;
    }

    function deployLlpManager(Vault vault, USDL usdl, RewardRouter rewardRouter) public returns (LlpManager){
        LlpManager llpManager = new LlpManager(address(vault), address(usdl), vm.envAddress("LLP"), llpCooldownDuration);
        llpManager.setHandler(address(rewardRouter), true);
        llpManager.whiteListToken(vm.envAddress("USDC"));
        console.log("LlpManager deployed at address: ", address(llpManager));
        return llpManager;
    }

    function deployAndInitializePriceFeed() public returns (PriceFeed){
        PriceFeed priceFeed = new PriceFeed(maxAllowedDelayPriceFeed, vm.envAddress("PYTH_CONTRACT"), vm.envAddress("UPDATER"));
        console.log("PriceFeed deployed at address: ", address(priceFeed));
        priceFeed.updateTokenIdMapping(vm.envAddress("USDC"), vm.envBytes32("USDC_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("ETH"), vm.envBytes32("ETH_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("BTC"), vm.envBytes32("BTC_PYTH_FEED"));
        console.log("PriceFeed initialized");
        return priceFeed;
    }

    function deployVault() public returns (Vault){
        Vault vault = new Vault(); 
        console.log("Vault deployed at address: ", address(vault));
        return vault;
    }

    function initializeVault(Vault vault, Router router, PriceFeed priceFeed, USDL usdl, VaultUtils vaultUtils) public {
        usdl.addVault(address(vault));
        vault.initialize(address(router), address(usdl), address(priceFeed),liquidationFeeUsd, fundingRateFactor, vm.envAddress("USDC"));
        vault.setTokenConfig(vm.envAddress("USDC"), 18, 0, true, true, false);
        vault.setTokenConfig(vm.envAddress("ETH"), 18, 0, false, false, true);
        vault.setTokenConfig(vm.envAddress("BTC"), 18, 0, false, false, true);
        vault.setMaxGlobalLongSize(vm.envAddress("USDC"), maxGlobalLongSize);
        vault.setMaxGlobalShortSize(vm.envAddress("USDC"), maxGlobalShortSize);
        vault.setVaultUtils(vaultUtils);
    }

}