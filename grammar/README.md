# Grammar Artifacts

## ISO/IEC 39075 BNF Grammar

### Provenance

The ISO/IEC 39075 BNF grammar is a digital artifact published by ISO and available at:
- https://standards.iso.org/iso-iec/39075/ed-1/en/ISO_IEC_39075(en).bnf.txt

**Permitted Use:**
> This file is a "digital artifact" that contains the grammar specified by ISO/IEC 39075.
> 
> This grammar may be used by implementers of GQL-implementations when generating parsers for the 
> GQL language.

### Vendoring

The file `ISO_IEC_39075.bnf.txt` is a vendored copy of the ISO artifact. **It is never hand-edited** — updates must always be fetched from the upstream source using the make targets below.

### Maintaining the Vendored Copy

To refresh the vendored grammar from upstream:
```bash
make grammar-fetch
```

To verify the vendored grammar matches the current upstream artifact (without updating):
```bash
make grammar-check-upstream
```

This check is useful for CI pipelines to detect upstream changes and alert the team when the grammar drifts.

### Supplementary Grammars

The `geode.bnf` file (created separately) is a supplementary extension grammar written in the same BNF notation as ISO/IEC 39075. It extends the base GQL language with Geode-specific constructs for graph querying and manipulation.
