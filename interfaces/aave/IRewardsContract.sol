// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface IRewardsContract {
  // set amount to type(uint256).max to claim all
  function claimRewards(address[] calldata assets, uint256 amount, address to) external returns (uint256 amountClaimed);
  function getRewardsBalance(address[] calldata assets, address user) external view returns (uint256);
}

