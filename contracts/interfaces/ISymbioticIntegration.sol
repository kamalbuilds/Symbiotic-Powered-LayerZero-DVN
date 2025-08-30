// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title ISymbioticIntegration
 * @notice Interfaces for Symbiotic integration components
 */

interface ISettlement {
    function verifySignature(
        bytes32 messageHash,
        bytes calldata aggregatedSignature,
        bytes calldata nonSignerPubkeys
    ) external view returns (bool);
    
    function commitValSetHeader(
        uint256 epoch,
        bytes32 headerHash,
        bytes calldata proof
    ) external;
    
    function getLatestValSetHeader() external view returns (bytes32, uint256);
}

interface IVotingPowerProvider {
    function getOperatorVotingPowerAt(
        address operator,
        uint256 timestamp,
        bytes calldata hint
    ) external view returns (uint256);
    
    function getTotalVotingPowerAt(
        uint256 timestamp,
        bytes calldata hint
    ) external view returns (uint256);
    
    function getOperatorVotingPowers(
        address[] calldata operators
    ) external view returns (uint256[] memory);
}

interface IKeyRegistry {
    function getOperatorKey(
        address operator
    ) external view returns (bytes memory blsKey, bool isActive);
    
    function registerKey(
        bytes calldata blsPublicKey,
        bytes calldata proofOfPossession
    ) external;
}

interface IValSetDriver {
    struct ValidatorSet {
        address[] validators;
        uint256[] votingPowers;
        uint256 totalVotingPower;
        uint256 epoch;
        bytes32 merkleRoot;
    }
    
    function getCurrentValidatorSet() external view returns (ValidatorSet memory);
    
    function getValidatorSetAt(
        uint256 epoch
    ) external view returns (ValidatorSet memory);
    
    function updateValidatorSet(
        address[] calldata validators,
        uint256[] calldata votingPowers
    ) external;
}

interface INetwork {
    function getNetworkId() external view returns (uint256);
    
    function getQuorumThreshold() external view returns (uint256);
    
    function getMinValidatorStake() external view returns (uint256);
    
    function isOperatorRegistered(address operator) external view returns (bool);
}