// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import '../src/contracts/core/PriceFeed.sol';
import "forge-std/Script.sol";
import '../src/contracts/core/Vault.sol';
import '../src/contracts/core/Router.sol';
import '../src/contracts/core/PositionManager.sol';
import '../src/contracts/core/OrderBook.sol';
import '../src/contracts/core/USDL.sol';
import '../src/contracts/core/PositionRouter.sol';
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

    function run() external{  
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY"); 
        uint nonce = vm.getNonce(0x143328D5d7C84515b3c8b3f8891471ff872C0015);
        console.log("Nonce: ", nonce);
        vm.startBroadcast(deployerPrivateKey);
        // IERC20 llp = IERC20(vm.envAddress("LLP"));
        // uint256 balance = llp.balanceOf(0x143328D5d7C84515b3c8b3f8891471ff872C0015);
        // console.log(balance);
        // RewardRouter rewardRouter = RewardRouter(vm.envAddress("REWARD_ROUTER"));
        // rewardRouter.burnLlp(balance, 0);
        // PositionRouter positionRouter  = PositionRouter(vm.envAddress("POSITION_ROUTER"));
        // IERC20 usdc = IERC20(vm.envAddress("USDC"));
        // positionRouter.createDecreasePosition{value:37*10**16}(address(usdc), vm.envAddress("ETH"), 10 **19, 10 **31, false, 
        // payable(0x143328D5d7C84515b3c8b3f8891471ff872C0015), 1900*10**31,37*10**16);
        // positionRouter.executeDecreasePositions(4, payable(0x143328D5d7C84515b3c8b3f8891471ff872C0015));
        // PositionRouter positionRouter = PositionRouter(vm.envAddress("POSITION_ROUTER"));
        // IERC20 usdc = IERC20(vm.envAddress("USDC"));
        // positionRouter.createDecreasePosition{value:37*10**16}(address(usdc), vm.envAddress("ETH"), 10 **19, 10 **31, false, 
        // payable(0x143328D5d7C84515b3c8b3f8891471ff872C0015), 1900*10**29,37*10**16);

        // PositionRouter positionRouter = new PositionRouter(vm.envAddress("VAULT"), vm.envAddress("ROUTER"), 37*10**16);
        // positionRouter.setPositionKeeper(0x143328D5d7C84515b3c8b3f8891471ff872C0015, true);
        // Router router = Router(vm.envAddress("ROUTER"));
        // router.addPlugin(address(positionRouter));
        // router.approvePlugin(address(positionRouter));
        // IERC20 usdc = IERC20(vm.envAddress("USDC"));
        // usdc.approve(address(router), 10**21);
        // positionRouter.createIncreasePosition{value:37*10**16}(address(usdc), vm.envAddress("ETH"), 10**19, 10 **31, true, 1900*10**30,37*10**16);
        // positionRouter.createIncreasePosition{value:37*10**16}(address(usdc), vm.envAddress("ETH"), 10 **19, 10 **31, false, 1900*10**29,37*10**16);
        // //set global size
        // Vault vault = Vault(vm.envAddress("VAULT"));
        // vault.setMaxGlobalLongSize(address(usdc), 10**21);
        // positionRouter.setPositionKeeper(0x143328D5d7C84515b3c8b3f8891471ff872C0015, true);
        // console.log( "idx");
        // console.log( positionRouter.increasePositionRequestKeysStart());
        // console.log(positionRouter.decreasePositionRequestKeysStart());
        // positionRouter.setDelayValues(0,0,1000000);
        // positionRouter.executeIncreasePositions(2, payable(0x0a6BF6d0d650807BFC0754764cF7ADCc4DeE0A20));
        // positionRouter.createDecreasePosition{value:37*10**16}(address(usdc), vm.envAddress("ETH"), 10 **19, 10 **31, false, payable(0x143328D5d7C84515b3c8b3f8891471ff872C0015), 1900*10**29,37*10**16);
        // positionRouter.executeDecreasePositions(1, payable(0x0a6BF6d0d650807BFC0754764cF7ADCc4DeE0A20));
        // console.log( "idx");
        // console.log(positionRouter.increasePositionRequestKeysStart());
        // console.log(positionRouter.decreasePositionRequestKeysStart());
        // RewardTracker usdc = RewardTracker(vm.envAddress("USDC"));
        // console.log(usdc.decimals());
        // console.log(usdc.balanceOf(vm.envAddress("VAULT")));
        // usdc.approve(vm.envAddress("LLP_MANAGER"), 10**20);
        //console.log(usdc.allowance(vm.envAddress("VAULT"), vm.envAddress("LLP_MANAGER")));
        // VaultUtils vaultUtils = new VaultUtils(Vault(vm.envAddress("VAULT")));
        // Vault(vm.envAddress("VAULT")).setVaultUtils(vaultUtils);
        // PriceFeed priceFeed = PriceFeed(vm.envAddress("PRICE_FEED"));
        // 
        // console.log("PriceFeed deployed at address: ", address(priceFeed));
        // Vault vault = Vault(vm.envAddress("VAULT"));
        // vault.setPriceFeed(address(priceFeed));
        //set manager in vault

        Vault vault = new Vault(); 
        console.log("Vault deployed at address: ", address(vault));
        USDL usdl = USDL(vm.envAddress("USDL"));
        usdl.removeVault(vm.envAddress("VAULT"));
        usdl.addVault(address(vault));
        //USDL usdl = new USDL(address(vault));
        // console.log("USDL deployed at address: ", address(usdl));
        Router router = new Router(address(vault));
        console.log("Router deployed at address: ", address(router));
        PriceFeed priceFeed = PriceFeed(vm.envAddress("PRICE_FEED"));
        vault.initialize(address(router), address(usdl), address(priceFeed),liquidationFeeUsd, fundingRateFactor, vm.envAddress("USDC"));
        vault.setTokenConfig(vm.envAddress("USDC"), 18, 0, true, true, false);
        vault.setTokenConfig(vm.envAddress("ETH"), 18, 0, false, false, true);
        vault.setTokenConfig(vm.envAddress("BTC"), 18, 0, false, false, true);
        vault.setMaxGlobalLongSize(vm.envAddress("USDC"), 10**24);
        VaultUtils vaultUtils = new VaultUtils(vault);
        console.log("VaultUtils deployed at address: ", address(vaultUtils));
        vault.setVaultUtils(vaultUtils);
        
        // //console.log("Vault initialized");
        PositionRouter positionRouter = new PositionRouter(address(vault), address(router), minExecutionFeeMarketOrder);
        positionRouter.setPositionKeeper(vm.envAddress("PRICE_FEED"), true);
        console.log("PositionRouter deployed at address: ", address(positionRouter));
        // //>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>LIQUIDITY POOL<<<<<<<<<
        // set minter in llp token to LLPManager
        //Llp llp = new Llp("LogX LP", "LLP");
        LlpManager llpManager = new LlpManager(address(vault), address(usdl), vm.envAddress("LLP"), llpCooldownDuration);
        console.log("LlpManager deployed at address: ", address(llpManager));
        // RewardTracker rewardTracker = new RewardTracker("fee LLP", "fLlp");
        // console.log("RewardTracker deployed at address: ", address(rewardTracker));
        RewardRouter rewardRouter = new RewardRouter();
        console.log("RewardRouter deployed at address: ", address(rewardRouter));
        rewardRouter.initialize(vm.envAddress("USDC"), vm.envAddress("LLP"), address(llpManager), address(vm.envAddress("REWARD_TRACKER")));
        //console.log("RewardRouter initialized");
        vm.stopBroadcast();
    }

    function allContractDeployments() public {
        Vault vault = deployVault();
        PriceFeed priceFeed  = deployAndInitializePriceFeed();
        Router router = deployRouter(vault);
        PositionRouter positionRouter =  deployPositionRouter(priceFeed, vault, router);
        USDL usdl = deployUSDL(vault);
        RewardRouter rewardRouter = deployRewardRouter();
        LlpManager llpManager = deployLlpManager(vault, usdl, rewardRouter);
        initializeLLP(llpManager);
        VaultUtils vaultUtils = deployVaultUtils(vault);
        initializeVault(vault, router, priceFeed, usdl, vaultUtils);
        RewardTracker rewardTracker = deployRewardTracker();
        initializeRewardRouter(rewardRouter, vm.envAddress("USDC"), vm.envAddress("LLP"), address(llpManager), address(rewardTracker));
        OrderBook orderBook = deployAndInitializeOrderBook(vault, router, positionRouter, usdl, vaultUtils);
        PositionManager positionManager = deployPositionManager(vault, router, orderBook);
    }

    function deployAndInitializeOrderBook(Vault vault, Router router, PositionRouter positionRouter, USDL usdl, VaultUtils vaultUtils) public returns (OrderBook){
        OrderBook orderBook = new OrderBook();
        console.log("OrderBook deployed at address: ", address(orderBook));
        orderBook.initialize( address(router), address(vault), address(usdl), minExecutionFeeLimitOrder, minPurchaseTokenAmountUsd);
        return orderBook;
    }

    function deployPositionManager(Vault vault, Router router, OrderBook orderBook) public returns (PositionManager){
        PositionManager positionManager = new PositionManager(address(vault), address(router), address(orderBook));
        console.log("PositionManager deployed at address: ", address(positionManager));
        return positionManager;
    }

    function initializeRewardRouter(RewardRouter rewardRouter, address usdc, address llp, address llpManager, address rewardTracker) public {
        RewardRouter rewardRouter = RewardRouter(rewardRouter);
        rewardRouter.initialize(usdc, llp, llpManager, rewardTracker);
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

    function deployPositionRouter(PriceFeed priceFeed, Vault vault, Router router) public returns (PositionRouter){
        PositionRouter positionRouter = new PositionRouter(address(vault), address(router), minExecutionFeeMarketOrder);
        console.log("PositionRouter deployed at address: ", address(positionRouter));
        positionRouter.setPositionKeeper(address(priceFeed), true);
        router.addPlugin(address(positionRouter));
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