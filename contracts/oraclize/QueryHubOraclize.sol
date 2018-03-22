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

pragma solidity ^0.4.18;

import "./oraclizeAPI.sol";
import "./IQueryHub.sol";
import "./IQueryCallBack.sol";


/// @title Organizational hub for all oraclize query functionality.  Market Contracts set up their queries
/// directly via this smart contract which houses all of the oraclize functionality
/// @author Phil Elsasser <phil@marketprotocol.io>
contract QueryHubOraclize is usingOraclize, IQueryHub {

    mapping(bytes32 => address) queryIDToCallBackContractAddress;

    uint constant public QUERY_CALLBACK_GAS = 150000;  // this is ~30,000 over needed gas currently - some cushion here
    //uint constant public QUERY_CALLBACK_GAS_PRICE = 20000000000 wei; // 20 gwei - need to make this dynamic!

    // events
    event OracleQuerySuccess(address indexed marketContractAddress);
    event OracleQueryFailed(address indexed marketContractAddress);

    function QueryHubOraclize() public {
        oraclize_setProof(proofType_TLSNotary | proofStorage_IPFS);
        //oraclize_setCustomGasPrice(QUERY_CALLBACK_GAS_PRICE);  //TODO: allow this to be changed by creator.
    }

    /*
    // PUBLIC METHODS
    */

    /// @notice only public for callbacks from oraclize, do not call
    /// @param queryID of the returning query, this should match our own internal mapping
    /// @param result query to be processed
    /// @param proof result proof
    function __callback(bytes32 queryID, string result, bytes proof) public {
        require(msg.sender == oraclize_cbAddress());
        address contractAddress = queryIDToCallBackContractAddress[queryID];
        require(contractAddress != address(0)); // ensures a valid query id.
        IQueryCallback callBackContract = IQueryCallback(contractAddress);
        callBackContract.queryCallBack(queryID, result);
    }

    function queryOracleHub(
        string oracleDataSource,
        string oracleQuery,
        uint expiration
    ) public payable returns (bytes32) {
        require(oraclize_getPrice(oracleDataSource, QUERY_CALLBACK_GAS) > msg.value);
        bytes32 queryId = oraclize_query(
            expiration,
            oracleDataSource,
            oracleQuery,
            QUERY_CALLBACK_GAS
        );
        require(queryId != 0); // query was not created.
        queryIDToCallBackContractAddress[queryId] = msg.sender;
        return queryId;
    }

    function queryOracleHubOnDemand(
        string oracleDataSource,
        string oracleQuery
    ) public payable returns (bytes32) {
        require(oraclize_getPrice(oracleDataSource, QUERY_CALLBACK_GAS) > msg.value);
        bytes32 queryId = oraclize_query(
            oracleDataSource,
            oracleQuery,
            QUERY_CALLBACK_GAS
        );
        require(queryId != 0); // query was not created.
        queryIDToCallBackContractAddress[queryId] = msg.sender;
        return queryId;
    }

    function getQueryPrice(string dataSource) public returns (uint) {
        return oraclize_getPrice(dataSource, QUERY_CALLBACK_GAS);
    }
}
