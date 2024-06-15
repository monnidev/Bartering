// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {DeployBartering} from "../../script/DeployBartering.s.sol";
import {Bartering} from "../../src/Bartering.sol";
import {Test, console} from "../../lib/forge-std/src/Test.sol";
import {Vm} from "../../lib/forge-std/src/Vm.sol";
import {StdCheats} from "../../lib/forge-std/src/StdCheats.sol";
import {MockERC20} from "../mocks/TokensMocks.sol";
import {MockERC721} from "../mocks/TokensMocks.sol";

contract BarteringTest is StdCheats, Test {
    Bartering public bartering;

    address public REQUESTER = makeAddr("requester");
    address public ACCEPTER = makeAddr("accepter");
    address public OWNER = makeAddr("owner");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() external {
        DeployBartering deployer = new DeployBartering();
        (bartering) = deployer.run(OWNER);
        vm.deal(REQUESTER, STARTING_USER_BALANCE);
        vm.deal(ACCEPTER, STARTING_USER_BALANCE);
        vm.deal(OWNER, STARTING_USER_BALANCE);
    }

    function testChangeFee(uint256 newFee) external {
        uint256 initialFee = bartering.getCurrentFee();
        vm.prank(OWNER);
        bartering.changeFee(newFee);
        if (initialFee != newFee) {
            assertEq(newFee, bartering.getCurrentFee());
        }
    }

    function testCreateBarterRequest() external {}

    // acceptBarterRequest
    // cancelBarterRequest
    // withdrawAllTokens
    // withdrawTokensByIndices
    // ownerWithdrawal
}
