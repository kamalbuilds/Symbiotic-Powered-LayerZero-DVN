import { ethers } from 'ethers';
import { EventEmitter } from 'events';
import axios from 'axios';

/**
 * DVN Worker Service
 * Monitors LayerZero events and coordinates with Symbiotic relay for verification
 */
export class DVNWorker extends EventEmitter {
    private provider: ethers.Provider;
    private signer: ethers.Wallet;
    private dvnContract: ethers.Contract;
    private relayClient: RelayClient;
    private jobQueue: Map<string, VerificationJob>;
    private isRunning: boolean = false;

    constructor(config: DVNWorkerConfig) {
        super();
        this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
        this.signer = new ethers.Wallet(config.privateKey, this.provider);
        this.dvnContract = new ethers.Contract(
            config.dvnAddress,
            DVN_ABI,
            this.signer
        );
        this.relayClient = new RelayClient(config.relayEndpoint);
        this.jobQueue = new Map();
    }

    /**
     * Start the DVN worker service
     */
    async start(): Promise<void> {
        if (this.isRunning) {
            throw new Error('Worker already running');
        }

        this.isRunning = true;
        console.log('🚀 DVN Worker starting...');

        // Start monitoring for job assignments
        await this.startJobMonitoring();

        // Start verification processing loop
        this.startVerificationLoop();

        // Start health monitoring
        this.startHealthMonitoring();

        console.log('✅ DVN Worker started successfully');
    }

    /**
     * Monitor for JobAssigned events from DVN contract
     */
    private async startJobMonitoring(): Promise<void> {
        const filter = this.dvnContract.filters.JobAssigned();
        
        this.dvnContract.on(filter, async (
            jobId: string,
            dstEid: number,
            headerHash: string,
            payloadHash: string,
            confirmations: bigint,
            sender: string,
            event: ethers.Log
        ) => {
            console.log(`📋 New job assigned: ${jobId}`);
            
            const job: VerificationJob = {
                jobId,
                dstEid,
                headerHash,
                payloadHash,
                confirmations: Number(confirmations),
                sender,
                blockNumber: event.blockNumber,
                transactionHash: event.transactionHash,
                status: 'pending',
                attempts: 0,
                timestamp: Date.now()
            };

            this.jobQueue.set(jobId, job);
            this.emit('jobReceived', job);

            // Start verification immediately
            this.processVerification(job);
        });
    }

    /**
     * Process verification for a job
     */
    private async processVerification(job: VerificationJob): Promise<void> {
        try {
            console.log(`🔍 Processing verification for job ${job.jobId}`);
            
            // Step 1: Fetch source chain block data
            const sourceBlockData = await this.fetchSourceChainData(job);
            
            // Step 2: Request signature aggregation from Symbiotic relay
            const aggregatedProof = await this.requestSymbioticSignatures(job, sourceBlockData);
            
            // Step 3: Submit verification to DVN contract
            await this.submitVerification(job, aggregatedProof);
            
            // Update job status
            job.status = 'completed';
            this.emit('jobCompleted', job);
            
            console.log(`✅ Job ${job.jobId} verified successfully`);
        } catch (error) {
            console.error(`❌ Verification failed for job ${job.jobId}:`, error);
            job.status = 'failed';
            job.attempts++;
            
            // Retry if under max attempts
            if (job.attempts < 3) {
                setTimeout(() => this.processVerification(job), 5000 * job.attempts);
            } else {
                this.emit('jobFailed', job, error);
            }
        }
    }

    /**
     * Fetch source chain block data for verification
     */
    private async fetchSourceChainData(job: VerificationJob): Promise<SourceChainData> {
        // Connect to source chain RPC
        const sourceProvider = this.getProviderForChain(job.dstEid);
        
        // Fetch block containing the message
        const block = await sourceProvider.getBlock(job.blockNumber);
        if (!block) {
            throw new Error(`Block ${job.blockNumber} not found`);
        }

        // Fetch transaction receipt
        const receipt = await sourceProvider.getTransactionReceipt(job.transactionHash);
        if (!receipt) {
            throw new Error(`Transaction ${job.transactionHash} not found`);
        }

        // Extract relevant logs
        const relevantLogs = receipt.logs.filter(log => 
            log.topics[0] === ethers.id('PacketSent(bytes,bytes,address)')
        );

        return {
            blockNumber: block.number,
            blockHash: block.hash!,
            blockTimestamp: block.timestamp,
            transactionHash: job.transactionHash,
            logs: relevantLogs,
            merkleProof: await this.generateMerkleProof(receipt, block)
        };
    }

    /**
     * Request signature aggregation from Symbiotic relay network
     */
    private async requestSymbioticSignatures(
        job: VerificationJob,
        sourceData: SourceChainData
    ): Promise<AggregatedProof> {
        console.log(`📡 Requesting signatures from Symbiotic relay...`);

        // Construct validation request
        const validationRequest = {
            networkId: await this.getSymbioticNetworkId(),
            messageHash: ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
                ['bytes32', 'bytes32', 'uint256'],
                [job.headerHash, job.payloadHash, sourceData.blockNumber]
            )),
            sourceChainId: this.getChainIdForEndpoint(job.dstEid),
            blockData: {
                number: sourceData.blockNumber,
                hash: sourceData.blockHash,
                timestamp: sourceData.blockTimestamp
            },
            proof: sourceData.merkleProof
        };

        // Send to relay for signature collection
        const response = await this.relayClient.requestSignatures(validationRequest);

        // Wait for aggregation to complete
        const aggregatedProof = await this.waitForAggregation(response.requestId);

        // Validate the aggregated proof
        if (!this.validateAggregatedProof(aggregatedProof, job)) {
            throw new Error('Invalid aggregated proof received');
        }

        return aggregatedProof;
    }

    /**
     * Submit verification to DVN contract
     */
    private async submitVerification(
        job: VerificationJob,
        proof: AggregatedProof
    ): Promise<void> {
        console.log(`📝 Submitting verification for job ${job.jobId}...`);

        // Encode the proof for contract
        const encodedProof = ethers.AbiCoder.defaultAbiCoder().encode(
            ['bytes', 'bytes', 'uint256', 'uint256'],
            [
                proof.aggregatedSignature,
                proof.nonSignerPubkeys,
                proof.totalVotingPower,
                proof.signedVotingPower
            ]
        );

        // Submit to DVN contract
        const tx = await this.dvnContract.submitVerification(
            job.jobId,
            encodedProof,
            {
                gasLimit: 500000 // Adjust based on testing
            }
        );

        console.log(`📤 Verification transaction sent: ${tx.hash}`);

        // Wait for confirmation
        const receipt = await tx.wait();
        
        if (receipt.status !== 1) {
            throw new Error(`Transaction failed: ${tx.hash}`);
        }

        console.log(`✅ Verification confirmed in block ${receipt.blockNumber}`);
    }

    /**
     * Wait for signature aggregation to complete
     */
    private async waitForAggregation(requestId: string): Promise<AggregatedProof> {
        const maxAttempts = 30;
        const pollInterval = 2000; // 2 seconds

        for (let i = 0; i < maxAttempts; i++) {
            const status = await this.relayClient.getAggregationStatus(requestId);

            if (status.completed) {
                return status.proof!;
            }

            if (status.failed) {
                throw new Error(`Aggregation failed: ${status.error}`);
            }

            // Check if we have enough signatures
            if (status.signatures && status.signatures.length > 0) {
                const votingPowerPercentage = (status.signedVotingPower / status.totalVotingPower) * 100;
                console.log(`⏳ Aggregation progress: ${votingPowerPercentage.toFixed(2)}% voting power`);
            }

            await new Promise(resolve => setTimeout(resolve, pollInterval));
        }

        throw new Error('Aggregation timeout');
    }

    /**
     * Validate aggregated proof
     */
    private validateAggregatedProof(proof: AggregatedProof, job: VerificationJob): boolean {
        // Check signature format
        if (!proof.aggregatedSignature || proof.aggregatedSignature === '0x') {
            return false;
        }

        // Check voting power meets quorum
        const quorumThreshold = 0.667; // 66.7%
        const votingPowerRatio = proof.signedVotingPower / proof.totalVotingPower;
        
        if (votingPowerRatio < quorumThreshold) {
            console.warn(`⚠️ Insufficient voting power: ${(votingPowerRatio * 100).toFixed(2)}%`);
            return false;
        }

        // Verify the signature corresponds to the correct message
        const expectedMessageHash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
            ['bytes32', 'bytes32'],
            [job.headerHash, job.payloadHash]
        ));

        // Additional validation would go here
        return true;
    }

    /**
     * Start verification processing loop
     */
    private startVerificationLoop(): void {
        setInterval(() => {
            // Process any pending jobs
            for (const [jobId, job] of this.jobQueue) {
                if (job.status === 'pending' && job.attempts < 3) {
                    const timeSinceCreation = Date.now() - job.timestamp;
                    
                    // Retry stale jobs
                    if (timeSinceCreation > 30000) { // 30 seconds
                        console.log(`🔄 Retrying stale job ${jobId}`);
                        this.processVerification(job);
                    }
                }
            }

            // Clean up old completed jobs
            const oneHourAgo = Date.now() - 3600000;
            for (const [jobId, job] of this.jobQueue) {
                if (job.timestamp < oneHourAgo && job.status === 'completed') {
                    this.jobQueue.delete(jobId);
                }
            }
        }, 10000); // Check every 10 seconds
    }

    /**
     * Start health monitoring
     */
    private startHealthMonitoring(): void {
        setInterval(async () => {
            try {
                // Check contract connectivity
                const networkId = await this.dvnContract.symbioticNetworkId();
                
                // Check relay connectivity
                const relayHealth = await this.relayClient.health();
                
                // Emit health status
                this.emit('healthCheck', {
                    timestamp: Date.now(),
                    contractConnected: !!networkId,
                    relayConnected: relayHealth.status === 'healthy',
                    pendingJobs: Array.from(this.jobQueue.values()).filter(j => j.status === 'pending').length,
                    completedJobs: Array.from(this.jobQueue.values()).filter(j => j.status === 'completed').length
                });
            } catch (error) {
                console.error('❌ Health check failed:', error);
                this.emit('healthCheckFailed', error);
            }
        }, 30000); // Every 30 seconds
    }

    /**
     * Stop the DVN worker
     */
    async stop(): Promise<void> {
        this.isRunning = false;
        await this.dvnContract.removeAllListeners();
        console.log('🛑 DVN Worker stopped');
    }

    // Helper methods
    private getProviderForChain(endpointId: number): ethers.Provider {
        // Map endpoint IDs to RPC URLs
        const rpcUrls: Record<number, string> = {
            101: process.env.ETH_RPC_URL || 'https://eth.llamarpc.com',
            102: process.env.BSC_RPC_URL || 'https://bsc-dataseed.binance.org/',
            106: process.env.AVAX_RPC_URL || 'https://api.avax.network/ext/bc/C/rpc',
            109: process.env.POLYGON_RPC_URL || 'https://polygon-rpc.com/',
            110: process.env.ARBITRUM_RPC_URL || 'https://arb1.arbitrum.io/rpc',
            111: process.env.OPTIMISM_RPC_URL || 'https://mainnet.optimism.io'
        };

        const rpcUrl = rpcUrls[endpointId];
        if (!rpcUrl) {
            throw new Error(`No RPC URL configured for endpoint ${endpointId}`);
        }

        return new ethers.JsonRpcProvider(rpcUrl);
    }

    private getChainIdForEndpoint(endpointId: number): number {
        const chainIds: Record<number, number> = {
            101: 1,     // Ethereum
            102: 56,    // BSC
            106: 43114, // Avalanche
            109: 137,   // Polygon
            110: 42161, // Arbitrum
            111: 10     // Optimism
        };

        return chainIds[endpointId] || 1;
    }

    private async getSymbioticNetworkId(): Promise<bigint> {
        return await this.dvnContract.symbioticNetworkId();
    }

    private async generateMerkleProof(
        receipt: ethers.TransactionReceipt,
        block: ethers.Block
    ): Promise<string> {
        // Generate Merkle proof for the transaction in the block
        // This would use a Merkle tree library in production
        return '0x' + '00'.repeat(32); // Placeholder
    }
}

// Type definitions
interface DVNWorkerConfig {
    rpcUrl: string;
    privateKey: string;
    dvnAddress: string;
    relayEndpoint: string;
}

interface VerificationJob {
    jobId: string;
    dstEid: number;
    headerHash: string;
    payloadHash: string;
    confirmations: number;
    sender: string;
    blockNumber: number;
    transactionHash: string;
    status: 'pending' | 'processing' | 'completed' | 'failed';
    attempts: number;
    timestamp: number;
}

interface SourceChainData {
    blockNumber: number;
    blockHash: string;
    blockTimestamp: number;
    transactionHash: string;
    logs: ethers.Log[];
    merkleProof: string;
}

interface AggregatedProof {
    aggregatedSignature: string;
    nonSignerPubkeys: string;
    totalVotingPower: number;
    signedVotingPower: number;
}

// Relay client for Symbiotic integration
class RelayClient {
    constructor(private endpoint: string) {}

    async requestSignatures(request: any): Promise<{ requestId: string }> {
        const response = await axios.post(`${this.endpoint}/signatures/request`, request);
        return response.data;
    }

    async getAggregationStatus(requestId: string): Promise<any> {
        const response = await axios.get(`${this.endpoint}/signatures/status/${requestId}`);
        return response.data;
    }

    async health(): Promise<{ status: string }> {
        const response = await axios.get(`${this.endpoint}/health`);
        return response.data;
    }
}

// Contract ABI (simplified)
const DVN_ABI = [
    'event JobAssigned(bytes32 indexed jobId, uint32 indexed dstEid, bytes32 headerHash, bytes32 payloadHash, uint64 confirmations, address sender)',
    'function submitVerification(bytes32 jobId, bytes calldata proof) external',
    'function symbioticNetworkId() view returns (uint256)'
];

export default DVNWorker;