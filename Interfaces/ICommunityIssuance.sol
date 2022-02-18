// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface ICommunityIssuance { 
    
    // --- Events ---
    
    event LQTYTokenAddressSet(address _lqtyTokenAddress);
    event RewardTokenAdded(address _rewardTokenAddress, uint rewardRatio);
    event RewardRatioUpdated(address _rewardTokenAddress, uint rewardRatio);
    event StabilityPoolAddressSet(address _stabilityPoolAddress);
    event TotalLQTYIssuedUpdated(uint _totalLQTYIssued);

    // --- Functions ---

    function setAddresses(address _lqtyTokenAddress, address _stabilityPoolAddress) external;

    function issueLQTY() external returns (uint);

    function sendLQTY(address _account, uint _LQTYamount) external;

    function addRewardToken(address _rewardTokenAddress, uint rewardTokenRatio) external;

    function setRewardTokenRatio(address _rewardTokenAddress, uint _rewardRatio) external;
}