import {NativeModule, requireNativeModule} from 'expo';

declare class RnNoirModule extends NativeModule {
  provePlonk: (
      trustedSetupUri: string,
      inputs: string,
      byteCode: string,
  ) => Promise<string>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<RnNoirModule>('RnNoir');