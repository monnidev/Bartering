// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "../lib/forge-std/src/Script.sol";
import {Bartering} from "../src/Bartering.sol";

contract DeployBartering is Script {
    function run(address _initialOwner) external returns (Bartering) {
        vm.startBroadcast(); // Start transaction
        Bartering _bartering = new Bartering(_initialOwner); // Deploy new contract
        vm.stopBroadcast(); // End transaction
        return (_bartering); // Return deployed contract
    }
}
