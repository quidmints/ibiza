import * as FileSystem from 'expo-file-system';
import {default as NoirModule} from './src/NoirModule';

export type NoirZKProof = {
    proof: string;
    pub_signals: string[];
};

export class NoirCircuitParams {
    public static readonly TrustedSetupFileName = `${FileSystem.documentDirectory}/noir/ultraPlonkTrustedSetup.dat`;

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
        const fileInfo = await FileSystem.getInfoAsync(
            NoirCircuitParams.TrustedSetupFileName,
        );

        if (!fileInfo.exists) {
            return null;
        }

        return fileInfo.uri;
    }

    static async downloadTrustedSetup(opts?: {
        onDownloadingProgress?: (p: FileSystem.DownloadProgressData) => void;
    }) {
        const dir = `${FileSystem.documentDirectory}noir`;

        // Ensure that the folder exists
        const dirInfo = await FileSystem.getInfoAsync(dir);
        if (!dirInfo.exists) {
            await FileSystem.makeDirectoryAsync(dir, {intermediates: true});
        }

        // Preparing path
        const fileUri = `${dir}/ultraPlonkTrustedSetup.dat`;
        const url =
            'https://storage.googleapis.com/rarimo-store/trusted-setups/ultraPlonkTrustedSetup.dat';

        // Continue downloading
        const downloadResumable = FileSystem.createDownloadResumable(
            url,
            fileUri,
            {},
            (progress) => {
                // DEBUG DOWNLOADING
                // console.log(
                //   `Progress: ${((progress.totalBytesWritten / progress.totalBytesExpectedToWrite) * 100).toFixed(1)}%`,
                // )
                opts?.onDownloadingProgress?.(progress);
            },
        );

        if (!(await NoirCircuitParams.getTrustedSetupUri())) {
            await downloadResumable.downloadAsync();
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

    static async getByteCodeUri(filename: string) {
        const fileInfo = await FileSystem.getInfoAsync(filename);

        if (!fileInfo.exists) {
            return null;
        }

        return fileInfo.uri;
    }

    async downloadByteCode(opts?: {
        onDownloadingProgress?: (
            downloadProgress: FileSystem.DownloadProgressData,
        ) => void;
    }): Promise<string> {
        const fileName = `${FileSystem.documentDirectory}/noir/${this.name}-bytecode.json`;
        const downloadResumable = FileSystem.createDownloadResumable(
            this.byteCodeUri,
            fileName,
            {},
            (downloadProgress) => {
                opts?.onDownloadingProgress?.(downloadProgress);
            },
        );

        if (!(await NoirCircuitParams.getByteCodeUri(fileName))) {
            await downloadResumable.downloadAsync();
        }

        const uri = await NoirCircuitParams.getByteCodeUri(fileName);

        if (!uri) {
            throw new Error(
                `Failed to download bytecode for noir circuit ${this.name}`,
            );
        }

        const byteCode = await FileSystem.readAsStringAsync(uri);

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
