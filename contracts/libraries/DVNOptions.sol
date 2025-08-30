// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title DVNOptions
 * @notice Library for parsing DVN options from bytes
 */
library DVNOptions {
    uint8 internal constant OPTION_TYPE_PRIORITY = 1;
    uint8 internal constant OPTION_TYPE_EXPIRY = 2;
    uint8 internal constant OPTION_TYPE_CUSTOM = 3;
    
    struct Options {
        uint8 priority;
        uint256 expiry;
        bytes customData;
    }
    
    /**
     * @notice Parse options from bytes
     * @param _options Raw options bytes
     * @return opts Parsed options struct
     */
    function parseOptions(bytes calldata _options) internal pure returns (Options memory opts) {
        if (_options.length == 0) {
            return Options(1, 0, "");
        }
        
        uint256 offset = 0;
        while (offset < _options.length) {
            uint8 optionType = uint8(_options[offset]);
            offset += 1;
            
            if (optionType == OPTION_TYPE_PRIORITY) {
                opts.priority = uint8(_options[offset]);
                offset += 1;
            } else if (optionType == OPTION_TYPE_EXPIRY) {
                opts.expiry = uint256(bytes32(_options[offset:offset + 32]));
                offset += 32;
            } else if (optionType == OPTION_TYPE_CUSTOM) {
                uint256 length = uint256(uint8(_options[offset]));
                offset += 1;
                opts.customData = _options[offset:offset + length];
                offset += length;
            } else {
                // Skip unknown option types
                offset += 1;
            }
        }
        
        return opts;
    }
    
    /**
     * @notice Encode options to bytes
     * @param _priority Priority level
     * @param _expiry Expiry timestamp
     * @param _customData Custom data bytes
     * @return options Encoded options
     */
    function encodeOptions(
        uint8 _priority,
        uint256 _expiry,
        bytes memory _customData
    ) internal pure returns (bytes memory options) {
        uint256 totalLength = 0;
        
        if (_priority > 0) {
            totalLength += 2; // type + value
        }
        if (_expiry > 0) {
            totalLength += 33; // type + 32 bytes
        }
        if (_customData.length > 0) {
            totalLength += 2 + _customData.length; // type + length + data
        }
        
        options = new bytes(totalLength);
        uint256 offset = 0;
        
        if (_priority > 0) {
            options[offset] = bytes1(OPTION_TYPE_PRIORITY);
            options[offset + 1] = bytes1(_priority);
            offset += 2;
        }
        
        if (_expiry > 0) {
            options[offset] = bytes1(OPTION_TYPE_EXPIRY);
            bytes32 expiryBytes = bytes32(_expiry);
            for (uint256 i = 0; i < 32; i++) {
                options[offset + 1 + i] = expiryBytes[i];
            }
            offset += 33;
        }
        
        if (_customData.length > 0) {
            options[offset] = bytes1(OPTION_TYPE_CUSTOM);
            options[offset + 1] = bytes1(uint8(_customData.length));
            for (uint256 i = 0; i < _customData.length; i++) {
                options[offset + 2 + i] = _customData[i];
            }
        }
        
        return options;
    }
}