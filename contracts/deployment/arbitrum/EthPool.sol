// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: d511a90d3722e4a323de89435179465e006f8335;
pragma solidity 0.8.17;

import "../../Pool.sol";


/**
 * @title EthPool
 * @dev Contract allowing user to deposit to and borrow WETH.e from a dedicated user account
 */
contract EthPool is Pool {
    function getMaxPoolUtilisationForBorrowing() override public view returns (uint256) {
        return 0.9e18;
    }

    function name() public virtual override pure returns(string memory _name){
        _name = "DeltaPrimeWrappedEther";
    }

    function symbol() public virtual override pure returns(string memory _symbol){
        _symbol = "DPWETHe";
    }

    function decimals() public virtual override pure returns(uint8 decimals){
        decimals = 18;
    }
}