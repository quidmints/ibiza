// Pure sanctions-list logic: decode a published export, canonicalise it, build the Merkle root.
//
// NO `//go:build wasip1` TAG, DELIBERATELY. `main.go` is WASM-only because it links the CRE runtime,
// which meant none of the logic below could be tested on a host machine - and this is exactly the
// logic that needs testing. `notary_registry/registry.go` is the same split, for the same reason,
// and this file deliberately mirrors it rather than inventing a second shape.
//
// WHAT CONSENSUS DOES NOT COVER. `cre.ConsensusIdenticalAggregation` requires every DON node to
// produce a BYTE-IDENTICAL result, which protects against a rogue NODE. It cannot protect against a
// DECODER THAT IS WRONG THE SAME WAY EVERYWHERE: every node agrees, and they agree on the wrong set.
// Consensus covers the FETCH, not the MEANING - and the meaning lives here.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// ONE LIST PER DEPLOYMENT, MANY LISTS SUPPORTED. There is no such thing as "the" sanctions list:
// the US, the UK, the UN and the EU each publish their own, under their own law, in their own
// schema, with their own idea of what a row even is. A workflow hardwired to one of them is a
// workflow that has to be rewritten to serve anybody else - so the jurisdiction-specific parts are
// a DECLARED SPEC (see `sources`) and everything below it is shared.
//
// THE SIX AXES a register can differ on are TODO.md sec. 2.18cb's, written for notary registers and
// confirmed here against three real sanctions exports:
//
//	1. TRANSPORT   - all three serve a single bulk file over HTTPS. None needed the zip handling
//	                 `notary_registry` carries, so none is implemented (no-unreachable-code); a
//	                 source that needs it declares it in its own decoder.
//	2. FORMAT      - XML for all three. Only the decode step may care.
//	3. SCHEMA      - completely different in all three, down to what a ROW is. See each decoder.
//	4. LISTING SEMANTICS - the one that breaks designs. Declared per source, never inferred.
//	5. LANGUAGE/SCRIPT   - names are committed AS PUBLISHED; nothing here folds case or script.
//	6. AUTHENTICITY      - declared per source, and it decides whether the postman can ever be
//	                       removed for that jurisdiction (sec. 2.18bv). It is a per-country answer,
//	                       so some lists may be trustlessly anchorable and others not.
// ═════════════════════════════════════════════════════════════════════════════════════════════
//
// Nothing in this file touches the network, the CRE runtime, or a chain: stdlib plus keccak.
package main

import (
	"encoding/binary"
	"encoding/xml"
	"fmt"
	"sort"

	"github.com/ethereum/go-ethereum/crypto"
)

// ═══════════════════════════════════════════════════════════════════
//  The canonical row every decoder produces
// ═══════════════════════════════════════════════════════════════════

// SubjectKind is what a listed row is ABOUT. Declared per source from that source's own vocabulary,
// never inferred from a name or guessed from a field's absence - the same fail-closed rule
// `notary_registry`'s status vocabulary follows, and for the same reason: a wrong mapping is silent.
type SubjectKind string

const (
	KindIndividual SubjectKind = "individual"
	KindEntity     SubjectKind = "entity"
	KindVessel     SubjectKind = "vessel"
	KindAircraft   SubjectKind = "aircraft"
)

// ListedSubject is ONE PUBLISHED ROW, canonicalised - not one person. The distinction is the whole
// reason this type exists rather than a per-source struct reaching the leaf directly:
//
//   - OFAC publishes one row per designation, with aliases nested inside it.
//   - OFSI publishes one row PER ALIAS, so a single designation appears several times under one
//     `UKSanctionsListRef` (measured: 19,761 rows carry only 5,135 distinct refs).
//
// A design that assumed "row == subject == unique reference" - which the US export happens to
// satisfy - collapses on the UK's the moment it is pointed at it.
type ListedSubject struct {
	// Reference is the source's OWN identifier for the listing, as published. Never our own
	// numbering: a row number is not stable across refreshes, and a name is not stable at all
	// (transliteration and alias ordering both vary).
	Reference string

	Kind SubjectKind

	// NameParts are the source's name fields IN ITS OWN ORDER AND ARITY, uncombined. They are not
	// joined into one string anywhere, because joining is what makes a leaf ambiguous - see
	// leafHash.
	NameParts []string
}

// ═══════════════════════════════════════════════════════════════════
//  Per-source declaration
// ═══════════════════════════════════════════════════════════════════

// ListingSemantics answers "what does this export say about someone who is NO LONGER listed?" -
// TODO.md sec. 2.18cb axis 4, which is the axis that decides whether DELISTING can be proven at all.
type ListingSemantics int

const (
	// membershipMeansListed: the export contains exactly those currently designated, and carries no
	// status field. Presence is provable against a Merkle root; ABSENCE IS NOT (sec. 2.18bp), so
	// "this person was removed" cannot be proven to this anchor by any proof. All three sources
	// declared below are this family - measured, not assumed.
	membershipMeansListed ListingSemantics = iota + 1

	// statusField: rows carry their own status, so delisting is a PRESENCE claim about a row whose
	// status says so - and therefore provable. No source here uses it yet; the constant exists
	// because the declaration must be able to express it, and a source that has one must say so.
	statusField

	// separateDelistingFeed: removals live in a second document, which must be fetched and pinned as
	// of the same instant as the first. OFAC and the UN both publish one; neither is anchored here.
	separateDelistingFeed
)

// Authenticity is axis 6: what, if anything, lets a verifier believe the bytes came from the
// authority rather than from whoever fetched them.
type Authenticity int

const (
	// authenticityTransportOnly: the publisher signs nothing. The only authenticity is the TLS
	// session the DON node itself opened, which the node cannot prove to anyone afterwards - so the
	// snapshot rests on DON honesty, and the postman CANNOT be removed for this source
	// (sec. 2.18bv/2.18br). This is not a claim that no signed artifact exists anywhere; it records
	// that the published export we fetch is unsigned and that nobody has found a detached signature
	// beside it. Finding one is a change to this field, not to any code.
	authenticityTransportOnly Authenticity = iota + 1

	// authenticityDetachedSignature: a `.p7s`/CMS or XAdES artifact is published alongside, so the
	// authority's own signature can be verified in-workflow and the trust in the DON drops to
	// liveness only.
	authenticityDetachedSignature
)

// SourceSpec is the whole per-jurisdiction declaration. Adding a country means adding an entry
// here plus a decoder - never editing the shared code below it.
type SourceSpec struct {
	// Key is the registry key. `registryIDFor` hashes it into the `registryId` that
	// RegistrySourceAnchor stores snapshots under, and leafHash binds it into every leaf.
	Key string

	// Decode maps the published bytes to canonical rows. It must be a pure function of its input:
	// two DON nodes handed identical bytes must produce an identical slice, in an identical order.
	Decode func(body []byte) ([]ListedSubject, error)

	Listing      ListingSemantics
	Authenticity Authenticity

	// ReferenceIdentifiesRow records whether the source's own identifier is unique across rows. It
	// is checked, not trusted: a source that declares uniqueness and stops honouring it has changed
	// what a row MEANS, and that must fail loudly rather than silently collapse two designations.
	ReferenceIdentifiesRow bool

	// PublishedAt documents where the export lives. It is NOT fetched from here - the operator
	// supplies the URL in config, because a hardcoded endpoint is a hardcoded dependency on one
	// publisher's URL scheme surviving. Kept so the two can be compared by a human.
	PublishedAt string
}

// sources is the declared roster. EVERY FIELD OF EVERY ENTRY WAS READ OFF THE REAL EXPORT on
// 2026-08-02, not off documentation of it - `notary_registry` shipped a guessed schema in which
// every single tag was wrong and the parse yielded ZERO rows (sec. 2.18ce), and the guess had been
// taken from third-party descriptions exactly like the ones available for these three.
//
// UNDECLARED MEANS UNPUBLISHABLE. `sourceFor` refuses a key that is not here, and refuses an entry
// whose semantics fields are unset - sec. 2.18cb's rule, which exists because a list published
// without declaring what its absences mean silently gives the weaker guarantee everywhere.
var sources = map[string]SourceSpec{
	// UNITED STATES - OFAC Specially Designated Nationals.
	// Measured 2026-08-02 on the 2026-07-29 publication: 19,181 entries, `uid` unique across all of
	// them, sdnType in {Entity 9840, Individual 7473, Vessel 1524, Aircraft 344}, `lastName` present
	// on every row, `firstName` on exactly the 7,473 Individuals.
	"OFAC_SDN": {
		Key:                    "OFAC_SDN",
		Decode:                 decodeOFACSDN,
		Listing:                membershipMeansListed,
		Authenticity:           authenticityTransportOnly,
		ReferenceIdentifiesRow: true,
		PublishedAt:            "https://sanctionslistservice.ofac.treas.gov/api/PublicationPreview/exports/SDN.XML",
	},

	// UNITED KINGDOM - OFSI consolidated list of financial sanctions targets.
	// Measured 2026-08-02: 19,761 rows carrying 5,135 distinct designations, because each alias is
	// its own row (AliasType: AKA 7,700 / Primary name 6,240 / Primary name variation 5,794 /
	// FKA 27). GroupTypeDescription in {Individual 13863, Entity 5817, Ship 81}. Only 13,865 of the
	// 19,761 rows are distinct once decoded, so DEDUPLICATION IS LOAD-BEARING HERE, not a
	// precaution: ~5,900 rows repeat a designation's name set exactly, and equal neighbours would
	// fail the contract's strict-ascent rule.
	"UK_OFSI_CONSOLIDATED": {
		Key:                    "UK_OFSI_CONSOLIDATED",
		Decode:                 decodeUKOFSI,
		Listing:                membershipMeansListed,
		Authenticity:           authenticityTransportOnly,
		ReferenceIdentifiesRow: false,
		PublishedAt:            "https://ofsistorage.blob.core.windows.net/publishlive/2022format/ConList.xml",
	},

	// UNITED NATIONS - Security Council consolidated list.
	// Measured 2026-08-02: 736 individuals + 275 entities, DATAID unique within each. The KIND is
	// carried STRUCTURALLY - by which container a row sits in - not by any field on the row, which
	// is why `Decode` cannot be a single generic element walk.
	"UN_SC_CONSOLIDATED": {
		Key:                    "UN_SC_CONSOLIDATED",
		Decode:                 decodeUNConsolidated,
		Listing:                membershipMeansListed,
		Authenticity:           authenticityTransportOnly,
		ReferenceIdentifiesRow: true,
		PublishedAt:            "https://scsanctions.un.org/resources/xml/en/consolidated.xml",
	},
}

// sourceFor resolves a declared source, fail-closed on both counts sec. 2.18cb names.
func sourceFor(registryKey string) (SourceSpec, error) {
	spec, ok := sources[registryKey]
	if !ok {
		return SourceSpec{}, fmt.Errorf(
			"no source declared for registry %q - a sanctions list's schema, its listing semantics "+
				"and its authenticity are per-jurisdiction facts that must be read off the real "+
				"export and declared in `sources` before it can publish", registryKey)
	}
	// A spec is a literal in this file, so an unset field means someone added an entry without
	// answering these questions. Publishing anyway would anchor a list while nobody has said what
	// its absences mean - which is precisely the silent, plausible-looking wrong answer a guard is
	// for. It cannot be reached from outside this package's own source, and that is the point.
	if spec.Listing == 0 || spec.Authenticity == 0 {
		return SourceSpec{}, fmt.Errorf(
			"source %q declares no listing semantics or no authenticity - refusing to publish a list "+
				"whose absences and provenance are undefined", registryKey)
	}
	if spec.Decode == nil {
		return SourceSpec{}, fmt.Errorf("source %q declares no decoder", registryKey)
	}
	return spec, nil
}

func registryIDFor(registryKey string) [32]byte {
	return crypto.Keccak256Hash([]byte(registryKey))
}

// decodeSubjects runs a source's decoder and enforces what the source claims about itself.
func decodeSubjects(registryKey string, body []byte) ([]ListedSubject, error) {
	spec, err := sourceFor(registryKey)
	if err != nil {
		return nil, err
	}

	subjects, err := spec.Decode(body)
	if err != nil {
		return nil, err
	}
	if len(subjects) == 0 {
		// Publishing an empty root would silently clear the anchored set, and an empty parse is far
		// more likely to be schema drift than a genuinely empty sanctions list. Loud beats plausible.
		return nil, fmt.Errorf("%s decoded 0 rows - refusing to publish an empty snapshot", registryKey)
	}

	if spec.ReferenceIdentifiesRow {
		seen := make(map[string]struct{}, len(subjects))
		for _, s := range subjects {
			if _, dup := seen[s.Reference]; dup {
				return nil, fmt.Errorf(
					"%s declares its reference unique but %q appears twice - the export has changed "+
						"what a row means, and continuing would merge two designations into one leaf",
					registryKey, s.Reference)
			}
			seen[s.Reference] = struct{}{}
		}
	}

	for _, s := range subjects {
		if s.Reference == "" {
			return nil, fmt.Errorf("%s produced a row with no reference - it could never be cited", registryKey)
		}
	}
	return subjects, nil
}

// ═══════════════════════════════════════════════════════════════════
//  Leaves
// ═══════════════════════════════════════════════════════════════════

// leafHash commits to the registry, the reference, the kind and every name part UNAMBIGUOUSLY.
//
// EVERY COMPONENT IS HASHED FIRST, so each is fixed-width and no boundary can be re-split. A bare
// concatenation with a delimiter - which is what this workflow shipped with, `uid + "|" + name` -
// hashes reference "12" with name "3X" identically to reference "123" with name "X", and forbids
// the delimiter from ever appearing inside a name. `notary_registry` had the same defect and fixed
// it the same way (sec. 2.18ao); the argument that real data never collides is an argument about
// TODAY'S DATA, not about the construction.
//
// THE PART COUNT IS COMMITTED TOO, in four fixed bytes, because arity varies BY SOURCE: three name
// parts and six name parts must not be able to collide by padding one with empties.
//
// THE REGISTRY KEY IS IN THE LEAF, which is what stops a leaf from one list being replayed as proof
// of listing on another. Without it, a UK row and a US row describing the same person hash
// identically, and a proof against the UK root would satisfy a check written against the US one.
func leafHash(registryKey string, s ListedSubject) [32]byte {
	parts := make([]byte, 0, 32*(3+len(s.NameParts))+4)
	parts = append(parts, crypto.Keccak256([]byte(registryKey))...)
	parts = append(parts, crypto.Keccak256([]byte(s.Reference))...)
	parts = append(parts, crypto.Keccak256([]byte(s.Kind))...)

	var count [4]byte
	binary.BigEndian.PutUint32(count[:], uint32(len(s.NameParts)))
	parts = append(parts, count[:]...)

	for _, p := range s.NameParts {
		parts = append(parts, crypto.Keccak256([]byte(p))...)
	}
	return crypto.Keccak256Hash(parts)
}

// snapshotLeaves produces exactly the array to hand to RegistrySourceAnchor: hashed, deduplicated,
// strictly ascending.
//
// SORTING IS NOT COSMETIC. `RegistrySourceAnchor._computeRoot` REVERTS with
// `LeavesNotStrictlySorted` on anything else, so an unsorted array is not a slow path or an untidy
// one - it is a workflow that can never publish at all. This workflow shipped that way: it sorted
// its ENTRIES by uid and then mapped them to hashes, which are in no particular order.
//
// DEDUPLICATION is required by the same rule from the other side: equal neighbours are not strict
// ascent, so a single duplicated row upstream would make the whole snapshot unpublishable. Two
// identical rows carry no more information than one, and the UK export - one row per alias - makes
// exact duplicates ordinary rather than exceptional.
func snapshotLeaves(registryKey string, subjects []ListedSubject) [][32]byte {
	leaves := make([][32]byte, 0, len(subjects))
	seen := make(map[[32]byte]struct{}, len(subjects))

	for _, s := range subjects {
		leaf := leafHash(registryKey, s)
		if _, dup := seen[leaf]; dup {
			continue
		}
		seen[leaf] = struct{}{}
		leaves = append(leaves, leaf)
	}

	sort.Slice(leaves, func(i, j int) bool { return bytesLess(leaves[i], leaves[j]) })
	return leaves
}

func bytesLess(a, b [32]byte) bool {
	for i := range a {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

// ═══════════════════════════════════════════════════════════════════
//  Merkle root - the exact algorithm RegistrySourceAnchor._computeRoot implements
// ═══════════════════════════════════════════════════════════════════

// merkleRoot mirrors the contract line for line: strict-ascent check, sorted-pair internal nodes
// (so proofs carry no direction bits), odd node promoted unchanged.
//
// IT ENFORCES THE ORDERING RATHER THAN IMPOSING IT, which is the difference that matters. A version
// that sorted internally would compute a root the contract could not reproduce from the same array,
// and the disagreement would surface as a revert at publish time with nothing pointing back here.
// Failing on the same condition, in the same place, is what keeps the two implementations honest.
func merkleRoot(leaves [][32]byte) ([32]byte, error) {
	if len(leaves) == 0 {
		// `_computeRoot` reverts EmptyLeafSet; there is no root to agree on.
		return [32]byte{}, fmt.Errorf("empty leaf set")
	}
	for i := 1; i < len(leaves); i++ {
		if !bytesLess(leaves[i-1], leaves[i]) {
			return [32]byte{}, fmt.Errorf(
				"leaves are not strictly ascending at index %d - RegistrySourceAnchor would revert "+
					"LeavesNotStrictlySorted", i)
		}
	}

	level := make([][32]byte, len(leaves))
	copy(level, leaves)

	for len(level) > 1 {
		next := make([][32]byte, 0, (len(level)+1)/2)
		for i := 0; i < len(level); i += 2 {
			if i+1 == len(level) {
				next = append(next, level[i]) // odd one out, carried up unchanged
				continue
			}
			next = append(next, hashSortedPair(level[i], level[i+1]))
		}
		level = next
	}
	return level[0], nil
}

// hashSortedPair orders the pair before hashing, so a proof does not need to carry direction bits -
// matching OpenZeppelin's MerkleProof and `RegistrySourceAnchor._hashSortedPair`.
func hashSortedPair(a, b [32]byte) [32]byte {
	if bytesLess(b, a) {
		a, b = b, a
	}
	return crypto.Keccak256Hash(a[:], b[:])
}

// ═══════════════════════════════════════════════════════════════════
//  UNITED STATES - OFAC SDN
// ═══════════════════════════════════════════════════════════════════

// ofacEntry is one designation. Verified against the real SDN.XML (2026-07-29 publication).
type ofacEntry struct {
	UID       string `xml:"uid"`
	FirstName string `xml:"firstName"`
	LastName  string `xml:"lastName"`
	SDNType   string `xml:"sdnType"`
}

// ofacList - note `publshInformation`: the missing "i" is Treasury's own, present in the published
// file. Spelling it correctly here would silently decode a zero Record_Count and disable the
// cross-check below.
//
// The document carries a default namespace. Go's encoding/xml matches on local name when the struct
// tag names no namespace, so these tags bind correctly - verified by decoding the real file, not
// assumed from the rule.
type ofacList struct {
	XMLName     xml.Name    `xml:"sdnList"`
	PublishDate string      `xml:"publshInformation>Publish_Date"`
	RecordCount int         `xml:"publshInformation>Record_Count"`
	Entries     []ofacEntry `xml:"sdnEntry"`
}

// ofacKinds is the declared vocabulary. An UNKNOWN sdnType is an ERROR, not a skip: OFAC adding a
// fifth type is exactly how a silent under-count arrives, and under-counting is the dangerous
// direction for a sanctions list - it omits someone who IS designated while the snapshot still
// looks complete.
var ofacKinds = map[string]SubjectKind{
	"Individual": KindIndividual,
	"Entity":     KindEntity,
	"Vessel":     KindVessel,
	"Aircraft":   KindAircraft,
}

func decodeOFACSDN(body []byte) ([]ListedSubject, error) {
	var list ofacList
	if err := xml.Unmarshal(body, &list); err != nil {
		return nil, fmt.Errorf("OFAC SDN parse: %w", err)
	}

	// THE EXPORT DECLARES ITS OWN LENGTH, so schema drift that drops rows is detectable without any
	// external reference point. This is the only one of the three sources that offers it, and it is
	// the single strongest anti-rot guard available anywhere in this file.
	if list.RecordCount != len(list.Entries) {
		return nil, fmt.Errorf(
			"OFAC SDN declares Record_Count %d but %d sdnEntry elements decoded - refusing to publish "+
				"a snapshot that disagrees with its own manifest",
			list.RecordCount, len(list.Entries))
	}

	subjects := make([]ListedSubject, 0, len(list.Entries))
	for _, e := range list.Entries {
		kind, known := ofacKinds[e.SDNType]
		if !known {
			return nil, fmt.Errorf(
				"OFAC SDN uid %q has unrecognised sdnType %q - declare it in ofacKinds rather than "+
					"defaulting, because guessing wrong drops a designated party from the snapshot",
				e.UID, e.SDNType)
		}
		// Both name fields always, in published order, even when empty: entities carry only
		// lastName, and a fixed arity is what keeps the two shapes from colliding.
		subjects = append(subjects, ListedSubject{
			Reference: e.UID,
			Kind:      kind,
			NameParts: []string{e.LastName, e.FirstName},
		})
	}
	return subjects, nil
}

// ═══════════════════════════════════════════════════════════════════
//  UNITED KINGDOM - OFSI consolidated list
// ═══════════════════════════════════════════════════════════════════

// ukTarget is ONE ALIAS ROW, not one designation - see ListedSubject's note. Tag names are
// case-sensitive and OFSI's own casing is inconsistent (`name1`..`name5` lowercase, `Name6`
// capitalised); these are copied from the published file rather than normalised.
//
// `GroupID` IS THE KEY, NOT `UKSanctionsListRef` - and that is a measurement, not a preference.
// The obvious choice is the FCDO reference, because it is the citable one ("GHR0086"). Over the
// 2026-08-02 export:
//
//   - `UKSanctionsListRef` is EMPTY on one row of 19,761 - Alexander SAMOFAL, a real individual
//     designated 2023-04-21 under Global Human Rights. Keying on it makes that person unanchorable
//     and, because a row with no reference is refused, takes the ENTIRE UK snapshot down with them.
//   - `GroupID` is present and non-empty on all 19,761 rows.
//   - They agree about grouping: 5,135 distinct values each, and NO GroupID spans more than one
//     reference. So nothing is lost by preferring the one that is always there.
//
// This is the whole argument for fetching the real file. Both fields look equally good in a schema
// description, an excerpt, or any fixture small enough to read - the difference is one row in
// twenty thousand, and it decides whether the list can be published at all.
type ukTarget struct {
	Name1     string `xml:"name1"`
	Name2     string `xml:"name2"`
	Name3     string `xml:"name3"`
	Name4     string `xml:"name4"`
	Name5     string `xml:"name5"`
	Name6     string `xml:"Name6"`
	GroupType string `xml:"GroupTypeDescription"`
	GroupID   string `xml:"GroupID"`
	AliasType string `xml:"AliasType"`
}

type ukConsolidatedList struct {
	XMLName xml.Name   `xml:"ArrayOfFinancialSanctionsTarget"`
	Targets []ukTarget `xml:"FinancialSanctionsTarget"`
}

var ukKinds = map[string]SubjectKind{
	"Individual": KindIndividual,
	"Entity":     KindEntity,
	"Ship":       KindVessel,
}

func decodeUKOFSI(body []byte) ([]ListedSubject, error) {
	var list ukConsolidatedList
	if err := xml.Unmarshal(body, &list); err != nil {
		return nil, fmt.Errorf("UK OFSI parse: %w", err)
	}

	subjects := make([]ListedSubject, 0, len(list.Targets))
	for _, t := range list.Targets {
		kind, known := ukKinds[t.GroupType]
		if !known {
			return nil, fmt.Errorf(
				"UK OFSI group %q has unrecognised GroupTypeDescription %q - declare it in ukKinds "+
					"rather than defaulting", t.GroupID, t.GroupType)
		}
		// ALL SIX PARTS, ALWAYS, IN PUBLISHED ORDER. Dropping the empties would let "Rudi" in slot 1
		// and "Rudi" in slot 2 produce the same leaf, and OFSI genuinely moves a name between slots
		// between alias rows of one designation (IRQ0140 does exactly that in the committed
		// fixture). Aliases are NOT collapsed: each published row is a distinct fact about which
		// spelling is sanctioned, and collapsing them would discard the only thing a screening
		// system matches on.
		subjects = append(subjects, ListedSubject{
			Reference: t.GroupID,
			Kind:      kind,
			NameParts: []string{t.Name1, t.Name2, t.Name3, t.Name4, t.Name5, t.Name6},
		})
	}
	return subjects, nil
}

// ═══════════════════════════════════════════════════════════════════
//  UNITED NATIONS - Security Council consolidated list
// ═══════════════════════════════════════════════════════════════════

// unRecord serves both containers: the UN's individual and entity rows share these fields, and the
// KIND comes from WHICH CONTAINER the row was in rather than from any field on it. That is a third
// way of encoding subject kind - after OFAC's `sdnType` field and OFSI's
// `GroupTypeDescription` - and it is why `Decode` is a per-source function rather than a table.
type unRecord struct {
	DataID     string `xml:"DATAID"`
	FirstName  string `xml:"FIRST_NAME"`
	SecondName string `xml:"SECOND_NAME"`
	ThirdName  string `xml:"THIRD_NAME"`
	FourthName string `xml:"FOURTH_NAME"`
}

type unConsolidatedList struct {
	XMLName     xml.Name   `xml:"CONSOLIDATED_LIST"`
	Individuals []unRecord `xml:"INDIVIDUALS>INDIVIDUAL"`
	Entities    []unRecord `xml:"ENTITIES>ENTITY"`
}

func decodeUNConsolidated(body []byte) ([]ListedSubject, error) {
	var list unConsolidatedList
	if err := xml.Unmarshal(body, &list); err != nil {
		return nil, fmt.Errorf("UN consolidated parse: %w", err)
	}

	subjects := make([]ListedSubject, 0, len(list.Individuals)+len(list.Entities))
	// Individuals first, then entities - document order within each. Deterministic because the input
	// bytes are, which is the only property consensus needs (see main.go's note on why nothing here
	// re-sorts the rows).
	for _, r := range list.Individuals {
		subjects = append(subjects, unSubject(r, KindIndividual))
	}
	for _, r := range list.Entities {
		// An entity's name arrives in FIRST_NAME with the rest empty - the same fixed arity as an
		// individual, so the two cannot collide across kinds even before the kind is hashed in.
		subjects = append(subjects, unSubject(r, KindEntity))
	}
	return subjects, nil
}

func unSubject(r unRecord, kind SubjectKind) ListedSubject {
	return ListedSubject{
		Reference: r.DataID,
		Kind:      kind,
		NameParts: []string{r.FirstName, r.SecondName, r.ThirdName, r.FourthName},
	}
}
