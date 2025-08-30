// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title ILayerZeroDVN
 * @notice Interface for LayerZero Decentralized Verifier Network
 */
interface ILayerZeroDVN {
    
    struct AssignJobParam {
        uint32 srcEid;
        uint32 dstEid;
        bytes header;
        bytes32 payloadHash;
        uint64 confirmations;
        address sender;
    }
    
    /**
     * @notice Assign a verification job to the DVN
     * @param _param Job parameters
     * @param _options Additional options
     * @return fee Fee charged for verification
     */
    function assignJob(
        AssignJobParam calldata _param,
        bytes calldata _options
    ) external payable returns (uint256 fee);
    
    /**
     * @notice Get fee quote for verification
     * @param _dstEid Destination endpoint ID
     * @param _confirmations Required confirmations
     * @param _sender Message sender
     * @param _options Additional options
     * @return fee Fee that would be charged
     */
    function getFee(
        uint32 _dstEid,
        uint64 _confirmations,
        address _sender,
        bytes calldata _options
    ) external view returns (uint256 fee);
}