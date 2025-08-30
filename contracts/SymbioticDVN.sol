// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./interfaces/ILayerZeroDVN.sol";
import "./interfaces/ISymbioticIntegration.sol";
import "./interfaces/IReceiveULN.sol";
import { DVNOptions } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/libs/DVNOptions.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title SymbioticDVN
 * @notice Stake-backed DVN for LayerZero using Symbiotic's economic security
 * @dev Implements ILayerZeroDVN interface with Symbiotic settlement verification
 */
contract SymbioticDVN is ILayerZeroDVN, Ownable, ReentrancyGuard, Pausable {
    using DVNOptions for bytes;

    // ============ State Variables ============
    
    /// @notice Symbiotic settlement contract for signature verification
    address public immutable settlement;
    
    /// @notice Symbiotic network ID for this DVN
    uint256 public immutable symbioticNetworkId;
    
    /// @notice Voting power provider for stake calculations
    address public immutable votingPowerProvider;
    
    /// @notice Minimum stake required for validators
    uint256 public minValidatorStake;
    
    /// @notice Required quorum percentage (basis points, e.g., 6667 = 66.67%)
    uint256 public quorumThreshold;
    
    /// @notice Fee configuration per destination chain
    mapping(uint32 => FeeConfig) public feeConfigs;
    
    /// @notice Verification jobs assigned to this DVN
    mapping(bytes32 => VerificationJob) public verificationJobs;
    
    /// @notice Validator registry
    mapping(address => ValidatorInfo) public validators;
    
    /// @notice ULN addresses per chain
    mapping(uint32 => address) public ulnLookup;
    
    /// @notice Message lib addresses per chain
    mapping(uint32 => address) public messageLibs;
    
    /// @notice Supported chain IDs
    uint32[] public supportedChains;
    
    /// @notice Worker address that can submit verifications
    address public worker;
    
    /// @notice Treasury for fee collection
    address public treasury;
    
    // ============ Structs ============
    
    struct FeeConfig {
        uint256 baseFee;
        uint256 perByteRate;
        uint256 confirmationMultiplier;
        bool isActive;
    }
    
    struct VerificationJob {
        bytes32 headerHash;
        bytes32 payloadHash;
        uint64 confirmations;
        uint32 dstEid;
        address sender;
        uint256 fee;
        uint256 timestamp;
        bool verified;
        bytes additionalData;
    }
    
    struct ValidatorInfo {
        bool isActive;
        uint256 stake;
        uint256 lastUpdateBlock;
        bytes blsPublicKey;
    }
    
    // ============ Events ============
    
    event JobAssigned(
        bytes32 indexed jobId,
        uint32 indexed dstEid,
        bytes32 headerHash,
        bytes32 payloadHash,
        uint64 confirmations,
        address sender
    );
    
    event JobVerified(
        bytes32 indexed jobId,
        bytes32 indexed headerHash,
        bytes32 indexed payloadHash
    );
    
    event FeeConfigUpdated(
        uint32 indexed dstEid,
        uint256 baseFee,
        uint256 perByteRate,
        uint256 confirmationMultiplier
    );
    
    event ValidatorUpdated(
        address indexed validator,
        bool isActive,
        uint256 stake
    );
    
    event QuorumThresholdUpdated(uint256 newThreshold);
    event WorkerUpdated(address indexed newWorker);
    event TreasuryUpdated(address indexed newTreasury);
    
    // ============ Modifiers ============
    
    modifier onlyWorker() {
        require(msg.sender == worker, "DVN: unauthorized worker");
        _;
    }
    
    modifier onlyMessageLib(uint32 _srcEid) {
        require(msg.sender == messageLibs[_srcEid], "DVN: unauthorized message lib");
        _;
    }
    
    // ============ Constructor ============
    
    constructor(
        address _settlement,
        uint256 _symbioticNetworkId,
        address _votingPowerProvider,
        uint256 _minValidatorStake,
        uint256 _quorumThreshold,
        address _worker,
        address _treasury
    ) Ownable(msg.sender) {
        require(_settlement != address(0), "DVN: invalid settlement");
        require(_votingPowerProvider != address(0), "DVN: invalid voting provider");
        require(_quorumThreshold > 5000 && _quorumThreshold <= 10000, "DVN: invalid quorum");
        require(_worker != address(0), "DVN: invalid worker");
        require(_treasury != address(0), "DVN: invalid treasury");
        
        settlement = _settlement;
        symbioticNetworkId = _symbioticNetworkId;
        votingPowerProvider = _votingPowerProvider;
        minValidatorStake = _minValidatorStake;
        quorumThreshold = _quorumThreshold;
        worker = _worker;
        treasury = _treasury;
    }
    
    // ============ External Functions ============
    
    /**
     * @notice Assigns a verification job to this DVN
     * @dev Called by LayerZero's ULN when a message needs verification
     * @param _param Job parameters including packet header and payload hash
     * @param _options Additional options for verification
     * @return fee The fee charged for this verification job
     */
    function assignJob(
        AssignJobParam calldata _param,
        bytes calldata _options
    ) external payable override onlyMessageLib(_param.srcEid) returns (uint256 fee) {
        require(!paused(), "DVN: paused");
        
        // Calculate job ID
        bytes32 jobId = keccak256(abi.encode(
            _param.srcEid,
            _param.dstEid,
            _param.header,
            _param.payloadHash,
            _param.confirmations
        ));
        
        // Ensure job doesn't already exist
        require(verificationJobs[jobId].timestamp == 0, "DVN: job already exists");
        
        // Calculate and validate fee
        fee = _calculateFee(
            _param.dstEid,
            _param.confirmations,
            _param.sender,
            _options
        );
        require(msg.value >= fee, "DVN: insufficient fee");
        
        // Store verification job
        verificationJobs[jobId] = VerificationJob({
            headerHash: keccak256(_param.header),
            payloadHash: _param.payloadHash,
            confirmations: _param.confirmations,
            dstEid: _param.dstEid,
            sender: _param.sender,
            fee: fee,
            timestamp: block.timestamp,
            verified: false,
            additionalData: _options
        });
        
        // Transfer fee to treasury
        if (fee > 0) {
            (bool success, ) = treasury.call{value: fee}("");
            require(success, "DVN: fee transfer failed");
        }
        
        // Refund excess
        if (msg.value > fee) {
            (bool success, ) = msg.sender.call{value: msg.value - fee}("");
            require(success, "DVN: refund failed");
        }
        
        emit JobAssigned(
            jobId,
            _param.dstEid,
            verificationJobs[jobId].headerHash,
            _param.payloadHash,
            _param.confirmations,
            _param.sender
        );
        
        return fee;
    }
    
    /**
     * @notice Get fee quote for verification
     * @param _dstEid Destination endpoint ID
     * @param _confirmations Required confirmations
     * @param _sender Message sender
     * @param _options Additional options
     * @return fee The fee that would be charged
     */
    function getFee(
        uint32 _dstEid,
        uint64 _confirmations,
        address _sender,
        bytes calldata _options
    ) external view override returns (uint256 fee) {
        return _calculateFee(_dstEid, _confirmations, _sender, _options);
    }
    
    /**
     * @notice Submit verification with Symbiotic proof
     * @dev Called by worker after collecting signatures from validators
     * @param _jobId Job identifier
     * @param _symbioticProof Aggregated BLS signature proof from Symbiotic validators
     */
    function submitVerification(
        bytes32 _jobId,
        bytes calldata _symbioticProof
    ) external onlyWorker nonReentrant {
        VerificationJob storage job = verificationJobs[_jobId];
        require(job.timestamp > 0, "DVN: job not found");
        require(!job.verified, "DVN: already verified");
        
        // Verify the Symbiotic proof
        bool isValid = _verifySymbioticProof(
            job.headerHash,
            job.payloadHash,
            _symbioticProof
        );
        require(isValid, "DVN: invalid proof");
        
        // Mark as verified
        job.verified = true;
        
        // Submit verification to destination ULN
        address dstUln = ulnLookup[job.dstEid];
        require(dstUln != address(0), "DVN: destination ULN not set");
        
        // Call verify on destination ULN
        IReceiveULN(dstUln).verify(
            abi.encodePacked(job.headerHash),
            job.payloadHash,
            job.confirmations
        );
        
        emit JobVerified(_jobId, job.headerHash, job.payloadHash);
    }
    
    // ============ Admin Functions ============
    
    function setFeeConfig(
        uint32 _dstEid,
        uint256 _baseFee,
        uint256 _perByteRate,
        uint256 _confirmationMultiplier
    ) external onlyOwner {
        feeConfigs[_dstEid] = FeeConfig({
            baseFee: _baseFee,
            perByteRate: _perByteRate,
            confirmationMultiplier: _confirmationMultiplier,
            isActive: true
        });
        
        emit FeeConfigUpdated(_dstEid, _baseFee, _perByteRate, _confirmationMultiplier);
    }
    
    function setUlnLookup(uint32 _eid, address _uln) external onlyOwner {
        require(_uln != address(0), "DVN: invalid ULN");
        ulnLookup[_eid] = _uln;
    }
    
    function setMessageLib(uint32 _eid, address _messageLib) external onlyOwner {
        require(_messageLib != address(0), "DVN: invalid message lib");
        messageLibs[_eid] = _messageLib;
    }
    
    function setQuorumThreshold(uint256 _threshold) external onlyOwner {
        require(_threshold > 5000 && _threshold <= 10000, "DVN: invalid threshold");
        quorumThreshold = _threshold;
        emit QuorumThresholdUpdated(_threshold);
    }
    
    function setWorker(address _worker) external onlyOwner {
        require(_worker != address(0), "DVN: invalid worker");
        worker = _worker;
        emit WorkerUpdated(_worker);
    }
    
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "DVN: invalid treasury");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ============ Internal Functions ============
    
    function _calculateFee(
        uint32 _dstEid,
        uint64 _confirmations,
        address, // _sender (unused in basic implementation)
        bytes calldata _options
    ) internal view returns (uint256) {
        FeeConfig memory config = feeConfigs[_dstEid];
        require(config.isActive, "DVN: chain not supported");
        
        uint256 optionsLength = _options.length;
        uint256 fee = config.baseFee;
        
        // Add per-byte cost
        fee += optionsLength * config.perByteRate;
        
        // Add confirmation multiplier
        fee += uint256(_confirmations) * config.confirmationMultiplier;
        
        return fee;
    }
    
    function _verifySymbioticProof(
        bytes32 _headerHash,
        bytes32 _payloadHash,
        bytes calldata _proof
    ) internal view returns (bool) {
        // Decode the proof components
        (
            bytes memory aggregatedSignature,
            bytes memory nonSignerPubkeys,
            uint256 totalVotingPower,
            uint256 signedVotingPower
        ) = abi.decode(_proof, (bytes, bytes, uint256, uint256));
        
        // Check quorum is met
        uint256 requiredPower = (totalVotingPower * quorumThreshold) / 10000;
        if (signedVotingPower < requiredPower) {
            return false;
        }
        
        // Construct message hash
        bytes32 messageHash = keccak256(abi.encode(
            symbioticNetworkId,
            _headerHash,
            _payloadHash,
            block.chainid
        ));
        
        // Call settlement contract to verify the aggregated signature
        (bool success, bytes memory result) = settlement.staticcall(
            abi.encodeWithSignature(
                "verifySignature(bytes32,bytes,bytes)",
                messageHash,
                aggregatedSignature,
                nonSignerPubkeys
            )
        );
        
        return success && abi.decode(result, (bool));
    }
    
    // ============ View Functions ============
    
    function getJob(bytes32 _jobId) external view returns (VerificationJob memory) {
        return verificationJobs[_jobId];
    }
    
    function isJobVerified(bytes32 _jobId) external view returns (bool) {
        return verificationJobs[_jobId].verified;
    }
    
    function getSupportedChains() external view returns (uint32[] memory) {
        return supportedChains;
    }
}