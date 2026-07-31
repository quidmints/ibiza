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
	plain, _ := parseRegistryExport([]byte(twoActiveNotaries))

	if merkleRoot(activeLeaves(zipped)) != merkleRoot(activeLeaves(plain)) {
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
	if got := len(activeLeaves(records)); got != 2 {
		t.Fatalf("want 2 active leaves, got %d", got)
	}
}

/*
 * THE CENSORSHIP-BY-PARSE-ERROR CASE, PINNED AS CURRENT BEHAVIOUR.
 *
 * The status test is an EXACT string compare against "active". A register that starts emitting
 * "Active", "ACTIVE", " active" or a Ukrainian-language status drops those notaries SILENTLY. Total
 * failure is caught - `onSchedule` refuses to publish an empty root - but a PARTIAL change is not,
 * and a mixed-casing export is exactly how a partial change arrives.
 *
 * This is not a hypothetical about a hostile registrar; it is what happens when a portal is
 * migrated. Recorded as a test rather than "fixed" by lowercasing, because case-folding would be a
 * GUESS about the register's vocabulary: if the real status set turns out to be Ukrainian, folding
 * ASCII case admits nobody extra and hides that the mapping was never verified. What is needed is
 * the actual status vocabulary from a real export - see task #12, which has to answer the same
 * question per country anyway.
 */
func TestAStatusCasingChangeSilentlyDropsNotaries(t *testing.T) {
	records := []NotaryRecordXML{
		{RegistrationNumber: "1", Status: "active"},
		{RegistrationNumber: "2", Status: "Active"}, // same register, migrated portal
		{RegistrationNumber: "3", Status: "ACTIVE"},
	}
	got := len(activeLeaves(records))
	if got != 1 {
		t.Fatalf(
			"want 1 (current exact-match behaviour), got %d - if this now returns 3 the matching was "+
				"relaxed; confirm the real status vocabulary first and update sec. 2.18ao",
			got,
		)
	}
}

// ── the Merkle root: it must agree with what the CONTRACT computes ──────────────────────────

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
 *
 * `leafHash` concatenates reg number, name, region and status. If two different notaries could
 * collide, or if a status change did not move the leaf, a revoked notary would stay provably active.
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
 * FIELD CONCATENATION IS AMBIGUOUS - a real (if narrow) collision, recorded rather than assumed away.
 *
 * `leafHash` keccaks the four fields CONCATENATED with no separator, so two different records whose
 * fields split differently at the same boundary hash identically. Here reg "12" + name "3X" and reg
 * "123" + name "X" produce the same bytes.
 *
 * WHY IT IS NOT URGENT: registration numbers are numeric and names are not, so the boundary is not
 * reachable with real data. WHY IT IS STILL WRONG: that is an argument about the DATA, not about the
 * construction, and it stops holding the moment a register uses alphanumeric registration numbers -
 * which task #12's other jurisdictions may well do. The fix is a length-prefixed or delimited
 * encoding, and it must land BEFORE a second country, since it changes every leaf.
 */
func TestFieldConcatenationIsAmbiguousAcrossTheRegNumberNameBoundary(t *testing.T) {
	left := NotaryRecordXML{RegistrationNumber: "12", FullName: "3X", Region: "Kyiv", Status: "active"}
	right := NotaryRecordXML{RegistrationNumber: "123", FullName: "X", Region: "Kyiv", Status: "active"}

	if leafHash(left) != leafHash(right) {
		t.Fatal("the concatenation ambiguity is FIXED - adopt a delimited encoding note in sec. 2.18ao and delete this test")
	}
}

/*
 * DUPLICATE RECORDS PRODUCE DUPLICATE LEAVES, which the CONTRACT rejects.
 *
 * `RegistrySourceAnchor` requires strictly ascending leaves, and sorting duplicates yields equal
 * neighbours rather than strict ascent - so a register that lists one notary twice makes the whole
 * snapshot unpublishable. That is a safe failure (loud, not silent) but it is a LIVENESS risk: one
 * duplicated row upstream stops every notary in the country from being refreshed. Deduplication
 * belongs in `activeLeaves`; this test states today's behaviour so the fix has a target.
 */
func TestDuplicateRecordsAreNotDeduplicated(t *testing.T) {
	dup := NotaryRecordXML{RegistrationNumber: "1", FullName: "Jane", Region: "Kyiv", Status: "active"}
	leaves := activeLeaves([]NotaryRecordXML{dup, dup})

	if len(leaves) != 2 || leaves[0] != leaves[1] {
		t.Fatal("duplicates are now deduplicated - good; update sec. 2.18ao and delete this test")
	}
}
