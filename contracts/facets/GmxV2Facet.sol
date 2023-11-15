// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: 799a1765b64edc5c158198ef84f785af79e234ae;
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/facets/avalanche/IGLPRewarder.sol";
import "../interfaces/facets/avalanche/IRewardRouterV2.sol";
import "../interfaces/facets/avalanche/IRewardTracker.sol";
import "../ReentrancyGuardKeccak.sol";
import {DiamondStorageLib} from "../lib/DiamondStorageLib.sol";
import "../OnlyOwnerOrInsolvent.sol";
import "../interfaces/ITokenManager.sol";

import "../interfaces/gmx-v2/Deposit.sol";
import "../interfaces/gmx-v2/Withdrawal.sol";
import "../interfaces/gmx-v2/Order.sol";
import "../interfaces/gmx-v2/BasicMulticall.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/gmx-v2/IDepositCallbackReceiver.sol";
import "../interfaces/gmx-v2/EventUtils.sol";
import "../interfaces/gmx-v2/IDepositUtils.sol";
import "../interfaces/gmx-v2/IWithdrawalUtils.sol";
import "../interfaces/gmx-v2/IGmxV2Router.sol";
import "../interfaces/gmx-v2/IWithdrawalCallbackReceiver.sol";

//This path is updated during deployment
import "../lib/local/DeploymentConstants.sol";

abstract contract GmxV2Facet is IDepositCallbackReceiver, IWithdrawalCallbackReceiver, ReentrancyGuardKeccak, OnlyOwnerOrInsolvent {
    using TransferHelper for address;

    // GMX contracts
    function getGMX_V2_ROUTER() internal pure virtual returns (address);

    function getGMX_V2_EXCHANGE_ROUTER() internal pure virtual returns (address);

    function getGMX_V2_DEPOSIT_VAULT() internal pure virtual returns (address);

    function getGMX_V2_WITHDRAWAL_VAULT() internal pure virtual returns (address);

    function getGMX_V2_KEEPER() internal pure virtual returns (address);

    // Mappings
    function marketToLongToken(address market) internal virtual pure returns (address);

    function marketToShortToken(address market) internal virtual pure returns (address);


    //TODO: can you create a small doc (can be a test file
    function _deposit(address gmToken, address depositedToken, uint256 tokenAmount, uint256 minGmAmount, uint256 executionFee) internal nonReentrant noBorrowInTheSameBlock onlyOwner returns (bytes[] memory) {
        address longToken = marketToLongToken(gmToken);
        address shortToken = marketToShortToken(gmToken);

        IERC20(depositedToken).approve(getGMX_V2_ROUTER(), tokenAmount);

        bytes[] memory data = new bytes[](3);

        data[0] = abi.encodeWithSelector(
            IGmxV2Router.sendWnt.selector,
            getGMX_V2_DEPOSIT_VAULT(),
            executionFee
        );
        data[1] = abi.encodeWithSelector(
            IGmxV2Router.sendTokens.selector,
            depositedToken,
            getGMX_V2_DEPOSIT_VAULT(),
            tokenAmount
        );
        data[2] = abi.encodeWithSelector(
            IDepositUtils.createDeposit.selector,
            IDepositUtils.CreateDepositParams({
                receiver: address(this), //receiver
                callbackContract: address(this), //callbackContract
                uiFeeReceiver: address(0), //uiFeeReceiver
                market: gmToken, //market
                initialLongToken: longToken, //initialLongToken
                initialShortToken: shortToken, //initialShortToken
                longTokenSwapPath: new address[](0), //longTokenSwapPath
                shortTokenSwapPath: new address[](0), //shortTokenSwapPath
                minMarketTokens: minGmAmount, //minMarketTokens
                shouldUnwrapNativeToken: false, //shouldUnwrapNativeToken
                executionFee: executionFee, //executionFee
                callbackGasLimit: 100000 //callbackGasLimit
            })
        );

        bytes[] memory results = BasicMulticall(getGMX_V2_EXCHANGE_ROUTER()).multicall{ value: msg.value }(data);

        // Freeze account
        DiamondStorageLib.freezeAccount(gmToken);

        // Reset assets exposure
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bytes32[] memory resetExposureAssets = new bytes32[](3);
        resetExposureAssets[0] = tokenManager.tokenAddressToSymbol(gmToken);
        resetExposureAssets[1] = tokenManager.tokenAddressToSymbol(longToken);
        resetExposureAssets[1] = tokenManager.tokenAddressToSymbol(shortToken);
        SolvencyMethods._resetPrimeAccountExposureForChosenAssets(resetExposureAssets);

        // Remove long/short token(s) from owned assets if whole balance(s) was/were used
        if(IERC20Metadata(longToken).balanceOf(address(this)) == 0){
            DiamondStorageLib.removeOwnedAsset(tokenManager.tokenAddressToSymbol(longToken));
        }
        if(IERC20Metadata(shortToken).balanceOf(address(this)) == 0){
            DiamondStorageLib.removeOwnedAsset(tokenManager.tokenAddressToSymbol(shortToken));
        }
        return results;
    }

    //TODO: withdrawal guard
    function _withdraw(address gmToken, uint256 gmAmount, uint256 minLongTokenAmount, uint256 minShortTokenAmount, uint256 executionFee) internal nonReentrant noBorrowInTheSameBlock onlyOwnerOrInsolvent returns (bytes[] memory) {
        bytes[] memory data = new bytes[](3);

        IERC20(gmToken).approve(getGMX_V2_ROUTER(), gmAmount);

        data[0] = abi.encodeWithSelector(
            IGmxV2Router.sendWnt.selector,
            getGMX_V2_WITHDRAWAL_VAULT(),
            executionFee
        );

        data[1] = abi.encodeWithSelector(
            IGmxV2Router.sendTokens.selector,
            gmToken,
            getGMX_V2_WITHDRAWAL_VAULT(),
            gmAmount
        );

        data[2] = abi.encodeWithSelector(
            IWithdrawalUtils.createWithdrawal.selector,
            IWithdrawalUtils.CreateWithdrawalParams({
                receiver: address(this), //receiver
                callbackContract: address(this), //callbackContract
                uiFeeReceiver: address(0), //uiFeeReceiver
                market: gmToken, //market
                longTokenSwapPath: new address[](0), //longTokenSwapPath
                shortTokenSwapPath: new address[](0), //shortTokenSwapPath
                minLongTokenAmount: minLongTokenAmount,
                minShortTokenAmount: minShortTokenAmount,
                shouldUnwrapNativeToken: false, //shouldUnwrapNativeToken
                executionFee: executionFee, //executionFee
                callbackGasLimit: 100000 //callbackGasLimit
            })
        );

        bytes[] memory results = BasicMulticall(getGMX_V2_EXCHANGE_ROUTER()).multicall{ value: msg.value }(data);

        // Freeze account
        DiamondStorageLib.freezeAccount(gmToken);

        // Reset assets exposure
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bytes32[] memory resetExposureAssets = new bytes32[](3);
        resetExposureAssets[0] = tokenManager.tokenAddressToSymbol(gmToken);
        resetExposureAssets[1] = tokenManager.tokenAddressToSymbol(marketToLongToken(gmToken));
        resetExposureAssets[1] = tokenManager.tokenAddressToSymbol(marketToShortToken(gmToken));
        SolvencyMethods._resetPrimeAccountExposureForChosenAssets(resetExposureAssets);

        // Remove GM token from owned assets if whole balance was used
        if(IERC20Metadata(gmToken).balanceOf(address(this)) == 0){
            DiamondStorageLib.removeOwnedAsset(tokenManager.tokenAddressToSymbol(gmToken));
        }

        return results;
    }

    function afterDepositExecution(bytes32 key, Deposit.Props memory deposit, EventUtils.EventLogData memory eventData) external onlyGmxV2Keeper nonReentrant override {
        // Set asset exposure
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bytes32[] memory resetExposureAssets = new bytes32[](3);
        resetExposureAssets[0] = tokenManager.tokenAddressToSymbol(deposit.addresses.market);
        resetExposureAssets[1] = tokenManager.tokenAddressToSymbol(marketToLongToken(deposit.addresses.market));
        resetExposureAssets[2] = tokenManager.tokenAddressToSymbol(marketToShortToken(deposit.addresses.market));
        SolvencyMethods._setPrimeAccountExposureForChosenAssets(resetExposureAssets);
        
        // Add owned assets
        if(IERC20Metadata(deposit.addresses.market).balanceOf(address(this)) > 0){
            DiamondStorageLib.addOwnedAsset(tokenManager.tokenAddressToSymbol(deposit.addresses.market), deposit.addresses.market);
        }

        // Unfreeze account
        DiamondStorageLib.unfreezeAccount(msg.sender);
    }

    function afterDepositCancellation(bytes32 key, Deposit.Props memory deposit, EventUtils.EventLogData memory eventData) external onlyGmxV2Keeper nonReentrant override {
        address longToken = marketToLongToken(deposit.addresses.market);
        address shortToken = marketToShortToken(deposit.addresses.market);
        // Set asset exposure
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bytes32[] memory resetExposureAssets = new bytes32[](3);
        resetExposureAssets[0] = tokenManager.tokenAddressToSymbol(deposit.addresses.market);
        resetExposureAssets[1] = tokenManager.tokenAddressToSymbol(longToken);
        resetExposureAssets[2] = tokenManager.tokenAddressToSymbol(shortToken);
        SolvencyMethods._setPrimeAccountExposureForChosenAssets(resetExposureAssets);

        // Add owned assets
        if(IERC20Metadata(longToken).balanceOf(address(this)) > 0){
            DiamondStorageLib.addOwnedAsset(tokenManager.tokenAddressToSymbol(longToken), longToken);
        }
        if(IERC20Metadata(shortToken).balanceOf(address(this)) > 0){
            DiamondStorageLib.addOwnedAsset(tokenManager.tokenAddressToSymbol(shortToken), shortToken);
        }

        DiamondStorageLib.unfreezeAccount(msg.sender);
    }

    function afterWithdrawalExecution(bytes32 key, Withdrawal.Props memory withdrawal, EventUtils.EventLogData memory eventData) external onlyGmxV2Keeper nonReentrant override {
        address longToken = marketToLongToken(withdrawal.addresses.market);
        address shortToken = marketToShortToken(withdrawal.addresses.market);
        // Set asset exposure
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bytes32[] memory resetExposureAssets = new bytes32[](3);
        resetExposureAssets[0] = tokenManager.tokenAddressToSymbol(withdrawal.addresses.market);
        resetExposureAssets[1] = tokenManager.tokenAddressToSymbol(longToken);
        resetExposureAssets[2] = tokenManager.tokenAddressToSymbol(shortToken);
        SolvencyMethods._setPrimeAccountExposureForChosenAssets(resetExposureAssets);

        // Add owned assets
        if(IERC20Metadata(longToken).balanceOf(address(this)) > 0){
            DiamondStorageLib.addOwnedAsset(tokenManager.tokenAddressToSymbol(longToken), longToken);
        }
        if(IERC20Metadata(shortToken).balanceOf(address(this)) > 0){
            DiamondStorageLib.addOwnedAsset(tokenManager.tokenAddressToSymbol(shortToken), shortToken);
        }

        //TODO: add assets
        DiamondStorageLib.unfreezeAccount(msg.sender);
    }

    function afterWithdrawalCancellation(bytes32 key, Withdrawal.Props memory withdrawal, EventUtils.EventLogData memory eventData) external onlyGmxV2Keeper nonReentrant override {
        // Set asset exposure
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bytes32[] memory resetExposureAssets = new bytes32[](3);
        resetExposureAssets[0] = tokenManager.tokenAddressToSymbol(withdrawal.addresses.market);
        resetExposureAssets[1] = tokenManager.tokenAddressToSymbol(marketToLongToken(withdrawal.addresses.market));
        resetExposureAssets[2] = tokenManager.tokenAddressToSymbol(marketToShortToken(withdrawal.addresses.market));
        SolvencyMethods._setPrimeAccountExposureForChosenAssets(resetExposureAssets);

        // Add owned assets
        if(IERC20Metadata(withdrawal.addresses.market).balanceOf(address(this)) > 0){
            DiamondStorageLib.addOwnedAsset(tokenManager.tokenAddressToSymbol(withdrawal.addresses.market), withdrawal.addresses.market);
        }

        DiamondStorageLib.unfreezeAccount(msg.sender);
    }

    // MODIFIERS
    //TODO: probably not a good solution
    modifier onlyGmxV2Keeper() {
        require(msg.sender == getGMX_V2_KEEPER(), "Must be a GMX V2 Keeper");
        _;
    }

    modifier onlyOwner() {
        DiamondStorageLib.enforceIsContractOwner();
        _;
    }
}