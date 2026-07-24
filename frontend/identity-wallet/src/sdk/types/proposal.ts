export interface ProposalQuestion {
  title: string;
  description?: string;
  variants: string[];
}

export interface ProposalCriteria {
  selector: bigint; //bit mask for criteria check
  citizenshipWhitelist: bigint[]; // array of bigint-encoded ASCII with country codes
  timestampUpperbound: bigint; //timestamp 
  identityCountUpperbound: bigint;
  sex: bigint; //ASCII-char bigint encoded 
  birthDateLowerbound: bigint; //mrz format date bigint encoded 
  birthDateUpperbound: bigint; //mrz format date bigint encoded 
  expirationDateLowerbound: bigint; //mrz format date bigint encoded 
}

export interface ProposalInfo {
  id: string;
  proposalSmtAddress: string;
  criteria: ProposalCriteria;
  startTimestamp: bigint;
  duration: bigint;
  imageCID: string;
  sendVoteContractAddress: string;
  title: string;
  description?: string;
  questions: ProposalQuestion[];
  rankingBased?: boolean;
  votingResults: bigint[][];
}
