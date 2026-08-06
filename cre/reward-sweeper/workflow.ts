import {
	bytesToHex,
	cre,
	encodeCallMsg,
	getNetwork,
	LAST_FINALIZED_BLOCK_NUMBER,
	prepareReportRequest,
	TxStatus,
	type Runtime,
} from '@chainlink/cre-sdk'
import {
	type Address,
	decodeFunctionResult,
	encodeAbiParameters,
	encodeFunctionData,
	parseAbiParameters,
	zeroAddress,
} from 'viem'
import { z } from 'zod'

// ─── Config Schema ──────────────────────────────────────────
export const configSchema = z.object({
	schedule: z.string(),
	evms: z.array(
		z.object({
			chainSelectorName: z.string(),
			// LivepeerRewardCaller v1 (immutable, permissionless) on Arbitrum One.
			rewardCaller: z.string(),
			// LivepeerSweepReceiver bridge (forwards the DON-signed report to
			// rewardCaller.rewardAll). Zero address = not deployed yet: the workflow
			// then reports what it WOULD do instead of writing.
			receiver: z.string(),
			gasLimit: z.string(),
		}),
	),
})
type Config = z.infer<typeof configSchema>

// Minimal ABI of the reads this workflow performs against LivepeerRewardCaller.
const RewardCallerABI = [
	{
		type: 'function',
		name: 'getPendingRewardCalls',
		inputs: [],
		outputs: [{ name: 'pending', type: 'address[]' }],
		stateMutability: 'view',
	},
] as const

// ─── Callback ───────────────────────────────────────────────
export const onCronTrigger = (runtime: Runtime<Config>): string => {
	const evmConfig = runtime.config.evms[0]

	// 1. Network + EVM client (Arbitrum One — mainnet, not testnet)
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: evmConfig.chainSelectorName,
		isTestnet: false,
	})
	if (!network) throw new Error(`Network not found: ${evmConfig.chainSelectorName}`)

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	// 2. Read: who would a sweep attempt right now?
	const callData = encodeFunctionData({
		abi: RewardCallerABI,
		functionName: 'getPendingRewardCalls',
	})
	const readResult = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: evmConfig.rewardCaller as Address,
				data: callData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()
	const pending = decodeFunctionResult({
		abi: RewardCallerABI,
		functionName: 'getPendingRewardCalls',
		data: bytesToHex(readResult.data),
	}) as readonly Address[]

	runtime.log(`livepeer.bot sweep check: ${pending.length} pending reward call(s)`)
	if (pending.length > 0) {
		runtime.log(`pending: ${pending.slice(0, 5).join(', ')}${pending.length > 5 ? ', …' : ''}`)
	}

	// 3. Conditional: nothing pending -> no write, no cost. The contract itself is
	//    idempotent, but skipping here keeps CRE executions nearly free on the
	//    ~5-of-6 daily firings where another layer already swept.
	if (pending.length === 0) {
		runtime.log('No pending reward calls. Skipping execution.')
		return 'Skipped — nothing pending'
	}

	// 4. Write path: DON-signed report -> LivepeerSweepReceiver -> rewardAll(0,0).
	//    Until the receiver bridge is deployed on Arbitrum, log intent and exit.
	if (evmConfig.receiver === zeroAddress) {
		runtime.log(
			`Receiver bridge not deployed yet — would execute rewardAll(0,0) for ${pending.length} pending subscriber(s).`,
		)
		return `Pending: ${pending.length} — receiver bridge not yet deployed`
	}

	const reportData = encodeAbiParameters(parseAbiParameters('bool executeSweep'), [true])
	const reportResponse = runtime.report(prepareReportRequest(reportData)).result()
	const writeResult = evmClient
		.writeReport(runtime, {
			receiver: evmConfig.receiver as Address,
			report: reportResponse,
			gasConfig: { gasLimit: evmConfig.gasLimit },
		})
		.result()

	if (writeResult.txStatus !== TxStatus.SUCCESS) {
		throw new Error(`Sweep TX failed: ${writeResult.errorMessage || writeResult.txStatus}`)
	}

	const txHash = bytesToHex(writeResult.txHash || new Uint8Array(32))
	runtime.log(`Sweep executed for ${pending.length} pending subscriber(s). TX: ${txHash}`)
	return `Executed — tx: ${txHash}`
}

// ─── Workflow Init ──────────────────────────────────────────
export function initWorkflow(config: Config) {
	const cronTrigger = new cre.capabilities.CronCapability()

	return [cre.handler(cronTrigger.trigger({ schedule: config.schedule }), onCronTrigger)]
}
