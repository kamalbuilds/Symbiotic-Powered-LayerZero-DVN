// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./interfaces/ISymbioticIntegration.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title VotingPowerProvider
 * @notice Manages voting power calculation from Symbiotic vaults
 * @dev Integrates with Symbiotic Core to derive validator voting power from staked assets
 */
contract VotingPowerProvider is IVotingPowerProvider, AccessControl {
    
    // ============ Constants ============
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");
    
    // ============ State Variables ============
    
    /// @notice Symbiotic vault factory address
    address public immutable vaultFactory;
    
    /// @notice Symbiotic operator registry
    address public immutable operatorRegistry;
    
    /// @notice Network ID for this voting power provider
    uint256 public immutable networkId;
    
    /// @notice Mapping of operator to their registered vaults
    mapping(address => address[]) public operatorVaults;
    
    /// @notice Mapping of vault to its weight multiplier (basis points)
    mapping(address => uint256) public vaultWeights;
    
    /// @notice Mapping of operator to custom voting power overrides
    mapping(address => VotingPowerOverride) public votingPowerOverrides;
    
    /// @notice Total number of registered operators
    uint256 public totalOperators;
    
    /// @notice Minimum stake required for voting power
    uint256 public minStakeRequired;
    
    /// @notice Maximum voting power cap per operator (basis points)
    uint256 public maxVotingPowerCap;
    
    // ============ Structs ============
    
    struct VotingPowerOverride {
        bool isActive;
        uint256 customPower;
        uint256 expiryTimestamp;
        string reason;
    }
    
    struct VaultInfo {
        address vaultAddress;
        uint256 weight;
        bool isActive;
        uint256 addedAt;
    }
    
    // ============ Events ============
    
    event VaultRegistered(address indexed vault, uint256 weight);
    event VaultWeightUpdated(address indexed vault, uint256 newWeight);
    event VaultRemoved(address indexed vault);
    event OperatorVaultAdded(address indexed operator, address indexed vault);
    event VotingPowerOverrideSet(address indexed operator, uint256 customPower, uint256 expiry);
    event MinStakeRequiredUpdated(uint256 newMinStake);
    event MaxVotingPowerCapUpdated(uint256 newCap);
    
    // ============ Constructor ============
    
    constructor(
        address _vaultFactory,
        address _operatorRegistry,
        uint256 _networkId
    ) {
        require(_vaultFactory != address(0), "VPP: invalid vault factory");
        require(_operatorRegistry != address(0), "VPP: invalid operator registry");
        
        vaultFactory = _vaultFactory;
        operatorRegistry = _operatorRegistry;
        networkId = _networkId;
        
        minStakeRequired = 100 * 10**18; // 100 tokens minimum
        maxVotingPowerCap = 2000; // 20% max per operator
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(VAULT_MANAGER_ROLE, msg.sender);
    }
    
    // ============ External Functions ============
    
    /**
     * @notice Get operator voting power at specific timestamp
     * @param operator Operator address
     * @param timestamp Timestamp for historical query
     * @param hint Hint data for efficient vault queries
     * @return votingPower The operator's voting power
     */
    function getOperatorVotingPowerAt(
        address operator,
        uint256 timestamp,
        bytes calldata hint
    ) external view override returns (uint256 votingPower) {
        // Check for override first
        VotingPowerOverride memory override_ = votingPowerOverrides[operator];
        if (override_.isActive && block.timestamp < override_.expiryTimestamp) {
            return override_.customPower;
        }
        
        // Calculate from vaults
        address[] memory vaults = operatorVaults[operator];
        uint256 totalPower = 0;
        
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 vaultPower = _getVaultPowerAt(vaults[i], operator, timestamp, hint);
            uint256 weight = vaultWeights[vaults[i]];
            
            if (weight == 0) {
                weight = 10000; // Default 100% weight
            }
            
            totalPower += (vaultPower * weight) / 10000;
        }
        
        // Apply minimum stake requirement
        if (totalPower < minStakeRequired) {
            return 0;
        }
        
        // Apply maximum cap
        uint256 totalVotingPower = _getTotalVotingPowerInternal(timestamp, hint);
        uint256 maxAllowed = (totalVotingPower * maxVotingPowerCap) / 10000;
        
        if (totalPower > maxAllowed) {
            return maxAllowed;
        }
        
        return totalPower;
    }
    
    /**
     * @notice Get total voting power at specific timestamp
     * @param timestamp Timestamp for historical query
     * @param hint Hint data for efficient queries
     * @return totalPower The total voting power across all operators
     */
    function getTotalVotingPowerAt(
        uint256 timestamp,
        bytes calldata hint
    ) external view override returns (uint256 totalPower) {
        return _getTotalVotingPowerInternal(timestamp, hint);
    }
    
    /**
     * @notice Get voting power for multiple operators
     * @param operators Array of operator addresses
     * @return powers Array of voting powers
     */
    function getOperatorVotingPowers(
        address[] calldata operators
    ) external view override returns (uint256[] memory powers) {
        powers = new uint256[](operators.length);
        
        for (uint256 i = 0; i < operators.length; i++) {
            powers[i] = this.getOperatorVotingPowerAt(
                operators[i],
                block.timestamp,
                ""
            );
        }
        
        return powers;
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Register a new vault with weight
     * @param vault Vault address
     * @param weight Weight multiplier in basis points
     */
    function registerVault(
        address vault,
        uint256 weight
    ) external onlyRole(VAULT_MANAGER_ROLE) {
        require(vault != address(0), "VPP: invalid vault");
        require(weight > 0 && weight <= 20000, "VPP: invalid weight"); // Max 200% weight
        
        vaultWeights[vault] = weight;
        emit VaultRegistered(vault, weight);
    }
    
    /**
     * @notice Update vault weight
     * @param vault Vault address
     * @param newWeight New weight in basis points
     */
    function updateVaultWeight(
        address vault,
        uint256 newWeight
    ) external onlyRole(VAULT_MANAGER_ROLE) {
        require(vaultWeights[vault] > 0, "VPP: vault not registered");
        require(newWeight > 0 && newWeight <= 20000, "VPP: invalid weight");
        
        vaultWeights[vault] = newWeight;
        emit VaultWeightUpdated(vault, newWeight);
    }
    
    /**
     * @notice Add vault to operator's voting power calculation
     * @param operator Operator address
     * @param vault Vault address
     */
    function addOperatorVault(
        address operator,
        address vault
    ) external onlyRole(OPERATOR_ROLE) {
        require(operator != address(0), "VPP: invalid operator");
        require(vault != address(0), "VPP: invalid vault");
        require(vaultWeights[vault] > 0, "VPP: vault not registered");
        
        // Check if already added
        address[] memory currentVaults = operatorVaults[operator];
        for (uint256 i = 0; i < currentVaults.length; i++) {
            require(currentVaults[i] != vault, "VPP: vault already added");
        }
        
        operatorVaults[operator].push(vault);
        
        if (currentVaults.length == 0) {
            totalOperators++;
        }
        
        emit OperatorVaultAdded(operator, vault);
    }
    
    /**
     * @notice Set voting power override for operator
     * @param operator Operator address
     * @param customPower Custom voting power
     * @param duration Override duration in seconds
     * @param reason Reason for override
     */
    function setVotingPowerOverride(
        address operator,
        uint256 customPower,
        uint256 duration,
        string calldata reason
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(operator != address(0), "VPP: invalid operator");
        require(duration > 0 && duration <= 30 days, "VPP: invalid duration");
        
        uint256 expiry = block.timestamp + duration;
        
        votingPowerOverrides[operator] = VotingPowerOverride({
            isActive: true,
            customPower: customPower,
            expiryTimestamp: expiry,
            reason: reason
        });
        
        emit VotingPowerOverrideSet(operator, customPower, expiry);
    }
    
    /**
     * @notice Clear voting power override
     * @param operator Operator address
     */
    function clearVotingPowerOverride(address operator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete votingPowerOverrides[operator];
    }
    
    /**
     * @notice Update minimum stake requirement
     * @param newMinStake New minimum stake
     */
    function setMinStakeRequired(uint256 newMinStake) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minStakeRequired = newMinStake;
        emit MinStakeRequiredUpdated(newMinStake);
    }
    
    /**
     * @notice Update maximum voting power cap
     * @param newCap New cap in basis points
     */
    function setMaxVotingPowerCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newCap >= 500 && newCap <= 5000, "VPP: invalid cap"); // 5% to 50%
        maxVotingPowerCap = newCap;
        emit MaxVotingPowerCapUpdated(newCap);
    }
    
    // ============ Internal Functions ============
    
    /**
     * @notice Get vault power for operator at timestamp
     */
    function _getVaultPowerAt(
        address vault,
        address operator,
        uint256 timestamp,
        bytes calldata hint
    ) internal view returns (uint256) {
        // Call Symbiotic vault to get operator's stake
        (bool success, bytes memory data) = vault.staticcall(
            abi.encodeWithSignature(
                "activeSharesOfAt(address,uint256,bytes)",
                operator,
                timestamp,
                hint
            )
        );
        
        if (!success) {
            return 0;
        }
        
        return abi.decode(data, (uint256));
    }
    
    /**
     * @notice Calculate total voting power internally
     */
    function _getTotalVotingPowerInternal(
        uint256 timestamp,
        bytes calldata hint
    ) internal view returns (uint256) {
        // In production, this would aggregate across all registered operators
        // For now, return a placeholder
        return 1000000 * 10**18; // 1M tokens total
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get operator's registered vaults
     * @param operator Operator address
     * @return vaults Array of vault addresses
     */
    function getOperatorVaults(address operator) external view returns (address[] memory) {
        return operatorVaults[operator];
    }
    
    /**
     * @notice Check if operator has minimum stake
     * @param operator Operator address
     * @return hasMinStake Whether operator meets minimum stake
     */
    function hasMinimumStake(address operator) external view returns (bool) {
        uint256 power = this.getOperatorVotingPowerAt(operator, block.timestamp, "");
        return power >= minStakeRequired;
    }
    
    /**
     * @notice Get vault information
     * @param vault Vault address
     * @return info Vault information struct
     */
    function getVaultInfo(address vault) external view returns (VaultInfo memory) {
        return VaultInfo({
            vaultAddress: vault,
            weight: vaultWeights[vault],
            isActive: vaultWeights[vault] > 0,
            addedAt: block.timestamp // Would track this in production
        });
    }
}