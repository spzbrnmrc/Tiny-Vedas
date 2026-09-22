# Paper LaTeX

Local-only tree (`paper/` is gitignored). Plan and locked numbers:
`PAPER.md`. Do not invent metrics.

## Targets

| Make | Venue | Class | Body limit |
|------|--------|--------|------------|
| `make` / `make asplos` | **ASPLOS 2027** (default conference) | `acmart` `sigplan,anonymous,review,nonacm` | **11 pages** (CFP). Refs + appendix free. |
| `make arxiv` | arXiv v0 (after one-cluster YOLO on the card) | `acmart` `sigplan,nonacm,authorversion,screen` | Longer OK; appendix in the same PDF. |
| `make mlsys` | MLSys 2027 (same default submit as ASPLOS) | official `mlsys2025` kit | **10 pages**. Appendix is a **separate** upload. |
| `make mlsys-appendix` | MLSys appendix PDF | same kit | Unlimited; reviewers need not read it. |

ASPLOS'27 also does a **rapid review of the first two pages only**.
Keep §1 self-contained. Do not squeeze the ACM template.

ASPLOS’27 CFP is **11 pages** of body. Budget for 11.

PDFs land in `build/<target>/`.

```bash
cd paper
make            # ASPLOS skeleton
make all        # every target
make arxiv-bundle
```

## Layout

```
paper/
  asplos/main.tex          # conference wrapper
  arxiv/main.tex           # author-visible preprint
  mlsys/main.tex           # 10-page main
  mlsys/appendix.tex       # separate appendix upload
  content/                 # shared body (one outline)
  bib/refs.bib
  vendor/acmart/           # CTAN acmart 2.20 + ACM-Reference-Format
  vendor/mlsys/            # official mlsys2025style.zip
  figures/                 # art later; captions already reserved
```

Shared outline:

1. Introduction — JIT places; SoC is the backend
2. Background — two tilings
3. IR and ABI
4. Placement
5. Backend
6. Implementation — locked numbers only
7. Evaluation — T1–T5 empty
8. Related work
9. Conclusion

Figure/table IDs F1–F6 and T1–T5 are already in the source.

**Visible text is for a reader.** Status, venue gates, forbidden
claims, and numbers still to measure live in comments in
`content/*.tex`. Read those comments before editing the draft.

## Before a real submit

- Author is Marco Spaziani Brunella / Siliscale (`content/authors-*.tex`).
- Fill `---` table cells from logs. Locked numbers live in `PAPER.md` (Status).
- Title stays the JIT title unless opportunistic L2/HBM + PD data steal it.
- ASPLOS: first two pages must survive a reader who stops there.
- Full names in every `.bib` entry; no “et al.”
