// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IReceiveULN
 * @notice Interface for LayerZero's Receive Ultra Light Node
 */
interface IReceiveULN {
    
    /**
     * @notice Submit verification for a message
     * @param _packetHeader Packet header
     * @param _payloadHash Payload hash
     * @param _confirmations Number of confirmations
     */
    function verify(
        bytes calldata _packetHeader,
        bytes32 _payloadHash,
        uint64 _confirmations
    ) external;
    
    /**
     * @notice Check if a message has been verified
     * @param _headerHash Header hash
     * @param _payloadHash Payload hash
     * @return verified Whether message is verified
     */
    function isVerified(
        bytes32 _headerHash,
        bytes32 _payloadHash
    ) external view returns (bool verified);
    
    /**
     * @notice Get verification status for a message
     * @param _srcEid Source endpoint ID
     * @param _dstEid Destination endpoint ID  
     * @param _headerHash Header hash
     * @param _payloadHash Payload hash
     * @return verifiedBy Bitmap of DVNs that verified
     * @return requiredDVNs Required DVN count
     */
    function getVerificationStatus(
        uint32 _srcEid,
        uint32 _dstEid,
        bytes32 _headerHash,
        bytes32 _payloadHash
    ) external view returns (uint256 verifiedBy, uint256 requiredDVNs);
}