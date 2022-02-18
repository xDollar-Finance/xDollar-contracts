// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/IActivePool.sol";
import "./Interfaces/ILUSDToken.sol";
import "./Interfaces/IFeeForwarder.sol";
import "./Dependencies/IERC20.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/IUniswapV2Router02.sol";


contract FeeForwarder is CheckContract, IFeeForwarder, Ownable {
    string constant public NAME = "FeeForwarder";
        
    address public targetToken;
    address public feeAdminAddress;
    address public feeRewardPoolAddress;
    address public uniswapRouterV2Address;

    mapping (address => mapping (address => address[])) public uniswapRoutes;

    event FeeAdminAddressChanged(address _feeAdminAddress);
    event FeeRewardPoolParamsChanged(address _targetToken, address _feeRewardPoolAddress);
    event UniswapRouterV2AddressChanged(address _uniswapRouterV2Address);

    function setAddresses(
        address _targetToken,
        address _feeAdminAddress,
        address _feeRewardPoolAddress,
        address _uniswapRouterV2Address   
    )
        external
        override
        onlyOwner
    {
        feeAdminAddress = _feeAdminAddress; 
        targetToken = _targetToken;          
        feeRewardPoolAddress = _feeRewardPoolAddress;
        uniswapRouterV2Address = _uniswapRouterV2Address;
                
        emit FeeAdminAddressChanged(_feeAdminAddress);
        emit FeeRewardPoolParamsChanged(_targetToken, _feeRewardPoolAddress);
        emit UniswapRouterV2AddressChanged(_uniswapRouterV2Address);

       _renounceOwnership();
    }
    
    function setFeeRewardPoolParams(address _targetToken, address _feeRewardPoolAddress) external override {
        require(msg.sender == feeAdminAddress, "FF: Caller not admin");
        targetToken = _targetToken;
        feeRewardPoolAddress = _feeRewardPoolAddress;
        emit FeeRewardPoolParamsChanged(_targetToken, _feeRewardPoolAddress);
    }

    function setConversionPath(address from, address to, address[] memory _uniswapRoute) external override {
        require(msg.sender == feeAdminAddress, "FF: Caller not admin");        
        require(from == _uniswapRoute[0],
            "The first token of the Uniswap route must be the from token");
        require(to == _uniswapRoute[_uniswapRoute.length - 1],
            "The last token of the Uniswap route must be the to token");
        uniswapRoutes[from][to] = _uniswapRoute;
    }
        
    // Transfers the funds from the msg.sender to FeeRewardPool
    // under normal circumstances, msg.sender is TroveManager or BorrowOperation
    // When _useConversionRate = false, try to swap all _token to targetToken.
    // When TM calls this function, _useConversionRate is set to false.
    // When BO calls this function, _useConversionRate is set to true.
    function poolNotifyFixedTarget(address _token, uint _amount) external override {
        if (targetToken == address(0) || feeRewardPoolAddress == address(0)) {
            return; // a No-op if target pool is not set yet
        }
        if (_token == targetToken) {
            // this is already the right token
            IERC20(_token).transferFrom(msg.sender, feeRewardPoolAddress, _amount);
        } 
        else if (!(uniswapRoutes[_token][targetToken].length > 1)) {
            // the route is not set for this token
            // in this case, directly send _token to feeRewardPoolAddress       
            IERC20(_token).transferFrom(msg.sender, feeRewardPoolAddress, _amount);
        }
        else {
            // this means all tokens should be first sent to the FF, swap to targetToken,
            // and then transferred to FeeRewardPool. This should be the case for TM
            // redemption, or BO borrow(when XUSD-targeToken has fair liquidity)
            
            // liquidate to targetToken and send it over
            IERC20(_token).transferFrom(msg.sender, address(this), _amount);
            _liquidate(_token, targetToken, _amount);
            // send the targetToken to FeeRewardPool
            IERC20(targetToken).transfer(feeRewardPoolAddress, IERC20(targetToken).balanceOf(address(this)));
        } 
    }

    function _liquidate(address _from, address _to, uint256 balanceToSwap) internal {
        if(balanceToSwap > 0){
            IERC20(_from).approve(uniswapRouterV2Address, 0);
            IERC20(_from).approve(uniswapRouterV2Address, balanceToSwap);

            IUniswapV2Router02(uniswapRouterV2Address).swapExactTokensForTokens(
                balanceToSwap,
                1, // we will accept any amount
                uniswapRoutes[_from][_to],
                address(this),
                block.timestamp
            );
        }
    }
}