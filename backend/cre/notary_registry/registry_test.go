// The first tests this workflow has ever had (sec. 2.18ao).
//
// WHY THIS FILE EXISTS. `backend/cre/notary_registry` is ~500 lines of OUR OWN code with no tests at
// all, and it decides WHO COUNTS AS A NOTARY. Since sec. 2.18am it is also load-bearing for privacy:
// the notary anonymity set is built from what this workflow publishes.
//
// WHAT CONSENSUS DOES NOT COVER. sec. 2.15a chose CRE over TLSNotary because
// `cre.ConsensusIdenticalAggregation` requires every DON node to produce a BYTE-IDENTICAL result.
// That protects against a rogue NODE. It does not protect against a PARSER THAT IS WRONG THE SAME
// WAY EVERYWHERE - every node agrees, and they agree on the wrong set. sec. 2.15a says as much
// ("scrapers rot"), and that is the part with no tests.
//
// THE DANGEROUS DIRECTION IS UNDER-COUNTING. A snapshot with EXTRA notaries would be caught by
// anyone comparing it against the public register. A snapshot MISSING real notaries silently removes
// their ability to act - censorship by parse error rather than by decision - and nobody downstream
// can tell the difference between "not a notary" and "the parser dropped you".
package main

import (
	"archive/zip"
	"bytes"
	"testing"
)

const twoActiveNotaries = `<?xml version="1.0" encoding="UTF-8"?>
<registry>
  <record><reg_number>123</reg_number><full_name>Jane Doe</full_name><region>Kyiv</region><status>active</status></record>
  <record><reg_number>456</reg_number><full_name>John Roe</full_name><region>Lviv</region><status>active</status></record>
</registry>`

func TestParsesAPlainXmlExport(t *testing.T) {
	records, err := parseRegistryExport([]byte(twoActiveNotaries))
	if err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	if len(records) != 2 {
		t.Fatalf("want 2 records, got %d", len(records))
	}
	if records[0].RegistrationNumber != "123" || records[0].FullName != "Jane Doe" ||
		records[0].Region != "Kyiv" || records[0].Status != "active" {
		t.Fatalf("fields did not land in the right struct members: %+v", records[0])
	}
}

// An export served as a .zip must parse identically - open-data catalogs commonly zip bulk exports,
// and the two paths must not disagree about what the register says.
func TestParsesAZippedExportIdentically(t *testing.T) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	f, err := zw.Create("registry.xml")
	if err != nil {
		t.Fatalf("build zip: %v", err)
	}
	if _, err := f.Write([]byte(twoActiveNotaries)); err != nil {
		t.Fatalf("write zip: %v", err)
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("close zip: %v", err)
	}

	zipped, err := parseRegistryExport(buf.Bytes())
	if err != nil {
		t.Fatalf("zipped parse failed: %v", err)
	}
	plain, err := parseRegistryExport([]byte(twoActiveNotaries))
	if err != nil {
		t.Fatalf("plain parse failed: %v", err)
	}

	zippedLeaves, err := activeLeaves(zipped)
	if err != nil {
		t.Fatalf("zipped active filter: %v", err)
	}
	plainLeaves, err := activeLeaves(plain)
	if err != nil {
		t.Fatalf("plain active filter: %v", err)
	}

	if merkleRoot(zippedLeaves) != merkleRoot(plainLeaves) {
		t.Fatal("the zipped and plain paths produced different roots for the same register")
	}
}

/*
 * SCHEMA ROT MUST FAIL LOUDLY, NOT QUIETLY.
 *
 * If the portal renames <record> or <registry>, Go's encoding/xml does NOT error - it returns zero
 * records, because unmarshalling into a struct simply finds nothing to fill. Every DON node would
 * do this identically and reach consensus on an empty register. The explicit zero-records check is
 * the only thing standing between a schema change and a published empty snapshot.
 */
func TestARenamedRecordElementIsRejectedRatherThanReturningNothing(t *testing.T) {
	renamed := `<registry><notary><reg_number>1</reg_number><status>active</status></notary></registry>`
	if _, err := parseRegistryExport([]byte(renamed)); err == nil {
		t.Fatal("a renamed record element parsed to zero records without an error - schema rot would be silent")
	}
}

func TestMalformedXmlIsRejected(t *testing.T) {
	if _, err := parseRegistryExport([]byte("<registry><record>")); err == nil {
		t.Fatal("truncated XML did not error")
	}
}

// A zip whose first entry is not the export (a README, a licence) must not be parsed as XML. The
// loop takes the FIRST non-directory file, so this pins what happens when that assumption breaks.
func TestAZipWhoseFirstEntryIsNotTheExportFailsRatherThanGuessing(t *testing.T) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	readme, _ := zw.Create("README.txt")
	readme.Write([]byte("bulk export of the notary register"))
	xmlFile, _ := zw.Create("registry.xml")
	xmlFile.Write([]byte(twoActiveNotaries))
	zw.Close()

	if _, err := parseRegistryExport(buf.Bytes()); err == nil {
		t.Fatal("a README ahead of the export parsed as XML without complaint")
	}
}

// ── the active filter: where a silent under-count would come from ───────────────────────────

func TestOnlyActiveNotariesBecomeLeaves(t *testing.T) {
	records := []NotaryRecordXML{
		{RegistrationNumber: "1", Status: "active"},
		{RegistrationNumber: "2", Status: "suspended"},
		{RegistrationNumber: "3", Status: "terminated"},
		{RegistrationNumber: "4", Status: "active"},
	}
	leaves, err := activeLeaves(records)
	if err != nil {
		t.Fatalf("known statuses must not error: %v", err)
	}
	if len(leaves) != 2 {
		t.Fatalf("want 2 active leaves, got %d", len(leaves))
	}
}

/*
 * THE CENSORSHIP-BY-PARSE-ERROR CASE, NOW FIXED (sec. 2.18ao).
 *
 * The filter used to compare exactly against "active", so a migrated portal emitting "Active"
 * dropped those notaries with NO error. Statuses are now normalised, so the same register survives
 * a casing change.
 */
func TestAStatusCasingChangeNoLongerDropsNotaries(t *testing.T) {
	records := []NotaryRecordXML{
		{RegistrationNumber: "1", Status: "active"},
		{RegistrationNumber: "2", Status: "Active"},
		{RegistrationNumber: "3", Status: "ACTIVE"},
		{RegistrationNumber: "4", Status: "  active  "},
	}
	leaves, err := activeLeaves(records)
	if err != nil {
		t.Fatalf("casing variants must not error: %v", err)
	}
	if len(leaves) != 4 {
		t.Fatalf("a casing change still drops notaries: want 4, got %d", len(leaves))
	}
}

/*
 * AND THE PART CASE-FOLDING ALONE WOULD NOT HAVE FIXED.
 *
 * If the register's vocabulary changes to something outside the known set - a Ukrainian-language
 * status, a new "inactive" - folding case admits nobody and the notary is silently omitted. That is
 * the same silent under-count in a different costume. An unknown status now REFUSES THE WHOLE
 * SNAPSHOT, so the failure is a visible outage a human fixes rather than a person quietly losing
 * the ability to act.
 */
func TestAnUnknownStatusRefusesTheSnapshotRatherThanOmittingTheNotary(t *testing.T) {
	records := []NotaryRecordXML{
		{RegistrationNumber: "1", Status: "active"},
		{RegistrationNumber: "2", Status: "\u0434\u0456\u044e\u0447\u0438\u0439"}, // "diyuchyi" - Ukrainian for active
	}
	if _, err := activeLeaves(records); err == nil {
		t.Fatal("an unrecognised status was silently skipped - that is censorship by parse error")
	}
}

func TestKnownInactiveStatusesAreSkippedWithoutError(t *testing.T) {
	records := []NotaryRecordXML{
		{RegistrationNumber: "1", Status: "active"},
		{RegistrationNumber: "2", Status: "Suspended"},
		{RegistrationNumber: "3", Status: "TERMINATED"},
	}
	leaves, err := activeLeaves(records)
	if err != nil {
		t.Fatalf("known inactive statuses must not error: %v", err)
	}
	if len(leaves) != 1 {
		t.Fatalf("want 1 active leaf, got %d", len(leaves))
	}
}

// ---- the Merkle root: it must agree with what the CONTRACT computes ------------------------

/*
 * THE ROOT IS ORDER-INDEPENDENT, which is what makes the workflow's output well-defined.
 *
 * `merkleRoot` sorts in place and hashes each pair in sorted order, so the register's own ordering
 * cannot change the answer. That matters because `RegistrySourceAnchor._computeRoot` recomputes the
 * root on-chain from the submitted leaves: if the two constructions disagreed about ordering, the
 * published root would not match the leaves that justify it.
 */
func TestTheRootDoesNotDependOnTheRegistersOrdering(t *testing.T) {
	a := [32]byte{1}
	b := [32]byte{2}
	c := [32]byte{3}

	forward := merkleRoot([][32]byte{a, b, c})
	backward := merkleRoot([][32]byte{c, b, a})
	shuffled := merkleRoot([][32]byte{b, a, c})

	if forward != backward || forward != shuffled {
		t.Fatal("the root depends on input order - the same register would publish different roots")
	}
}

func TestASingleLeafIsItsOwnRoot(t *testing.T) {
	only := [32]byte{7}
	if merkleRoot([][32]byte{only}) != only {
		t.Fatal("a one-notary register did not produce the leaf as its root")
	}
}

func TestAnEmptyRegisterProducesTheZeroRoot(t *testing.T) {
	if merkleRoot(nil) != ([32]byte{}) {
		t.Fatal("an empty leaf set did not produce the zero root")
	}
}

/*
 * CHANGING ANY FIELD CHANGES THE LEAF - the property the whole snapshot rests on.
 */
func TestEveryFieldIsBoundIntoTheLeaf(t *testing.T) {
	base := NotaryRecordXML{RegistrationNumber: "123", FullName: "Jane Doe", Region: "Kyiv", Status: "active"}
	h := leafHash(base)

	variants := map[string]NotaryRecordXML{
		"registration number": {RegistrationNumber: "124", FullName: "Jane Doe", Region: "Kyiv", Status: "active"},
		"full name":           {RegistrationNumber: "123", FullName: "Jane Roe", Region: "Kyiv", Status: "active"},
		"region":              {RegistrationNumber: "123", FullName: "Jane Doe", Region: "Lviv", Status: "active"},
		"status":              {RegistrationNumber: "123", FullName: "Jane Doe", Region: "Kyiv", Status: "suspended"},
	}
	for field, v := range variants {
		if leafHash(v) == h {
			t.Fatalf("changing the %s did not change the leaf", field)
		}
	}
}

/*
 * THE CONCATENATION AMBIGUITY, NOW FIXED (sec. 2.18ao).
 *
 * `leafHash` used to keccak the four fields concatenated with no separator, so reg "12" + name "3X"
 * hashed identically to reg "123" + name "X". Each field is now hashed first, making every part
 * fixed-width, so no boundary is ambiguous.
 */
func TestFieldsCannotBeReSplitAcrossTheRegNumberNameBoundary(t *testing.T) {
	left := NotaryRecordXML{RegistrationNumber: "12", FullName: "3X", Region: "Kyiv", Status: "active"}
	right := NotaryRecordXML{RegistrationNumber: "123", FullName: "X", Region: "Kyiv", Status: "active"}

	if leafHash(left) == leafHash(right) {
		t.Fatal("two different notaries still collide across the reg-number/name boundary")
	}
}

/*
 * THE SAME NOTARY LISTED TWICE MUST NOT BREAK THE SNAPSHOT (sec. 2.18ao).
 *
 * RegistrySourceAnchor requires STRICTLY ascending leaves, and sorting duplicates yields equal
 * neighbours rather than strict ascent - so one duplicated row upstream used to make the whole
 * country's snapshot unpublishable. A safe failure, but a liveness one.
 */
func TestDuplicateRecordsAreDeduplicated(t *testing.T) {
	dup := NotaryRecordXML{RegistrationNumber: "1", FullName: "Jane", Region: "Kyiv", Status: "active"}
	other := NotaryRecordXML{RegistrationNumber: "2", FullName: "John", Region: "Lviv", Status: "active"}

	leaves, err := activeLeaves([]NotaryRecordXML{dup, other, dup})
	if err != nil {
		t.Fatalf("duplicates must not error: %v", err)
	}
	if len(leaves) != 2 {
		t.Fatalf("want 2 deduplicated leaves, got %d", len(leaves))
	}
}

/*
 * AND THE PROPERTY DEDUPLICATION EXISTS FOR: the submitted leaves must be STRICTLY ascending, which
 * is what the contract checks. Sorting alone does not give that when duplicates are present.
 */
func TestSubmittedLeavesAreStrictlyAscending(t *testing.T) {
	dup := NotaryRecordXML{RegistrationNumber: "1", FullName: "Jane", Region: "Kyiv", Status: "active"}
	records := []NotaryRecordXML{dup, dup,
		{RegistrationNumber: "2", FullName: "John", Region: "Lviv", Status: "active"},
		{RegistrationNumber: "3", FullName: "Ann", Region: "Odesa", Status: "active"},
	}
	leaves, err := activeLeaves(records)
	if err != nil {
		t.Fatalf("active filter: %v", err)
	}
	merkleRoot(leaves) // sorts in place, exactly as onSchedule relies on before submitting

	for i := 1; i < len(leaves); i++ {
		if bytes.Compare(leaves[i-1][:], leaves[i][:]) >= 0 {
			t.Fatalf("leaves are not strictly ascending at %d - RegistrySourceAnchor would reject the snapshot", i)
		}
	}
}
