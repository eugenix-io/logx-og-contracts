// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import '../libraries/token/MintableBaseToken.sol';

contract LLP is MintableBaseToken{
    constructor() MintableBaseToken("LogX LP", "LLP", 0) {
    }

    function id() external pure returns (string memory _name) {
        return "LLP";
    }
}