// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/math/MathUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";


import {BaseStrategy} from "@badger-finance/BaseStrategy.sol";
import {ILendingPool} from "../interfaces/aave/ILendingPool.sol";
import {IRewardsContract} from "../interfaces/aave/IRewardsContract.sol";
import {IRouter} from "../interfaces/joe/IRouter.sol";



contract MyStrategy is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    event Debug(string name, uint256 value);

// address public want; // Inherited from BaseStrategy
    // address public lpComponent; // Token that represents ownership in a pool, not always used
    // address public reward; // Token we farm

    address constant public REWARD = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7; 

    // Representing balance of deposits
    address constant public aToken = 0x686bEF2417b6Dc32C50a3cBfbCC3bb60E1e9a15D;

    // Joe Router
    IRouter constant public ROUTER = IRouter(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);

    // We hardcode the address as we need to keep track of funds
    // If lending pool were to change, we would migrate and retire the strategy
    // https://docs.aave.com/developers/the-core-protocol/addresses-provider
    ILendingPool constant public LENDING_POOL = ILendingPool(0x4F01AeD16D97E3aB5ab2B501154DC9bb0F1A5A2C);
    IRewardsContract constant public REWARDS_CONTRACT = IRewardsContract(0x01D83Fe6A10D2f2B7AF17034343746188272cAc9);


    /// @dev Initialize the Strategy with security settings as well as tokens
    /// @notice Proxies will set any non constant variable you declare as default value
    /// @dev add any extra changeable variable at end of initializer as shown
    function initialize(address _vault, address[1] memory _wantConfig) public initializer {
        __BaseStrategy_init(_vault);
        /// @dev Add config here
        want = _wantConfig[0];
        
        // Approve want for earning interest
        IERC20Upgradeable(want).safeApprove(
            address(LENDING_POOL),
            type(uint256).max
        );

        // Aprove Reward so we can sell it
        IERC20Upgradeable(REWARD).safeApprove(
            address(ROUTER),
            type(uint256).max
        );
    }
    
    /// @dev Return the name of the strategy
    function getName() external pure override returns (string memory) {
        return "avalance-wbtc-aave";
    }

    /// @dev Return a list of protected tokens
    /// @notice It's very important all tokens that are meant to be in the strategy to be marked as protected
    /// @notice this provides security guarantees to the depositors they can't be sweeped away
    function getProtectedTokens() public view virtual override returns (address[] memory) {
        address[] memory protectedTokens = new address[](3);
        protectedTokens[0] = want;
        protectedTokens[0] = aToken;
        protectedTokens[1] = REWARD;
        return protectedTokens;
    }

    /// @dev Deposit `_amount` of want, investing it to earn yield
    function _deposit(uint256 _amount) internal override {
        emit Debug("_amount", _amount);
        LENDING_POOL.deposit(want, _amount, address(this), 0);
    }

    /// @dev Withdraw all funds, this is used for migrations, most of the time for emergency reasons
    function _withdrawAll() internal override {
        uint256 toWithdraw = IERC20Upgradeable(aToken).balanceOf(address(this)); // Cache to save gas on worst case
        if(toWithdraw == 0){
            // AAVE reverts if trying to withdraw 0
            return;
        }

        // Withdraw everything!!
        LENDING_POOL.withdraw(want, type(uint256).max, address(this));
    }

    /// @dev Withdraw `_amount` of want, so that it can be sent to the vault / depositor
    /// @notice just unlock the funds and return the amount you could unlock
    function _withdrawSome(uint256 _amount) internal override returns (uint256) {
        uint256 maxAmount = IERC20Upgradeable(aToken).balanceOf(address(this)); // Cache to save gas on worst case
        if(_amount > maxAmount){
            _amount = maxAmount; // saves gas here
        }

        uint256 balBefore = balanceOfWant();
        LENDING_POOL.withdraw(want, _amount, address(this));
        uint256 balAfter = balanceOfWant();

        // Handle case of slippage
        return balAfter.sub(balBefore);
    }


    /// @dev Does this function require `tend` to be called?
    function _isTendable() internal override pure returns (bool) {
        return false; // Instead of tending, we re-deposit in harvest
    }

    function _harvest() internal override returns (TokenAmount[] memory harvested) {
        address[] memory tokens = new address[](1);
        tokens[0] = aToken;
        
        // Claim all rewards
        REWARDS_CONTRACT.claimRewards(tokens, type(uint256).max, address(this));

        uint256 allRewards = IERC20Upgradeable(REWARD).balanceOf(address(this));

        // Sell 50%
        uint256 toSell = allRewards.mul(5000).div(MAX_BPS);

        // Sell for more want
        address[] memory path = new address[](2);
        path[0] = REWARD;
        path[1] = want;

        uint256 beforeWant = IERC20Upgradeable(want).balanceOf(address(this));
        ROUTER.swapExactTokensForTokens(toSell, 0, path, address(this), block.timestamp);
        uint256 afterWant = IERC20Upgradeable(want).balanceOf(address(this));

        // Report profit for the want increase (NOTE: We are not getting perf fee on AAVE APY with this code)
        uint256 wantHarvested = afterWant.sub(beforeWant);
        _reportToVault(wantHarvested);

        // Remaining balance to emit to tree
        uint256 rewardEmitted = IERC20Upgradeable(REWARD).balanceOf(address(this)); 
        _processExtraToken(REWARD, rewardEmitted);

        // Return the same value for APY and offChain automation
        harvested = new TokenAmount[](2);
        harvested[0] = TokenAmount(want, wantHarvested);
        harvested[1] = TokenAmount(REWARD, rewardEmitted);
        return harvested;
    }


    // Example tend is a no-op which returns the values, could also just revert
    function _tend() internal override returns (TokenAmount[] memory tended){
        uint256 balanceToTend = balanceOfWant();
        _deposit(balanceToTend);

        // Return all tokens involved for offChain tracking and automation
        tended = new TokenAmount[](3);
        tended[0] = TokenAmount(want, balanceToTend);
        tended[1] = TokenAmount(aToken, 0);
        tended[2] = TokenAmount(REWARD, 0); 
        return tended;
    }

    /// @dev Return the balance (in want) that the strategy has invested somewhere
    function balanceOfPool() public view override returns (uint256) {
        return IERC20Upgradeable(aToken).balanceOf(address(this));
    }

    /// @dev Return the balance of rewards that the strategy has accrued
    /// @notice Used for offChain APY and Harvest Health monitoring
    function balanceOfRewards() external view override returns (TokenAmount[] memory rewards) {
        address[] memory tokens = new address[](1);
        tokens[0] = aToken;

        uint256 accruedRewards = REWARDS_CONTRACT.getRewardsBalance(tokens, address(this));
        rewards = new TokenAmount[](1);
        rewards[0] = TokenAmount(REWARD, accruedRewards); 
        return rewards;
    }
}