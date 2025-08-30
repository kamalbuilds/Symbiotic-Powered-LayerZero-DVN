import { ethers } from 'hardhat';
import { Contract } from 'ethers';
import * as fs from 'fs';
import * as path from 'path';

/**
 * Deployment script for Symbiotic-powered DVN
 */
async function main() {
    console.log('🚀 Starting Symbiotic DVN deployment...\n');

    // Get deployer account
    const [deployer] = await ethers.getSigners();
    console.log('📋 Deployer address:', deployer.address);
    console.log('💰 Deployer balance:', ethers.formatEther(await ethers.provider.getBalance(deployer.address)), 'ETH\n');

    // Load deployment configuration
    const config = loadDeploymentConfig();
    
    // Step 1: Deploy VotingPowerProvider
    console.log('1️⃣ Deploying VotingPowerProvider...');
    const VotingPowerProvider = await ethers.getContractFactory('VotingPowerProvider');
    const votingPowerProvider = await VotingPowerProvider.deploy(
        config.symbiotic.vaultFactory,
        config.symbiotic.operatorRegistry,
        config.symbiotic.networkId
    );
    await votingPowerProvider.waitForDeployment();
    console.log('✅ VotingPowerProvider deployed to:', await votingPowerProvider.getAddress());

    // Step 2: Deploy KeyRegistry
    console.log('\n2️⃣ Deploying KeyRegistry...');
    const KeyRegistry = await ethers.getContractFactory('KeyRegistry');
    const keyRegistry = await KeyRegistry.deploy();
    await keyRegistry.waitForDeployment();
    console.log('✅ KeyRegistry deployed to:', await keyRegistry.getAddress());

    // Step 3: Deploy ValSetDriver
    console.log('\n3️⃣ Deploying ValSetDriver...');
    const ValSetDriver = await ethers.getContractFactory('ValSetDriver');
    const valSetDriver = await ValSetDriver.deploy(
        await votingPowerProvider.getAddress(),
        await keyRegistry.getAddress(),
        config.symbiotic.quorumThreshold,
        config.symbiotic.minValidatorStake
    );
    await valSetDriver.waitForDeployment();
    console.log('✅ ValSetDriver deployed to:', await valSetDriver.getAddress());

    // Step 4: Deploy Settlement contract
    console.log('\n4️⃣ Deploying Settlement...');
    const Settlement = await ethers.getContractFactory('Settlement');
    const settlement = await Settlement.deploy(
        await valSetDriver.getAddress(),
        config.symbiotic.networkId
    );
    await settlement.waitForDeployment();
    console.log('✅ Settlement deployed to:', await settlement.getAddress());

    // Step 5: Deploy SymbioticDVN
    console.log('\n5️⃣ Deploying SymbioticDVN...');
    const SymbioticDVN = await ethers.getContractFactory('SymbioticDVN');
    const dvn = await SymbioticDVN.deploy(
        await settlement.getAddress(),
        config.symbiotic.networkId,
        await votingPowerProvider.getAddress(),
        config.symbiotic.minValidatorStake,
        config.symbiotic.quorumThreshold,
        config.dvn.worker,
        config.dvn.treasury
    );
    await dvn.waitForDeployment();
    const dvnAddress = await dvn.getAddress();
    console.log('✅ SymbioticDVN deployed to:', dvnAddress);

    // Step 6: Configure DVN for supported chains
    console.log('\n6️⃣ Configuring DVN for supported chains...');
    for (const chain of config.supportedChains) {
        console.log(`   📍 Configuring ${chain.name}...`);
        
        // Set ULN lookup
        await dvn.setUlnLookup(chain.eid, chain.ulnAddress);
        console.log(`      ✓ ULN set to ${chain.ulnAddress}`);
        
        // Set Message Library
        await dvn.setMessageLib(chain.eid, chain.messageLib);
        console.log(`      ✓ Message lib set to ${chain.messageLib}`);
        
        // Set fee configuration
        await dvn.setFeeConfig(
            chain.eid,
            ethers.parseEther(chain.baseFee),
            ethers.parseEther(chain.perByteRate),
            ethers.parseEther(chain.confirmationMultiplier)
        );
        console.log(`      ✓ Fee config set`);
    }

    // Step 7: Initialize validator set
    console.log('\n7️⃣ Initializing validator set...');
    if (config.initialValidators && config.initialValidators.length > 0) {
        for (const validator of config.initialValidators) {
            console.log(`   📝 Registering validator ${validator.address}...`);
            
            // Register BLS key in KeyRegistry
            await keyRegistry.registerOperator(
                validator.address,
                validator.blsPublicKey,
                validator.proofOfPossession
            );
            console.log(`      ✓ BLS key registered`);
        }
        
        // Update validator set in ValSetDriver
        const validatorAddresses = config.initialValidators.map(v => v.address);
        const votingPowers = await votingPowerProvider.getOperatorVotingPowers(validatorAddresses);
        await valSetDriver.updateValidatorSet(validatorAddresses, votingPowers);
        console.log('   ✅ Validator set initialized');
    }

    // Step 8: Set up cross-chain settlements
    console.log('\n8️⃣ Setting up cross-chain settlements...');
    for (const chain of config.crossChainSettlements) {
        console.log(`   🌉 Deploying Settlement on ${chain.name}...`);
        // This would deploy Settlement contracts on other chains
        // For now, we'll just log the configuration
        console.log(`      Chain ID: ${chain.chainId}`);
        console.log(`      RPC: ${chain.rpcUrl}`);
    }

    // Step 9: Save deployment addresses
    console.log('\n9️⃣ Saving deployment addresses...');
    const deploymentInfo = {
        network: config.network,
        timestamp: new Date().toISOString(),
        contracts: {
            votingPowerProvider: await votingPowerProvider.getAddress(),
            keyRegistry: await keyRegistry.getAddress(),
            valSetDriver: await valSetDriver.getAddress(),
            settlement: await settlement.getAddress(),
            symbioticDVN: dvnAddress
        },
        configuration: {
            symbioticNetworkId: config.symbiotic.networkId,
            quorumThreshold: config.symbiotic.quorumThreshold,
            minValidatorStake: config.symbiotic.minValidatorStake,
            supportedChains: config.supportedChains.map(c => ({
                name: c.name,
                eid: c.eid,
                chainId: c.chainId
            }))
        }
    };

    const deploymentPath = path.join(__dirname, '../deployments', `${config.network}.json`);
    fs.mkdirSync(path.dirname(deploymentPath), { recursive: true });
    fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));
    console.log('✅ Deployment info saved to:', deploymentPath);

    // Step 10: Verify contracts on Etherscan
    if (config.verifyContracts && config.etherscanApiKey) {
        console.log('\n🔟 Verifying contracts on Etherscan...');
        await verifyContracts(deploymentInfo.contracts, config);
    }

    console.log('\n✨ Deployment completed successfully!');
    console.log('📋 Summary:');
    console.log('   DVN Address:', dvnAddress);
    console.log('   Settlement Address:', await settlement.getAddress());
    console.log('   Supported Chains:', config.supportedChains.length);
    console.log('   Initial Validators:', config.initialValidators?.length || 0);
}

/**
 * Load deployment configuration
 */
function loadDeploymentConfig(): any {
    const configPath = path.join(__dirname, '../config/deployment.json');
    if (!fs.existsSync(configPath)) {
        throw new Error(`Deployment config not found at ${configPath}`);
    }
    return JSON.parse(fs.readFileSync(configPath, 'utf8'));
}

/**
 * Verify contracts on Etherscan
 */
async function verifyContracts(contracts: any, config: any): Promise<void> {
    const { run } = require('hardhat');
    
    for (const [name, address] of Object.entries(contracts)) {
        try {
            console.log(`   Verifying ${name} at ${address}...`);
            await run('verify:verify', {
                address: address,
                constructorArguments: getConstructorArgs(name, contracts, config)
            });
            console.log(`   ✅ ${name} verified`);
        } catch (error: any) {
            if (error.message.includes('Already Verified')) {
                console.log(`   ℹ️ ${name} already verified`);
            } else {
                console.log(`   ❌ Failed to verify ${name}:`, error.message);
            }
        }
    }
}

/**
 * Get constructor arguments for contract verification
 */
function getConstructorArgs(contractName: string, contracts: any, config: any): any[] {
    switch (contractName) {
        case 'votingPowerProvider':
            return [
                config.symbiotic.vaultFactory,
                config.symbiotic.operatorRegistry,
                config.symbiotic.networkId
            ];
        case 'keyRegistry':
            return [];
        case 'valSetDriver':
            return [
                contracts.votingPowerProvider,
                contracts.keyRegistry,
                config.symbiotic.quorumThreshold,
                config.symbiotic.minValidatorStake
            ];
        case 'settlement':
            return [
                contracts.valSetDriver,
                config.symbiotic.networkId
            ];
        case 'symbioticDVN':
            return [
                contracts.settlement,
                config.symbiotic.networkId,
                contracts.votingPowerProvider,
                config.symbiotic.minValidatorStake,
                config.symbiotic.quorumThreshold,
                config.dvn.worker,
                config.dvn.treasury
            ];
        default:
            return [];
    }
}

// Run deployment
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('❌ Deployment failed:', error);
        process.exit(1);
    });