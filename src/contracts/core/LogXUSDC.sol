// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import '../libraries/token/MintableBaseToken.sol';

contract LogXUSDC is MintableBaseToken{
    constructor() MintableBaseToken("LogX USDC", "USDC.L", 0) {
    }

    function id() external pure returns (string memory _name) {
        return "USDC.L";
    }
}