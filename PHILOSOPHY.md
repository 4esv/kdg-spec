# Key-Delimited Garbage: Design Rationale

**Status of this document**

This document is informational. It does not define the format. The normative definition is in [SPEC.md](./SPEC.md). This document records the reasoning that accompanied the design and the structural observations that the design produced.

---

## 1. Scope

This document describes the principles underlying the Key-Delimited Garbage (KDG) format.

Section 2 states the information-theoretic basis of the design. Sections 3 through 6 record correspondences between properties of the format and quantities that appear elsewhere in mathematics and physics. Sections 7 through 9 address the separator, the symmetry of the record, and biological precedent. Section 10 defines the operational concept of slack.

The correspondences recorded in Sections 4, 5, and 6 are illustrative. They are included because they are, in the strict sense, true. They carry no normative weight.

---

## 2. Information-Theoretic Basis

Information, in the sense of Bateson [1], is a difference that makes a difference. Shannon [2] formalized the information content of a symbol as a function of the probability of its occurrence.

In a KDG document, a field is identified by a delimiter drawn from a set of size *N*, where *N* is the number of defined fields. The delimiter therefore carries log₂(*N*) bits of information. A format that restates a field name on every record transmits those bits on every record. A format that states the name once and reuses the delimiter transmits them once.

For a schema applied to *M* records, KDG has a smaller description length than JSON under the minimum description length principle of Kolmogorov [3]. The key is stated once; the delimiter is reused thereafter.

This is the claim in this document that is both quantitative and entirely conventional.

---

## 3. Delimiter Selection and Character Encoding

A delimiter is a single character. Its identity is its code point in the character encoding in use. The recommended delimiters and their decimal code points are:

| Delimiter | Code point | Use |
|-----------|-----------|-----|
| `!` | 33 | alert |
| `#` | 35 | number |
| `$` | 36 | value |
| `%` | 37 | ratio |
| `&` | 38 | relation |
| `/` | 47 | path |
| `@` | 64 | identity |
| `^` | 94 | priority |
| `\|` | 124 | choice |
| `~` | 126 | description |

It is observed that the code points 35, 36, 37, and 38 are consecutive. No normative significance is attached to this observation. It is recorded because it is the kind of fact that a careful reader would otherwise later discover and overstate.

---

## 4. Numerical Structure of the Type and Error Systems

The specification defines five types and eight error conditions.

Five and eight are consecutive terms of the Fibonacci sequence; the next term is thirteen. The ratio of consecutive Fibonacci terms tends to the golden ratio, and 8/5 = 1.6 approximates 1.618.

No normative significance is attached to this correspondence. The type system has five members because that is the number of members it has, and the error taxonomy has eight members for the same reason. That the two counts are consecutive Fibonacci terms is an observation about the counts, not a property of the format.

---

## 5. Correspondence with the Platonic Solids

There are exactly five Platonic solids. The specification defines exactly five types. The correspondence is reproduced for reference:

| Solid | Faces | Type | Property shared |
|-------|-------|------|-----------------|
| Tetrahedron | 4 | `bool` | two states is the fewest that is still a choice |
| Cube | 6 | `int` | countable and rigid |
| Octahedron | 8 | `float` | continuous and symmetric |
| Dodecahedron | 12 | `date` | twelve faces, twelve months |
| Icosahedron | 20 | `str` | the most faces, the most room |

This correspondence is illustrative. It is not a mapping, and it is not a justification.

---

## 6. Correspondence with the Eightfold Classification

In 1961, Gell-Mann organized the known hadrons into a classification of eight members, named the Eightfold Way [5]. The specification defines eight error conditions. The correspondence is reproduced for reference:

| Error | Classification |
|-------|---------------|
| `DuplicateDelimiter` | two particles occupying one state |
| `InvalidType` | a particle of no known species |
| `MalformedDefinition` | a symmetry broken at the source |
| `UndefinedDelimiter` | an interaction with an unobserved field |
| `DuplicateField` | Pauli exclusion, violated |
| `TypeMismatch` | a decay into the wrong channel |
| `MissingSeparator` | a system with no ground state |
| `UnterminatedValue` | an open string |

This correspondence is illustrative. A parser is not a baryon. The comparison is to classification by failure mode, not to any physical claim.

---

## 7. The Separator as a Boundary Condition

A KDG document consists of a definition block and a data block, separated by a single blank line. The blank line is a boundary condition: it is the point at which the document stops declaring structure and starts containing values.

Formats differ in where they place this boundary. CSV places it in a header row. JSON places it in a delimiter within each value. KDG places it in a dedicated line, and the absence of that line is a well-defined error.

A boundary condition that cannot be absent is not a boundary condition; it is a convention.

---

## 8. Symmetry and Conservation

Noether's theorem [4] states that every continuous symmetry of a physical system corresponds to a conserved quantity. Symmetry in time conserves energy; symmetry in space conserves momentum.

A KDG record is invariant under permutation of its fields. Permutation invariance is a symmetry. By Noether's theorem, a KDG document conserves some quantity.

The identification of that quantity is left to further work. It is likely the field count.

---

## 9. Biological Precedent

The genetic code maps sixty-four codons, each a sequence of three nucleotides, to amino acids, with explicit start and stop signals delimiting the translation [7]. A codon is a short symbol that identifies a value. The start and stop signals are delimiters. The genetic code is, without metaphor, a key-delimited format.

The genetic code predates the first text serialization format by approximately four billion years. KDG does not claim priority.

---

## 10. Slack

Slack is the operational property that a format demands as little as possible of its producer after the initial declaration of structure.

CSV requires the producer to remember the order of columns. JSON requires the producer to restate the name of every field on every record. KDG requires neither.

Slack is defined here because it is the property the design was intended to maximize, and because defining it permits it to be referenced in later documents.

---

## References

[1] Bateson, Gregory. *Steps to an Ecology of Mind*. 1972.

[2] Shannon, Claude E. "A Mathematical Theory of Communication." *Bell System Technical Journal*. 1948.

[3] Kolmogorov, Andrey N. "Three approaches to the quantitative definition of information." *Problems of Information Transmission* 1(1). 1965.

[4] Noether, Emmy. "Invariante Variationsprobleme." *Nachrichten von der Königlichen Gesellschaft der Wissenschaften zu Göttingen*. 1918.

[5] Gell-Mann, Murray. "The Eightfold Way: A Theory of Strong Interaction Symmetry." CTSL-20. 1961.

[6] Bradner, Scott. "Key words for use in RFCs to Indicate Requirement Levels." RFC 2119. 1997.

[7] Crick, Francis H. C., et al. "General Nature of the Genetic Code for Proteins." *Nature* 192. 1961.
