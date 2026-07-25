import {Directory, File, Paths} from 'expo-file-system';
import {default as NoirModule} from './src/NoirModule';

export type NoirZKProof = {
    proof: string;
    pub_signals: string[];
};

export class NoirCircuitParams {
    // expo-file-system 57's File/Directory API replaced the old string-path
    // (documentDirectory/getInfoAsync/createDownloadResumable) API entirely - `exists`/`create`
    // are synchronous properties/methods on File/Directory instances, not async calls.
    static readonly NoirDir = new Directory(Paths.document, 'noir');
    static readonly TrustedSetupFile = new File(NoirCircuitParams.NoirDir, 'ultraPlonkTrustedSetup.dat');

    constructor(
        public name: string,
        public byteCodeUri: string,
        public pub_signals_count: number,
    ) {
    }

    static fromName(circuitName: string): NoirCircuitParams {
        const found = supportedNoirCircuits.find((el) => el.name === circuitName);

        if (!found) {
            throw new Error(`Noir Circuit with name ${circuitName} not found`);
        }

        return found;
    }

    static async getTrustedSetupUri() {
        if (!NoirCircuitParams.TrustedSetupFile.exists) {
            return null;
        }

        return NoirCircuitParams.TrustedSetupFile.uri;
    }

    static async downloadTrustedSetup(opts?: {
        onDownloadingProgress?: (p: {bytesWritten: number; totalBytes: number}) => void;
    }) {
        if (!NoirCircuitParams.NoirDir.exists) {
            NoirCircuitParams.NoirDir.create({intermediates: true});
        }

        const url =
            'https://storage.googleapis.com/rarimo-store/trusted-setups/ultraPlonkTrustedSetup.dat';

        if (!(await NoirCircuitParams.getTrustedSetupUri())) {
            const task = File.createDownloadTask(url, NoirCircuitParams.TrustedSetupFile, {
                onProgress: opts?.onDownloadingProgress,
            });
            await task.downloadAsync();
        }

        const uri = await NoirCircuitParams.getTrustedSetupUri();

        if (!uri) {
            throw new Error('Failed to download trusted setup');
        }

        return uri;
    }

    public static formatArray(
        arr: string[] = [],
        useHex: boolean,
    ): string[] {
        const ensureHexPrefix = (val: string): string => {
            return val.startsWith('0x') ? val : `0x${val}`;
        };

        return arr.map(item => {
            const bigIntValue = BigInt(item);

            if (useHex) {
                return ensureHexPrefix(bigIntValue.toString(16));
            } else {
                return bigIntValue.toString(10);
            }
        })
    }

    static async getByteCodeUri(file: File) {
        if (!file.exists) {
            return null;
        }

        return file.uri;
    }

    async downloadByteCode(opts?: {
        onDownloadingProgress?: (p: {bytesWritten: number; totalBytes: number}) => void;
    }): Promise<string> {
        const file = new File(NoirCircuitParams.NoirDir, `${this.name}-bytecode.json`);

        if (!(await NoirCircuitParams.getByteCodeUri(file))) {
            const task = File.createDownloadTask(this.byteCodeUri, file, {
                onProgress: opts?.onDownloadingProgress,
            });
            await task.downloadAsync();
        }

        const uri = await NoirCircuitParams.getByteCodeUri(file);

        if (!uri) {
            throw new Error(
                `Failed to download bytecode for noir circuit ${this.name}`,
            );
        }

        const byteCode = await file.text();

        if (!byteCode) {
            throw new Error(`Failed to read bytecode for noir circuit ${this.name}`);
        }

        return byteCode;
    }

    async prove(inputs: string, byteCodeString: string): Promise<NoirZKProof> {
        const trustedSetupUri = await NoirCircuitParams.getTrustedSetupUri();

        if (!trustedSetupUri) {
            throw new Error('Trusted setup not found. Please download it first.');
        }

        const proof: string = await NoirModule.provePlonk(
            trustedSetupUri,
            inputs,
            byteCodeString,
        );

        if (!proof) {
            throw new Error(`Failed to generate proof for noir circuit ${this.name}`);
        }

        const pubSignalDataLength = 64; // hex

        const pubSignals: string[] = [];
        for (let i = 0; i < this.pub_signals_count; i++) {
            const start = i * pubSignalDataLength;
            const end = start + pubSignalDataLength;
            pubSignals.push(proof.substring(start, end));
        }

        const actualProof = proof.substring(
            pubSignalDataLength * this.pub_signals_count,
        );

        return {
            pub_signals: pubSignals,
            proof: actualProof,
        };
    }
}

const supportedNoirCircuits: NoirCircuitParams[] = [
    new NoirCircuitParams(
        'query_identity',
        'https://storage.googleapis.com/rarimo-store/passport-zk-circuits-noir/id_cards/query_identity_td1.json',
        24,
    ),
    new NoirCircuitParams(
        'register_light_160',
        'https://storage.googleapis.com/rarimo-store/passport-zk-circuits-noir/id_cards/register_lite_160.json',
        3,
    ),
    new NoirCircuitParams(
        'register_light_224',
        'https://storage.googleapis.com/rarimo-store/passport-zk-circuits-noir/id_cards/register_lite_224.json',
        3,
    ),
    new NoirCircuitParams(
        'register_light_256',
        'https://storage.googleapis.com/rarimo-store/passport-zk-circuits-noir/id_cards/register_lite_256.json',
        3,
    ),
    new NoirCircuitParams(
        'register_light_384',
        'https://storage.googleapis.com/rarimo-store/passport-zk-circuits-noir/id_cards/register_lite_384.json',
        3,
    ),
    new NoirCircuitParams(
        'register_light_512',
        'https://storage.googleapis.com/rarimo-store/passport-zk-circuits-noir/id_cards/register_lite_512.json',
        3,
    ),
]

export default NoirModule;
