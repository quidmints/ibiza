export interface QueryProofParams {
  eventId: string;
  eventData: string;
  selector: string;
  timestampLowerbound: string;
  timestampUpperbound: string;
  identityCountLowerbound: string;
  identityCountUpperbound: string;
  birthDateLowerbound: string;
  birthDateUpperbound: string;
  expirationDateLowerbound: string;
  expirationDateUpperbound: string;
  citizenshipMask: string;
}
