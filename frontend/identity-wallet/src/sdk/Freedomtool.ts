import {
  AbiCoder,
  JsonRpcProvider,
  keccak256,
  toBeHex,
  toBigInt,
  zeroPadValue,
} from "ethers";
import {
  IDCardVoting__factory,
  PoseidonSMT__factory,
  ProposalsState,
  ProposalsState__factory,
  QueryProofParams,
  StateKeeper,
} from "./types";
import { ProposalInfo, ProposalQuestion } from "./types/proposal";
import { BaseVoting } from "./types/contracts/IDCardVoting";
import { Rarime } from "./Rarime";
import { RarimePassport } from "./RarimePassport";
import { Time } from "@distributedlab/tools";
import { createIDCardVotingContract } from "./helpers/contracts";
import { NoirZKProof } from "./RnNoirModule";

const ROOT_VALIDITY = 3600n;
const UINT32_MAX = 2n ** 32n - 1n;
const UINT64_MAX = 2n ** 64n - 1n;

export const MRZ_ZERO_DATE = 52983525027888n; // "000000"
export interface FreedomToolAPIConfiguration {
  ipfsUrl: string;
  votingRelayerUrl: string;
  votingRpcUrl: string;
}

export interface SubmitProposalParams {
  answers: number[];
  proposalInfo: ProposalInfo;
  rarime: Rarime;
  passport: RarimePassport;
}

interface IPFSProposalMetadata {
  title: string;
  description?: string;
  acceptedOptions: ProposalQuestion[];
  imageCid?: string;
  rankingBased?: boolean;
}

export interface FreedomToolContractsConfiguration {
  proposalStateAddress: string;
}

export interface FreedomToolConfiguration {
  contracts: FreedomToolContractsConfiguration;
  api: FreedomToolAPIConfiguration;
}

export class FreedomTool {
  private config: FreedomToolConfiguration;

  constructor(config: FreedomToolConfiguration) {
    this.config = config;
  }

  public async getProposalInfo(proposalId: string): Promise<ProposalInfo> {
    const contractData = await this.getProposalInfoFromContracts(proposalId);

    const ipfsData = await this.getProposalMetadata(contractData[2][4]);

    const proposalCriteria = await this.getProposalRules(
      proposalId,
      contractData[2][5][0]
    );

    const proposalInfo: ProposalInfo = {
      id: proposalId,
      proposalSmtAddress: contractData[0],
      criteria: {
        selector: proposalCriteria[0],
        citizenshipWhitelist: proposalCriteria[1],
        timestampUpperbound: proposalCriteria[2],
        identityCountUpperbound: proposalCriteria[3],
        sex: proposalCriteria[4],
        birthDateLowerbound: proposalCriteria[5],
        birthDateUpperbound: proposalCriteria[6],
        expirationDateLowerbound: proposalCriteria[7],
      },
      rankingBased: ipfsData.rankingBased ?? false,
      startTimestamp: contractData[2][0],
      duration: contractData[2][1],
      imageCID: ipfsData.imageCid ?? "",
      sendVoteContractAddress: contractData[2][5][0],
      title: ipfsData.title,
      questions: ipfsData.acceptedOptions,
      votingResults: contractData[3],
      description: ipfsData.description ?? "",
    };

    return proposalInfo;
  }

  public async isAlreadyVoted(
    proposalInfo: ProposalInfo,
    rarime: Rarime
  ): Promise<boolean> {
    const provider = new JsonRpcProvider(this.config.api.votingRpcUrl);

    const proposalsState = ProposalsState__factory.connect(
      this.config.contracts.proposalStateAddress,
      provider
    );

    const eventId = await proposalsState.getProposalEventId(proposalInfo.id);

    const nullifier = rarime.getEventNullifier(eventId);

    const poseidonSmt = PoseidonSMT__factory.connect(
      proposalInfo.proposalSmtAddress,
      provider
    );

    const smtProof = await poseidonSmt.getProof(nullifier);

    return smtProof[2];
  }

  public async verify(
    proposalInfo: ProposalInfo,
    passport: RarimePassport,
    rarime: Rarime
  ) {
    let nowTimestamp = new Time().timestamp;

    if (nowTimestamp < proposalInfo.startTimestamp) {
      throw new Error("Voting has not started.");
    }

    if (nowTimestamp > proposalInfo.startTimestamp + proposalInfo.duration) {
      throw new Error("Voting has ended.");
    }

    passport.verifyPassport(proposalInfo);

    if (await this.isAlreadyVoted(proposalInfo, rarime)) {
      throw new Error("User has already voted");
    }
  }

  public async submitProposal({
    answers,
    proposalInfo: proposalInfo,
    rarime,
    passport,
  }: SubmitProposalParams): Promise<string> {
    await this.verify(proposalInfo, passport, rarime);

    const passportInfo = await rarime.getPassportInfo(passport);

    const queryProofParams = await this.buildQueryProofParams(
      answers,
      proposalInfo,
      passportInfo
    );

    const queryProof = await rarime.generateQueryProof(
      queryProofParams,
      passport
    );

    const txCallData = await this.buildProposalCallData(
      answers,
      proposalInfo,
      rarime,
      passport,
      queryProof,
      passportInfo
    );

    const txHash = await this.sendProposalRequest(txCallData, proposalInfo);

    return txHash;
  }

  private async getProposalRules(
    proposalId: string,
    sendVoteContractAddress: string
  ): Promise<BaseVoting.ProposalRulesStructOutput> {
    const provider = new JsonRpcProvider(this.config.api.votingRpcUrl);

    const contract = IDCardVoting__factory.connect(
      sendVoteContractAddress,
      provider
    );

    return contract.getProposalRules(proposalId);
  }

  private async getProposalInfoFromContracts(
    proposalId: string
  ): Promise<ProposalsState.ProposalInfoStructOutput> {
    const provider = new JsonRpcProvider(this.config.api.votingRpcUrl);

    const contract = ProposalsState__factory.connect(
      this.config.contracts.proposalStateAddress,
      provider
    );

    return contract.getProposalInfo(proposalId);
  }

  private async getProposalMetadata(
    ipfsCid: string
  ): Promise<IPFSProposalMetadata> {
    const ipfsResponse = await fetch(
      this.config.api.ipfsUrl + `/ipfs/` + ipfsCid,
      {
        method: "GET",
        headers: {
          "Content-Type": "application/json",
        },
      }
    );

    if (!ipfsResponse.ok) {
      throw new Error(`HTTP error ${ipfsResponse.status}`);
    }

    return ipfsResponse.json();
  }

  private getEventData(votes: number[]): string {
    // 2) ABI‑encode as an array of (uint256,uint256) structs
    const abiCoder = AbiCoder.defaultAbiCoder();
    const encoded = abiCoder.encode(["uint256[]"], [votes.map((v) => 1 << v)]);

    // 3) Take keccak256 hash
    const hashHex = keccak256(encoded);

    // 4) Cast to BigInt
    const hashBn = toBigInt(hashHex);

    // 5) Mask down to 248 bits: (1<<248) - 1
    const mask = (BigInt(1) << BigInt(248)) - BigInt(1);
    const truncated = hashBn & mask;

    // 6) Zero‑pad up to 32 bytes (uint256) and return hex
    return zeroPadValue(toBeHex(truncated), 32);
  }

  private async getEventId(proposalInfo: ProposalInfo): Promise<bigint> {
    const provider = new JsonRpcProvider(this.config.api.votingRpcUrl);

    const proposalsState = ProposalsState__factory.connect(
      this.config.contracts.proposalStateAddress,
      provider
    );

    return proposalsState.getProposalEventId(proposalInfo.id);
  }

  private async buildQueryProofParams(
    answers: number[],
    proposalInfo: ProposalInfo,
    passportInfo: [
      StateKeeper.PassportInfoStructOutput,
      StateKeeper.IdentityInfoStructOutput
    ]
  ): Promise<QueryProofParams> {
    const eventId = await this.getEventId(proposalInfo);

    const eventData = this.getEventData(answers);

    let timestampUpperbound =
      proposalInfo.criteria.timestampUpperbound - ROOT_VALIDITY;

    let identityCounterUpperBound = UINT32_MAX;

    if (passportInfo[1][1] > proposalInfo.criteria.timestampUpperbound) {
      timestampUpperbound = UINT64_MAX - 1n;
      identityCounterUpperBound = proposalInfo.criteria.identityCountUpperbound;
    }

    const queryProofParams: QueryProofParams = {
      eventId: eventId.toString(),
      eventData: eventData,
      selector: proposalInfo.criteria.selector.toString(),
      timestampLowerbound: "0",
      timestampUpperbound: timestampUpperbound.toString(),
      identityCountLowerbound: "0",
      identityCountUpperbound: identityCounterUpperBound.toString(),
      birthDateLowerbound: proposalInfo.criteria.birthDateLowerbound.toString(),
      birthDateUpperbound: proposalInfo.criteria.birthDateUpperbound.toString(),
      expirationDateLowerbound:
        proposalInfo.criteria.expirationDateLowerbound.toString(),
      expirationDateUpperbound: MRZ_ZERO_DATE.toString(),
      citizenshipMask: "0",
    };

    return queryProofParams;
  }

  private async buildProposalCallData(
    answers: number[],
    proposalInfo: ProposalInfo,
    rarime: Rarime,
    passport: RarimePassport,
    queryProof: NoirZKProof,
    passportInfo: [
      StateKeeper.PassportInfoStructOutput,
      StateKeeper.IdentityInfoStructOutput
    ]
  ): Promise<string> {
    let identityCreationTimestamp = 0n;

    if (passportInfo[1][1] > proposalInfo.criteria.timestampUpperbound) {
      identityCreationTimestamp = UINT64_MAX - 1n;
    }
    
    const idCardVoting = createIDCardVotingContract(
      proposalInfo.sendVoteContractAddress,
      new JsonRpcProvider(this.config.api.votingRpcUrl)
    );

    const abiCode = new AbiCoder();
    const userDataEncoded = abiCode.encode(
      ["uint256", "uint256[]", "tuple(uint256,uint256,uint256)"],
      [
        proposalInfo.id,
        // votes mask
        answers.map((v) => 1 << Number(v)),
        // User payload: (nullifier, citizenship, identity_creation_timestamp)
        [
          "0x" + queryProof.pub_signals[0],
          "0x" + queryProof.pub_signals[6],
          identityCreationTimestamp,
        ],
      ]
    );

    const smtProof = await rarime.getSMTProof(passport);

    const txCallData = idCardVoting.contractInterface.encodeFunctionData(
      "executeTD1Noir",
      [
        smtProof.root,
        "0x" + queryProof.pub_signals[14],
        userDataEncoded,
        "0x" + queryProof.proof,
      ]
    );

    return txCallData;
  }

  private async sendProposalRequest(
    txCallData: string,
    proposalInfo: ProposalInfo
  ): Promise<string> {
    const sendVoteRequest = {
      data: {
        attributes: {
          tx_data: txCallData,
          destination: proposalInfo.sendVoteContractAddress,
        },
      },
    };

    const sendVoteResponse = await fetch(
      this.config.api.votingRelayerUrl +
        "/integrations/proof-verification-relayer/v3/vote",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(sendVoteRequest),
      }
    );

    if (!sendVoteResponse.ok) {
      throw new Error(`HTTP error ${sendVoteResponse.status}`);
    }

    const sendVoteResponseParsed = await sendVoteResponse.json();

    return sendVoteResponseParsed.data.id;
  }
}
