// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "./Helper.t.sol";



contract LLPAndRewardsTest is Test, Helper {
    /* 1. addLiquidityForAccount
        1.1 try with authenticated address
        1.2 try invalid token
        1.3 balance of funding accoutn should decrease
        1.4 llp supply should increase
        1.5 check llp balance of funding account before and after
        1.6 catch AddLiquidity event
    */
    /* 2. removeLiquidityForAccount
        2.1 try with authenticated address
        2.2 try invalid token
        2.3 llp should be burned
        2.4 _receiver account balance should increase
    */

    /* 3. stakeForAccount
        3.0 invalid handler
        3.1 balance of account should decrease
        3.2 balance of RewardTracker shoudl increase
        3.3 fllp should be minted to user
        3.4 check values in positions[account] are set correctly
        3.5 totalDeposit supply shoudl increase
        3.6 catch event
    */

    /* 4. unstakeForAccount
        4.1 in alid handler
        4.2 try unstaking more than staked value
        4.3 value in positions[_account] should update accordingly
        4.4 depositBalance should decrease
        4.5 fllp is burned
        4.6 balance of account is increased
        4.7 balance of RewardTracker is decreased
        4.8 catch event
    */

    /* 5. claimForAccount
        5.1 invalid handler
        5.2 balance of account shoudl increase by claimable amount

    */
}