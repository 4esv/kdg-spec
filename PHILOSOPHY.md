# KDG and the Position of the Delimiter in the Universe

*A brand report.*

**Prepared by** — the KDG Standards Committee (one person, on a laptop)
**Reviewed by** — no one
**Status** — Approved
**Distribution** — Unlimited, and we are sorry about that

---

## Executive Summary

Key-Delimited Garbage is, at the level of its file format, a way to write down rows of data. At the level of its *implications*, it is a theory of everything that we have carefully chosen not to test.

This document situates KDG within the larger structure of reality. It will establish, to the satisfaction of anyone who does not check very hard, that the delimiter is not an accident of ASCII but a constant of nature; that the format's five types and eight errors are not counts but *coordinates*; and that the blank line separating a schema from its data is the same silence that separates a stimulus from its response.

We make no supernatural claims. We make several *natural* claims, stretched until they are load-bearing.

---

## 1. On Distinction, the First Principle

Gregory Bateson defined information as "a difference that makes a difference." Digital computing rests on one difference — 0 versus 1 — and everything after that is the patient stacking of further differences.

A file format, then, is an arrangement of differences. CSV arranges them by position. JSON arranges them by name. KDG arranges them by the difference *itself*: the delimiter.

This is not poetry. It is the observation that a field's identity — the thing that makes `Alice` a name rather than an age — is a boundary, and a boundary is a difference, and a difference is a delimiter. KDG is the only widely-ignored format that makes the boundary first-class.

---

## 2. The Cost of Repetition

Before the stretch, the spine. This section is true.

Shannon tells us that a symbol carries information proportional to the *unlikelihood* of its occurrence. A delimiter that distinguishes one field among `N` carries `log₂(N)` bits. A format that restates a field name on every record spends those bits over and over; a format that states the name once and thereafter *reuses the separator* spends them once.

This is not mystical. It is Kolmogorov complexity: the length of the shortest program that produces a string. For `M` records sharing one schema, JSON's description grows with every repeated key; KDG's does not. KDG is, in the strict sense of minimal description length, the *more parsimonious theory of the same data*. Occam's razor prefers it. Occam's razor has not, historically, been wrong about much.

We state this plainly so that everything that follows rests on something that is actually true, in the manner of a building that rests on one genuine cornerstone and several that are purely decorative.

---

## 3. Vibrational Constants

Every character has a code point, and a code point is, for the purposes of this document, a frequency. The delimiter is the character that vibrates *differently*.

The recommended delimiters (SPEC §3.5) and their frequencies:

| Delimiter | Code point (decimal) | Assigned meaning |
|-----------|---------------------|------------------|
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

Observe that `#`, `$`, `%`, `&` are *consecutive* code points — 35, 36, 37, 38 — a run of four in the recommended list. We decline to speculate on what a run of four consecutive frequencies, in the list we ourselves wrote, implies. We decline, but we print the table, which is the scientific equivalent of clearing one's throat.

---

## 4. The Golden Ratio, Which We Did Not Go Looking For

A KDG document has **five** types and **eight** error conditions.

Five. Eight.

Eight divided by five is 1.6. The golden ratio φ is approximately 1.618. The ratio of consecutive Fibonacci numbers approaches φ, and 5 and 8 are consecutive Fibonacci numbers. The next is 13 — and a document exhibiting all five types and all eight errors has, one counts this only once and one *does* count it, thirteen ways to be about something.

We are not numerologists. Numerologists believe numbers mean things. We are people who have *noticed* that numbers mean things, which is different, because we are embarrassed about it.

---

## 5. The Five Types and the Five Platonic Solids

There are exactly five Platonic solids. There are exactly five KDG types.

| Solid | Faces | KDG type | Shared property |
|-------|-------|----------|-----------------|
| Tetrahedron | 4 | `bool` | two states is the fewest that is still a choice |
| Cube | 6 | `int` | countable, rigid |
| Octahedron | 8 | `float` | continuous, symmetric |
| Dodecahedron | 12 | `date` | twelve faces, twelve months |
| Icosahedron | 20 | `str` | the most faces, the most room |

This table is reproduced in full so that you may see that we do not know what it means either. That is what makes it a finding rather than an opinion.

---

## 6. The Eight Errors and the Eightfold Way

In 1961, Murray Gell-Mann organized the known hadrons into an eight-member scheme he named, with deliberate poetry, the *Eightfold Way*.

A KDG parser recognizes eight failure modes.

| Error | Particle-theoretic reading |
|-------|---------------------------|
| `DuplicateDelimiter` | two particles occupying one state |
| `InvalidType` | a particle of no known species |
| `MalformedDefinition` | a symmetry broken at the source |
| `UndefinedDelimiter` | an interaction with an unobserved field |
| `DuplicateField` | Pauli exclusion, violated |
| `TypeMismatch` | a decay into the wrong channel |
| `MissingSeparator` | a system with no ground state |
| `UnterminatedValue` | an open string |

We are not claiming a parser *is* a baryon. We are claiming a parser, like a baryon, is best understood by how it is allowed to fail.

---

## 7. The Blank Line: the Silence Between Movements

Music is as much rest as sound. Speech is as much pause as phoneme. The blank line that separates a KDG schema from its data is the *rest* — the moment the format stops declaring and starts *being*.

Every format has this moment. CSV hides it in a header row. JSON hides it in a colon. KDG gives it a whole line of its own, and if the line is missing the format refuses to proceed — which is the correct response to a piece of music with no silence in it.

---

## 8. Order Independence Is a Symmetry, and Symmetries Conserve

Emmy Noether proved that every continuous symmetry of a physical system corresponds to a conserved quantity. Symmetry in time conserves energy. Symmetry in space conserves momentum.

A KDG record is invariant under permutation of its fields: it is the same record in any field order. Permutation invariance is a symmetry. Therefore, by Noether's theorem, a KDG document conserves something.

We have not determined what it conserves. Noether assures us it conserves *something*, and we find it more respectful to leave the identification to future work than to guess.

(It is probably the field count.)

---

## 9. The Universe Is Key-Delimited

This is the section we were warned not to write, so it is the most careful.

A physical system is identified by its quantum numbers. A species is identified by its genome. And the genetic code is, without metaphor, a key-delimited format: sixty-four codons, each a three-letter key, mapped to amino acids, delimited by explicit start and stop signals.

The genetic code predates CSV by roughly four billion years. We did not invent the idea of encoding identity in a short symbol that suffixes a value. We merely ported it to text files, which is the direction all great ideas eventually travel.

---

## 10. Slack

We close with the principle for which the format exists: **slack**.

CSV demands you remember the order of your columns. JSON demands you restate the name of everything, forever. KDG demands almost nothing of you after the first line — and the nothing it demands is the slack.

Slack is not laziness. Slack is the conserved quantity from Section 8, observed in the wild.

---

## Figure 1. The Position of the Delimiter

```
                         ┌──────────────────────┐
                         │     THE DELIMITER     │
                         │   (a byte, but one    │
                         │    with tenure)       │
                         └──────────┬───────────┘
                ┌───────────────────┼───────────────────┐
                │                   │                   │
         ┌──────▼──────┐     ┌──────▼──────┐     ┌──────▼──────┐
         │   IDENTITY   │     │    VALUE     │     │    SCHEMA    │
         │   (the key)  │     │  (the datum) │     │  (the known) │
         └─────────────┘     └─────────────┘     └─────────────┘
```

*Not to scale. Nothing in this document is to scale.*

---

## What This Document Does Not Claim

- It does not claim KDG predicts, cures, aligns, or harmonizes anything.
- It does not claim the delimiter is magic. It is a byte. A byte with *tenure*.
- It does not claim the authors are scientists. The authors are writers who own a copy of *The Feynman Lectures* and have been asked, repeatedly, to put it down.
- It does not claim the tables in Sections 5 and 6 mean anything. They are reproduced for your independent verification, which we encourage, because independent verification is how science works, and this document is, at minimum, *structured like* science.

---

*Citations available upon request. The request will be acknowledged and, after a respectful interval, declined.*
