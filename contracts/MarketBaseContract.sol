/*
    Copyright 2017 Phillip A. Elsasser

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
*/

pragma solidity 0.4.18;

import "./Creatable.sol";
import "./ContractSpecs.sol";
import "./libraries/MathLib.sol";
import "./libraries/OrderLib.sol";
import "./Accounts.sol";
import "./tokens/TokenLockerInterface.sol";

import "zeppelin-solidity/contracts/token/ERC20.sol";
import "zeppelin-solidity/contracts/token/SafeERC20.sol";

/// @title MarketBaseContract base contract implement all needed functionality for trading.
/// @notice this is the abstract base contract that all contracts should inherit from to
/// implement different oracle solutions.
/// @author Phil Elsasser <phil@marketprotcol.io>
contract MarketBaseContract is Creatable, ContractSpecs, Accounts {
    using MathLib for int;
    using MathLib for uint;
    using OrderLib for address;
    using OrderLib for OrderLib.Order;
    using OrderLib for OrderLib.OrderMappings;
    using SafeERC20 for ERC20;

    enum ErrorCodes {
        ORDER_EXPIRED,              // past designated timestamp
        ORDER_DEAD                  // order if fully filled or fully cancelled
    }

    // constants
    ERC20 constant MKT_TOKEN = ERC20(0x123);                    // placeholder for our token
    TokenLockerInterface constant TOKEN_LOCKER = TokenLockerInterface(0x124);
    uint public constant MKT_MIN_CONTRACT_CREATOR = 50 ether;

    // state variables
    uint public lastPrice;
    uint public settlementPrice;
    bool public isSettled;

    // accounting
    OrderLib.OrderMappings orderMappings;

    // events
    event UpdatedLastPrice(string price);
    event ContractSettled(uint settlePrice);
    event UpdatedUserBalance(address indexed user, uint balance);
    event UpdatedPoolBalance(uint balance);
    event Error(ErrorCodes indexed errorCode, bytes32 indexed orderHash);

    // order events
    event OrderFilled(
        address indexed maker,
        address indexed taker,
        address indexed feeRecipient,
        int filledQty,
        uint paidMakerFee,
        uint paidTakerFee,
        bytes32 orderHash // should this be indexed?
    );

    event OrderCancelled(
        address indexed maker,
        address indexed feeRecipient,
        int cancelledQty,
        bytes32 indexed orderHash
    );


    /// @param contractName viewable name of this contract (BTC/ETH, LTC/ETH, etc)
    /// @param baseTokenAddress address of the ERC20 token that will be used for collateral and pricing
    /// @param contractSpecs array of unsigned integers including:
    /// floorPrice minimum tradeable price of this contract, contract enters settlement if breached
    /// capPrice maximum tradeable price of this contract, contract enters settlement if breached
    /// priceDecimalPlaces number of decimal places to convert our queried price from a floating point to
    /// an integer
    /// qtyDecimalPlaces decimal places to multiply traded qty by.
    /// expirationTimeStamp - seconds from epoch that this contract expires and enters settlement
    function MarketBaseContract(
        string contractName,
        address baseTokenAddress,
        uint[5] contractSpecs
    ) ContractSpecs(contractName, baseTokenAddress, contractSpecs) public payable
    {
        //require(MKT_TOKEN.balanceOf(msg.sender) > MKT_MIN_CONTRACT_CREATOR);    // creator must be MKT holder
    }

    /*
    // EXTERNAL METHODS
    */

    /// @notice deposits tokens to the smart contract to fund the user account and provide needed tokens for collateral
    /// pool upon trade matching.
    /// @param depositAmount qty of ERC20 tokens to deposit to the smart contract to cover open orders and collateral
    function depositTokensForTrading(uint256 depositAmount) external {
        require(TOKEN_LOCKER.isUserLocked(address(this), msg.sender));
        depositTokensForTrading(BASE_TOKEN, depositAmount);
    }

    // @notice called by a participant wanting to trade a specific order
    /// @param orderAddresses - maker, taker and feeRecipient addresses
    /// @param unsignedOrderValues makerFee, takerFree, price, expirationTimeStamp, and salt (for hashing)
    /// @param orderQty quantity of the order
    /// @param qtyToFill quantity taker is willing to fill of original order(max)
    /// @param v order signature
    /// @param r order signature
    /// @param s order signature
    function tradeOrder(
        address[3] orderAddresses,
        uint[5] unsignedOrderValues,
        int orderQty,
        int qtyToFill,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (int filledQty)
    {
        require(!isSettled);                                // no trading past settlement
        require(orderQty != 0 && qtyToFill != 0);           // no zero trades
        require(orderQty.isSameSign(qtyToFill));            // signs should match
        address contractAddress = address(this);
        require(TOKEN_LOCKER.isUserLocked(contractAddress, msg.sender));
        OrderLib.Order memory order = contractAddress.createOrder(orderAddresses, unsignedOrderValues, orderQty);
        require(TOKEN_LOCKER.isUserLocked(contractAddress, order.maker));

        // taker can be anyone, or specifically the caller!
        require(order.taker == address(0) || order.taker == msg.sender);
        // do not allow self trade
        require(order.maker != address(0) && order.maker != order.taker);
        require(
            order.maker.isValidSignature(
                order.orderHash,
                v,
                r,
                s
        ));


        if (now >= order.expirationTimeStamp) {
            Error(ErrorCodes.ORDER_EXPIRED, order.orderHash);
            return 0;
        }

        int remainingQty = orderQty.subtract(getQtyFilledOrCancelledFromOrder(order.orderHash));
        if (remainingQty == 0) { // there is no qty remaining  - cannot fill!
            Error(ErrorCodes.ORDER_DEAD, order.orderHash);
            return 0;
        }

        filledQty = MathLib.absMin(remainingQty, qtyToFill);
         updatePositions(
            this,
            order.maker,
            order.taker,
            filledQty,
            order.price
        );
        orderMappings.addFilledQtyToOrder(order.orderHash, filledQty);

        uint paidMakerFee = 0;
        uint paidTakerFee = 0;

        if (order.feeRecipient != address(0)) {
            // we need to transfer fees to recipient
            uint filledAbsQty = filledQty.abs();
            uint orderAbsQty = filledQty.abs();
            if (order.makerFee > 0) {
                paidMakerFee = order.makerFee.divideFractional(filledAbsQty, orderAbsQty);
                MKT_TOKEN.safeTransferFrom(
                    order.maker,
                    order.feeRecipient,
                    paidMakerFee
                );
            }

            if (order.takerFee > 0) {
                paidTakerFee = order.takerFee.divideFractional(filledAbsQty, orderAbsQty);
                MKT_TOKEN.safeTransferFrom(
                    order.taker,
                    order.feeRecipient,
                    paidTakerFee
                );
            }
        }

        OrderFilled(
            order.maker,
            order.taker,
            order.feeRecipient,
            filledQty,
            paidMakerFee,
            paidTakerFee,
            order.orderHash
        );

        return filledQty;
    }

    /// @notice called by the maker of an order to attempt to cancel the order before its expiration time stamp
    /// @param orderAddresses - maker, taker and feeRecipient addresses
    /// @param unsignedOrderValues makerFee, takerFree, price, expirationTimeStamp, and salt (for hashing)
    /// @param orderQty quantity of the order
    /// @param qtyToCancel quantity maker is attempting to cancel
    /// @return qty that was successfully cancelled of order.
    function cancelOrder(
        address[3] orderAddresses,
        uint[5] unsignedOrderValues,
        int orderQty,
        int qtyToCancel
    ) external returns (int qtyCancelled)
    {
        require(qtyToCancel != 0 && qtyToCancel.isSameSign(orderQty));      // cannot cancel 0 and signs must match
        require(!isSettled);
        OrderLib.Order memory order = address(this).createOrder(orderAddresses, unsignedOrderValues, orderQty);
        require(order.maker == msg.sender);                                // only maker can cancel standing order
        if (now >= order.expirationTimeStamp) {
            Error(ErrorCodes.ORDER_EXPIRED, order.orderHash);
            return 0;
        }

        int remainingQty = orderQty.subtract(getQtyFilledOrCancelledFromOrder(order.orderHash));
        if (remainingQty == 0) { // there is no qty remaining to cancel order is dead
            Error(ErrorCodes.ORDER_DEAD, order.orderHash);
            return 0;
        }

        qtyCancelled = MathLib.absMin(qtyToCancel, remainingQty);   // we can only cancel what remains
        orderMappings.addCancelledQtyToOrder(order.orderHash, qtyCancelled);
        OrderCancelled(
            order.maker,
            order.feeRecipient,
            qtyCancelled,
            order.orderHash
        );

        return qtyCancelled;
    }

    // @notice called by a user after settlement has occurred.  This function will finalize all accounting around any
    // outstanding positions and return all remaining collateral to the caller. This should only be called after
    // settlement has occurred.
    function settleAndClose() external {
        require(isSettled);
        require(TOKEN_LOCKER.isUserLocked(address(this), msg.sender));
        settleAndClose(this, settlementPrice);
    }

    /// @notice allows a user to request an extra query to oracle in order to push the contract into
    /// settlement.  A user may call this as many times as they like, since they are the ones paying for
    /// the call to our oracle and post processing. This is useful for both a failsafe and as a way to
    /// settle a contract early if a price cap or floor has been breached.
    function requestEarlySettlement() external payable;

    /*
    // PUBLIC METHODS
    */

    /// @notice returns the qty that is no longer available to trade for a given order
    /// @param orderHash hash of order to find filled and cancelled qty
    /// @return int quantity that is no longer able to filled from the supplied order hash
    function getQtyFilledOrCancelledFromOrder(bytes32 orderHash) public view returns (int) {
        return orderMappings.getQtyFilledOrCancelledFromOrder(orderHash);
    }

    /// @notice removes token from users trading account
    /// @param withdrawAmount qty of token to attempt to withdraw
    function withdrawTokens(uint256 withdrawAmount) public {
         withdrawTokens(BASE_TOKEN, withdrawAmount);
    }

    /*
    // PRIVATE METHODS
    */

    /// @dev checks our last query price to see if our contract should enter settlement due to it being past our
    //  expiration date or outside of our tradeable ranges.
    function checkSettlement() internal {
        if (isSettled)   // already settled.
            return;

        if (now > EXPIRATION) {  // note: miners can cheat this by small increments of time (minutes, not hours)
            isSettled = true;   // time based expiration has occurred.
        } else if (lastPrice >= PRICE_CAP || lastPrice <= PRICE_FLOOR) {
            isSettled = true;   // we have breached/touched our pricing bands
        }

        if (isSettled) {
            settleContract(lastPrice);
        }
    }

    /// @dev records our final settlement price and fires needed events.
    /// @param finalSettlementPrice final query price at time of settlement
    function settleContract(uint finalSettlementPrice) private {
        settlementPrice = finalSettlementPrice;
        ContractSettled(finalSettlementPrice);
        // TODO: return any remaining ether balance to creator of this contract (no longer needs gas for queries)
    }
}