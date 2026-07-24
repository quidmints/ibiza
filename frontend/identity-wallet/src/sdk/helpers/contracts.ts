import { Provider, Signer } from "ethers";
import {
  IDCardVoting__factory,
  RegistrationSimple__factory,
} from "../types/contracts";

type AbstractFactoryClass = {
  connect: (address: string, signerOrProvider: Signer | Provider) => unknown;
  createInterface: () => unknown;
};

type AbstractFactoryClassReturnType<F extends AbstractFactoryClass> = {
  contractInstance: ReturnType<F["connect"]>;
  contractInterface: ReturnType<F["createInterface"]>;
};

type RawProvider = Provider | Signer;

const createContract = <F extends AbstractFactoryClass>(
  address: string,
  rawProvider: RawProvider,
  factoryClass: F
): AbstractFactoryClassReturnType<F> => {
  const contractInstance = factoryClass.connect(
    address,
    rawProvider
  ) as ReturnType<F["connect"]>;

  const contractInterface = factoryClass.createInterface() as ReturnType<
    F["createInterface"]
  >;

  return {
    contractInstance,
    contractInterface,
  };
};

export const createRegistrationSimpleContract = (
  address: string,
  provider: RawProvider
) => {
  const { contractInstance, contractInterface } = createContract(
    address,
    provider,
    RegistrationSimple__factory
  );

  return {
    contractInstance,
    contractInterface,
  };
};

export const createIDCardVotingContract = (
  address: string,
  provider: RawProvider
) => {
  const { contractInstance, contractInterface } = createContract(
    address,
    provider,
    IDCardVoting__factory
  );

  return {
    contractInstance,
    contractInterface,
  };
};
