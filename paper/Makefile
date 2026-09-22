# Paper builds. Default = ASPLOS'27 (conference target).
#   make          -> asplos
#   make arxiv
#   make mlsys
#   make mlsys-appendix
#   make all
#   make arxiv-bundle   # source zip for arXiv upload

LATEX  := pdflatex -interaction=nonstopmode -halt-on-error -file-line-error
BIBTEX := bibtex
ROOT   := $(abspath .)
BUILD  := $(ROOT)/build

.PHONY: all asplos arxiv mlsys mlsys-appendix clean arxiv-bundle
.DEFAULT_GOAL := asplos

all: asplos arxiv mlsys mlsys-appendix

asplos:
	$(call latex-acm,asplos,asplos/main.tex)

arxiv:
	$(call latex-acm,arxiv,arxiv/main.tex)

mlsys:
	$(call latex-mlsys,mlsys,mlsys/main.tex)

mlsys-appendix:
	$(call latex-mlsys,mlsys-appendix,mlsys/appendix.tex)

define latex-acm
	mkdir -p $(BUILD)/$(1)
	cd $(BUILD)/$(1) && \
	  TEXINPUTS=$(ROOT)/vendor/acmart:$(ROOT)/content:$(ROOT)/figures:$(ROOT)/$(dir $(2)): \
	  BIBINPUTS=$(ROOT)/bib: \
	  BSTINPUTS=$(ROOT)/vendor/acmart: \
	  $(LATEX) $(ROOT)/$(2)
	cd $(BUILD)/$(1) && \
	  BSTINPUTS=$(ROOT)/vendor/acmart: \
	  BIBINPUTS=$(ROOT)/bib: \
	  $(BIBTEX) $(basename $(notdir $(2)))
	cd $(BUILD)/$(1) && \
	  TEXINPUTS=$(ROOT)/vendor/acmart:$(ROOT)/content:$(ROOT)/figures:$(ROOT)/$(dir $(2)): \
	  BIBINPUTS=$(ROOT)/bib: \
	  BSTINPUTS=$(ROOT)/vendor/acmart: \
	  $(LATEX) $(ROOT)/$(2)
	cd $(BUILD)/$(1) && \
	  TEXINPUTS=$(ROOT)/vendor/acmart:$(ROOT)/content:$(ROOT)/figures:$(ROOT)/$(dir $(2)): \
	  BIBINPUTS=$(ROOT)/bib: \
	  BSTINPUTS=$(ROOT)/vendor/acmart: \
	  $(LATEX) $(ROOT)/$(2)
	@echo "PDF: $(BUILD)/$(1)/$(basename $(notdir $(2))).pdf"
endef

define latex-mlsys
	mkdir -p $(BUILD)/$(1)
	cd $(BUILD)/$(1) && \
	  TEXINPUTS=$(ROOT)/vendor/mlsys:$(ROOT)/content:$(ROOT)/figures:$(ROOT)/$(dir $(2)): \
	  BIBINPUTS=$(ROOT)/bib: \
	  BSTINPUTS=$(ROOT)/vendor/mlsys: \
	  $(LATEX) $(ROOT)/$(2)
	cd $(BUILD)/$(1) && \
	  BSTINPUTS=$(ROOT)/vendor/mlsys: \
	  BIBINPUTS=$(ROOT)/bib: \
	  $(BIBTEX) $(basename $(notdir $(2)))
	cd $(BUILD)/$(1) && \
	  TEXINPUTS=$(ROOT)/vendor/mlsys:$(ROOT)/content:$(ROOT)/figures:$(ROOT)/$(dir $(2)): \
	  BIBINPUTS=$(ROOT)/bib: \
	  BSTINPUTS=$(ROOT)/vendor/mlsys: \
	  $(LATEX) $(ROOT)/$(2)
	cd $(BUILD)/$(1) && \
	  TEXINPUTS=$(ROOT)/vendor/mlsys:$(ROOT)/content:$(ROOT)/figures:$(ROOT)/$(dir $(2)): \
	  BIBINPUTS=$(ROOT)/bib: \
	  BSTINPUTS=$(ROOT)/vendor/mlsys: \
	  $(LATEX) $(ROOT)/$(2)
	@echo "PDF: $(BUILD)/$(1)/$(basename $(notdir $(2))).pdf"
endef

# arXiv wants a flat-ish source tree. This packs what the compiler needs.
arxiv-bundle: arxiv
	mkdir -p $(BUILD)/arxiv-src
	rsync -a --delete \
	  --exclude build --exclude '*.pdf' \
	  $(ROOT)/content $(ROOT)/bib $(ROOT)/figures $(ROOT)/vendor/acmart \
	  $(ROOT)/arxiv $(ROOT)/Makefile $(ROOT)/README.md \
	  $(BUILD)/arxiv-src/
	cd $(BUILD) && zip -r arxiv-source.zip arxiv-src
	@echo "ZIP: $(BUILD)/arxiv-source.zip"

clean:
	rm -rf $(BUILD)
