// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

// Common interface for FeeForwarder
interface IFeeForwarder {
    function setAddresses(
        address _targetToken,
        address _feeAdminAddress,
        address _feeRewardPoolAddress,
        address _uniswapRouterV2Address
    //    uint _borrowingFeeConversionNumerator,
    //    uint _borrowingFeeConversionDenominator  
    ) external;    
    function poolNotifyFixedTarget(address _token, uint _amount) external;
    function setFeeRewardPoolParams(address _targetToken, address _feeRewardPoolAddress) external;
    function setConversionPath(address from, address to, address[] memory _uniswapRoute) external;
}