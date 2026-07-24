import React from "react";
import { SafeAreaView, ScrollView, Text, View, StyleSheet } from "react-native";

import { IdentityVault, IdentityVaultConfig } from "./src/identity/IdentityVault";
import { InMemoryIdentityVaultStore } from "./src/identity/store";
import { StoredDocument } from "./src/identity/IdentityVault";

// TODO(fork wiring): point these at OUR deployed HolderStateKeeper / HolderRegistration
// (app/contracts/holder) + our relayer/RPC. Placeholders until deploy.
const CONFIG: IdentityVaultConfig = {
  contractsConfiguration: {
    stateKeeperAddress: "0x0000000000000000000000000000000000000000",
    registerSimpleContractAddress: "0x0000000000000000000000000000000000000000",
    poseidonSmtAddress: "0x0000000000000000000000000000000000000000",
  },
  apiConfiguration: {
    jsonRpcEvmUrl: "https://rpc.example/holder-tree",
    rarimeApiUrl: "https://relayer.example",
  },
};

export default function App() {
  const vaultRef = React.useRef(new IdentityVault(CONFIG, new InMemoryIdentityVaultStore()));
  const [holderRoot, setHolderRoot] = React.useState<string>("…");
  const [docs, setDocs] = React.useState<StoredDocument[]>([]);
  const [citizenships, setCitizenships] = React.useState<string[]>([]);

  React.useEffect(() => {
    (async () => {
      const vault = vaultRef.current;
      const root = await vault.holderRoot();
      setHolderRoot(root.profileKey);
      setDocs(await vault.listDocuments());
      setCitizenships(await vault.citizenships());
    })();
  }, []);

  return (
    <SafeAreaView style={styles.safe}>
      <ScrollView contentContainerStyle={styles.container}>
        <Text style={styles.h1}>Identity Wallet</Text>
        <Text style={styles.subtle}>One holder key · many documents (multi-citizenship + renewal/revocation)</Text>

        <View style={styles.card}>
          <Text style={styles.label}>Holder root (the ONE key all documents bind to)</Text>
          <Text style={styles.mono} numberOfLines={1} ellipsizeMode="middle">0x{holderRoot}</Text>
        </View>

        <View style={styles.card}>
          <Text style={styles.label}>Citizenships ({citizenships.length})</Text>
          <Text style={styles.value}>{citizenships.length ? citizenships.join(", ") : "— (no current documents yet)"}</Text>
        </View>

        <Text style={styles.section}>Documents ({docs.length})</Text>
        {docs.length === 0 ? (
          <Text style={styles.subtle}>No documents. Scan a passport to add one (multi-citizenship: add several under the same holder key).</Text>
        ) : (
          docs.map((d) => (
            <View key={d.documentKey} style={styles.card}>
              <Text style={styles.value}>{d.docType}{d.country ? ` · ${d.country}` : ""}</Text>
              <Text style={styles.mono} numberOfLines={1} ellipsizeMode="middle">{d.documentKey}</Text>
              <Text style={styles.subtle}>status: {d.status}{d.notAfter ? ` · expires ${new Date(d.notAfter * 1000).toISOString().slice(0, 10)}` : ""}</Text>
            </View>
          ))
        )}

        <View style={styles.note}>
          <Text style={styles.noteText}>
            This shell drives <Text style={styles.bold}>IdentityVault</Text> (one-key-multiple-documents). Live add/renew/revoke need: (1) a scanned passport (RarimePassport from NFC), (2) OUR deployed HolderStateKeeper/HolderRegistration, (3) the forked query circuit for "current document". See README — three forks.
          </Text>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: "#0f1020" },
  container: { padding: 20, paddingBottom: 48 },
  h1: { color: "#fff", fontSize: 26, fontWeight: "800" },
  subtle: { color: "#8a8ab0", fontSize: 12.5, marginTop: 4, lineHeight: 18 },
  section: { color: "#cfcff0", fontSize: 15, fontWeight: "700", marginTop: 20, marginBottom: 6 },
  card: { backgroundColor: "#1a1b35", borderRadius: 12, padding: 14, marginTop: 10 },
  label: { color: "#9a9ac8", fontSize: 11, textTransform: "uppercase", letterSpacing: 0.5 },
  value: { color: "#fff", fontSize: 15, fontWeight: "600", marginTop: 2 },
  mono: { color: "#7ad7a0", fontSize: 12, fontFamily: "Courier", marginTop: 4 },
  note: { backgroundColor: "#241a08", borderLeftColor: "#c9851f", borderLeftWidth: 3, borderRadius: 8, padding: 12, marginTop: 22 },
  noteText: { color: "#e7c98a", fontSize: 12, lineHeight: 18 },
  bold: { fontWeight: "800", color: "#fff" },
});
